import Foundation
import YardletAgentTools

/// The app's side of `browser_handoff`: it shows the handed-over tab in the task's panel and tells the person, and
/// takes the notice back when the handoff ends.
@MainActor
protocol BrowserHandoffPresenting: AnyObject {
    /// `notice` names this handoff's notification.
    func handoffStarted(session: UUID, tabKey: UUID?, reason: String, notice: String)
    func handoffEnded(notice: String)
    /// The longest one call from the task's harness may wait (`SessionToolPolicy.waitCeiling`).
    func handoffWaitCeiling(for session: UUID) -> Duration
}

struct BrowserAgentToolError: Error, Equatable {
    var message: String

    init(_ message: String) {
        self.message = message
    }
}

/// Runs the browser tools against a task's pages over CDP. Input is trusted CDP input
/// (`Input.dispatchMouseEvent`, `Input.dispatchKeyEvent`, `Input.insertText`), so pages see it as
/// the user's own. A tool acts on the tab its `tabId` names, else on the task's active tab; the tab
/// tools go to the task's tab directory.
@MainActor
final class BrowserAgentTools {
    /// The page of the task's tab with the given id, or of its active tab for nil.
    typealias PageProvider = @MainActor (UUID, String?) async throws -> BrowserAgentPage

    private let pages: PageProvider
    private let directory: (any BrowserAgentTabDirectory)?
    private let closePage: @MainActor (UUID) -> Void
    /// The task's project folders, for file uploads and the `file:` pages it opens freely. The broker, which
    /// learns them when a task is injected, sets this.
    var workspaceRoots: @MainActor (UUID) -> [URL]
    /// Whether the task may open a file outside its folders, given its real path: the app answers yes at once
    /// for a task that runs without asking, whose shell reads the file anyway, and asks the person on the
    /// task's request card otherwise (`AppModel.allowsBrowserFile`). Without the app (tests) it is refused.
    var allowsFileOutsideFolders: @MainActor (UUID, String) async -> Bool = { _, _ in false }
    /// The files outside its folders each task was let open, so a page that shows one asks once.
    private var openedOutsideFolders: [UUID: Set<String>] = [:]
    /// Where the copies of uploaded files go (`BrowserAgentWorkspaceFile.privateCopy`): the broker's private
    /// folder, which goes when Yardlet quits.
    var uploadFolder = FileManager.default.temporaryDirectory
        .appending(path: "Yardlet-uploads-\(ProcessInfo.processInfo.processIdentifier)", directoryHint: .isDirectory)
    /// Chromium on macOS needs editing commands with key events (see `BrowserAgentKeyPress`).
    private let usesMacEditingCommands: Bool
    /// How often text waits look again.
    var pollInterval: Duration = .milliseconds(200)
    var commandTimeout: Duration = .seconds(15)
    var loadTimeout: Duration = .seconds(30)
    /// The vault `browser_fill_credential` asks (design docs/BROWSER_VAULT_DESIGN.md); nil leaves the tool refusing.
    var vault: VaultCenter?
    /// Values the vault filled lately, which no result may carry back.
    var vaultScrub = VaultScrubList()
    /// Counts armed passkeys, so a passkey's timer leaves alone one armed after it.
    var passkeyGeneration = 0
    /// Pages holding an armed passkey (weakly).
    var pagesWithPasskeys: [ObjectIdentifier: () -> BrowserAgentPage?] = [:]
    /// The app, which shows a handed-over tab and tells the person; nil (tests) hands over without telling anyone.
    weak var handoffs: (any BrowserHandoffPresenting)?
    /// How long `browser_handoff` waits when the call does not say.
    static let handoffDefaultWait: Duration = .seconds(600)
    /// The notifications of each task's handoffs not ended yet, which go when its turn ends.
    private var handoffNotices: [UUID: Set<String>] = [:]

    /// Tools that still work while a JavaScript dialog pauses the page.
    private static let usableDuringDialog: Set<String> = [
        AgentToolCatalog.handleDialog, AgentToolCatalog.fileUpload, AgentToolCatalog.consoleMessages
    ]
    /// Tools that send the page input events (CDP `Input.*`), which Chromium drops while a window of its own is over
    /// the tab, as Chrome does under a tab's dialog: what each sends.
    private static let inputTools: [String: String] = [
        AgentToolCatalog.click: "click", AgentToolCatalog.type: "typing", AgentToolCatalog.pressKey: "key press",
        AgentToolCatalog.scroll: "scroll"
    ]

    /// The tools over a task's tab directory (the app's `BrowserAgentTabs`).
    init(
        usesMacEditingCommands: Bool,
        tabs: any BrowserAgentTabDirectory,
        workspaceRoots: @escaping @MainActor (UUID) -> [URL] = { _ in [] }
    ) {
        self.usesMacEditingCommands = usesMacEditingCommands
        self.pages = { [unowned tabs] session, tabID in try tabs.page(for: session, tabID: tabID) }
        directory = tabs
        closePage = { [unowned tabs] in tabs.closeAll(for: $0) }
        self.workspaceRoots = workspaceRoots
    }

    /// The tools over one page per task, without the tab tools (tests and stand-ins).
    init(
        usesMacEditingCommands: Bool,
        pages: @escaping @MainActor (UUID) async throws -> BrowserAgentPage,
        closePage: @escaping @MainActor (UUID) -> Void = { _ in },
        workspaceRoots: @escaping @MainActor (UUID) -> [URL] = { _ in [] }
    ) {
        self.usesMacEditingCommands = usesMacEditingCommands
        self.pages = { session, _ in try await pages(session) }
        directory = nil
        self.closePage = closePage
        self.workspaceRoots = workspaceRoots
    }

    func closeTab(for sessionID: UUID) {
        closePage(sessionID)
        openedOutsideFolders.removeValue(forKey: sessionID)
    }

    /// The task's turn ended: what the agent set on its tabs for the turn goes (screen sizes, color schemes).
    func taskTurnEnded(_ sessionID: UUID) async {
        for notice in handoffNotices.removeValue(forKey: sessionID) ?? [] { handoffs?.handoffEnded(notice: notice) }
        await directory?.endAgentEmulation(for: sessionID)
    }

    /// The notification of a handoff, by its id.
    static func handoffNotice(_ id: UUID) -> String { "yardlet-handoff-\(id.uuidString)" }

    func run(tool: String, arguments: JSONValue, sessionID: UUID) async -> AgentToolResult {
        guard AgentToolCatalog.definition(named: tool) != nil || VaultToolCatalog.definition(named: tool) != nil else {
            return .error("Unknown Yardlet tool: \(tool)")
        }
        let result: AgentToolResult
        if AgentToolCatalog.tabToolNames.contains(tool) {
            result = runTabTool(tool, arguments, sessionID: sessionID)
        } else if tool == AgentToolCatalog.batch {
            result = await batch(arguments, sessionID: sessionID)
        } else {
            result = await runOnPage(tool, arguments, sessionID: sessionID).result
        }
        return vaultScrub.scrub(result)
    }

    /// A page tool on the tab it names. browser_navigate on a tab whose page does not respond, or that the
    /// host could not open, opens the tab in its place first (`BrowserAgentTabDirectory.replace`), since
    /// that page cannot move.
    private func runOnPage(_ tool: String, _ arguments: JSONValue, sessionID: UUID) async
        -> (result: AgentToolResult, page: BrowserAgentPage?) {
        switch await page(for: sessionID, arguments) {
        case .success(var page):
            var replaced: String?
            let stuck = page.unresponsive(), unopened = page.openFailure()
            if tool == AgentToolCatalog.navigate, stuck != nil || unopened != nil, let directory {
                do {
                    let old = page.tabID
                    page = try directory.replace(String(old), for: sessionID)
                    page.workspaceRoots = workspaceRoots(sessionID)
                    replaced = stuck.map {
                        "Tab \(old)'s page was not responding (\(Self.describe($0))); the tab was opened again in its "
                            + "place as tabId \"\(page.tabID)\", and the address loaded there."
                    } ?? "Tab \(old) could not open (\(unopened?.message ?? "")); the tab was opened again in its place as "
                        + "tabId \"\(page.tabID)\"."
                } catch let error as BrowserAgentToolError {
                    return (.error(error.message), page)
                } catch {
                    return (.error(Self.describe(error)), page)
                }
            }
            var result = await run(tool, arguments, on: page, sessionID: sessionID)
            if let replaced { result.content.insert(.text(replaced), at: 0) }
            return (result, page)
        case .failure(let error): return (.error(error.message), nil)
        }
    }

    /// The page a tool's `tabId` names, or the task's active page.
    private func page(for sessionID: UUID, _ arguments: JSONValue) async -> Result<BrowserAgentPage, BrowserAgentToolError> {
        do {
            let page = try await pages(sessionID, arguments["tabId"]?.stringValue)
            page.workspaceRoots = workspaceRoots(sessionID)
            // A tab the memory saver discarded loads its page again as the tool reaches it.
            await page.untilRestored()
            return .success(page)
        } catch let error as BrowserAgentToolError {
            return .failure(error)
        } catch {
            return .failure(BrowserAgentToolError("The browser could not start: \(error.localizedDescription)"))
        }
    }

    // MARK: - Tabs

