import Foundation

/// Owns the browser host's lifetime and routes its events to tabs.
///
/// Each task (session) has up to `maxTabsPerSession` tabs in strip order, one of them fronted: the
/// one the task's side panel last showed and the agent's browser tools use when they name no tab. Each
/// tab is a tab of the side panel (the Codex app's), which knows it by its `key`: the key outlives the
/// host, so a tab opened again after the host ended or Yardlet restarted is the same panel tab. A session tab stays until it is closed (from the
/// panel, by the agent, or for its task when the task is archived or deleted), as the Codex app keeps
/// a thread's browser pages until the thread is archived; a panel closing or the agent stopping does
/// not close it. When the last tab is gone the host waits
/// `idleGrace` (60 seconds) and ends, returning all of Chromium's memory; the next tab starts it
/// again. Tabs opened without a session (`openTab(url:viewport:)`) also stay until closed.
///
/// A session tab is shown to its engine (painting, full-speed timers) while a panel shows it or
/// within `agentVisibleWindow` of the agent's last use (or of opening); otherwise it is hidden, so an
/// unwatched page stops painting and its timers slow down, as the Codex app throttles a page nobody sees.
///
/// Tabs lost with the host (a crash, or the host ending as Yardlet quits) leave their last addresses
/// behind (`rememberedTabs(forSession:)`), and the panel and the agent's tools open them again
/// (`restoreTabs(forSession:viewport:)`). Closing a task's tabs for the task forgets them.
@MainActor
final class BrowserHostClient {
    typealias Launcher = @MainActor () throws -> any BrowserHostConnection

    let idleGrace: Duration
    let agentVisibleWindow: Duration
    let shutdownTimeout: Duration
    private let launcher: Launcher
    private var connection: (any BrowserHostConnection)?
    /// Yardlet asked the running host to end (`shutdown`); it closes every tab on its way out.
    private var isHostEnding = false
    private var tabs: [BrowserTabID: BrowserTab] = [:]
    private var nextTabID = 1
    private var idleTask: Task<Void, Never>?
    private var retentionTask: Task<Void, Never>?
    /// Each session's tabs in strip order, and its fronted tab.
    private var sessionOrder: [UUID: [BrowserTabID]] = [:]
    private var frontedTabs: [UUID: BrowserTabID] = [:]
    /// Each session's tabs as they were when the host ended, to open again.
    private var remembered: [UUID: BrowserRememberedTabs] = [:]
    /// Addresses of each session's recently closed tabs, newest last.
    private var closedAddresses: [UUID: [String]] = [:]
    private var sessionObservers: [UUID: [UUID: () -> Void]] = [:]
    /// Cookie imports waiting for the host's `cookiesImported`.
    private var cookieImports: [Int: CheckedContinuation<Int, Never>] = [:]
    private var nextCookieImport = 1

    /// The most tabs one task keeps, as the Claude app's Browser pane (⌘1…⌘9 reach all of them).
    nonisolated static let maxTabsPerSession = 9

    private(set) var launchCount = 0
    private(set) var hostProcessID: Int?
    private(set) var hostEngine: String?
    private(set) var acceleratedPaint: Bool?
    private(set) var lastTermination: String?
    /// Chromium's own windows in the host (the passkey dialog, a site's sign-in window, the print dialog), each with
    /// the tab it is over when the host knows it; empty when none is open.
    private(set) var chromiumWindows: [BrowserChromiumWindow] = []
    var chromiumWindowTitles: [String] { chromiumWindows.map(\.title) }
    /// Called when one of Chromium's windows comes over a tab of a task whose panel is not on screen (the agent's
    /// background tab, a task the person is not in): the person sees the window only where a panel shows its tab.
    var onChromiumWindowOverHiddenTab: ((BrowserTab) -> Void)?
    /// Called after the windows or their tabs changed, for placing them over their tabs.
    var onChromiumWindowsChange: (() -> Void)?
    /// What opens other apps' addresses a page asks for (LaunchServices on macOS).
    var externalApps: any BrowserExternalApps = NoExternalApps()
    /// Called on every host start and exit, for status displays and measurements.
    var onHostStateChange: ((_ isRunning: Bool) -> Void)?
    /// Called when the agent uses a session's tab, for the rail's preview of what it drives.
    var onAgentActivity: ((_ session: UUID, _ tab: BrowserTabID) -> Void)?
    /// Called when a tab goes away: closed, or lost with the host.
    var onTabClosed: ((BrowserTabID) -> Void)?

    init(
        idleGrace: Duration = .seconds(60),
        agentVisibleWindow: Duration = .seconds(60),
        shutdownTimeout: Duration = .seconds(5),
        launcher: @escaping Launcher
    ) {
        self.idleGrace = idleGrace
        self.agentVisibleWindow = agentVisibleWindow
        self.shutdownTimeout = shutdownTimeout
        self.launcher = launcher
    }

    var isHostRunning: Bool { connection != nil }
    /// The profile a session's tabs open in (`BrowserTaskProfiles`); nil, or no provider, is the default profile.
    var profileForSession: (@MainActor (UUID) -> BrowserTabProfile?)?
    /// Tabs moved to another session with their pages; the profile they are in goes with them.
    var onTabsMoved: (@MainActor (_ source: UUID, _ target: UUID) -> Void)?
    /// The host ended (idle, quit or crashed): the moment no profile folder is open.
    var onHostEnded: (@MainActor () -> Void)?

    /// A person signed in on a task's page: that site's cookies also go to the default profile, where new
    /// tasks start from. Nothing to do when the task's tabs use the default profile.
    func copyCookies(fromSession session: UUID, toDefaultFor domain: String) {
        guard let profile = profileForSession?(session), let connection else { return }
        connection.send(.copyCookies(from: profile.key, to: nil, domain: domain))
    }

