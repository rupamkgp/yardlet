import Foundation

/// Chrome DevTools Protocol as the browser tools use it. `BrowserDevToolsClient` provides it for
/// any host that speaks CDP (CEF, WebView2); tests provide a scripted one.
@MainActor
protocol BrowserAgentCDP: AnyObject {
    func send(_ method: String, _ params: [String: JSONValue], timeout: Duration) async throws -> JSONValue
    /// A command for a frame from another site, on its own session (`frameSessions`); nil is the tab's own.
    func send(_ method: String, _ params: [String: JSONValue], session: String?, timeout: Duration) async throws -> JSONValue
    /// Every CDP event of the tab's own session received so far, oldest first.
    var eventLog: [(method: String, params: JSONValue)] { get }
    /// The page's frames from other sites, each on a session of its own, once `attachFrames()` asked for them.
    var frameSessions: [BrowserFrameSession] { get }
    func attachFrames() async throws
}

extension BrowserAgentCDP {
    /// A connection without frame sessions (tests) answers only for the tab's own.
    func send(_ method: String, _ params: [String: JSONValue], session: String?, timeout: Duration) async throws -> JSONValue {
        guard session == nil else { throw BrowserDevToolsError.closed }
        return try await send(method, params, timeout: timeout)
    }
    var frameSessions: [BrowserFrameSession] { [] }
    func attachFrames() async throws {}
}

extension BrowserDevToolsClient: BrowserAgentCDP {
    var eventLog: [(method: String, params: JSONValue)] { events }

    func send(_ method: String, _ params: [String: JSONValue], timeout: Duration) async throws -> JSONValue {
        try await send(method, params, session: nil, timeout: timeout)
    }
}

/// One task's page as the tools see it: its CDP connection, the references of its latest
/// snapshot, and what the host reported that CDP does not carry (a JavaScript dialog or a file
/// chooser waiting for an answer, a navigation the address policy blocked).
@MainActor
final class BrowserAgentPage {
    let cdp: any BrowserAgentCDP
    let tabID: BrowserTabID
    /// Sends a host command for this tab (dialog answers).
    private let sendCommand: (BrowserHostCommand) -> Void
    /// The task's project folders, the only places a file upload may come from.
    var workspaceRoots: [URL] = []
    /// Whether the tab's page responds (`BrowserTab.unresponsive`); tests leave it responding.
    var unresponsive: () -> BrowserTabUnresponsiveness? = { nil }
    /// How the tab's renderer ended, until the page loads again (`BrowserTab.crash`).
    var crash: () -> BrowserTabCrash? = { nil }
    /// Why the host could not open the tab, which then has no page (`BrowserTab.openFailure`).
    var openFailure: () -> BrowserTabOpenFailure? = { nil }
    /// The size the host draws the tab at (`BrowserTab.viewport`); nil in tests.
    var viewport: () -> BrowserViewport? = { nil }
    /// The screen size the tab's page is shown at, and who chose it (`BrowserTab.emulation`).
    var emulation: () -> BrowserViewportEmulation? = { nil }
    /// Shows the page at a screen size, or its own again (`BrowserTab.emulate`).
    var emulate: (BrowserViewportEmulation?) async throws -> Void = { _ in
        throw BrowserAgentToolError("This browser cannot emulate a screen size.")
    }
    /// The side-panel tab this is (`BrowserTab.key`), for the panel to show it; nil in tests.
    var tabKey: UUID?
    /// Whether the tab closed.
    var isClosed: () -> Bool = { false }
    /// Hands the tab to the person (`BrowserTab.handOff`), reads the handoff, and ends it.
    var handOff: (String) -> (handoff: BrowserHandoff, isNew: Bool)? = { _ in nil }
    var handoff: () -> BrowserHandoff? = { nil }
    var endHandoff: () -> Void = {}
    /// Emulates a color scheme, or follows the Mac again (`BrowserTab.emulateColorScheme`).
    var emulateColorScheme: (String?) async throws -> Void = { _ in
        throw BrowserAgentToolError("This browser cannot emulate a color scheme.")
    }
    /// What the vault last filled into this page, until the field is gone or the page navigates.
    var vaultFill: BrowserAgentVaultFill?
    /// The vault's passkey waiting in this tab's authenticator for the page's next request.
    var armedPasskey: BrowserAgentArmedPasskey? {
        didSet { onArmedPasskeyChange?(self) }
    }
    /// The tools keep the pages that hold a passkey, to take them all back when the vault is turned off.
    var onArmedPasskeyChange: ((BrowserAgentPage) -> Void)?

    /// `@e3` → its element (a backend DOM node, and the session of its frame), from the latest snapshot.
    private(set) var refs: [String: BrowserAgentSnapshot.Ref] = [:]
    /// Where each frame from another site sits, from the latest snapshot: its iframe, in the session of the frame
    /// that holds it.
    private(set) var frameOwners: [String: BrowserAgentSnapshot.Ref] = [:]
    private(set) var snapshotCount = 0
    /// Where the event log stood at the latest snapshot. A main-frame navigation after it ends the
    /// references even when the old document is kept alive (the back/forward cache), where its
    /// nodes would still answer with their old positions.
    private(set) var snapshotEventMark = 0
    var domainsEnabled = false