    private func runTabTool(_ tool: String, _ arguments: JSONValue, sessionID: UUID) -> AgentToolResult {
        guard let directory else { return .error("This browser keeps one tab per task.") }
        do {
            switch tool {
            case AgentToolCatalog.tabList:
                let (tabs, panelOpen) = try directory.tabs(for: sessionID)
                let listing = JSONValue.object([
                    "panelOpen": .bool(panelOpen),
                    "tabs": .array(tabs.map { tab in
                        var fields: [String: JSONValue] = ["tabId": .string(tab.id), "origin": .string(tab.origin),
                                                           "isActive": .bool(tab.isActive), "responding": .bool(tab.isResponding)]
                        if tab.isShown { fields["shownInPanel"] = .bool(true) }
                        if tab.personUse != nil { fields["personUsing"] = .bool(true) }
                        return .object(fields)
                    })
                ])
                let shown = tabs.first(where: \.isShown)
                var note = tabs.isEmpty
                    ? "This task has no browser tab yet; browser_navigate or browser_tab_new opens one."
                    : panelOpen
                    ? "The task's browser panel is open and shows " + (shown.map { "tab \($0.id)" } ?? "a tab")
                        + "; other tabs run in the background."
                    : "The task's browser panel is closed: the pages still work, as background pages, so timing and "
                        + "animation can be off. Prefer browser_snapshot to screenshots for reading them."
                if let active = tabs.first(where: \.isActive), let shown, active.id != shown.id {
                    note += " Tools without a tabId act on tab \(active.id), your active tab."
                }
                if let used = tabs.first(where: { $0.personUse != nil }), let use = used.personUse {
                    note += " The person is using tab \(used.id) there (\(Self.describe(use)))."
                }
                let stuck = tabs.filter { !$0.isResponding && $0.crash == nil && $0.openFailure == nil }.map(\.id)
                let stuckNote = stuck.isEmpty ? "" : "\nNot responding: tab " + stuck.joined(separator: ", tab ")
                    + " (its page's renderer is busy; browser_navigate opens a page again in its place, browser_tab_close closes it)."
                let crashed = tabs.compactMap { tab in tab.crash.map { "tab \(tab.id) (\($0))" } }
                let crashNote = crashed.isEmpty ? "" : "\nCrashed: " + crashed.joined(separator: ", ")
                    + " (its page's renderer ended; browser_navigate opens a page again in its place, browser_tab_close closes it)."
                let unopened = tabs.compactMap { tab in tab.openFailure.map { "tab \(tab.id) (\($0))" } }
                let unopenedNote = unopened.isEmpty ? "" : "\nCould not open: " + unopened.joined(separator: ", ")
                    + " (it has no page; browser_navigate opens it again in its place, browser_tab_close closes it)."
                return .text(Self.json(listing) + "\n" + note + stuckNote + crashNote + unopenedNote)
            case AgentToolCatalog.tabNew:
                let foreground = arguments["foreground"]?.boolValue ?? false
                let tab = try directory.newTab(for: sessionID, foreground: foreground)
                let where_ = tab.isActive ? Self.activeTabText(directory.personTab(for: sessionID), besides: tab.id, opened: true)
                    : "It opened behind the active tab."
                return .text(Self.json(.object(["tabId": .string(tab.id), "isActive": .bool(tab.isActive)]))
                    + "\nOpened a blank tab. \(where_) Load a page with browser_navigate and tabId \"\(tab.id)\".")
            case AgentToolCatalog.tabSelect:
                guard let id = arguments["tabId"]?.stringValue else { throw BrowserAgentToolError("browser_tab_select needs a tabId.") }
                try directory.select(id, for: sessionID)
                return .text("Tab \(id) " + Self.activeTabText(directory.personTab(for: sessionID), besides: id, opened: false))
            case AgentToolCatalog.tabClose:
                guard let id = arguments["tabId"]?.stringValue else { throw BrowserAgentToolError("browser_tab_close needs a tabId.") }
                let active = try directory.close(id, for: sessionID)
                return .text(active.map { "Closed tab \(id). Tab \($0.id) is now the active tab." }
                    ?? "Closed tab \(id), the task's last tab.")
            default:
                throw BrowserAgentToolError("Unknown Yardlet tool: \(tool)")
            }
        } catch let error as BrowserAgentToolError {
            return .error(error.message)
        } catch {
            return .error(error.localizedDescription)
        }
    }

    /// Where the agent's active tab stands: shown in the panel, or behind the tab the person keeps there.
    private static func activeTabText(_ person: BrowserAgentTabInfo?, besides id: String, opened: Bool) -> String {
        let subject = opened ? "It is" : "is now"
        guard let person, person.id != id, let use = person.personUse else { return "\(subject) the active tab." }
        return "\(subject) your active tab: tools without a tabId act on it. The browser panel stays on tab \(person.id), "
            + "which the person is using (\(describe(use)))."
    }

    /// How the person is using a tab, as a fact.
    static func describe(_ use: BrowserPersonUse) -> String {
        if use.hasKeyboard { return "the page has their keyboard" }
        guard let seconds = use.secondsSinceInput else { return "they are on it" }
        return seconds < 2 ? "their last input to it was just now" : "their last input to it was \(seconds) seconds ago"
    }

    /// A tool on the tab the person is using says so: the fact and the ways to a tab of the agent's own.
    private func personNote(_ page: BrowserAgentPage, sessionID: UUID?) -> String? {
        guard let sessionID, let person = directory?.personTab(for: sessionID), person.id == String(page.tabID),
              let use = person.personUse else { return nil }
        return "The person is using this tab in the browser panel (\(Self.describe(use))), so what you do here happens "
            + "on the page they are working in. browser_tab_new opens a tab of your own; browser_handoff hands this one "
            + "to them."
    }