    /// Brings the person's sign-ins for `sites` over from another browser (`BrowserLoginImport`): each profile (a key;
    /// nil for the default profile, where new tasks start) loses its cookies of those sites and takes `cookies`, one
    /// profile after another. What each set, as `cookiesImported` counts them; -1 for one the host did not answer
    /// within `timeout`. Starts the host when it is not running.
    func importCookies(_ cookies: [BrowserImportedCookie], sites: [String], into profiles: [String?],
                       timeout: Duration = .seconds(15)) async throws -> [Int] {
        var counts: [Int] = []
        for profile in profiles {
            let connection = try currentConnection()
            let request = nextCookieImport
            nextCookieImport += 1
            let count = await withCheckedContinuation { continuation in
                cookieImports[request] = continuation
                connection.send(.importCookies(request: request, to: profile, sites: sites, cookies: cookies))
                Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    self?.cookieImports.removeValue(forKey: request)?.resume(returning: -1)
                }
            }
            counts.append(count)
        }
        if tabs.isEmpty { scheduleIdleShutdown() }
        return counts
    }
    var openTabCount: Int { tabs.count }

    // MARK: Session tabs

    /// The session's open tabs in strip order.
    func tabs(forSession session: UUID) -> [BrowserTab] {
        (sessionOrder[session] ?? []).compactMap { tabs[$0] }
    }

    /// The session's fronted tab, if the host has one: the tab its panel shows and the agent's tools
    /// use when they name none.
    func tab(forSession session: UUID) -> BrowserTab? {
        if let id = frontedTabs[session], let tab = tabs[id] { return tab }
        return tabs(forSession: session).first
    }

    /// The page the session's fronted tab last showed, also after its tabs were lost with the host.
    /// Nil for a task whose tabs showed no page or were closed for the task.
    func lastAddress(forSession session: UUID) -> String? {
        if let tab = tab(forSession: session) { return tab.lastPageURL }
        return remembered[session].map { $0.addresses[$0.fronted] }
    }

    /// The session's tabs as they were when the host ended, until they are opened again.
    func rememberedTabs(forSession session: UUID) -> BrowserRememberedTabs? {
        remembered[session]
    }

    /// The session's fronted tab, opened at `url` (starting the host) when it has none. An existing tab
    /// keeps its page; `url` is not loaded again.
    func openTab(forSession session: UUID, url: String, viewport: BrowserViewport) throws -> BrowserTab {
        if let tab = tab(forSession: session) { return tab }
        let tab = try open(url: url, viewport: viewport, session: session, key: UUID(), after: nil)
        frontedTabs[session] = tab.id
        reschedule()
        notifySession(session)
        return tab
    }

    /// Another tab for the session, after its others or right after `after`. `select` fronts it;
    /// otherwise it opens behind the fronted tab, as the Claude app's `tabs_create` does by default.
    /// - Parameter key: the side-panel tab it is; a tab opened for a panel tab that has none yet
    ///   passes that tab's key.
    func newTab(forSession session: UUID, url: String, viewport: BrowserViewport, select: Bool,
                key: UUID = UUID(), after: BrowserTab? = nil) throws -> BrowserTab {
        guard tabs(forSession: session).count < Self.maxTabsPerSession else { throw BrowserTabLimitError() }
        guard tab(key: key, forSession: session) == nil else { throw BrowserTabKeyInUseError() }
        let tab = try open(url: url, viewport: viewport, session: session, key: key,
                           after: after.flatMap { $0.session == session ? $0.id : nil })
        if select || frontedTabs[session].flatMap({ tabs[$0] }) == nil { frontedTabs[session] = tab.id }
        reschedule()
        notifySession(session)
        return tab
    }

    /// The session's open tab that is the side-panel tab `key`.
    func tab(key: UUID, forSession session: UUID) -> BrowserTab? {
        tabs(forSession: session).first { $0.key == key }
    }

    /// Fronts a session tab.
    func select(_ tab: BrowserTab) {
        guard let session = tab.session, tabs[tab.id] === tab, frontedTabs[session] != tab.id else { return }
        frontedTabs[session] = tab.id
        notifySession(session)
    }

    /// Tabs to open again for a session with none (saved with the task before Yardlet restarted).
    func rememberTabs(_ saved: BrowserRememberedTabs, forSession session: UUID) {
        guard tabs(forSession: session).isEmpty, remembered[session] == nil, !saved.addresses.isEmpty else { return }
        remembered[session] = BrowserRememberedTabs(addresses: saved.addresses, keys: saved.keys,
                                                    fronted: min(max(0, saved.fronted), saved.addresses.count - 1))
    }

    /// Opens the session's tabs lost with the host again, fronting the one that was fronted. Nil when
    /// the session has open tabs or nothing to restore.
    @discardableResult
    func restoreTabs(forSession session: UUID, viewport: BrowserViewport) throws -> BrowserTab? {
        guard tabs(forSession: session).isEmpty, let saved = remembered[session] else { return nil }
        remembered[session] = nil
        var opened: [BrowserTab] = []
        for (index, address) in saved.addresses.prefix(Self.maxTabsPerSession).enumerated() {
            opened.append(try open(url: address, viewport: viewport, session: session, key: saved.key(at: index), after: nil))
        }
        if let fronted = opened.indices.contains(saved.fronted) ? opened[saved.fronted] : opened.first {
            frontedTabs[session] = fronted.id
        }
        reschedule()
        notifySession(session)
        return tab(forSession: session)
    }

    /// A tab whose page does not respond, replaced by a new one at `url` under the same key, in the same
    /// place and as much in front: the side panel keeps its tab. A renderer Chromium's hang monitor holds
    /// is ended first; the new tab may still share a process with another page of the same site.
    @discardableResult
    func replace(_ tab: BrowserTab, url: String) throws -> BrowserTab {
        guard tabs[tab.id] === tab, let session = tab.session else { throw BrowserTabGoneError() }
        if tab.unresponsive == .hangMonitor { connection?.send(.unresponsive(tab: tab.id, action: .terminate)) }
        var order = sessionOrder[session] ?? []
        let index = order.firstIndex(of: tab.id) ?? order.count
        let wasFront = frontedTabs[session] == tab.id
        // Gone without the session hearing it as closed: the same key opens again below.
        tabs.removeValue(forKey: tab.id)
        connection?.send(.close(tab: tab.id))
        tab.markClosed()
        onTabClosed?(tab.id)
        order.removeAll { $0 == tab.id }
        sessionOrder[session] = order
        let replacement = try open(url: url, viewport: tab.viewport ?? .offscreenDefault, session: session, key: tab.key,
                                   after: nil, at: min(index, order.count))
        if wasFront || frontedTabs[session].flatMap({ tabs[$0] }) == nil { frontedTabs[session] = replacement.id }
        reschedule()
        notifySession(session)
        return replacement
    }

    /// "Wait" for a page that does not respond: Chromium's hang monitor waits another 15 seconds and
    /// says so again if it still does not; a page that did not answer the agent is taken as answering
    /// until it misses another call.
    func waitForPage(_ tab: BrowserTab) {
        guard tabs[tab.id] === tab, tab.unresponsive != nil else { return }
        if tab.hangReported { connection?.send(.unresponsive(tab: tab.id, action: .wait)) }
        let deadline = ContinuousClock.now + Self.unresponsiveWait
        tab.wait(until: deadline)
        guard let session = tab.session else { return }
        notifySession(session)
        // Still not handling input once the wait is over: it says so again.
        Task { @MainActor [weak self, weak tab] in
            try? await Task.sleep(until: deadline + .milliseconds(50), clock: .continuous)
            guard let self, let tab, self.tabs[tab.id] === tab, tab.unresponsive != nil else { return }
            self.notifySession(session)
        }
    }

    /// How long Wait waits before a renderer that still does not handle input shows again (Chromium's
    /// hang monitor timeout).
    nonisolated static let unresponsiveWait: Duration = .seconds(15)

    /// The page of a session tab did not answer a DevTools call that needs its renderer.
    fileprivate func pageDidNotAnswer(_ tab: BrowserTab) {
        if let session = tab.session { notifySession(session) }
    }

    /// Opens the session's most recently closed tab again, fronted, as a new side-panel tab. Nil when
    /// none was closed.
    func reopenClosedTab(forSession session: UUID, viewport: BrowserViewport) throws -> BrowserTab? {
        guard let address = closedAddresses[session]?.last else { return nil }
        let tab = try newTab(forSession: session, url: address, viewport: viewport, select: true)
        closedAddresses[session]?.removeLast()
        return tab
    }

    /// Gives a session tab to another task, page and all: the tab leaves its strip as if it had never
    /// been there (no reopen entry) and joins the end of `target`'s, in front when `select` or when
    /// `target` has no tab in front. Nothing is sent to the host; the page goes on as it was. The new-task
    /// screen's tabs move this way to the task it starts, as the Codex app's thread takes over its
    /// draft's tabs.
    func move(_ tab: BrowserTab, toSession target: UUID, select: Bool) throws {
        guard tabs[tab.id] === tab, let source = tab.session, source != target else { return }
        guard tabs(forSession: target).count < Self.maxTabsPerSession else { throw BrowserTabLimitError() }
        var order = sessionOrder[source] ?? []
        if let index = order.firstIndex(of: tab.id) {
            order.remove(at: index)
            if frontedTabs[source] == tab.id {
                frontedTabs[source] = order.isEmpty ? nil : order[min(index, order.count - 1)]
            }
        }
        sessionOrder[source] = order.isEmpty ? nil : order
        tab.session = target
        onTabsMoved?(source, target)
        remembered[target] = nil
        sessionOrder[target, default: []].append(tab.id)
        if select || frontedTabs[target].flatMap({ tabs[$0] }) == nil { frontedTabs[target] = tab.id }
        reschedule()
        notifySession(source)
        notifySession(target)
    }

    /// Moves every tab of `source` to `target` in strip order, keeping the one in front in front, and
    /// tabs `source` lost with the host, to open again there. A tab past `target`'s limit stays.
    func moveTabs(fromSession source: UUID, toSession target: UUID) {
        guard source != target else { return }
        let fronted = tab(forSession: source)
        for tab in tabs(forSession: source) {
            try? move(tab, toSession: target, select: tab === fronted)
        }
        if let saved = remembered[source], tabs(forSession: target).isEmpty, remembered[target] == nil {
            remembered[source] = nil
            remembered[target] = saved
            notifySession(target)
        }
    }

    /// Closes every tab of the session and forgets its addresses: the task was archived or deleted.
    func closeTabs(forSession session: UUID) {
        for tab in tabs(forSession: session) { close(tab) }
        remembered[session] = nil
        closedAddresses[session] = nil
        frontedTabs[session] = nil
        sessionOrder[session] = nil
        notifySession(session)
    }

    /// Calls `observer` when the session's tabs open, close, change order or front, or a tab's title,
    /// address, icon or loading changes. Frames and other page events do not call it.
    func addTabsObserver(forSession session: UUID, _ observer: @escaping () -> Void) -> UUID {
        let token = UUID()
        sessionObservers[session, default: [:]][token] = observer
        return token
    }

    func removeTabsObserver(_ token: UUID, forSession session: UUID) {
        sessionObservers[session]?[token] = nil
        if sessionObservers[session]?.isEmpty == true { sessionObservers[session] = nil }
    }

    /// A panel shows the tab. The tab is kept, and shown to its engine, for as long as a panel is
    /// attached; attaching also asks for a fresh frame.
    func attachPanel(to tab: BrowserTab) {
        guard tabs[tab.id] === tab else { return }
        tab.panelCount += 1
        tab.wasPanelAttached = true
        tab.isShown = true
        connection?.send(.visibility(tab: tab.id, isHidden: false))
        reschedule()
    }

    /// - Parameter occluded: the panel had reported itself occluded (`setPanelOccluded`) and not
    ///   yet visible again.
    func detachPanel(from tab: BrowserTab, occluded: Bool = false) {
        guard tab.panelCount > 0 else { return }
        tab.panelCount -= 1
        if occluded { tab.occludedPanelCount = max(0, tab.occludedPanelCount - 1) }
        tab.occludedPanelCount = min(tab.occludedPanelCount, tab.panelCount)
        reschedule()
    }

    /// An attached panel is on screen or not: its window is miniaturized, covered, on another
    /// space, or the app is hidden. An occluded panel still holds the tab, but no longer keeps it
    /// painting; the tab hides like a panel-less one and paints again when the panel shows.
    func setPanelOccluded(_ occluded: Bool, on tab: BrowserTab) {
        guard tabs[tab.id] === tab, tab.panelCount > 0 else { return }
        tab.occludedPanelCount = min(tab.panelCount, max(0, tab.occludedPanelCount + (occluded ? 1 : -1)))
        reschedule()
    }

    /// The agent used the session's fronted tab. Call it (or `noteAgentActivity(on:)` for the tab used)
    /// on every agent browser action; it shows the tab to its engine for `agentVisibleWindow` after the
    /// last call, also while the panel fronts another tab.
    func noteAgentActivity(forSession session: UUID) {
        guard let tab = tab(forSession: session) else { return }
        noteAgentActivity(on: tab)
    }

    func noteAgentActivity(on tab: BrowserTab) {
        guard tabs[tab.id] === tab else { return }
        tab.lastAgentActivity = .now
        // Shown before the agent's next command, which follows on the same connection.
        updateVisibility(of: tab, now: .now)
        tab.onAgentActivity?()
        if let session = tab.session { onAgentActivity?(session, tab.id) }
        reschedule()
    }

    // MARK: Tabs without a session

    /// Opens a tab outside any session, starting the host if none is running. It stays until
    /// closed.
    func openTab(url: String, viewport: BrowserViewport) throws -> BrowserTab {
        try open(url: url, viewport: viewport, session: nil, key: UUID(), after: nil)
    }

    func closeTab(_ tab: BrowserTab) {
        close(tab)
    }

    /// Closes a tab as a person closes it, as Chrome does: a page that asks before it is left asks first
    /// ("Leave site?", `BrowserTab.closeQuestion`), Stay keeps the tab, and the tab goes once the host closes
    /// it (`closed`). A page that neither asks nor closes within `closeAnswerWait` is closed as `closeTab` closes
    /// it: Chromium gives a renderer that does not answer 500 ms and then closes, but not to a tab with DevTools
    /// attached, which every Yardlet tab is (`ShouldIgnoreUnresponsiveRenderer`).
    func requestClose(_ tab: BrowserTab) {
        guard tabs[tab.id] === tab, !tab.isClosing else { return }
        guard let connection else { return close(tab) }
        tab.isClosing = true
        connection.send(.requestClose(tab: tab.id))
        Task { @MainActor [weak self, weak tab] in
            try? await Task.sleep(for: Self.closeAnswerWait)
            guard let self, let tab, self.tabs[tab.id] === tab, tab.isClosing, tab.closeQuestion == nil else { return }
            self.close(tab)
        }
    }

    nonisolated static let closeAnswerWait: Duration = .seconds(1)

    /// The person stayed on a page that asked before its close: the tab is no longer closing.
    fileprivate func closeStayed(_ tab: BrowserTab) {
        if let session = tab.session { notifySession(session) }
    }

    /// Opens a pop-up the browser blocked, from the panel's list, as Chrome's list opens one: another tab of the
    /// task, in front. It has no `window.opener`: Chromium made no window for the request, so the new tab loads
    /// its address (Chrome keeps the original request and its opener).
    func openBlockedPopup(_ url: String, from tab: BrowserTab) {
        guard tabs[tab.id] === tab, tab.blockedPopups.contains(url) else { return }
        tab.forgetBlockedPopup(url)
        openWindow(url, from: tab, background: false, userGesture: true)
    }

    // MARK: Host

    /// Asks the host to exit now and ends it if it has not exited within `shutdownTimeout`.
    func shutdownHost() {
        idleTask?.cancel()
        idleTask = nil
        retentionTask?.cancel()
        retentionTask = nil
        guard let current = connection else { return }
        isHostEnding = true
        current.send(.shutdown)
        let timeout = shutdownTimeout
        Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard let self, self.connection === current else { return }
            current.terminate()
        }
    }

    /// Ends the host for application termination: it closes its tabs and shuts Chromium down, and
    /// Yardlet waits up to `shutdownTimeout` for that before ending it. The tabs stay the tasks' tabs,
    /// saved with them to open again at the next launch.
    func terminateHost() {
        idleTask?.cancel()
        idleTask = nil
        retentionTask?.cancel()
        retentionTask = nil
        guard let current = connection else { return }
        isHostEnding = true
        current.send(.shutdown)
        if !current.waitUntilExit(timeout: shutdownTimeout) { current.terminate() }
    }

    func send(_ command: BrowserHostCommand) {
        connection?.send(command)
    }

    /// Chromium's windows over this task's tabs.
    func chromiumWindows(forSession session: UUID) -> [BrowserChromiumWindow] {
        chromiumWindows.filter { window in window.tab.flatMap { tabs[$0] }?.session == session }
    }

    /// Closes Chromium's windows over this task's tabs as Escape would (a passkey request ends with
    /// NotAllowedError); another task's windows and one whose tab is not known stay. False when it has none.
    @discardableResult
    func closeChromiumWindows(forSession session: UUID) -> Bool {
        let windows = chromiumWindows(forSession: session)
        guard !windows.isEmpty, let connection else { return false }
        connection.send(.closeChromiumWindows(tabs: Array(Set(windows.compactMap(\.tab))).sorted()))
        return true
    }

    /// Closes every one of Chromium's windows (QA's cleanup). False when none is open.
    @discardableResult
    func closeChromiumWindows() -> Bool {
        guard !chromiumWindowTitles.isEmpty, let connection else { return false }
        connection.send(.closeChromiumWindows(tabs: nil))
        return true
    }

    // MARK: Internals

    private func open(url: String, viewport: BrowserViewport, session: UUID?, key: UUID, after: BrowserTabID?,
                      at position: Int? = nil) throws -> BrowserTab {
        idleTask?.cancel()
        idleTask = nil
        let connection = try currentConnection()
        let tab = BrowserTab(id: nextTabID, client: self, session: session, key: key)
        tab.viewport = viewport
        nextTabID += 1
        tabs[tab.id] = tab
        if let session {
            // A tab opened for the task after the host ended replaces the tabs it lost.
            remembered[session] = nil
            var order = sessionOrder[session] ?? []
            if let position { order.insert(tab.id, at: min(position, order.count)) }
            else if let after, let index = order.firstIndex(of: after) { order.insert(tab.id, at: index + 1) }
            else { order.append(tab.id) }
            sessionOrder[session] = order
        }
        connection.send(.open(tab: tab.id, url: url, viewport: viewport, profile: session.flatMap { profileForSession?($0) }))
        return tab
    }

    private func close(_ tab: BrowserTab) {
        guard tabs.removeValue(forKey: tab.id) != nil else { return }
        tab.isClosing = false
        connection?.send(.close(tab: tab.id))
        tab.markClosed()
        if let session = tab.session { removeFromSession(tab, session: session) }
        onTabClosed?(tab.id)
        guard tabs.isEmpty else { return }
        retentionTask?.cancel()
        retentionTask = nil
        scheduleIdleShutdown()
    }

    /// Takes a closed tab out of its session's strip. A fronted tab hands the front to the tab that
    /// took its place, else the one before it, as Chrome does; its address goes on the reopen list.
    private func removeFromSession(_ tab: BrowserTab, session: UUID) {
        var order = sessionOrder[session] ?? []
        guard let index = order.firstIndex(of: tab.id) else { return }
        order.remove(at: index)
        sessionOrder[session] = order.isEmpty ? nil : order
        if frontedTabs[session] == tab.id {
            frontedTabs[session] = order.isEmpty ? nil : order[min(index, order.count - 1)]
        }
        if let address = tab.lastPageURL {
            var closed = closedAddresses[session] ?? []
            closed.append(address)
            closedAddresses[session] = Array(closed.suffix(10))
        }
        notifySession(session)
    }

    /// A page's new-window request: another tab of its task, in front unless a background-tab
    /// click asked for it behind, as the Codex and Claude apps' browsers open one. Without a user
    /// gesture nothing opens (Chrome blocks those pop-ups too). A tab outside a task, or a task with
    /// no room for another tab, loads the address itself, as before 2026-10-22.
    private func openWindow(_ url: String, from opener: BrowserTab, background: Bool, userGesture: Bool) {
        guard userGesture else { return }
        if let session = opener.session,
           let tab = try? newTab(forSession: session, url: url, viewport: opener.viewport ?? .offscreenDefault, select: !background) {
            opener.receive(.openedTab(tab: opener.id, newTab: tab.id, url: url))
            return
        }
        connection?.send(.navigate(tab: opener.id, url: url))
        opener.receive(.openedTab(tab: opener.id, newTab: nil, url: url))
    }

    /// A page's new window the host made, so it keeps `window.opener` (a card issuer's 3-D Secure window,
    /// PayPal and sign-in popups answer the page that opened them): another tab of the opener's task,
    /// placed as `openWindow` places one. A tab outside a task, or a task with no room for another tab,
    /// closes it, and the opener loads the address itself, as `openWindow` does.
    private func adoptPopup(_ id: BrowserTabID, opener: BrowserTab?, url: String, background: Bool) {
        guard tabs[id] == nil else { return }
        guard let opener, let session = opener.session, tabs(forSession: session).count < Self.maxTabsPerSession else {
            connection?.send(.close(tab: id))
            guard let opener else { return }
            connection?.send(.navigate(tab: opener.id, url: url))
            opener.receive(.openedTab(tab: opener.id, newTab: nil, url: url))
            return
        }
        let tab = BrowserTab(id: id, client: self, session: session, key: UUID())
        tab.viewport = opener.viewport
        tabs[id] = tab
        sessionOrder[session, default: []].append(id)
        if !background || frontedTabs[session].flatMap({ tabs[$0] }) == nil { frontedTabs[session] = id }
        opener.receive(.openedTab(tab: opener.id, newTab: id, url: url))
        reschedule()
        notifySession(session)
    }

    /// A page's request to open another app's address, by Chrome's rules (`BrowserExternalAppPolicy`): after one
    /// request, the page asks again only after another click or key press (Chrome's flood guard); an address no
    /// app opens, or one Yardlet itself would open, goes nowhere; a mail link and a site the person always
    /// allowed open without asking; any other asks the person in the tab's panel. What the agent's input led to
    /// always asks. The tab hears what came of it (`externalAppHandled`).
    private func handleExternalApp(_ request: BrowserExternalAppRequest, on tab: BrowserTab) {
        func report(_ outcome: BrowserExternalAppOutcome, app: String? = nil) {
            tab.receive(.externalAppHandled(tab: tab.id, url: request.url, app: app, outcome: outcome))
        }
        let lastInput = [tab.lastPersonInput, tab.lastAgentActivity].compactMap { $0 }.max()
        if let last = tab.lastExternalAppRequest, lastInput.map({ $0 < last }) ?? true { return report(.ignored) }
        tab.lastExternalAppRequest = .now
        guard let url = URL(string: request.url), let scheme = url.scheme?.lowercased(), let app = externalApps.appName(for: url)
        else { return report(.noApp) }
        let byAgent = tab.isDrivenByAgent
        if BrowserExternalAppPolicy.opensWithoutAsking(scheme: scheme, remembered: request.remembered, byAgent: byAgent) {
            externalApps.open(url)
            return report(.opened, app: app)
        }
        tab.externalAppQuestion = BrowserExternalAppQuestion(
            url: request.url, origin: request.origin, app: app,
            offersAlwaysAllow: BrowserExternalAppPolicy.mayRemember(origin: request.origin), byAgent: byAgent)
        report(.asked, app: app)
    }

    /// The person's answer in the panel: Open opens the app, and with "Always allow" checked the tab's profile
    /// keeps that this site may open such links without asking.
    fileprivate func answer(_ question: BrowserExternalAppQuestion, open: Bool, alwaysAllow: Bool, on tab: BrowserTab) {
        guard open, let url = URL(string: question.url), let scheme = url.scheme?.lowercased() else { return }
        if alwaysAllow, question.offersAlwaysAllow {
            connection?.send(.allowExternalApp(tab: tab.id, origin: question.origin, scheme: scheme))
        }
        externalApps.open(url)
    }

    /// Keeps the addresses of a session's tabs that showed a page, for `restoreTabs`. A tab the person was
    /// closing is not kept.
    private func remember(_ session: UUID) {
        let open = tabs(forSession: session)
        let fronted = tab(forSession: session)
        let kept = open.filter { $0.lastPageURL != nil && !$0.isClosing }
        guard !kept.isEmpty else { return }
        remembered[session] = BrowserRememberedTabs(
            addresses: kept.compactMap(\.lastPageURL),
            keys: kept.map(\.key),
            fronted: kept.firstIndex { $0 === fronted } ?? 0
        )
    }

    private func notifySession(_ session: UUID) {
        for observer in (sessionObservers[session] ?? [:]).values { observer() }
    }

    private func currentConnection() throws -> any BrowserHostConnection {
        if let connection { return connection }
        let connection = try launcher()
        launchCount += 1
        connection.eventHandler = { [weak self, weak connection] event in
            guard let self, let connection, self.connection === connection else { return }
            self.handle(event)
        }
        self.connection = connection
        onHostStateChange?(true)
        return connection
    }

    private func scheduleIdleShutdown() {
        idleTask?.cancel()
        let grace = idleGrace
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: grace)
            guard !Task.isCancelled, let self, self.tabs.isEmpty else { return }
            self.shutdownHost()
        }
    }

    /// Until when a session tab without a visible panel stays shown for the agent (nil: no longer).
    private func agentVisibleUntil(_ tab: BrowserTab) -> ContinuousClock.Instant? {
        guard tab.session != nil, tab.visiblePanelCount == 0 else { return nil }
        // A tab the agent opened without a panel is shown from its opening; once a panel has shown
        // the tab, only the agent's use does (a panel's own tab hides as soon as the panel is off screen).
        guard let since = tab.lastAgentActivity ?? (tab.wasPanelAttached ? nil : tab.openedAt) else { return nil }
        return max(since, tab.openedAt) + agentVisibleWindow
    }

    private func updateVisibility(of tab: BrowserTab, now: ContinuousClock.Instant) {
        let shown = tab.session == nil || tab.visiblePanelCount > 0 || (agentVisibleUntil(tab).map { now < $0 } ?? false)
        guard shown != tab.isShown else { return }
        tab.isShown = shown
        connection?.send(.visibility(tab: tab.id, isHidden: !shown))
    }

    /// Brings each tab's visibility up to date and wakes again when the next agent window ends.
    private func reschedule() {
        retentionTask?.cancel()
        retentionTask = nil
        let now = ContinuousClock.now
        var earliest: ContinuousClock.Instant?
        for tab in tabs.values {
            updateVisibility(of: tab, now: now)
            if tab.isShown, let hideAt = agentVisibleUntil(tab), hideAt > now {
                earliest = earliest.map { min($0, hideAt) } ?? hideAt
            }
        }
        guard let earliest else { return }
        retentionTask = Task { [weak self] in
            try? await Task.sleep(until: earliest, clock: .continuous)
            guard !Task.isCancelled else { return }
            self?.reschedule()
        }
    }

    private func handle(_ event: BrowserHostEvent) {
        switch event {
        case .ready(let processID, let engine, let accelerated):
            hostProcessID = processID
            hostEngine = engine
            acceleratedPaint = accelerated
        case .chromiumWindow(let isShown, let titles, let kinds, let ids, let owners):
            let titles = isShown ? (titles ?? [""]) : []
            let before = chromiumWindows
            chromiumWindows = titles.indices.map { index in
                func value<T>(_ list: [T]?) -> T? { list.flatMap { $0.indices.contains(index) ? $0[index] : nil } }
                return BrowserChromiumWindow(title: titles[index], kind: value(kinds).flatMap(BrowserChromiumWindow.Kind.init) ?? .passkey,
                                             id: value(ids) ?? 0, tab: value(owners).flatMap { $0 >= 0 ? $0 : nil })
            }
            // A window newly over a tab of a task no panel shows on screen: the task's panel is to show the tab.
            for window in chromiumWindows where !before.contains(window) {
                guard let tab = window.tab.flatMap({ tabs[$0] }), let session = tab.session,
                      !tabs(forSession: session).contains(where: { $0.visiblePanelCount > 0 }) else { continue }
                onChromiumWindowOverHiddenTab?(tab)
            }
            onChromiumWindowsChange?()
        case .cookiesImported(let request, let count):
            cookieImports.removeValue(forKey: request)?.resume(returning: count)
        case .terminated(let reason):
            for waiting in cookieImports.values { waiting.resume(returning: -1) }
            cookieImports.removeAll()
            chromiumWindows = []
            onChromiumWindowsChange?()
            connection = nil
            isHostEnding = false
            hostProcessID = nil
            lastTermination = reason
            onHostEnded?()
            idleTask?.cancel()
            idleTask = nil
            retentionTask?.cancel()
            retentionTask = nil
            let sessions = Array(sessionOrder.keys)
            for session in sessions { remember(session) }
            let orphaned = tabs.values
            tabs.removeAll()
            sessionOrder.removeAll()
            frontedTabs.removeAll()
            orphaned.forEach { $0.receive(event) }
            orphaned.forEach { onTabClosed?($0.id) }
            sessions.forEach(notifySession)
            onHostStateChange?(false)
        case .failed(_, let id?, _):
            // One tab's failure is that tab's; it never reaches the page another tab shows.
            guard let tab = tabs[id] else { return }
            tab.receive(event)
            if let session = tab.session { notifySession(session) }
        case .failed:
            tabs.values.forEach { $0.receive(event) }
        case .address(let id, _), .title(let id, _), .favicon(let id, _, _):
            guard let tab = tabs[id] else { return }
            tab.receive(event)
            if let session = tab.session { notifySession(session) }
        case .responsiveness(let id, _), .pageCrashed(let id, _, _, _):
            guard let tab = tabs[id] else { return }
            let before = tab.unresponsive
            tab.receive(event)
            if tab.unresponsive != before, let session = tab.session { notifySession(session) }
        case .loading(let id, let isLoading, _, _):
            guard let tab = tabs[id] else { return }
            let changed = tab.isLoading != isLoading
            tab.receive(event)
            // The side panel's tabs show which pages are loading; the rest of the state needs no notice.
            if changed, let session = tab.session { notifySession(session) }
        case .newWindow(let id, let url, let background, let userGesture):
            guard let tab = tabs[id] else { return }
            tab.receive(event)
            openWindow(url, from: tab, background: background, userGesture: userGesture)
        case .externalApp(let id, let request):
            guard let tab = tabs[id] else { return }
            handleExternalApp(request, on: tab)
        case .javaScriptDialog(let id, _), .javaScriptDialogReset(let id):
            guard let tab = tabs[id] else { return }
            let asked = tab.closeQuestion
            tab.receive(event)
            // A page asks before the person's close goes on: the panel brings its tab forward to ask, as Chrome does.
            if tab.closeQuestion != asked, let session = tab.session { notifySession(session) }
        case .popupOpened(let id, let openerID, let url, let background):
            adoptPopup(id, opener: tabs[openerID], url: url, background: background)
        case .download(let id, let download):
            guard let tab = tabs[id] else { return }
            tab.receive(event)
            // A tab a page opened only to download (a target=_blank link to a file) never shows a page. As
            // in Chrome it closes and its opener comes back, once the download ends: CEF reports nothing
            // more of a download whose tab has closed, and the panel's download row waits for its end.
            if ![.started, .inProgress].contains(download.state), tab.lastPageURL == nil,
               let opener = tabs.values.first(where: { $0.openedTabs.contains(tab.id) }) {
                select(opener)
                close(tab)
            }
        case .closed(let id):
            // The page closed itself; a tab Yardlet closed is already gone. A host asked to end closes
            // every tab first: those are lost with it, as in a crash, and `.terminated` keeps them.
            guard !isHostEnding, let tab = tabs[id] else { return }
            tab.receive(event)
            close(tab)
        default:
            if let id = event.tab { tabs[id]?.receive(event) }
        }
    }
}

