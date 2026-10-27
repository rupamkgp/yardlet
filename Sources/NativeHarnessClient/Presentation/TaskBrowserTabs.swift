import Foundation
import Observation

/// One of a task's browser tabs as the task keeps it between Yardlet's runs: the page it showed and
/// the page's title, under the side-panel tab's key (`BrowserTab.key`).
struct BrowserTabPage: Codable, Equatable, Sendable {
    var key: UUID
    var address: String
    var title: String
}

/// A task's browser tabs as its side panel shows them, each a side-panel tab of its own as in the Codex
/// app: the page and title of each, saved with the task, and while the browser has the tab, its icon
/// and whether it loads. The browser engine's tabs fill it in (`TaskWorkspaceState.syncBrowserTabs`);
/// a build without the engine keeps a WebKit preview page per tab here instead.
@MainActor @Observable
final class TaskBrowserTabs {
    struct Tab: Equatable {
        var address = ""
        var title = ""
        /// PNG; never saved, so a tab shows its globe until its page loads again.
        var favicon: Data?
        var isLoading = false
    }

    private(set) var tabs: [UUID: Tab]
    /// The build without the browser engine: each tab's WebKit page, which owns the page's state.
    @ObservationIgnored private var previews: [UUID: BrowserPreviewModel] = [:]
    @ObservationIgnored var onChange: (() -> Void)?

    init(pages: [BrowserTabPage] = []) {
        tabs = Dictionary(pages.map { ($0.key, Tab(address: $0.address, title: $0.title)) }) { first, _ in first }
    }

    func tab(_ key: UUID) -> Tab? { tabs[key] }

    /// What the browser reports of its tab `key`; a nil address keeps the page last shown.
    func update(_ key: UUID, address: String?, title: String, favicon: Data?, isLoading: Bool) {
        var tab = tabs[key] ?? Tab()
        if let address, !address.isEmpty, address != "about:blank" { tab.address = address }
        tab.title = title
        tab.favicon = favicon
        tab.isLoading = isLoading
        guard tab != tabs[key] else { return }
        let saved = tabs[key].map { ($0.address, $0.title) }
        tabs[key] = tab
        if saved.map({ $0 != (tab.address, tab.title) }) ?? true { onChange?() }
    }

    /// A new tab's page before the browser opens it (a duplicate, a link from the conversation).
    func setAddress(_ address: String, for key: UUID) {
        guard tabs[key]?.address != address else { return }
        tabs[key, default: Tab()].address = address
        onChange?()
    }

    /// The tabs closed: their pages and, in the build without the engine, their WebKit pages go.
    func remove(_ keys: some Sequence<UUID>) {
        var changed = false
        for key in keys {
            changed = tabs.removeValue(forKey: key) != nil || changed
            previews.removeValue(forKey: key)?.terminateForApplicationShutdown()
        }
        if changed { onChange?() }
    }

    /// The pages of the panel's browser tabs, in the panel's order, for the task's snapshot. The page
    /// used last and, with several, every page and the one used last also go where a build before
    /// side-panel browser tabs reads them.
    func preferences(order: [UUID], latest: UUID?) -> BrowserPreviewPreferences? {
        let pages = order.map { key in
            BrowserTabPage(key: key, address: tabs[key]?.address ?? "", title: tabs[key]?.title ?? "")
        }
        guard !pages.isEmpty else { return nil }
        let shown = pages.filter { !$0.address.isEmpty }
        let latestAddress = latest.flatMap { tabs[$0]?.address } ?? ""
        return BrowserPreviewPreferences(
            address: latestAddress.isEmpty ? shown.last?.address ?? "" : latestAddress,
            tabs: shown.count > 1 ? shown.map(\.address) : nil,
            selectedTab: shown.count > 1 ? shown.firstIndex { $0.key == latest } ?? 0 : nil,
            pages: pages)
    }

    // MARK: The build without the browser engine

    /// The WebKit page of tab `key`, made at its saved address the first time it shows.
    func preview(for key: UUID) -> BrowserPreviewModel {
        if let preview = previews[key] { return preview }
        let preview = BrowserPreviewModel(preferences: .init(address: tabs[key]?.address ?? ""))
        preview.onChange = { [weak self, weak preview] in
            guard let self, let preview else { return }
            self.update(key, address: preview.address, title: preview.title, favicon: nil, isLoading: preview.isLoading)
        }
        previews[key] = preview
        return preview
    }

    func terminateForApplicationShutdown() {
        for preview in previews.values { preview.terminateForApplicationShutdown() }
    }
}

extension BrowserPreviewPreferences {
    /// The pages of a task saved before each browser tab was a side-panel tab of its own, as
    /// side-panel tabs with new keys, and which was in front.
    var legacyPages: (pages: [BrowserTabPage], fronted: Int) {
        let addresses = tabs.flatMap { $0.isEmpty ? nil : $0 } ?? [address]
        let pages = addresses.map { BrowserTabPage(key: UUID(), address: $0, title: "") }
        return (pages, min(max(0, selectedTab ?? 0), max(0, pages.count - 1)))
    }
}