    private static func json(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    func run(_ tool: String, _ arguments: JSONValue, on page: BrowserAgentPage, sessionID: UUID? = nil) async -> AgentToolResult {
        if let dialog = page.dialog, !Self.usableDuringDialog.contains(tool) {
            return .error("\(Self.describe(dialog)) The page is paused until you answer it with browser_handle_dialog.")
        }
        // Input the tab would drop is not sent and does not read as done; reading the page and moving it still work.
        if let input = Self.inputTools[tool] {
            let over = browserDialogs(sessionID).own.filter { $0.tab == page.tabID }
            if !over.isEmpty {
                return .error("The \(input) was not sent to tab \(page.tabID). " + Self.describeBrowserDialog(over)
                    + " browser_handle_dialog with accept false closes it; " + Self.closeOutcome(over) + ".")
            }
        }
        do {
            // Answering a dialog or a file chooser needs no CDP, and CDP waits while a dialog is open.
            if page.dialog == nil, tool != AgentToolCatalog.handleDialog, tool != AgentToolCatalog.fileUpload {
                try await enableDomains(page)
            }
            // A file a link, a script or an iframe brought into the page is let in as browser_navigate lets it.
            if tool != AgentToolCatalog.navigate, tool != AgentToolCatalog.handleDialog {
                for address in page.shownFiles().sorted() {
                    try await allowFile(address, on: page, sessionID: sessionID, shown: true)
                }
            }
            var result = try await perform(tool, arguments, on: page, sessionID: sessionID)
            result.content += notices(after: tool, on: page, sessionID: sessionID).map { .text($0) }
            if let note = unresponsiveNote(page) { result.content.append(.text(note)) }
            if let note = personNote(page, sessionID: sessionID) { result.content.append(.text(note)) }
            return result
        } catch is BrowserAgentDialogOpened {
            let dialog = page.dialog.map(Self.describe) ?? "A JavaScript dialog opened."
            return .text("\(dialog) It opened during \(tool). The page is paused until you answer it with "
                + "browser_handle_dialog.")
        } catch let error as BrowserAgentToolError {
            return failure(error.message, after: tool, on: page, sessionID: sessionID)
        } catch {
            return failure(Self.describe(error), after: tool, on: page, sessionID: sessionID)
        }
    }

    /// A page tool's failure, with what is known of the tab. A tab the host could not open failed for that
    /// alone: its calls are refused, which would otherwise read as a browser that is not running.
    private func failure(_ message: String, after tool: String, on page: BrowserAgentPage, sessionID: UUID?) -> AgentToolResult {
        if page.openFailure() != nil, let note = unresponsiveNote(page) { return .error(note) }
        return .error(message + browserDialogNote(after: tool, sessionID: sessionID) + (unresponsiveNote(page).map { "\n" + $0 } ?? ""))
    }

    /// What is known when the tab's page does not respond, its renderer ended, or the host could not open
    /// it: a fact, with the tools that act on the tab.
    private func unresponsiveNote(_ page: BrowserAgentPage) -> String? {
        if let unopened = page.openFailure() {
            return "This tab could not open: \(unopened.message). It has no page. browser_navigate opens it again in its "
                + "place; browser_tab_close closes the tab."
        }
        if let stuck = page.unresponsive() {
            return "This tab's page is not responding: \(Self.describe(stuck)). The browser host and the tab are open; "
                + "a tab the panel does not show still answers. browser_navigate opens a page again in its place; "
                + "browser_tab_close closes the tab."
        }
        guard let crash = page.crash() else { return nil }
        return "This tab's page crashed: its renderer ended (error code \(crash.errorCode)). The browser host and the "
            + "tab are open. browser_navigate opens a page again in its place; browser_tab_close closes the tab."
    }

    static func describe(_ stuck: BrowserTabUnresponsiveness) -> String {
        switch stuck {
        case .hangMonitor:
            "Chromium reports that its renderer has not handled input for 15 seconds (its main thread is busy, "
                + "such as a script that has not returned)"
        case .unanswered(let method):
            "its renderer did not answer \(method) in time (its main thread is busy, such as a script that has "
                + "not returned)"
        }
    }

    /// Chromium's windows over the task's tabs, and those whose tab is not known; none without a task (tests).
    private func browserDialogs(_ sessionID: UUID?) -> (own: [BrowserChromiumWindow], unknownTab: [BrowserChromiumWindow]) {
        guard let sessionID, let directory else { return ([], []) }
        return directory.browserDialogs(for: sessionID)
    }

    /// A failed tool still says that a window of Chromium's own waits over one of the task's tabs: it is often why
    /// a page stopped. So may one whose tab is not known (the print dialog), which may be another task's.
    private func browserDialogNote(after tool: String, sessionID: UUID?) -> String {
        guard tool != AgentToolCatalog.handleDialog else { return "" }
        let (own, unknownTab) = browserDialogs(sessionID)
        var notes: [String] = []
        if !own.isEmpty { notes.append(Self.describeBrowserDialog(own) + " browser_handle_dialog with accept false closes it.") }
        if !unknownTab.isEmpty { notes.append(Self.describeUnknownTabDialog(unknownTab)) }
        return notes.map { "\n" + $0 }.joined()
    }

    /// What the page did besides the tool's own result: a dialog or file chooser now waiting, or an
    /// address the policy refused.
    private func notices(after tool: String, on page: BrowserAgentPage, sessionID: UUID?) -> [String] {
        var notices: [String] = []
        let blocked = page.takeBlockedNavigations()
        if !blocked.isEmpty {
            let urls = blocked.joined(separator: ", ")
            notices.append("The page tried to open \(urls), which the browser's address policy blocks.")
        }
        if page.takeFilledValueBlocks() > 0 {
            notices.append("The page tried to go to an address carrying the password Yardlet filled into it (a form that "
                + "sends its fields in the address, as one without method=\"post\" does). Yardlet stopped it before anything "
                + "was sent, and the page stayed where it was. If the page's own script had not loaded yet, wait for it and "
                + "click its sign-in button again; otherwise hand the tab to the person with browser_handoff.")
        }
        for opened in page.takeOpenedTabs() {
            notices.append(opened.tab.map { "The page opened \(opened.url) in a new tab (tabId \"\($0)\"); "
                + "browser_tab_list shows which tab is active." }
                ?? "The page opened \(opened.url) in place: this task already has its most tabs.")
        }
        for popup in page.takeBlockedPopups() {
            notices.append("The page tried to open \(popup) in a pop-up without a click; the browser blocked it, as Chrome "
                + "does, and lists it in the panel for the person. browser_tab_new opens that address in a tab of its own.")
        }
        for request in page.takeExternalApps() {
            notices.append(Self.describe(request))
        }
        // Only the task's own: another task's window is over that task's tab, not this one's.
        let own = browserDialogs(sessionID).own
        if !own.isEmpty, tool != AgentToolCatalog.handleDialog {
            notices.append(Self.describeBrowserDialog(own) + " browser_handle_dialog with accept false closes it; "
                + Self.closeOutcome(own) + ".")
        }
        if let dialog = page.dialog, tool != AgentToolCatalog.handleDialog {
            notices.append("\(Self.describe(dialog)) Answer it with browser_handle_dialog.")
        }
        if let prompt = page.permissionPrompt {
            notices.append("The page (\(prompt.origin)) asks permission for \(prompt.permissions.joined(separator: ", ")) and "
                + "waits: only the person can answer, in the browser panel's bar (Allow or Block).")
        }
        if let chooser = page.fileDialog, tool != AgentToolCatalog.fileUpload {
            let title = chooser.title.isEmpty ? "" : " “\(chooser.title)”"
            notices.append("A file chooser\(title) is open (\(chooser.mode.rawValue)). Answer it with browser_file_upload, "
                + "or cancel it with no paths.")
        }
        return notices
    }

    /// Chromium's own windows over the task's tabs, which wait for the person: the passkey dialog, a site's sign-in
    /// window (HTTP authentication). Chromium ties each to its tab, as Chrome does: the person sees it over the tab
    /// where a panel shows the tab, and the tab takes no input meanwhile.
    static func describeBrowserDialog(_ windows: [BrowserChromiumWindow]) -> String {
        let described = kinds(of: windows).map { kind in
            let named = name(of: kind, in: windows)
            let name = named.prefix(1).uppercased() + named.dropFirst()
            let place = Self.over(windows.filter { $0.kind == kind })
            return switch kind {
            case .passkey:
                "\(name) is open \(place): it waits for the person at this Mac (a passkey, a phone's QR code or a security "
                    + "key, or a note that none is available), and the page's request waits until it closes."
            case .signIn:
                "\(name) is open \(place): it asks the person at this Mac for a username and password, and the page waits "
                    + "until it closes."
            case .print:
                "\(name) is open \(place): it waits for the person at this Mac, and the page waits until it closes."
            case .other:
                "\(name) is open \(place) and waits for the person at this Mac."
            }
        }
        let tabs = windows.contains { $0.tab != nil }
        return (described + (tabs ? ["Chromium ignores input to that tab until it closes. The person sees it only while this task's "
            + "browser panel shows that tab; browser_handoff shows the tab to the person."] : [])).joined(separator: " ")
    }

    /// "over tab 32", "over tabs 32 and 39".
    private static func over(_ windows: [BrowserChromiumWindow]) -> String {
        let tabs = Array(Set(windows.compactMap(\.tab))).sorted().map(String.init)
        return switch tabs.count {
        case 0: "over the browser"
        case 1: "over tab \(tabs[0])"
        default: "over tabs \(tabs.dropLast().joined(separator: ", ")) and \(tabs.last!)"
        }
    }

    /// Chromium's windows whose tab the browser does not know (the print dialog runs without one): they may be
    /// another task's, and only the person closes them.
    static func describeUnknownTabDialog(_ windows: [BrowserChromiumWindow]) -> String {
        let names = kinds(of: windows).map { name(of: $0, in: windows) }.joined(separator: " and ")
        return names.prefix(1).uppercased() + names.dropFirst() + " is open in the browser, and which tab opened it is not known, "
            + "so it may be another task's. It waits for the person at this Mac, who alone can close it."
    }

    /// What closing those windows does to the page.
    static func closeOutcome(_ windows: [BrowserChromiumWindow]) -> String {
        kinds(of: windows).map { kind in
            switch kind {
            case .passkey: "the page's passkey request then gets NotAllowedError"
            case .signIn: "the sign-in is then cancelled and the page shows what the site sends without it (often 401 Unauthorized)"
            case .print: "printing is then cancelled"
            case .other: "the window is then cancelled"
            }
        }.joined(separator: "; ")
    }

    private static func kinds(of windows: [BrowserChromiumWindow]) -> [BrowserChromiumWindow.Kind] {
        windows.reduce(into: []) { if !$0.contains($1.kind) { $0.append($1.kind) } }
    }

    /// "Chromium's passkey dialog “…”", "Chromium's sign-in window for the site's HTTP authentication", …
    private static func name(of kind: BrowserChromiumWindow.Kind, in windows: [BrowserChromiumWindow]) -> String {
        let named = windows.filter { $0.kind == kind && !$0.title.isEmpty }.map(\.title)
        let title = named.isEmpty ? "" : " “\(named.joined(separator: "”, “"))”"
        return switch kind {
        case .passkey: "Chromium's passkey dialog\(title)"
        case .signIn: "Chromium's sign-in window for the site's HTTP authentication\(title)"
        case .print: "the system's print dialog\(title)"
        case .other: "a window of Chromium's own\(title)"
        }
    }

    /// What came of the page's request to open another app's address.
    static func describe(_ request: (url: String, app: String?, outcome: BrowserExternalAppOutcome)) -> String {
        let app = request.app ?? "another app"
        switch request.outcome {
        case .asked:
            return "The page asks to open \(request.url) in \(app), an app outside the browser, and waits: only the person can "
                + "answer, in the browser panel's bar (Open or Cancel). Nothing opens on the agent's input alone."
        case .opened:
            return "The page opened \(request.url) in \(app), outside the browser."
        case .noApp:
            return "The page tried to open \(request.url), which no app on this Mac opens; nothing happened."
        case .ignored:
            return "The page asked again to open \(request.url) in another app; as in Chrome, the browser lets that through only "
                + "after the next click or key press."
        }
    }

    static func describe(_ dialog: BrowserJavaScriptDialog) -> String {
        let kind = dialog.kind == .beforeUnload ? "leave-page" : dialog.kind.rawValue
        var text = "A JavaScript \(kind) dialog from \(dialog.origin) is open: “\(dialog.message)”."
        if dialog.kind == .prompt, !dialog.defaultPrompt.isEmpty { text += " Default text: “\(dialog.defaultPrompt)”." }
        return text
    }

    // MARK: - Dispatch

    private func perform(_ tool: String, _ arguments: JSONValue, on page: BrowserAgentPage,
                         sessionID: UUID?) async throws -> AgentToolResult {
        switch tool {
        case VaultToolCatalog.fillCredential: try await fillCredential(arguments, on: page, sessionID: sessionID)
        case AgentToolCatalog.navigate: try await navigate(arguments, on: page, sessionID: sessionID)
        case AgentToolCatalog.snapshot: try await snapshot(on: page)
        case AgentToolCatalog.click: try await click(arguments, on: page)
        case AgentToolCatalog.type: try await type(arguments, on: page)
        case AgentToolCatalog.pressKey: try await pressKey(arguments, on: page)
        case AgentToolCatalog.scroll: try await scroll(arguments, on: page)
        case AgentToolCatalog.selectOption: try await selectOption(arguments, on: page)
        case AgentToolCatalog.waitFor: try await waitFor(arguments, on: page)
        case AgentToolCatalog.screenshot: try await screenshot(arguments, on: page)
        case AgentToolCatalog.consoleMessages: consoleMessages(arguments, on: page)
        case AgentToolCatalog.evaluate: try await evaluate(arguments, on: page)
        case AgentToolCatalog.handleDialog: try handleDialog(arguments, on: page, sessionID: sessionID)
        case AgentToolCatalog.fileUpload: try await fileUpload(arguments, on: page)
        case AgentToolCatalog.resize: try await resize(arguments, on: page)
        case AgentToolCatalog.handoff: try await handOff(arguments, on: page, sessionID: sessionID)
        default: throw BrowserAgentToolError("Unknown Yardlet tool: \(tool)")
        }
    }

    private func enableDomains(_ page: BrowserAgentPage) async throws {
        guard !page.domainsEnabled else { return }
        // Runtime replays the console messages logged before it was enabled; Log replays its buffer.
        for domain in ["Page", "Runtime", "Log"] {
            _ = try await send(page, "\(domain).enable")
        }
        // Frames from other sites (a payment form, an embedded sign-in) answer on sessions of their own.
        try? await page.cdp.attachFrames()
        // The files the page shows already; the frame navigations logged since Page.enable follow.
        let mark = page.cdp.eventLog.count
        page.seedFrames(try await send(page, "Page.getFrameTree"), eventMark: mark)
        page.domainsEnabled = true
    }

    /// Lets a `file:` address through when its real path is in the task's folders, the task was let open it
    /// before, or `allowsFileOutsideFolders` says yes; throws otherwise. `shown` is for a file the page
    /// already shows.
    private func allowFile(_ address: String, on page: BrowserAgentPage, sessionID: UUID?, shown: Bool = false) async throws {
        guard let path = BrowserAgentWorkspaceFile.realPath(ofFileAddress: address),
              !BrowserAgentWorkspaceFile.isInside(path, roots: page.workspaceRoots) else { return }
        if let sessionID, openedOutsideFolders[sessionID]?.contains(path) == true { return }
        guard let sessionID, await allowsFileOutsideFolders(sessionID, path) else {
            throw BrowserAgentToolError(shown
                ? "The page shows \(path), a file outside this task's folders, and the person did not allow opening it."
                : "The person did not allow opening \(path).")
        }
        openedOutsideFolders[sessionID, default: []].insert(path)
    }

    // MARK: - Tools

    private func navigate(_ arguments: JSONValue, on page: BrowserAgentPage, sessionID: UUID?) async throws -> AgentToolResult {
        guard let input = arguments["url"]?.stringValue else {
            throw BrowserAgentToolError("browser_navigate needs a url.")
        }
        // The panel's address rule, which the host enforces again on every navigation.
        let url: String
        do {
            url = try BrowserURLPolicy.resolve(input)
        } catch BrowserURLPolicy.AddressError.blockedScheme(let scheme) {
            throw BrowserAgentToolError("The browser does not open \(scheme): addresses; it opens "
                + BrowserURLPolicy.allowedSchemes.sorted().joined(separator: ", ") + ".")
        } catch {
            throw BrowserAgentToolError("\(input) is not an address the browser can open.")
        }
        // A file outside the task's folders, after `..` and symbolic links, opens only as the task's shell could read it.
        try await allowFile(url, on: page, sessionID: sessionID)
        let mark = page.cdp.eventLog.count
        let blockedMark = page.blockedNavigations.count
        let result = try await send(page, "Page.navigate", ["url": .string(url)], timeout: loadTimeout)
        page.clearRefs()
        if let failure = result["errorText"]?.stringValue, !failure.isEmpty {
            // The host refuses in its own navigation hook, which Chromium reports as an abort.
            for _ in 0..<10 where page.blockedNavigations.count == blockedMark {
                try? await Task.sleep(for: .milliseconds(50))
            }
            if page.blockedNavigations.count > blockedMark {
                // Name what was refused: a redirect can lead somewhere other than `url`.
                throw BrowserAgentToolError("The browser's address policy blocked "
                    + page.takeBlockedNavigations().joined(separator: ", ") + ".")
            }
            throw BrowserAgentToolError("Could not load \(url): \(failure)")
        }
        if page.blockedNavigations.count > blockedMark {
            throw BrowserAgentToolError("The browser's address policy blocked "
                + page.takeBlockedNavigations().joined(separator: ", ") + ".")
        }
        var note = ""
        // A same-document navigation (a fragment change) has no loader and fires no load event.
        if result["loaderId"]?.stringValue != nil {
            let loaded = await waitForEvent(on: page, after: mark, timeout: loadTimeout) { method, _ in
                method == "Page.loadEventFired"
            } stopWhen: {
                page.blockedNavigations.count > blockedMark || page.dialog != nil
            }
            if page.blockedNavigations.count > blockedMark {
                throw BrowserAgentToolError("The browser's address policy blocked "
                    + page.takeBlockedNavigations().joined(separator: ", ") + ".")
            }
            if page.dialog != nil { throw BrowserAgentDialogOpened() }
            if !loaded { note = "\nThe page is still loading." }
        }
        let location = try await pageLocation(page)
        return .text("Loaded \(location.url)\nTitle: \(location.title)\(note)")
    }

    private func snapshot(on page: BrowserAgentPage) async throws -> AgentToolResult {
        let mark = page.cdp.eventLog.count
        let read = try await readFrames(page)
        let rendered = BrowserAgentSnapshot.render(frames: read.frames)
        page.replaceRefs(rendered.refs, frameOwners: read.owners, eventMark: mark)
        let location = try await pageLocation(page)
        return .text("Page URL: \(location.url)\nPage title: \(location.title)\n\n\(rendered.text)")
    }

    /// How long one frame's tree may take; a frame that does not answer in time is left out of the snapshot.
    private static let frameTimeout: Duration = .seconds(5)

    /// The page's accessibility trees, frame by frame (Chromium gives each document its own): the main frame, the
    /// frames that render in its process (by `frameId`), and each frame from another site on its own session
    /// (`BrowserFrameSession`) with the frames of its process. Each frame is placed under the iframe that holds it
    /// (`DOM.getFrameOwner`), and `owners` keeps where each other-site frame's iframe is, for its coordinates.
    private func readFrames(_ page: BrowserAgentPage) async throws
        -> (frames: [BrowserAgentSnapshot.Frame], owners: [String: BrowserAgentSnapshot.Ref]) {
        let main = try await send(page, "Accessibility.getFullAXTree")
        var frames = [BrowserAgentSnapshot.Frame(nodes: main["nodes"]?.arrayValue ?? [])]
        let sessions = page.cdp.frameSessions
        let remote = Set(sessions.map(\.frameID))
        await addProcessFrames(of: nil, root: 0, to: &frames, skipping: remote, on: page)
        var roots: [String: Int] = [:]
        for session in sessions {
            guard let tree = try? await send(page, "Accessibility.getFullAXTree", session: session.id,
                                             timeout: Self.frameTimeout) else { continue }
            frames.append(BrowserAgentSnapshot.Frame(nodes: tree["nodes"]?.arrayValue ?? [], session: session.id))
            roots[session.id] = frames.count - 1
            await addProcessFrames(of: session.id, root: frames.count - 1, to: &frames, skipping: remote, on: page)
        }
        var owners: [String: BrowserAgentSnapshot.Ref] = [:]
        for session in sessions {
            guard let index = roots[session.id],
                  let owner = try? await send(page, "DOM.getFrameOwner", ["frameId": .string(session.frameID)],
                                              session: session.parent, timeout: Self.frameTimeout)["backendNodeId"]?.integerValue
            else { continue }
            owners[session.id] = BrowserAgentSnapshot.Ref(node: Int(owner), session: session.parent)
            if let holder = frames.indices.first(where: { frames[$0].session == session.parent && frames[$0].holds(Int(owner)) }) {
                frames[holder].children[Int(owner)] = index
            }
        }
        return (frames, owners)
    }

    /// The frames below `root` that render in the same process as it: each one's tree, under its iframe.
    private func addProcessFrames(of session: String?, root: Int, to frames: inout [BrowserAgentSnapshot.Frame],
                                  skipping remote: Set<String>, on page: BrowserAgentPage) async {
        guard let tree = try? await send(page, "Page.getFrameTree", session: session, timeout: Self.frameTimeout),
              let top = tree["frameTree"] else { return }
        var indexByFrame: [String: Int] = [:]
        if let id = top["frame"]?["id"]?.stringValue { indexByFrame[id] = root }
        var pending = top["childFrames"]?.arrayValue ?? []
        while !pending.isEmpty {
            let child = pending.removeFirst()
            guard let id = child["frame"]?["id"]?.stringValue, !remote.contains(id),
                  let parent = child["frame"]?["parentId"]?.stringValue.flatMap({ indexByFrame[$0] }),
                  let nodes = try? await send(page, "Accessibility.getFullAXTree", ["frameId": .string(id)], session: session,
                                              timeout: Self.frameTimeout)["nodes"]?.arrayValue,
                  let owner = try? await send(page, "DOM.getFrameOwner", ["frameId": .string(id)], session: session,
                                              timeout: Self.frameTimeout)["backendNodeId"]?.integerValue
            else { continue }
            frames.append(BrowserAgentSnapshot.Frame(nodes: nodes, session: session))
            frames[parent].children[Int(owner)] = frames.count - 1
            indexByFrame[id] = frames.count - 1
            pending += child["childFrames"]?.arrayValue ?? []
        }
    }

    private func click(_ arguments: JSONValue, on page: BrowserAgentPage) async throws -> AgentToolResult {
        let point: (x: Double, y: Double)
        let target: String
        if let ref = arguments["ref"]?.stringValue {
            point = try await center(of: ref, on: page)
            target = ref
        } else if let x = arguments["x"]?.doubleValue, let y = arguments["y"]?.doubleValue {
            point = (x, y)
            target = "(\(Self.format(x)), \(Self.format(y)))"
        } else {
            throw BrowserAgentToolError("browser_click needs a ref from browser_snapshot, or x and y.")
        }
        let button = arguments["button"]?.stringValue ?? "left"
        guard ["left", "right", "middle"].contains(button) else {
            throw BrowserAgentToolError("button must be left, right, or middle.")
        }
        var modifiers = 0
        for name in arguments["modifiers"]?.arrayValue?.compactMap(\.stringValue) ?? [] {
            guard let modifier = BrowserAgentKeyPress.Modifier(rawValue: name) else {
                throw BrowserAgentToolError("Unknown modifier \(name); use Alt, Control, Meta, or Shift.")
            }
            modifiers |= modifier.bit
        }
        let clicks = arguments["doubleClick"]?.boolValue == true ? 2 : 1
        let buttons: Int64 = button == "left" ? 1 : button == "right" ? 2 : 4
        let base: [String: JSONValue] = [
            "x": .number(point.x), "y": .number(point.y), "modifiers": .integer(Int64(modifiers))
        ]
        _ = try await send(page, "Input.dispatchMouseEvent", base.merging(["type": .string("mouseMoved")]) { $1 })
        for count in 1...clicks {
            let press = base.merging([
                "button": .string(button), "clickCount": .integer(Int64(count))
            ]) { $1 }
            _ = try await send(page, "Input.dispatchMouseEvent",
                               press.merging(["type": .string("mousePressed"), "buttons": .integer(buttons)]) { $1 })
            _ = try await send(page, "Input.dispatchMouseEvent",
                               press.merging(["type": .string("mouseReleased"), "buttons": .integer(0)]) { $1 })
        }
        let what = clicks == 2 ? "Double-clicked" : button == "left" ? "Clicked" : "Clicked with the \(button) button"
        return .text("\(what) \(target) at (\(Self.format(point.x)), \(Self.format(point.y))).")
    }

    private func type(_ arguments: JSONValue, on page: BrowserAgentPage) async throws -> AgentToolResult {
        guard let ref = arguments["ref"]?.stringValue, let text = arguments["text"]?.stringValue else {
            throw BrowserAgentToolError("browser_type needs a ref and text.")
        }
        let element = try self.element(ref, on: page)
        do {
            _ = try await send(page, "DOM.focus", ["backendNodeId": .integer(Int64(element.node))], session: element.session, ref: ref)
        } catch let error as BrowserAgentToolError where !error.message.contains(" is stale") {
            throw BrowserAgentToolError("\(ref) cannot take keyboard focus, so it is not a text field.")
        }
        let kind = try await call(page, ref: ref, element: element, function: """
            function() {
              if (this instanceof HTMLInputElement || this instanceof HTMLTextAreaElement) {
                if (this.readOnly || this.disabled) return 'readonly';
                this.select();
                return 'field';
              }
              if (this.isContentEditable) {
                const range = document.createRange();
                range.selectNodeContents(this);
                const selection = window.getSelection();
                selection.removeAllRanges();
                selection.addRange(range);
                return 'editable';
              }
              return 'other';
            }
            """)
        switch kind.stringValue {
        case "readonly": throw BrowserAgentToolError("\(ref) is read-only or disabled.")
        case "other": throw BrowserAgentToolError("\(ref) is not an editable text field.")
        default: break
        }
        if text.isEmpty {
            try await dispatch(BrowserAgentKeyPress.parse("Backspace")!, on: page)
        } else {
            _ = try await send(page, "Input.insertText", ["text": .string(text)])
        }
        var summary = "Typed \(text.count) characters into \(ref)"
        if arguments["submit"]?.boolValue == true {
            try await dispatch(BrowserAgentKeyPress.parse("Enter")!, on: page)
            summary += " and pressed Enter"
        }
        return .text(summary + ".")
    }

    private func pressKey(_ arguments: JSONValue, on page: BrowserAgentPage) async throws -> AgentToolResult {
        guard let name = arguments["key"]?.stringValue else {
            throw BrowserAgentToolError("browser_press_key needs a key.")
        }
        guard let press = BrowserAgentKeyPress.parse(name) else {
            throw BrowserAgentToolError("Unknown key \(name). Use names like Enter, Tab, Escape, ArrowDown, "
                + "Backspace, or one character, with modifiers joined by + (Shift+Tab, Meta+a).")
        }
        try await dispatch(press, on: page)
        return .text("Pressed \(name).")
    }

    private func scroll(_ arguments: JSONValue, on page: BrowserAgentPage) async throws -> AgentToolResult {
        let deltaX = arguments["deltaX"]?.doubleValue ?? 0
        let deltaY = arguments["deltaY"]?.doubleValue ?? 0
        let ref = arguments["ref"]?.stringValue
        if deltaX == 0, deltaY == 0 {
            guard let ref else { throw BrowserAgentToolError("browser_scroll needs deltaX or deltaY, or a ref.") }
            try await scrollIntoView(ref, try element(ref, on: page), on: page)
        } else {
            let point: (x: Double, y: Double)
            if let ref {
                point = try await center(of: ref, on: page)
            } else if let x = arguments["x"]?.doubleValue, let y = arguments["y"]?.doubleValue {
                point = (x, y)
            } else {
                let viewport = try await viewport(page)
                point = (viewport.width / 2, viewport.height / 2)
            }
            _ = try await send(page, "Input.dispatchMouseEvent", [
                "type": .string("mouseWheel"), "x": .number(point.x), "y": .number(point.y),
                "deltaX": .number(deltaX), "deltaY": .number(deltaY)
            ])
            // Wheel scrolling finishes asynchronously in the compositor.
            try? await Task.sleep(for: .milliseconds(150))
        }
        let position = try await evaluateValue(page, "[Math.round(scrollX), Math.round(scrollY), "
            + "document.documentElement.scrollWidth, document.documentElement.scrollHeight]")
        let values = position.arrayValue?.compactMap(\.doubleValue) ?? []
        guard values.count == 4 else { return .text("Scrolled.") }
        return .text("Scrolled. The page is at x=\(Self.format(values[0])), y=\(Self.format(values[1])) of "
            + "\(Self.format(values[2]))×\(Self.format(values[3])).")
    }

    private func selectOption(_ arguments: JSONValue, on page: BrowserAgentPage) async throws -> AgentToolResult {
        guard let ref = arguments["ref"]?.stringValue,
              let values = arguments["values"]?.arrayValue?.compactMap(\.stringValue), !values.isEmpty else {
            throw BrowserAgentToolError("browser_select_option needs a ref and at least one value.")
        }
        let element = try self.element(ref, on: page)
        let outcome = try await call(page, ref: ref, element: element, arguments: [.object(["value": .array(values.map { .string($0) })])],
                                     function: """
            function(wanted) {
              if (!(this instanceof HTMLSelectElement)) return { error: 'is not a select element' };
              if (this.disabled) return { error: 'is disabled' };
              const options = Array.from(this.options);
              const chosen = [];
              for (const value of (this.multiple ? wanted : wanted.slice(0, 1))) {
                const match = options.find(o => o.value === value)
                  || options.find(o => o.label.trim() === value.trim() || o.text.trim() === value.trim());
                if (!match) return { error: 'has no option "' + value + '"', options: options.map(o => o.label || o.value) };
                chosen.push(match);
              }
              this.focus();
              for (const option of options) option.selected = chosen.includes(option);
              this.dispatchEvent(new Event('input', { bubbles: true }));
              this.dispatchEvent(new Event('change', { bubbles: true }));
              return { selected: chosen.map(o => o.label || o.value) };
            }
            """)
        if let error = outcome["error"]?.stringValue {
            let options = outcome["options"]?.arrayValue?.compactMap(\.stringValue) ?? []
            let list = options.isEmpty ? "" : " Options: " + options.prefix(50).joined(separator: ", ")
            throw BrowserAgentToolError("\(ref) \(error).\(list)")
        }
        let selected = outcome["selected"]?.arrayValue?.compactMap(\.stringValue) ?? []
        return .text("Selected \(selected.map { "\"\($0)\"" }.joined(separator: ", ")) in \(ref).")
    }