/// One page in the host. Events arrive through `eventHandler` and any added observers; CDP goes
/// through `devTools`.
@MainActor
final class BrowserTab {
    let id: BrowserTabID
    /// The side-panel tab this is. It stays with the tab when it moves to another task, and a tab
    /// opened again (after the host ended, or Yardlet restarted) takes the key it had.
    let key: UUID
    /// The task this tab belongs to; nil for a tab opened outside any session. It changes only when the
    /// tab moves to another task (`BrowserHostClient.move(_:toSession:select:)`).
    fileprivate(set) var session: UUID?
    private weak var client: BrowserHostClient?
    private(set) var isClosed = false
    /// The page's current address, as the host last reported it.
    private(set) var currentURL: String?
    /// The last address that was a page (not empty, not about:blank), to open again.
    private(set) var lastPageURL: String?
    /// The size the tab was opened or last resized at, for the tabs its page opens.
    fileprivate(set) var viewport: BrowserViewport?
    /// The screen size the page is shown at instead of its view's own, and who chose it; nil while the page
    /// takes its view's size (`emulate(_:)`).
    private(set) var emulation: BrowserViewportEmulation?
    /// The color scheme the agent emulates (`browser_resize` colorScheme), "light" or "dark"; nil follows the Mac.
    private(set) var emulatedColorScheme: String?
    /// The size the tab was last given without an emulation, which a tab no panel shows takes again.
    private var ownViewport: BrowserViewport?
    /// This Chromium's major version and brands, read from the page before any phone was emulated.
    private var browserIdentity: (major: String, brands: [JSONValue])?
    /// Called when `emulation` changes, for the panel that shows the tab.
    var onEmulationChange: (() -> Void)?
    /// The agent handed the tab to the person (`browser_handoff`), until the agent's wait ends.
    private(set) var handoff: BrowserHandoff?
    /// Called when `handoff` changes, for the panel that shows the tab.
    var onHandoffChange: (() -> Void)?
    /// The page's title and navigation state, as the host last reported them, for a panel that
    /// fronts the tab later.
    private(set) var title = ""
    private(set) var isLoading = false
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    /// The tab's page does not respond: Chromium says its renderer has not handled input for 15
    /// seconds, or it has not answered a DevTools call its renderer answers. Nil once it answers, its
    /// renderer ended, or within 15 seconds of Wait.
    var unresponsive: BrowserTabUnresponsiveness? {
        if hangReported, waitedUntil.map({ ContinuousClock.now >= $0 }) ?? true { return .hangMonitor }
        return unanswered.map { .unanswered(method: $0) }
    }
    fileprivate var hangReported = false
    fileprivate var waitedUntil: ContinuousClock.Instant?
    private var unanswered: String?
    /// The tab's renderer ended (it crashed, ran out of memory or was killed); nil once the tab loads
    /// again, which starts another renderer.
    private(set) var crash: BrowserTabCrash?
    /// The host could not open the tab, so it has no page: why, as the host said. Such a tab opens
    /// again in its place (`BrowserHostClient.replace`), as Chrome's Reload does for its error page.
    private(set) var openFailure: BrowserTabOpenFailure?
    /// The tabs this tab's page opened (new-window requests, `openedTab`).
    private(set) var openedTabs: Set<BrowserTabID> = []
    /// What the page asks permission for and waits on, until the person answers or the page moves on.
    private(set) var permissionPrompt: BrowserPermissionPrompt?
    /// Another app's address the page asked to open, waiting for the person (the panel's bar), until the page
    /// moves on.
    fileprivate(set) var externalAppQuestion: BrowserExternalAppQuestion?
    /// Pop-ups the page opened without a click, which the browser blocked as Chrome does, in order (Chrome's
    /// address-bar list, at most 25), until the page moves on.
    private(set) var blockedPopups: [String] = []
    /// The person's last input to the page: a click or key press in its panel, or an address, Back, Forward or
    /// Reload there (`notePersonInput`).
    fileprivate(set) var lastPersonInput: ContinuousClock.Instant?
    /// The page's last request to open another app (Chrome's flood guard waits for the next input).
    fileprivate var lastExternalAppRequest: ContinuousClock.Instant?
    /// The person closed the tab and its page is asked first (`BrowserHostClient.requestClose`); false once it
    /// closes or the person stays.
    fileprivate(set) var isClosing = false
    /// The page's leave-page question during that close ("Leave site?"), for the panel that shows the tab.
    private(set) var closeQuestion: BrowserJavaScriptDialog?
    /// The page's focused field is a password field, as the host last reported (false once the renderer
    /// ends), for a panel that shows the tab later.
    private(set) var isPasswordFieldFocused = false
    /// The page's icon as PNG, which the host downloads through the page's own profile; nil until
    /// one arrives, and again once the tab goes to another site.
    private(set) var favicon: Data?
    /// The page whose icon `favicon` is, by host.
    private var faviconHost: String?
    fileprivate(set) var panelCount = 0
    /// Attached panels that are not on screen (`BrowserHostClient.setPanelOccluded`).
    fileprivate(set) var occludedPanelCount = 0
    /// A panel has shown the tab at some point.
    fileprivate(set) var wasPanelAttached = false
    fileprivate(set) var lastAgentActivity: ContinuousClock.Instant?
    fileprivate let openedAt = ContinuousClock.now
    /// Whether the engine was last told the tab is shown (a new tab starts shown).
    fileprivate(set) var isShown = true
    /// The panel's primary handler.
    var eventHandler: ((BrowserHostEvent) -> Void)?
    /// Called whenever the agent reports using this tab.
    var onAgentActivity: (() -> Void)?
    private var observers: [UUID: (BrowserHostEvent) -> Void] = [:]
    private(set) lazy var devTools: BrowserDevToolsClient = {
        let devTools = BrowserDevToolsClient { [weak self] message in
            guard let self, !self.isClosed, self.openFailure == nil else { return false }
            self.client?.send(.devTools(tab: self.id, message: message))
            return self.client?.isHostRunning == true
        }
        devTools.onTimeout = { [weak self] method in self?.devToolsTimedOut(method) }
        devTools.onAnswer = { [weak self] method in self?.devToolsAnswered(method) }
        return devTools
    }()

