import Foundation

/// A task's tab as the tab tools report it.
struct BrowserAgentTabInfo: Equatable, Sendable {
    /// The id the other browser tools take as `tabId`.
    var id: String
    /// Where the page is from: scheme, host and port only, since titles and paths are the page's own
    /// words (the Claude app's `tabs_context` lists origins for the same reason).
    var origin: String
    /// The fronted tab: the one the panel shows and the tools use when they name none.
    var isActive: Bool
    /// False while the tab's page does not respond (`BrowserTab.unresponsive`) or its renderer ended.
    var isResponding = true
    /// The error code of the tab's renderer that ended (`BrowserTabCrash.errorCode`).
    var crash: String?
}

/// The task's tabs, for the tab tools and for a tool that names a tab.
@MainActor
protocol BrowserAgentTabDirectory: AnyObject {
    /// The page of the task's tab `tabID`, or of its fronted tab when `tabID` is nil (opening one when
    /// the task has none). Reports agent use of the tab.
    func page(for sessionID: UUID, tabID: String?) throws -> BrowserAgentPage
    func tabs(for sessionID: UUID) throws -> (tabs: [BrowserAgentTabInfo], panelOpen: Bool)
    /// A blank tab after the task's others; `foreground` fronts it.
    func newTab(for sessionID: UUID, foreground: Bool) throws -> BrowserAgentTabInfo
    func select(_ tabID: String, for sessionID: UUID) throws
    /// Closes the tab and returns the tab fronted now, if any.
    func close(_ tabID: String, for sessionID: UUID) throws -> BrowserAgentTabInfo?
    /// The task was archived or deleted: its tabs close.
    func closeAll(for sessionID: UUID)
    /// A tab whose page does not respond, opened again in its place under the same side-panel tab
    /// (`BrowserHostClient.replace`); returns the new tab's page.
    func replace(_ tabID: String, for sessionID: UUID) throws -> BrowserAgentPage
    /// Chromium's own windows in the browser (the passkey dialog, a site's sign-in window, the print dialog);
    /// empty when none is open.
    var browserDialogs: [BrowserChromiumWindow] { get }
    /// Closes them as Escape would: a passkey request ends with NotAllowedError, a sign-in or printing is cancelled.
    func closeBrowserDialogs() -> Bool
}

/// The agent's side of each task's browser tabs. The host keeps the task's tabs, which the task's
/// panel shows and these tools drive: the first tool call opens the task's tab in the background (no
/// panel opens), and every call reports agent activity so the host shows the tab it uses to its
/// engine while the agent works. The tools follow each tab's events through an observer, since the
/// panel owns the fronted tab's event handler.
@MainActor
final class BrowserAgentTabs: BrowserAgentTabDirectory {
    private struct Entry {
        let tab: BrowserTab
        let page: BrowserAgentPage
        let observer: UUID
    }

    private let client: @MainActor () -> BrowserHostClient?
    private let unavailableReason: String
    private var entries: [BrowserTabID: Entry] = [:]
    /// Called before a tool reaches the task's tabs: the app loads the task's side panel, which hands
    /// the tabs it saved before Yardlet restarted to the engine to open again, so the agent and the
    /// panel have the same tabs.
    var prepareSession: (@MainActor (UUID) -> Void)?

    /// `client` is nil when this build carries no browser engine.
    init(
        unavailableReason: String = "This Yardlet build has no browser engine, so the browser tools are unavailable.",
        client: @escaping @MainActor () -> BrowserHostClient?
    ) {
        self.unavailableReason = unavailableReason
        self.client = client
    }

    func page(for sessionID: UUID, tabID: String?) throws -> BrowserAgentPage {
        let client = try requireClient(for: sessionID)
        let tab = try tabID.map { try existingTab($0, for: sessionID, in: client) } ?? frontedTab(for: sessionID, in: client)
        let page = entry(for: tab).page
        tab.noteAgentActivity()
        return page
    }

    func tabs(for sessionID: UUID) throws -> (tabs: [BrowserAgentTabInfo], panelOpen: Bool) {
        let client = try requireClient(for: sessionID)
        // The panel's tabs saved before a restart or lost with the host are the task's tabs: they open
        // again, so their ids are ones the other tools take.
        if client.tabs(forSession: sessionID).isEmpty, client.rememberedTabs(forSession: sessionID) != nil {
            _ = try start { try client.restoreTabs(forSession: sessionID, viewport: .offscreenDefault) }
        }
        let fronted = client.tab(forSession: sessionID)
        let tabs = client.tabs(forSession: sessionID)
        return (tabs.map { info($0, fronted: fronted) }, tabs.contains { $0.isPanelAttached })
    }