    private func waitFor(_ arguments: JSONValue, on page: BrowserAgentPage) async throws -> AgentToolResult {
        let appears = arguments["text"]?.stringValue
        let disappears = arguments["textGone"]?.stringValue
        guard appears != nil || disappears != nil else {
            guard let seconds = arguments["time"]?.doubleValue, seconds >= 0 else {
                throw BrowserAgentToolError("browser_wait_for needs text, textGone, or time.")
            }
            let capped = min(seconds, 30)
            try? await Task.sleep(for: .milliseconds(Int(capped * 1000)))
            return .text("Waited \(Self.format(capped)) seconds.")
        }
        let timeout = min(max(arguments["timeout"]?.doubleValue ?? 10, 0), 60)
        let deadline = ContinuousClock.now + .milliseconds(Int(timeout * 1000))
        while true {
            let body = try await evaluateValue(page, "document.body ? document.body.innerText : ''").stringValue ?? ""
            let appeared = appears.map { body.contains($0) } ?? true
            let gone = disappears.map { !body.contains($0) } ?? true
            if appeared && gone {
                let parts = [appears.map { "\"\($0)\" appeared" }, disappears.map { "\"\($0)\" is gone" }].compactMap { $0 }
                return .text(parts.joined(separator: " and ") + ".")
            }
            guard ContinuousClock.now < deadline else {
                let wanted = appears.map { "\"\($0)\" to appear" } ?? "\"\(disappears ?? "")\" to disappear"
                throw BrowserAgentToolError("Waited \(Self.format(timeout)) seconds for \(wanted); it did not.")
            }
            try? await Task.sleep(for: pollInterval)
        }
    }