    /// DevTools calls the page's renderer answers (its main thread): all but the moves, which the
    /// browser answers once the new page commits and a slow server keeps waiting.
    static func needsRenderer(_ method: String) -> Bool {
        !["Page.navigate", "Page.reload", "Page.navigateToHistoryEntry"].contains(method)
            && !method.hasPrefix("Target.") && !method.hasPrefix("Browser.")
    }

    /// Wait: a page that missed a call is taken as answering until it misses another; one Chromium
    /// reports stays hidden for 15 seconds, as Chrome's Wait waits.
    fileprivate func wait(until deadline: ContinuousClock.Instant) {
        unanswered = nil
        if hangReported { waitedUntil = deadline }
    }

    private func devToolsTimedOut(_ method: String) {
        guard !isClosed, unanswered == nil, Self.needsRenderer(method) else { return }
        unanswered = method
        client?.pageDidNotAnswer(self)
    }

    private func devToolsAnswered(_ method: String) {
        guard unanswered != nil, Self.needsRenderer(method) else { return }
        unanswered = nil
        client?.pageDidNotAnswer(self)
    }

    init(id: BrowserTabID, client: BrowserHostClient, session: UUID? = nil, key: UUID = UUID()) {
        self.id = id
        self.client = client
        self.session = session
        self.key = key
    }