    /// A JavaScript dialog the page is paused on.
    private(set) var dialog: BrowserJavaScriptDialog?
    /// A file chooser waiting for files.
    private(set) var fileDialog: BrowserFileDialog?
    /// A permission the page asks for, which only the person answers (the panel's bar).
    private(set) var permissionPrompt: BrowserPermissionPrompt?
    /// Addresses the host's policy refused that no tool result has named yet, oldest first. A
    /// refusal can arrive just after the tool that caused it answered, so the next result names it.
    private(set) var blockedNavigations: [String] = []
    private var dialogWatchers: [UUID: () -> Void] = [:]

    init(cdp: any BrowserAgentCDP, tabID: BrowserTabID = 0, send: @escaping (BrowserHostCommand) -> Void = { _ in }) {
        self.cdp = cdp
        self.tabID = tabID
        sendCommand = send
    }

    // MARK: References

    func replaceRefs(_ refs: [String: BrowserAgentSnapshot.Ref], frameOwners: [String: BrowserAgentSnapshot.Ref] = [:],
                     eventMark: Int) {
        self.refs = refs
        self.frameOwners = frameOwners
        snapshotEventMark = eventMark
        snapshotCount += 1
    }

    func clearRefs() {
        refs = [:]
    }

    /// True when the main frame navigated since the latest snapshot.
    var navigatedSinceSnapshot: Bool {
        let log = cdp.eventLog
        guard log.count > snapshotEventMark else { return false }
        return log[snapshotEventMark...].contains {
            $0.method == "Page.frameNavigated" && $0.params["frame"]?["parentId"] == nil
        }
    }

    // MARK: Host events

    func receive(_ event: BrowserHostEvent) {
        switch event {
        case .javaScriptDialog(_, let dialog):
            self.dialog = dialog
            let watchers = dialogWatchers.values
            dialogWatchers = [:]
            watchers.forEach { $0() }
        case .javaScriptDialogReset:
            dialog = nil
        case .fileDialog(_, let dialog):
            fileDialog = dialog
        case .permissionPrompt(_, let prompt):
            permissionPrompt = prompt
        case .permissionPromptDismissed(_, let prompt):
            if permissionPrompt?.id == prompt { permissionPrompt = nil }
        case .navigationBlocked(_, let url):
            blockedNavigations.append(url)
            if blockedNavigations.count > 50 { blockedNavigations.removeFirst(25) }
        case .openedTab(_, let newTab, let url):
            openedTabs.append((newTab, url))
        case .newWindow(_, let url, _, false):
            blockedPopups.append(url)
            if blockedPopups.count > 25 { blockedPopups.removeFirst() }
        case .externalAppHandled(_, let url, let app, let outcome):
            externalApps.append((url, app, outcome))
            if externalApps.count > 25 { externalApps.removeFirst() }
        case .closed, .terminated, .pageCrashed:
            dialog = nil
            fileDialog = nil
            permissionPrompt = nil
        default:
            break
        }
    }

    /// New-window requests the page made since the last tool said so: the tab each opened (nil when
    /// the task had no room and the page went there itself) and its address.
    private(set) var openedTabs: [(tab: BrowserTabID?, url: String)] = []

    func takeOpenedTabs() -> [(tab: BrowserTabID?, url: String)] {
        defer { openedTabs = [] }
        return openedTabs
    }

    /// Pop-ups the page opened without a click, which the browser blocked, since the last tool said so.
    private(set) var blockedPopups: [String] = []

    func takeBlockedPopups() -> [String] {
        defer { blockedPopups = [] }
        return blockedPopups
    }

    /// What came of the page's requests to open other apps' addresses since the last tool said so.
    private(set) var externalApps: [(url: String, app: String?, outcome: BrowserExternalAppOutcome)] = []

    func takeExternalApps() -> [(url: String, app: String?, outcome: BrowserExternalAppOutcome)] {
        defer { externalApps = [] }
        return externalApps
    }

    /// The refusals not yet named, which are then counted as named.
    func takeBlockedNavigations() -> [String] {
        defer { blockedNavigations = [] }
        return blockedNavigations
    }

    /// Calls `watcher` once, when a JavaScript dialog opens.
    func watchForDialog(_ watcher: @escaping () -> Void) -> UUID {
        let token = UUID()
        dialogWatchers[token] = watcher
        return token
    }

    func stopWatchingForDialog(_ token: UUID) {
        dialogWatchers[token] = nil
    }

    func answerDialog(accept: Bool, text: String?) -> BrowserJavaScriptDialog? {
        guard let dialog else { return nil }
        self.dialog = nil
        sendCommand(.javaScriptDialogResult(tab: tabID, dialog: dialog.id, accepted: accept, text: text))
        return dialog
    }

    /// Draws the tab at another size (the full-page screenshot, for the moment it captures).
    func resize(to viewport: BrowserViewport) {
        sendCommand(.resize(tab: tabID, viewport: viewport))
    }

    func answerFileDialog(paths: [String]?) -> BrowserFileDialog? {
        guard let fileDialog else { return nil }
        self.fileDialog = nil
        sendCommand(.fileDialogResult(tab: tabID, dialog: fileDialog.id, paths: paths))
        return fileDialog
    }
}