    private func screenshot(_ arguments: JSONValue, on page: BrowserAgentPage) async throws -> AgentToolResult {
        let format = arguments["format"]?.stringValue ?? "png"
        guard ["png", "jpeg"].contains(format) else { throw BrowserAgentToolError("format must be png or jpeg.") }
        let metrics = try await send(page, "Page.getLayoutMetrics")
        let visual = metrics["cssVisualViewport"]
        let pageX = visual?["pageX"]?.doubleValue ?? 0
        let pageY = visual?["pageY"]?.doubleValue ?? 0
        // Images are made at one pixel per CSS pixel, whatever the display scale.
        let pixelRatio = try await evaluateValue(page, "devicePixelRatio").doubleValue ?? 1
        let scale = 1 / max(pixelRatio, 0.1)
        var params: [String: JSONValue] = ["format": .string(format)]
        if format == "jpeg" { params["quality"] = .integer(80) }
        let fullPage = arguments["ref"] == nil && arguments["fullPage"]?.boolValue == true
        var pageHeight = 0.0
        let clip: (x: Double, y: Double, width: Double, height: Double)
        if let ref = arguments["ref"]?.stringValue {
            let element = try self.element(ref, on: page)
            try await scrollIntoView(ref, element, on: page)
            let box = try await bounds(of: ref, element: element, on: page)
            let scrolled = try await send(page, "Page.getLayoutMetrics")["cssVisualViewport"]
            clip = (box.x + (scrolled?["pageX"]?.doubleValue ?? 0), box.y + (scrolled?["pageY"]?.doubleValue ?? 0),
                    box.width, box.height)
        } else if fullPage {
            let content = metrics["cssContentSize"]
            pageHeight = content?["height"]?.doubleValue ?? 0
            // The view drawn for the capture is a GPU texture, at most 16,384 device pixels a side.
            let most = ((16_384 - 4) / max(pixelRatio, 0.1)).rounded(.down)
            clip = (0, 0, min(content?["width"]?.doubleValue ?? 0, most), min(pageHeight, most))
            params["captureBeyondViewport"] = .bool(true)
        } else {
            clip = (pageX, pageY, visual?["clientWidth"]?.doubleValue ?? 0, visual?["clientHeight"]?.doubleValue ?? 0)
        }
        guard clip.width >= 1, clip.height >= 1 else {
            throw BrowserAgentToolError("There is nothing visible to capture.")
        }
        params["clip"] = .object([
            "x": .number(clip.x), "y": .number(clip.y), "width": .number(clip.width),
            "height": .number(clip.height), "scale": .number(scale)
        ])
        let covered = await coverVaultFields(on: page)
        let shot: JSONValue
        do {
            let capture = { try await self.send(page, "Page.captureScreenshot", params, timeout: self.loadTimeout) }
            shot = fullPage ? try await drawn(atLeast: (clip.width, clip.height), pixelRatio: pixelRatio, on: page, capture)
                : try await capture()
        } catch {
            if covered { await restoreVaultFields(on: page) }
            throw error
        }
        if covered { await restoreVaultFields(on: page) }
        // Capturing beyond the viewport lays the page out for the moment as Chromium likes, which drops an emulated
        // phone's touch points; the emulation goes back as it was.
        if fullPage, let emulation = page.emulation() { try? await page.emulate(emulation) }
        guard let data = shot["data"]?.stringValue else { throw BrowserAgentToolError("The browser returned no image.") }
        let location = try? await pageLocation(page)
        var text = "Screenshot of \(location?.url ?? "the page"), \(Self.format(clip.width))×\(Self.format(clip.height)) CSS pixels."
        if pageHeight > clip.height { text += " The page is \(Self.format(pageHeight)) CSS pixels tall; this is its top." }
        return AgentToolResult(content: [.image(data: data, mimeType: "image/\(format)"), .text(text)])
    }