    var isPanelAttached: Bool { panelCount > 0 }
    /// Attached panels that are on screen.
    var visiblePanelCount: Int { panelCount - occludedPanelCount }

    func send(_ command: BrowserHostCommand) {
        guard !isClosed else { return }
        switch command {
        case .resize(_, let viewport):
            self.viewport = viewport
            if emulation == nil { ownViewport = viewport }
        case .mouse(_, let input) where input.kind == .down:
            lastPersonInput = .now
        case .key(_, let input) where input.kind == .rawDown:
            lastPersonInput = .now
        case .javaScriptDialogResult(_, let dialog, let accepted, _) where dialog == closeQuestion?.id:
            closeQuestion = nil
            if !accepted {
                isClosing = false
                client?.closeStayed(self)
            }
        default:
            break
        }
        client?.send(command)
    }

    /// The person used the page from its panel without a click or key press on it: an address, Back, Forward
    /// or Reload.
    func notePersonInput() {
        lastPersonInput = .now
    }

    /// The agent's input came after the person's last (or the person has not used the page): what the page does
    /// now follows the agent.
    var isDrivenByAgent: Bool {
        guard let agent = lastAgentActivity else { return false }
        return lastPersonInput.map { agent > $0 } ?? true
    }

    /// The person's answer to the page's request to open another app.
    func answerExternalApp(open: Bool, alwaysAllow: Bool) {
        guard let question = externalAppQuestion else { return }
        externalAppQuestion = nil
        client?.answer(question, open: open, alwaysAllow: alwaysAllow, on: self)
    }