    func newTab(for sessionID: UUID, foreground: Bool) throws -> BrowserAgentTabInfo {
        let client = try requireClient(for: sessionID)
        // A task whose tabs were lost with the host gets them back first, so the new tab goes after them.
        if client.tabs(forSession: sessionID).isEmpty {
            _ = try start { try client.restoreTabs(forSession: sessionID, viewport: .offscreenDefault) }
        }
        let tab = try start {
            try client.newTab(forSession: sessionID, url: "about:blank", viewport: .offscreenDefault, select: foreground)
        }
        _ = entry(for: tab)
        tab.noteAgentActivity()
        return info(tab, fronted: client.tab(forSession: sessionID))
    }

    func select(_ tabID: String, for sessionID: UUID) throws {
        let client = try requireClient(for: sessionID)
        let tab = try existingTab(tabID, for: sessionID, in: client)
        tab.select()
        tab.noteAgentActivity()
    }

    func close(_ tabID: String, for sessionID: UUID) throws -> BrowserAgentTabInfo? {
        let client = try requireClient(for: sessionID)
        let tab = try existingTab(tabID, for: sessionID, in: client)
        forget(tab.id)
        tab.close()
        return client.tab(forSession: sessionID).map { info($0, fronted: $0) }
    }

    func replace(_ tabID: String, for sessionID: UUID) throws -> BrowserAgentPage {
        let client = try requireClient(for: sessionID)
        let tab = try existingTab(tabID, for: sessionID, in: client)
        forget(tab.id)
        let replacement = try start { try client.replace(tab, url: "about:blank") }
        let page = entry(for: replacement).page
        replacement.noteAgentActivity()
        return page
    }

    func closeAll(for sessionID: UUID) {
        guard let client = client() else { return }
        for tab in client.tabs(forSession: sessionID) { forget(tab.id) }
        client.closeTabs(forSession: sessionID)
    }

    var browserDialogs: [BrowserChromiumWindow] { client()?.chromiumWindows ?? [] }

    func closeBrowserDialogs() -> Bool {
        client()?.closeChromiumWindows() ?? false
    }

    // MARK: Internals

    private func requireClient(for sessionID: UUID) throws -> BrowserHostClient {
        guard let client = client() else { throw BrowserAgentToolError(unavailableReason) }
        prepareSession?(sessionID)
        return client
    }

    /// The task's fronted tab; when it has none, the tabs it lost with the host, else a blank tab.
    private func frontedTab(for sessionID: UUID, in client: BrowserHostClient) throws -> BrowserTab {
        if let tab = client.tab(forSession: sessionID) { return tab }
        return try start {
            try client.restoreTabs(forSession: sessionID, viewport: .offscreenDefault)
                ?? client.openTab(forSession: sessionID, url: "about:blank", viewport: .offscreenDefault)
        }
    }

    private func existingTab(_ tabID: String, for sessionID: UUID, in client: BrowserHostClient) throws -> BrowserTab {
        guard let tab = client.tabs(forSession: sessionID).first(where: { String($0.id) == tabID }) else {
            throw BrowserAgentToolError("This task's browser has no tab \(tabID). browser_tab_list lists its tabs.")
        }
        return tab
    }

    private func start<T>(_ open: () throws -> T) throws -> T {
        do {
            return try open()
        } catch let limit as BrowserTabLimitError {
            throw BrowserAgentToolError(limit.localizedDescription)
        } catch {
            throw BrowserAgentToolError("The browser could not start: \(error.localizedDescription)")
        }
    }

    private func entry(for tab: BrowserTab) -> Entry {
        if let entry = entries[tab.id], entry.tab === tab { return entry }
        forget(tab.id)
        entries = entries.filter { !$0.value.tab.isClosed }
        let page = BrowserAgentPage(cdp: tab.devTools, tabID: tab.id) { [weak tab] command in tab?.send(command) }
        page.unresponsive = { [weak tab] in tab?.unresponsive }
        page.crash = { [weak tab] in tab?.crash }
        page.viewport = { [weak tab] in tab?.viewport }
        let observer = tab.addEventObserver { [weak page] event in page?.receive(event) }
        let entry = Entry(tab: tab, page: page, observer: observer)
        entries[tab.id] = entry
        return entry
    }

    private func forget(_ id: BrowserTabID) {
        guard let entry = entries.removeValue(forKey: id) else { return }
        entry.tab.removeEventObserver(entry.observer)
    }

    private func info(_ tab: BrowserTab, fronted: BrowserTab?) -> BrowserAgentTabInfo {
        BrowserAgentTabInfo(id: String(tab.id), origin: Self.origin(of: tab.currentURL ?? "about:blank"), isActive: tab === fronted,
                            isResponding: tab.unresponsive == nil && tab.crash == nil, crash: tab.crash?.errorCode)
    }

    static func origin(of address: String) -> String {
        guard let url = URL(string: address), let scheme = url.scheme?.lowercased() else { return address }
        guard let host = url.host(), !host.isEmpty else {
            return scheme == "about" ? address : scheme + ":"
        }
        return "\(scheme)://\(host)" + (url.port.map { ":\($0)" } ?? "")
    }
}