    /// Chromium captures beyond the viewport by drawing the view at the capture's size for the moment
    /// (`PageHandler::CaptureScreenshot` sets the view's size), but CEF's windowless view keeps the size
    /// Yardlet gives it, so the page's first screen repeated down the image. The tab is drawn at the
    /// capture's size here instead, with the page's layout viewport held at its size by device metrics
    /// emulation as Chromium's capture holds it, so the page lays out as before; then both go back.
    private func drawn<T>(atLeast size: (width: Double, height: Double), pixelRatio: Double, on page: BrowserAgentPage,
                          _ capture: () async throws -> T) async throws -> T {
        guard let viewport = page.viewport() else { return try await capture() }
        // An emulated screen size already holds the layout viewport at the view's size (one CSS pixel a point).
        let emulated = page.emulation() != nil
        // CSS pixels to the view's points (the page's zoom); the host's view has whole points.
        let points = emulated ? 1 : pixelRatio / max(viewport.scale, 0.1)
        var drawn = viewport
        drawn.width = max(viewport.width, (size.width * points).rounded(.up))
        drawn.height = max(viewport.height, (size.height * points).rounded(.up))
        guard drawn != viewport else { return try await capture() }
        if !emulated {
            _ = try await send(page, "Emulation.setDeviceMetricsOverride", [
                "width": .integer(Int64(viewport.width)), "height": .integer(Int64(viewport.height)),
                "deviceScaleFactor": .integer(0), "mobile": .bool(false)
            ])
        }
        page.resize(to: drawn)
        let result: Result<T, any Error>
        do { result = .success(try await capture()) } catch { result = .failure(error) }
        // The panel's size again, unless the panel resized the tab meanwhile; the view first, so the page
        // is never laid out at the drawn size.
        if page.viewport() == drawn { page.resize(to: viewport) }
        if !emulated { _ = try? await send(page, "Emulation.clearDeviceMetricsOverride") }
        return try result.get()
    }

    /// The Claude app's `resize_window` in the Browser pane: a preset or a custom size, and the color scheme, on the
    /// tab, which the agent's turn end clears (`taskTurnEnded`).
    private func resize(_ arguments: JSONValue, on page: BrowserAgentPage) async throws -> AgentToolResult {
        let preset = arguments["preset"]?.stringValue
        let width = arguments["width"]?.doubleValue
        let height = arguments["height"]?.doubleValue
        let scheme = arguments["colorScheme"]?.stringValue
        if let scheme, !["light", "dark"].contains(scheme) {
            throw BrowserAgentToolError("Unknown colorScheme \"\(scheme.prefix(40))\". Use light or dark.")
        }
        var parts: [String] = []
        let previous = page.emulation()
        let sides = 1...Double(BrowserViewportEmulation.maximumSide)
        if preset == "desktop" {
            try await page.emulate(nil)
            parts.append("Viewport emulation cleared; the tab is back to its own size (the panel's)")
        } else if preset != nil || width != nil || height != nil {
            let emulation: BrowserViewportEmulation
            if let preset {
                guard let size = [BrowserViewportEmulation.mobile, BrowserViewportEmulation.tablet].first(where: { $0.id == preset }) else {
                    throw BrowserAgentToolError("Unknown preset \"\(preset.prefix(40))\". Use mobile, tablet, or desktop.")
                }
                emulation = BrowserViewportEmulation(size, owner: .agent)
            } else if let width, let height, sides.contains(width), sides.contains(height) {
                emulation = BrowserViewportEmulation(width: Int(width.rounded()), height: Int(height.rounded()), owner: .agent)
            } else {
                throw BrowserAgentToolError("A custom viewport needs both width and height, each a number from 1 to "
                    + "\(BrowserViewportEmulation.maximumSide). Use preset \"mobile\" or \"tablet\" for a device size, or "
                    + "preset \"desktop\" to clear the emulation and return to the tab's own size.")
            }
            try await page.emulate(emulation)
            var text = "Viewport set to \(emulation.width)x\(emulation.height)\(preset.map { " (\($0))" } ?? "") on this tab "
                + "(the panel shows it scaled down to fit when it is larger). Reset it with preset \"desktop\" as soon as you "
                + "finish testing; Yardlet also clears a size you set when your turn ends"
            if emulation.mobile { text += ". The page sees a touch phone with Android Chrome's user agent; your clicks still arrive as mouse clicks" }
            parts.append(text)
        }
        if let previous, previous.owner == .person, preset != nil || width != nil || height != nil {
            parts.append("This replaced the \(previous.width)x\(previous.height) size the person picked in the panel's Viewport menu")
        }
        if let scheme {
            try await page.emulateColorScheme(scheme)
            parts.append("Color scheme emulation set to \(scheme) on this tab; it survives reloads until you set it again or your "
                + "turn ends")
        }
        guard !parts.isEmpty else {
            throw BrowserAgentToolError("Provide a preset (mobile, tablet or desktop), width and height, or colorScheme.")
        }
        return .text(parts.joined(separator: ". ") + ".")
    }