    fileprivate func forgetBlockedPopup(_ url: String) {
        blockedPopups.removeAll { $0 == url }
    }

    func close() {
        client?.closeTab(self)
    }

    /// Fronts this tab in its task's strip.
    func select() {
        client?.select(self)
    }

    /// Adds an event observer besides `eventHandler` (the agent's tools use this).
    @discardableResult
    func addEventObserver(_ observer: @escaping (BrowserHostEvent) -> Void) -> UUID {
        let token = UUID()
        observers[token] = observer
        return token
    }

    func removeEventObserver(_ token: UUID) {
        observers[token] = nil
    }

    /// Answers the page's permission prompt.
    func answerPermission(_ result: BrowserPermissionResult) {
        guard let prompt = permissionPrompt else { return }
        permissionPrompt = nil
        send(.permissionResult(tab: id, prompt: prompt.id, result: result))
    }

    /// Reports agent use of this tab to the lifetime manager.
    func noteAgentActivity() {
        client?.noteAgentActivity(on: self)
    }

    // MARK: Screen size emulation

    /// Shows the page at `emulation`'s size, or at its view's own again for nil, as the Claude app's Browser pane
    /// does over CDP: the page lays out at the size (a phone also gets touch and Android Chrome's user agent), and
    /// the tab is drawn at it, so a panel shows it scaled down and the page's coordinates stay the agent's. It holds
    /// across reloads and navigations, since the tab's DevTools session keeps it.
    func emulate(_ emulation: BrowserViewportEmulation?) async throws {
        // The size the tab has before its first emulation is its own, which it takes again after the last.
        if self.emulation == nil { ownViewport = viewport }
        self.emulation = emulation
        onEmulationChange?()
        let timeout: Duration = .seconds(15)
        if let emulation {
            _ = try await devTools.send("Emulation.setDeviceMetricsOverride", emulation.deviceMetrics, timeout: timeout)
            _ = try await devTools.send("Emulation.setTouchEmulationEnabled", emulation.mobile
                ? ["enabled": .bool(true), "maxTouchPoints": .integer(5)] : ["enabled": .bool(false)], timeout: timeout)
            if emulation.mobile {
                let identity = try await readBrowserIdentity()
                _ = try await devTools.send("Emulation.setUserAgentOverride", [
                    "userAgent": .string(BrowserViewportEmulation.phoneUserAgent(chromeMajor: identity.major)),
                    "userAgentMetadata": BrowserViewportEmulation.phoneUserAgentMetadata(brands: identity.brands)
                ], timeout: timeout)
            } else {
                _ = try await devTools.send("Emulation.setUserAgentOverride", ["userAgent": .string("")], timeout: timeout)
            }
        } else {
            _ = try await devTools.send("Emulation.clearDeviceMetricsOverride", timeout: timeout)
            _ = try await devTools.send("Emulation.setTouchEmulationEnabled", ["enabled": .bool(false)], timeout: timeout)
            _ = try await devTools.send("Emulation.setUserAgentOverride", ["userAgent": .string("")], timeout: timeout)
        }
        // A panel showing the tab draws it at the size itself (`onEmulationChange`); without one the tab does.
        guard !isPanelAttached, var size = emulation == nil ? ownViewport ?? viewport : viewport else { return }
        if let emulation {
            size.width = Double(emulation.width)
            size.height = Double(emulation.height)
        }
        send(.resize(tab: id, viewport: size))
    }

    /// Emulates `prefers-color-scheme` ("light" or "dark") on the page, or follows the Mac again for nil.
    func emulateColorScheme(_ scheme: String?) async throws {
        emulatedColorScheme = scheme
        _ = try await devTools.send("Emulation.setEmulatedMedia", [
            "features": .array([.object(["name": .string("prefers-color-scheme"), "value": .string(scheme ?? "")])])
        ], timeout: .seconds(15))
    }

    // MARK: Handing the tab to the person

    /// The agent hands the tab to the person for a step only they can take. A handoff still waiting for them takes the
    /// new reason, and one they answered after the agent's last wait gave up is returned as it is, so the call reads
    /// the answer. Returns the handoff and whether it is new.
    func handOff(reason: String) -> (handoff: BrowserHandoff, isNew: Bool) {
        if var earlier = handoff, earlier.answer != .turnEnded {
            if earlier.answer == nil {
                earlier.reason = reason
                handoff = earlier
                onHandoffChange?()
            }
            return (earlier, false)
        }
        let new = BrowserHandoff(id: UUID(), reason: reason)
        handoff = new
        onHandoffChange?()
        return (new, true)
    }

    /// The person's answer from the panel's bar, or the end of the agent's turn.
    func answerHandoff(_ answer: BrowserHandoff.Answer) {
        guard var waiting = handoff, waiting.answer == nil else { return }
        waiting.answer = answer
        handoff = waiting
        onHandoffChange?()
    }