    /// Hands the tab to the person and waits: for their Done or Decline in the panel's bar, for `text` on the page,
    /// for the end of the agent's turn, or for the timeout, after which the tab stays theirs and a call waits again.
    private func handOff(_ arguments: JSONValue, on page: BrowserAgentPage, sessionID: UUID?) async throws -> AgentToolResult {
        guard let reason = arguments["reason"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty else {
            throw BrowserAgentToolError("browser_handoff needs a reason: what the person is to do in the tab.")
        }
        let text = arguments["text"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        let ceiling = sessionID.flatMap { handoffs?.handoffWaitCeiling(for: $0) } ?? .seconds(25 * 60)
        let asked = arguments["timeout"]?.doubleValue.map { Duration.milliseconds(Int(max(0, $0) * 1000)) } ?? Self.handoffDefaultWait
        let timeout = min(asked, ceiling)
        guard let started = page.handOff(String(reason.prefix(500))) else {
            throw BrowserAgentToolError("This browser cannot hand a tab to the person.")
        }
        let notice = Self.handoffNotice(started.handoff.id)
        if started.isNew, let sessionID {
            handoffNotices[sessionID, default: []].insert(notice)
            handoffs?.handoffStarted(session: sessionID, tabKey: page.tabKey, reason: started.handoff.reason, notice: notice)
        }
        let start = ContinuousClock.now
        func waited() -> String { Self.format(Double((ContinuousClock.now - start).components.seconds)) + " seconds" }
        func end() {
            page.endHandoff()
            if let sessionID { handoffNotices[sessionID]?.remove(notice) }
            handoffs?.handoffEnded(notice: notice)
        }
        while true {
            if page.isClosed() {
                if let sessionID { handoffNotices[sessionID]?.remove(notice) }
                handoffs?.handoffEnded(notice: notice)
                throw BrowserAgentToolError("The tab closed before the person answered.")
            }
            switch page.handoff()?.answer {
            case .done?:
                end()
                let location = try? await pageLocation(page)
                return .text("The person said they are done in the tab, after \(waited()). The page is at "
                    + "\(location?.url ?? "an unknown address") (“\(location?.title ?? "")”).")
            case .declined?:
                end()
                return .text("The person declined to do this in the tab, after \(waited()). The tab is as they left it.")
            case .turnEnded?:
                end()
                return .text("The task's turn ended before the person answered; the tab is no longer handed to them.")
            case nil:
                break
            }
            if let text, page.dialog == nil,
               let body = try? await evaluateValue(page, "document.body ? document.body.innerText : ''").stringValue,
               body.contains(text) {
                end()
                return .text("“\(text)” appeared on the page after \(waited()), so the person's part is done; the tab is "
                    + "yours again.")
            }
            if ContinuousClock.now - start >= timeout {
                return .text("The person has not answered after \(waited()). The tab stays handed to them, with its bar in "
                    + "the panel, until they answer or your turn ends; browser_handoff on this tab waits again.")
            }
            try? await Task.sleep(for: max(pollInterval, .milliseconds(250)))
        }
    }

    private func consoleMessages(_ arguments: JSONValue, on page: BrowserAgentPage) -> AgentToolResult {
        let onlyErrors = arguments["onlyErrors"]?.boolValue == true
        var lines: [String] = []
        for event in page.cdp.eventLog {
            switch event.method {
            case "Runtime.consoleAPICalled":
                let level = event.params["type"]?.stringValue ?? "log"
                guard !onlyErrors || level == "error" || level == "assert" else { continue }
                let text = (event.params["args"]?.arrayValue ?? []).map(Self.remoteObjectText).joined(separator: " ")
                lines.append("[\(level)] \(text)")
            case "Runtime.exceptionThrown":
                let details = event.params["exceptionDetails"]
                let text = details?["exception"]?["description"]?.stringValue ?? details?["text"]?.stringValue ?? "Uncaught error"
                lines.append("[uncaught] \(text)")
            case "Log.entryAdded":
                let entry = event.params["entry"]
                let level = entry?["level"]?.stringValue ?? "info"
                guard !onlyErrors || level == "error" else { continue }
                var line = "[\(level)] \(entry?["text"]?.stringValue ?? "")"
                if let url = entry?["url"]?.stringValue, !url.isEmpty { line += " (\(url))" }
                lines.append(line)
            default:
                continue
            }
        }
        guard !lines.isEmpty else { return .text(onlyErrors ? "No errors." : "No console messages.") }
        let recent = lines.suffix(200).map { $0.count > 2_000 ? String($0.prefix(2_000)) + "…" : $0 }
        let header = lines.count > recent.count ? "Last \(recent.count) of \(lines.count) messages:\n" : ""
        return .text(header + recent.joined(separator: "\n"))
    }

    private func evaluate(_ arguments: JSONValue, on page: BrowserAgentPage) async throws -> AgentToolResult {
        guard let function = arguments["function"]?.stringValue, !function.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw BrowserAgentToolError("browser_evaluate needs a function.")
        }
        if vaultFilledDocument(page) {
            throw BrowserAgentToolError("Yardlet's password manager filled a password or code on this page, so browser_evaluate "
                + "does not run on it. Reload it (browser_navigate to its address) or go to another page to use browser_evaluate "
                + "again; browser_snapshot, clicks and typing work as before.")
        }
        let result: JSONValue
        if let ref = arguments["ref"]?.stringValue {
            let element = try self.element(ref, on: page)
            let objectID = try await objectID(ref: ref, element: element, on: page)
            result = try await send(page, "Runtime.callFunctionOn", [
                "functionDeclaration": .string(function), "objectId": .string(objectID),
                "arguments": .array([.object(["objectId": .string(objectID)])]),
                "returnByValue": .bool(true), "awaitPromise": .bool(true), "userGesture": .bool(true)
            ], session: element.session, ref: ref)
        } else {
            // A function is called; any other expression is returned as it is.
            let expression = "(async () => { const value = (\n\(function)\n); "
                + "return typeof value === 'function' ? await value() : await value; })()"
            result = try await send(page, "Runtime.evaluate", [
                "expression": .string(expression), "returnByValue": .bool(true), "awaitPromise": .bool(true),
                "userGesture": .bool(true)
            ])
        }
        if let details = result["exceptionDetails"] {
            let message = details["exception"]?["description"]?.stringValue ?? details["text"]?.stringValue ?? "The function threw."
            throw BrowserAgentToolError("The function threw: \(message)")
        }
        let text = Self.valueText(result["result"])
        return .text(text.count > 50_000 ? String(text.prefix(50_000)) + "\n… (cut at 50,000 characters)" : text)
    }

    /// Each action runs on the tab its own input names, else on the task's active tab at that moment.
    private func batch(_ arguments: JSONValue, sessionID: UUID) async -> AgentToolResult {
        guard let actions = arguments["actions"]?.arrayValue, !actions.isEmpty else {
            return .error("browser_batch needs a non-empty actions list.")
        }
        guard actions.count <= 50 else { return .error("A batch can hold at most 50 actions.") }
        var content: [AgentToolContent] = []
        for (index, action) in actions.enumerated() {
            let number = index + 1
            let name = action["name"]?.stringValue ?? ""
            let input = action["input"] ?? .object([:])
            let result: AgentToolResult
            var page: BrowserAgentPage?
            if !AgentToolCatalog.batchableNames.contains(name) {
                result = .error(name == AgentToolCatalog.batch
                    ? "A batch cannot contain another batch."
                    : "Unknown browser tool \"\(name)\".")
            } else if case .object = input {
                if AgentToolCatalog.tabToolNames.contains(name) {
                    result = runTabTool(name, input, sessionID: sessionID)
                } else {
                    let ran = await runOnPage(name, input, sessionID: sessionID)
                    if let found = ran.page { page = found }
                    result = ran.result
                }
            } else {
                result = .error("The input must be an object.")
            }
            for part in result.content {
                if case .text(let text) = part {
                    content.append(.text("\(number). \(name)\(result.isError ? " failed" : ""): \(text)"))
                } else {
                    content.append(part)
                }
            }
            let skipped = actions.count - number
            let skippedText = "\(skipped) later action\(skipped == 1 ? " was" : "s were") not run."
            if result.isError {
                if skipped > 0 { content.append(.text("Stopped at action \(number); \(skippedText)")) }
                return AgentToolResult(content: content, isError: true)
            }
            // A dialog pauses the page, so the rest would only fail; the agent answers it first.
            if page?.dialog != nil, skipped > 0 {
                content.append(.text("Stopped after action \(number) because a dialog is open; \(skippedText)"))
                return AgentToolResult(content: content)
            }
        }
        return AgentToolResult(content: content)
    }

    private func handleDialog(_ arguments: JSONValue, on page: BrowserAgentPage, sessionID: UUID?) throws -> AgentToolResult {
        guard let accept = arguments["accept"]?.boolValue else {
            throw BrowserAgentToolError("browser_handle_dialog needs accept (true or false).")
        }
        let (windows, unknownTab) = browserDialogs(sessionID)
        if page.dialog == nil, let sessionID, !windows.isEmpty {
            // Only the person can finish a passkey request, a sign-in or printing; the agent can only let it go.
            guard !accept else {
                throw BrowserAgentToolError(Self.describeBrowserDialog(windows) + " Only the person at this Mac can complete it; "
                    + "browser_handle_dialog with accept false closes it.")
            }
            guard directory?.closeBrowserDialogs(for: sessionID) == true else {
                throw BrowserAgentToolError("Chromium's window could not be closed.")
            }
            let names = Self.kinds(of: windows).map { Self.name(of: $0, in: windows) }.joined(separator: " and ")
            let passkey = windows.contains { $0.kind == .passkey } ? " The site can then offer another way to sign in." : ""
            return .text("Closed \(names); " + Self.closeOutcome(windows) + "." + passkey)
        }
        guard let dialog = page.answerDialog(accept: accept, text: arguments["promptText"]?.stringValue) else {
            // Another task's window, or one whose tab is not known, is not this task's to close.
            throw BrowserAgentToolError("No JavaScript dialog is open." + (unknownTab.isEmpty ? ""
                : " " + Self.describeUnknownTabDialog(unknownTab) + " browser_handle_dialog does not close it."))
        }
        let kind = dialog.kind == .beforeUnload ? "leave-page" : dialog.kind.rawValue
        return .text("\(accept ? "Accepted" : "Dismissed") the \(kind) dialog “\(dialog.message)”.")
    }

    private func fileUpload(_ arguments: JSONValue, on page: BrowserAgentPage) async throws -> AgentToolResult {
        guard let chooser = page.fileDialog else {
            throw BrowserAgentToolError("No file chooser is open. Click the page's file input first.")
        }
        let requested = arguments["paths"]?.arrayValue?.compactMap(\.stringValue) ?? []
        guard !requested.isEmpty else {
            _ = page.answerFileDialog(paths: nil)
            return .text("Cancelled the file chooser.")
        }
        if chooser.mode != .openMultiple, requested.count > 1 {
            throw BrowserAgentToolError("This file chooser takes one \(chooser.mode == .openFolder ? "folder" : "file").")
        }
        var paths = try requested.map { try BrowserAgentWorkspaceFile.resolve($0, roots: page.workspaceRoots, mode: chooser.mode) }
        // A file goes as a copy read from the path just checked; a folder or a place to save stays a path.
        if chooser.mode == .open || chooser.mode == .openMultiple {
            let checked = paths, roots = page.workspaceRoots, folder = uploadFolder
            paths = try await Task.detached(priority: .userInitiated) {
                try checked.map { try BrowserAgentWorkspaceFile.privateCopy(of: $0, roots: roots, in: folder) }
            }.value
            guard page.fileDialog?.id == chooser.id else {
                throw BrowserAgentToolError("The file chooser closed while the files were being read.")
            }
        }
        _ = page.answerFileDialog(paths: paths)
        return .text("Gave the file chooser " + paths.map { "“\(URL(filePath: $0).lastPathComponent)”" }
            .joined(separator: ", ") + ".")
    }

    // MARK: - Helpers

    func dispatch(_ press: BrowserAgentKeyPress, on page: BrowserAgentPage) async throws {
        var held = 0
        for modifier in press.modifiers {
            held |= modifier.bit
            _ = try await send(page, "Input.dispatchKeyEvent", keyEvent("rawKeyDown", modifier.key, modifiers: held))
        }
        var down = keyEvent(press.key.text == nil ? "rawKeyDown" : "keyDown", press.key, modifiers: held)
        if usesMacEditingCommands, !press.macEditingCommands.isEmpty {
            down["commands"] = .array(press.macEditingCommands.map { .string($0) })
        }
        _ = try await send(page, "Input.dispatchKeyEvent", down)
        _ = try await send(page, "Input.dispatchKeyEvent", keyEvent("keyUp", press.key, modifiers: held))
        for modifier in press.modifiers.reversed() {
            held &= ~modifier.bit
            _ = try await send(page, "Input.dispatchKeyEvent", keyEvent("keyUp", modifier.key, modifiers: held))
        }
    }

    private func keyEvent(_ type: String, _ key: BrowserAgentKeyPress.Key, modifiers: Int) -> [String: JSONValue] {
        var event: [String: JSONValue] = [
            "type": .string(type), "key": .string(key.key), "code": .string(key.code),
            "windowsVirtualKeyCode": .integer(Int64(key.keyCode)), "modifiers": .integer(Int64(modifiers))
        ]
        if key.location != 0 { event["location"] = .integer(Int64(key.location)) }
        if type == "keyDown", let text = key.text {
            event["text"] = .string(text)
            event["unmodifiedText"] = .string(text)
        }
        return event
    }

    func element(_ ref: String, on page: BrowserAgentPage) throws -> BrowserAgentSnapshot.Ref {
        let normalized = ref.hasPrefix("@") ? ref : "@" + ref
        if let node = page.refs[normalized] {
            if page.navigatedSinceSnapshot {
                page.clearRefs()
                throw BrowserAgentToolError("\(ref) is stale: the page navigated since the last snapshot. Call "
                    + "browser_snapshot again.")
            }
            return node
        }
        if page.snapshotCount == 0 {
            throw BrowserAgentToolError("There is no snapshot yet, so \(ref) means nothing. Call browser_snapshot "
                + "first and use its references.")
        }
        throw BrowserAgentToolError("\(ref) is not in the latest snapshot. References last until the next snapshot "
            + "or navigation; call browser_snapshot again.")
    }

    private func center(of ref: String, on page: BrowserAgentPage) async throws -> (x: Double, y: Double) {
        let element = try element(ref, on: page)
        try await scrollIntoView(ref, element, on: page)
        let box = try await bounds(of: ref, element: element, on: page)
        return (box.x + box.width / 2, box.y + box.height / 2)
    }

    /// Brings the element into view: in a frame from another site, each iframe that holds it first, outermost first.
    private func scrollIntoView(_ ref: String, _ element: BrowserAgentSnapshot.Ref, on page: BrowserAgentPage) async throws {
        for owner in try frameOwners(of: element, ref: ref, on: page).reversed() {
            _ = try await send(page, "DOM.scrollIntoViewIfNeeded", ["backendNodeId": .integer(Int64(owner.node))],
                               session: owner.session, ref: ref)
        }
        _ = try await send(page, "DOM.scrollIntoViewIfNeeded", ["backendNodeId": .integer(Int64(element.node))],
                           session: element.session, ref: ref)
    }

    /// The iframes that hold an element of a frame from another site, innermost first.
    private func frameOwners(of element: BrowserAgentSnapshot.Ref, ref: String, on page: BrowserAgentPage) throws
        -> [BrowserAgentSnapshot.Ref] {
        var owners: [BrowserAgentSnapshot.Ref] = []
        var session = element.session
        while let frame = session {
            guard let owner = page.frameOwners[frame], owners.count < 20 else {
                throw BrowserAgentToolError("\(ref) is stale: its frame changed since the last snapshot. Call browser_snapshot again.")
            }
            owners.append(owner)
            session = owner.session
        }
        return owners
    }

    /// The element's box in the tab's viewport CSS pixels. A frame from another site gives its elements' boxes in its
    /// own viewport, which starts at the content box of the iframe that holds it.
    private func bounds(of ref: String, element: BrowserAgentSnapshot.Ref, on page: BrowserAgentPage) async throws
        -> (x: Double, y: Double, width: Double, height: Double) {
        let quads = try await send(page, "DOM.getContentQuads", ["backendNodeId": .integer(Int64(element.node))],
                                   session: element.session, ref: ref)
        var offset = (x: 0.0, y: 0.0)
        for owner in try frameOwners(of: element, ref: ref, on: page) {
            let model = try await send(page, "DOM.getBoxModel", ["backendNodeId": .integer(Int64(owner.node))],
                                       session: owner.session, ref: ref)
            let content = model["model"]?["content"]?.arrayValue?.compactMap(\.doubleValue) ?? []
            guard content.count == 8 else { throw BrowserAgentToolError("\(ref)'s frame has no box on the page.") }
            offset.x += stride(from: 0, to: 8, by: 2).map { content[$0] }.min()!
            offset.y += stride(from: 1, to: 8, by: 2).map { content[$0] }.min()!
        }
        for quad in quads["quads"]?.arrayValue ?? [] {
            let points = quad.arrayValue?.compactMap(\.doubleValue) ?? []
            guard points.count == 8 else { continue }
            let xs = stride(from: 0, to: 8, by: 2).map { points[$0] }
            let ys = stride(from: 1, to: 8, by: 2).map { points[$0] }
            let box = (x: xs.min()! + offset.x, y: ys.min()! + offset.y, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
            if box.width >= 1, box.height >= 1 { return box }
        }
        throw BrowserAgentToolError("\(ref) has no visible box on the page (it may be hidden or empty).")
    }

    private func objectID(ref: String, element: BrowserAgentSnapshot.Ref, on page: BrowserAgentPage) async throws -> String {
        let resolved = try await send(page, "DOM.resolveNode", ["backendNodeId": .integer(Int64(element.node))],
                                      session: element.session, ref: ref)
        guard let id = resolved["object"]?["objectId"]?.stringValue else {
            throw BrowserAgentToolError("\(ref) could not be found on the page. Call browser_snapshot again.")
        }
        return id
    }

    /// Calls a function with the element as `this` and returns its JSON result.
    private func call(_ page: BrowserAgentPage, ref: String, element: BrowserAgentSnapshot.Ref, arguments: [JSONValue] = [],
                      function: String) async throws -> JSONValue {
        let objectID = try await objectID(ref: ref, element: element, on: page)
        let result = try await send(page, "Runtime.callFunctionOn", [
            "functionDeclaration": .string(function), "objectId": .string(objectID),
            "arguments": .array(arguments), "returnByValue": .bool(true)
        ], session: element.session, ref: ref)
        if let details = result["exceptionDetails"] {
            throw BrowserAgentToolError("The page raised an error: "
                + (details["exception"]?["description"]?.stringValue ?? details["text"]?.stringValue ?? "unknown"))
        }
        return result["result"]?["value"] ?? .null
    }

    private func evaluateValue(_ page: BrowserAgentPage, _ expression: String) async throws -> JSONValue {
        let result = try await send(page, "Runtime.evaluate", [
            "expression": .string(expression), "returnByValue": .bool(true)
        ])
        return result["result"]?["value"] ?? .null
    }

    private func pageLocation(_ page: BrowserAgentPage) async throws -> (url: String, title: String) {
        let value = try await evaluateValue(page, "[location.href, document.title]")
        let parts = value.arrayValue?.compactMap(\.stringValue) ?? []
        return (parts.first ?? "", parts.count > 1 ? parts[1] : "")
    }

    private func viewport(_ page: BrowserAgentPage) async throws -> (width: Double, height: Double) {
        let visual = try await send(page, "Page.getLayoutMetrics")["cssVisualViewport"]
        return (visual?["clientWidth"]?.doubleValue ?? 800, visual?["clientHeight"]?.doubleValue ?? 600)
    }

    private func waitForEvent(
        on page: BrowserAgentPage, after mark: Int, timeout: Duration,
        _ matches: (String, JSONValue) -> Bool,
        stopWhen shouldStop: () -> Bool = { false }
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        var checked = mark
        while true {
            let log = page.cdp.eventLog
            if log.count > checked {
                if log[checked...].contains(where: { matches($0.method, $0.params) }) { return true }
                checked = log.count
            }
            guard ContinuousClock.now < deadline, !shouldStop() else { return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Sends a CDP command. With a ref, a missing node reads as a stale reference. A JavaScript
    /// dialog that opens meanwhile pauses the page, and with it the command's answer, so the wait
    /// ends there (`BrowserAgentDialogOpened`) instead of at the command's time limit.
    func send(
        _ page: BrowserAgentPage, _ method: String, _ params: [String: JSONValue] = [:], session: String? = nil,
        timeout: Duration? = nil, ref: String? = nil
    ) async throws -> JSONValue {
        do {
            return try await sendUnlessDialogOpens(page, method, params, session: session, timeout: timeout ?? commandTimeout)
        } catch BrowserDevToolsError.protocolError(_, let error) {
            let message = error["message"]?.stringValue ?? error.readableText ?? "unknown error"
            // A node that is gone, or the frame session it was in (the frame navigated or closed).
            if let ref, message.localizedCaseInsensitiveContains("node") || message.localizedCaseInsensitiveContains("session") {
                throw BrowserAgentToolError("\(ref) is stale: the page changed since the last snapshot. Call "
                    + "browser_snapshot again.")
            }
            throw BrowserAgentToolError("The browser refused \(method): \(message)")
        }
    }

    private func sendUnlessDialogOpens(
        _ page: BrowserAgentPage, _ method: String, _ params: [String: JSONValue], session: String?, timeout: Duration
    ) async throws -> JSONValue {
        guard page.dialog == nil else { throw BrowserAgentDialogOpened() }
        let answered = BrowserAgentOnce()
        return try await withCheckedThrowingContinuation { continuation in
            let watcher = page.watchForDialog {
                guard answered.claim() else { return }
                continuation.resume(throwing: BrowserAgentDialogOpened())
            }
            Task { @MainActor in
                let result: Result<JSONValue, any Error>
                do {
                    result = .success(try await page.cdp.send(method, params, session: session, timeout: timeout))
                } catch {
                    result = .failure(error)
                }
                page.stopWatchingForDialog(watcher)
                guard answered.claim() else { return }
                continuation.resume(with: result)
            }
        }
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case BrowserDevToolsError.timedOut(let method): "The browser did not answer \(method) in time."
        case BrowserDevToolsError.closed: "The browser tab closed. Call the tool again to open a new one."
        case BrowserDevToolsError.notSent: "The browser is not running. Call the tool again to start it."
        default: error.localizedDescription
        }
    }

    private static func remoteObjectText(_ object: JSONValue) -> String {
        if let value = object["value"] {
            if let text = value.stringValue { return text }
            return valueText(.object(["value": value]))
        }
        return object["unserializableValue"]?.stringValue ?? object["description"]?.stringValue
            ?? object["type"]?.stringValue ?? ""
    }

    /// A `Runtime.RemoteObject` returned by value, as text.
    private static func valueText(_ object: JSONValue?) -> String {
        guard let object else { return "undefined" }
        if let value = object["value"] {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted]
            return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "null"
        }
        if let unserializable = object["unserializableValue"]?.stringValue { return unserializable }
        if object["type"]?.stringValue == "undefined" { return "undefined" }
        return object["description"]?.stringValue ?? "undefined"
    }

    private static func format(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }
}