    /// The agent's wait read the answer: the tab is the agent's again.
    func endHandoff() {
        guard handoff != nil else { return }
        handoff = nil
        onHandoffChange?()
    }

    /// The agent's turn ended: the size and color scheme it set go, as the Claude app clears them; the person's stay.
    func endAgentEmulation() async {
        // A waiting call reads that the turn ended; an answer no call read belongs to the turn that ended.
        if handoff?.answer == nil { answerHandoff(.turnEnded) } else { endHandoff() }
        if emulation?.owner == .agent { try? await emulate(nil) }
        if emulatedColorScheme != nil { try? await emulateColorScheme(nil) }
    }

    private func readBrowserIdentity() async throws -> (major: String, brands: [JSONValue]) {
        if let browserIdentity { return browserIdentity }
        let read = try await devTools.send("Runtime.evaluate", [
            "expression": .string("[navigator.userAgent, navigator.userAgentData ? navigator.userAgentData.brands : []]"),
            "returnByValue": .bool(true)
        ], timeout: .seconds(15))
        let values = read["result"]?["value"]?.arrayValue ?? []
        let identity = (major: BrowserViewportEmulation.chromeMajor(in: values.first?.stringValue ?? "") ?? "154",
                        brands: values.count > 1 ? values[1].arrayValue ?? [] : [])
        browserIdentity = identity
        return identity
    }

    fileprivate func markClosed() {
        isClosed = true
        devTools.failPending()
    }

    fileprivate func receive(_ event: BrowserHostEvent) {
        switch event {
        case .devTools(_, let message):
            devTools.receive(message)
        case .address(_, let url):
            currentURL = url
            if !url.isEmpty, url != "about:blank" { lastPageURL = url }
            // Another site's icon is not this page's; the same site's stays until its own arrives.
            if favicon != nil, URL(string: url)?.host() != faviconHost {
                favicon = nil
                faviconHost = nil
            }
        case .title(_, let title):
            self.title = title
        case .favicon(_, let url, let png):
            favicon = png.isEmpty ? nil : png
            faviconHost = URL(string: currentURL ?? url)?.host()
        case .loading(_, let isLoading, let canGoBack, let canGoForward):
            self.isLoading = isLoading
            self.canGoBack = canGoBack
            self.canGoForward = canGoForward
            if isLoading { crash = nil }
        case .responsiveness(_, let isResponsive):
            hangReported = !isResponsive
            waitedUntil = nil
            if isResponsive { unanswered = nil }
        case .pageCrashed(_, let reason, let status, let code):
            hangReported = false
            waitedUntil = nil
            unanswered = nil
            crash = BrowserTabCrash(status: status ?? "crashed", code: code ?? 0, errorCode: reason)
        case .passwordField(_, let isFocused):
            isPasswordFieldFocused = isFocused
        case .failed(let message, _?, let limit):
            openFailure = BrowserTabOpenFailure(message: message, limit: limit)
        case .openedTab(_, let newTab?, _):
            openedTabs.insert(newTab)
        case .newWindow(_, let url, _, false):
            // Chrome keeps the first 25 (PopupBlockerTabHelper kMaximumNumberOfPopups).
            if blockedPopups.count < 25 { blockedPopups.append(url) }
        case .newDocument:
            blockedPopups = []
            externalAppQuestion = nil
        case .javaScriptDialog(_, let dialog) where dialog.kind == .beforeUnload && isClosing:
            closeQuestion = dialog
        case .javaScriptDialogReset:
            closeQuestion = nil
        case .permissionPrompt(_, let prompt):
            permissionPrompt = prompt
        case .permissionPromptDismissed(_, let prompt):
            if permissionPrompt?.id == prompt { permissionPrompt = nil }
        case .terminated, .closed:
            isClosed = true
            permissionPrompt = nil
            externalAppQuestion = nil
            closeQuestion = nil
            devTools.failPending()
        default:
            break
        }
        eventHandler?(event)
        for observer in observers.values { observer(event) }
    }
}

/// A tab the agent handed to the person (`browser_handoff`): what it asks of them, and how it ended.
struct BrowserHandoff: Equatable, Sendable {
    enum Answer: Equatable, Sendable {
        /// The person's Done.
        case done
        /// The person's Decline.
        case declined
        /// The agent's turn ended first.
        case turnEnded
    }

    let id: UUID
    var reason: String
    var answer: Answer?
}

/// One of Chromium's own windows in the host, as the host tells what it is.
struct BrowserChromiumWindow: Equatable, Sendable {
    enum Kind: String, Sendable {
        /// Chromium's passkey dialog (a passkey, a phone's QR code, a security key).
        case passkey
        /// Chromium's sign-in window for a site's HTTP authentication.
        case signIn
        /// The system's print dialog (`window.print()`, the PDF viewer's Print).
        case print
        case other
    }
    var title: String
    var kind: Kind
    /// The window's number in the host (`presentChromiumWindows` names it).
    var id: Int = 0
    /// The tab the window is over; nil when the host does not know it (the print dialog).
    var tab: BrowserTabID?
}

/// A task's tabs as they were when the host ended: their addresses and side-panel keys in strip order
/// and which was fronted.
struct BrowserRememberedTabs: Equatable, Sendable {
    var addresses: [String]
    /// One per address; an address without one opens as a new side-panel tab.
    var keys: [UUID] = []
    var fronted: Int

    func key(at index: Int) -> UUID {
        keys.indices.contains(index) ? keys[index] : UUID()
    }
}

/// Why the host could not open a tab, as it said (`BrowserHostEvent.failed`).
struct BrowserTabOpenFailure: Equatable, Sendable {
    let message: String
    /// The most tabs the host holds, when that many were open.
    let limit: Int?
}

/// Why a tab's page is not responding.
/// How a tab's renderer ended, as CEF reports it.
struct BrowserTabCrash: Equatable, Sendable {
    /// CEF's termination status: "crashed", "oom", "killed", "abnormal", "launch-failed" …
    let status: String
    /// The exit code: the signal's number when it crashed.
    let code: Int
    /// Chrome's sad tab's "Error code", as the host names it: SIGTRAP (a failed CHECK), SIGSEGV, Out of
    /// Memory …
    let errorCode: String
}

enum BrowserTabUnresponsiveness: Equatable, Sendable {
    /// Chromium's hang monitor: the renderer has not handled input for 15 seconds (the host reads it
    /// every second, and holds the hang monitor's callback to end the renderer where Chromium gives one).
    case hangMonitor
    /// The page did not answer `method`, a DevTools call its renderer answers, in time.
    case unanswered(method: String)
}

/// The tab is no longer open.
struct BrowserTabGoneError: LocalizedError, Equatable {
    var errorDescription: String? { "The browser tab is no longer open." }
}

/// The task already has a tab for that side-panel tab.
struct BrowserTabKeyInUseError: LocalizedError, Equatable {
    var errorDescription: String? { "This task already has a browser tab for that side-panel tab." }
}

/// A task already has `BrowserHostClient.maxTabsPerSession` tabs.
struct BrowserTabLimitError: LocalizedError, Equatable {
    var errorDescription: String? {
        "This task already has \(BrowserHostClient.maxTabsPerSession) browser tabs. Close one to open another."
    }
}
