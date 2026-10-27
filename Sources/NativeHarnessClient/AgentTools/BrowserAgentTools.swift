import Foundation
import YardletAgentTools

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
    /// The task's project folders, for file uploads. The broker, which learns them when a task is
    /// injected, sets this.
    var workspaceRoots: @MainActor (UUID) -> [URL]
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

    /// Tools that still work while a JavaScript dialog pauses the page.
    private static let usableDuringDialog: Set<String> = [
        AgentToolCatalog.handleDialog, AgentToolCatalog.fileUpload, AgentToolCatalog.consoleMessages
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
    }

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

    /// A page tool on the tab it names. browser_navigate on a tab whose page does not respond opens the
    /// page in its place first (`BrowserAgentTabDirectory.replace`), since the stuck page cannot move.
    private func runOnPage(_ tool: String, _ arguments: JSONValue, sessionID: UUID) async
        -> (result: AgentToolResult, page: BrowserAgentPage?) {
        switch await page(for: sessionID, arguments) {
        case .success(var page):
            var replaced: String?
            if tool == AgentToolCatalog.navigate, let stuck = page.unresponsive(), let directory {
                do {
                    let old = page.tabID
                    page = try directory.replace(String(old), for: sessionID)
                    page.workspaceRoots = workspaceRoots(sessionID)
                    replaced = "Tab \(old)'s page was not responding (\(Self.describe(stuck))); the tab was opened again in its "
                        + "place as tabId \"\(page.tabID)\", and the address loaded there."
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
                        .object(["tabId": .string(tab.id), "origin": .string(tab.origin), "isActive": .bool(tab.isActive),
                                 "responding": .bool(tab.isResponding)])
                    })
                ])
                let note = tabs.isEmpty
                    ? "This task has no browser tab yet; browser_navigate or browser_tab_new opens one."
                    : panelOpen
                    ? "The task's browser panel is open and shows the active tab; other tabs run in the background."
                    : "The task's browser panel is closed: the pages still work, as background pages, so timing and "
                        + "animation can be off. Prefer browser_snapshot to screenshots for reading them."
                let stuck = tabs.filter { !$0.isResponding && $0.crash == nil }.map(\.id)
                let stuckNote = stuck.isEmpty ? "" : "\nNot responding: tab " + stuck.joined(separator: ", tab ")
                    + " (its page's renderer is busy; browser_navigate opens a page again in its place, browser_tab_close closes it)."
                let crashed = tabs.compactMap { tab in tab.crash.map { "tab \(tab.id) (\($0))" } }
                let crashNote = crashed.isEmpty ? "" : "\nCrashed: " + crashed.joined(separator: ", ")
                    + " (its page's renderer ended; browser_navigate opens a page again in its place, browser_tab_close closes it)."
                return .text(Self.json(listing) + "\n" + note + stuckNote + crashNote)
            case AgentToolCatalog.tabNew:
                let foreground = arguments["foreground"]?.boolValue ?? false
                let tab = try directory.newTab(for: sessionID, foreground: foreground)
                let where_ = tab.isActive ? "It is the active tab." : "It opened behind the active tab."
                return .text(Self.json(.object(["tabId": .string(tab.id), "isActive": .bool(tab.isActive)]))
                    + "\nOpened a blank tab. \(where_) Load a page with browser_navigate and tabId \"\(tab.id)\".")
            case AgentToolCatalog.tabSelect:
                guard let id = arguments["tabId"]?.stringValue else { throw BrowserAgentToolError("browser_tab_select needs a tabId.") }
                try directory.select(id, for: sessionID)
                return .text("Tab \(id) is now the active tab.")
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

    private static func json(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    func run(_ tool: String, _ arguments: JSONValue, on page: BrowserAgentPage, sessionID: UUID? = nil) async -> AgentToolResult {
        if let dialog = page.dialog, !Self.usableDuringDialog.contains(tool) {
            return .error("\(Self.describe(dialog)) The page is paused until you answer it with browser_handle_dialog.")
        }
        do {
            // Answering a dialog or a file chooser needs no CDP, and CDP waits while a dialog is open.
            if page.dialog == nil, tool != AgentToolCatalog.handleDialog, tool != AgentToolCatalog.fileUpload {
                try await enableDomains(page)
            }
            var result = try await perform(tool, arguments, on: page, sessionID: sessionID)
            result.content += notices(after: tool, on: page).map { .text($0) }
            if let note = unresponsiveNote(page) { result.content.append(.text(note)) }
            return result
        } catch is BrowserAgentDialogOpened {
            let dialog = page.dialog.map(Self.describe) ?? "A JavaScript dialog opened."
            return .text("\(dialog) It opened during \(tool). The page is paused until you answer it with "
                + "browser_handle_dialog.")
        } catch let error as BrowserAgentToolError {
            return .error(error.message + browserDialogNote(after: tool) + (unresponsiveNote(page).map { "\n" + $0 } ?? ""))
        } catch {
            return .error(Self.describe(error) + browserDialogNote(after: tool) + (unresponsiveNote(page).map { "\n" + $0 } ?? ""))
        }
    }

    /// What is known when the tab's page does not respond or its renderer ended: a fact, with the tools
    /// that act on the tab.
    private func unresponsiveNote(_ page: BrowserAgentPage) -> String? {
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

    /// A failed tool still says that a window of Chromium's own waits: it is often why a page stopped.
    private func browserDialogNote(after tool: String) -> String {
        guard let windows = directory?.browserDialogs, !windows.isEmpty, tool != AgentToolCatalog.handleDialog else { return "" }
        return "\n" + Self.describeBrowserDialog(windows) + " browser_handle_dialog with accept false closes it."
    }

    /// What the page did besides the tool's own result: a dialog or file chooser now waiting, or an
    /// address the policy refused.
    private func notices(after tool: String, on page: BrowserAgentPage) -> [String] {
        var notices: [String] = []
        let blocked = page.takeBlockedNavigations()
        if !blocked.isEmpty {
            let urls = blocked.joined(separator: ", ")
            notices.append("The page tried to open \(urls), which the browser's address policy blocks.")
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
        if let windows = directory?.browserDialogs, !windows.isEmpty, tool != AgentToolCatalog.handleDialog {
            notices.append(Self.describeBrowserDialog(windows) + " browser_handle_dialog with accept false closes it; "
                + Self.closeOutcome(windows) + ".")
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

    /// Chromium's own windows over the browser panel, which wait for the person: the passkey dialog, a site's
    /// sign-in window (HTTP authentication), the print dialog.
    static func describeBrowserDialog(_ windows: [BrowserChromiumWindow]) -> String {
        kinds(of: windows).map { kind in
            let named = name(of: kind, in: windows)
            let name = named.prefix(1).uppercased() + named.dropFirst()
            return switch kind {
            case .passkey:
                "\(name) is open over the browser: it waits for the person at this Mac (a passkey, a phone's QR code or a security "
                    + "key, or a note that none is available), and the page's request waits until it closes."
            case .signIn:
                "\(name) is open over the browser: it asks the person at this Mac for a username and password, and the page waits "
                    + "until it closes."
            case .print:
                "\(name) is open over the browser: it waits for the person at this Mac, and the page waits until it closes."
            case .other:
                "\(name) is open over the browser and waits for the person at this Mac."
            }
        }.joined(separator: " ")
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
        case AgentToolCatalog.navigate: try await navigate(arguments, on: page)
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
        case AgentToolCatalog.handleDialog: try handleDialog(arguments, on: page)
        case AgentToolCatalog.fileUpload: try fileUpload(arguments, on: page)
        default: throw BrowserAgentToolError("Unknown Yardlet tool: \(tool)")
        }
    }

    private func enableDomains(_ page: BrowserAgentPage) async throws {
        guard !page.domainsEnabled else { return }
        // Runtime replays the console messages logged before it was enabled; Log replays its buffer.
        for domain in ["Page", "Runtime", "Log"] {
            _ = try await send(page, "\(domain).enable")
        }
        page.domainsEnabled = true
    }

    // MARK: - Tools

    private func navigate(_ arguments: JSONValue, on page: BrowserAgentPage) async throws -> AgentToolResult {
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
        let tree = try await send(page, "Accessibility.getFullAXTree")
        let rendered = BrowserAgentSnapshot.render(nodes: tree["nodes"]?.arrayValue ?? [])
        page.replaceRefs(rendered.refs, eventMark: mark)
        let location = try await pageLocation(page)
        return .text("Page URL: \(location.url)\nPage title: \(location.title)\n\n\(rendered.text)")
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
        let node = try backendNode(ref, on: page)
        do {
            _ = try await send(page, "DOM.focus", ["backendNodeId": .integer(Int64(node))], ref: ref)
        } catch let error as BrowserAgentToolError where !error.message.contains(" is stale") {
            throw BrowserAgentToolError("\(ref) cannot take keyboard focus, so it is not a text field.")
        }
        let kind = try await call(page, ref: ref, node: node, function: """
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
            let node = try backendNode(ref, on: page)
            _ = try await send(page, "DOM.scrollIntoViewIfNeeded", ["backendNodeId": .integer(Int64(node))], ref: ref)
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
        let node = try backendNode(ref, on: page)
        let outcome = try await call(page, ref: ref, node: node, arguments: [.object(["value": .array(values.map { .string($0) })])],
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
            let node = try backendNode(ref, on: page)
            _ = try await send(page, "DOM.scrollIntoViewIfNeeded", ["backendNodeId": .integer(Int64(node))], ref: ref)
            let box = try await bounds(of: ref, node: node, on: page)
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
        // CSS pixels to the view's points (the page's zoom); the host's view has whole points.
        let points = pixelRatio / max(viewport.scale, 0.1)
        var drawn = viewport
        drawn.width = max(viewport.width, (size.width * points).rounded(.up))
        drawn.height = max(viewport.height, (size.height * points).rounded(.up))
        guard drawn != viewport else { return try await capture() }
        _ = try await send(page, "Emulation.setDeviceMetricsOverride", [
            "width": .integer(Int64(viewport.width)), "height": .integer(Int64(viewport.height)),
            "deviceScaleFactor": .integer(0), "mobile": .bool(false)
        ])
        page.resize(to: drawn)
        let result: Result<T, any Error>
        do { result = .success(try await capture()) } catch { result = .failure(error) }
        // The panel's size again, unless the panel resized the tab meanwhile; the view first, so the page
        // is never laid out at the drawn size.
        if page.viewport() == drawn { page.resize(to: viewport) }
        _ = try? await send(page, "Emulation.clearDeviceMetricsOverride")
        return try result.get()
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
        if await vaultValueIsLive(on: page) {
            throw BrowserAgentToolError("A value Yardlet's password manager filled is still in a field on this page, so browser_evaluate "
                + "does not run here until the field is gone or the page navigates (submitting the form usually does both).")
        }
        let result: JSONValue
        if let ref = arguments["ref"]?.stringValue {
            let node = try backendNode(ref, on: page)
            let objectID = try await objectID(ref: ref, node: node, on: page)
            result = try await send(page, "Runtime.callFunctionOn", [
                "functionDeclaration": .string(function), "objectId": .string(objectID),
                "arguments": .array([.object(["objectId": .string(objectID)])]),
                "returnByValue": .bool(true), "awaitPromise": .bool(true), "userGesture": .bool(true)
            ], ref: ref)
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

    private func handleDialog(_ arguments: JSONValue, on page: BrowserAgentPage) throws -> AgentToolResult {
        guard let accept = arguments["accept"]?.boolValue else {
            throw BrowserAgentToolError("browser_handle_dialog needs accept (true or false).")
        }
        if page.dialog == nil, let windows = directory?.browserDialogs, !windows.isEmpty {
            // Only the person can finish a passkey request, a sign-in or printing; the agent can only let it go.
            guard !accept else {
                throw BrowserAgentToolError(Self.describeBrowserDialog(windows) + " Only the person at this Mac can complete it; "
                    + "browser_handle_dialog with accept false closes it.")
            }
            guard directory?.closeBrowserDialogs() == true else { throw BrowserAgentToolError("Chromium's window could not be closed.") }
            let names = Self.kinds(of: windows).map { Self.name(of: $0, in: windows) }.joined(separator: " and ")
            let passkey = windows.contains { $0.kind == .passkey } ? " The site can then offer another way to sign in." : ""
            return .text("Closed \(names); " + Self.closeOutcome(windows) + "." + passkey)
        }
        guard let dialog = page.answerDialog(accept: accept, text: arguments["promptText"]?.stringValue) else {
            throw BrowserAgentToolError("No JavaScript dialog is open.")
        }
        let kind = dialog.kind == .beforeUnload ? "leave-page" : dialog.kind.rawValue
        return .text("\(accept ? "Accepted" : "Dismissed") the \(kind) dialog “\(dialog.message)”.")
    }

    private func fileUpload(_ arguments: JSONValue, on page: BrowserAgentPage) throws -> AgentToolResult {
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
        let paths = try requested.map { try BrowserAgentWorkspaceFile.resolve($0, roots: page.workspaceRoots, mode: chooser.mode) }
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

    func backendNode(_ ref: String, on page: BrowserAgentPage) throws -> Int {
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
        let node = try backendNode(ref, on: page)
        _ = try await send(page, "DOM.scrollIntoViewIfNeeded", ["backendNodeId": .integer(Int64(node))], ref: ref)
        let box = try await bounds(of: ref, node: node, on: page)
        return (box.x + box.width / 2, box.y + box.height / 2)
    }

    /// The element's box in viewport CSS pixels.
    private func bounds(of ref: String, node: Int, on page: BrowserAgentPage) async throws
        -> (x: Double, y: Double, width: Double, height: Double) {
        let quads = try await send(page, "DOM.getContentQuads", ["backendNodeId": .integer(Int64(node))], ref: ref)
        for quad in quads["quads"]?.arrayValue ?? [] {
            let points = quad.arrayValue?.compactMap(\.doubleValue) ?? []
            guard points.count == 8 else { continue }
            let xs = stride(from: 0, to: 8, by: 2).map { points[$0] }
            let ys = stride(from: 1, to: 8, by: 2).map { points[$0] }
            let box = (x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
            if box.width >= 1, box.height >= 1 { return box }
        }
        throw BrowserAgentToolError("\(ref) has no visible box on the page (it may be hidden or empty).")
    }

    private func objectID(ref: String, node: Int, on page: BrowserAgentPage) async throws -> String {
        let resolved = try await send(page, "DOM.resolveNode", ["backendNodeId": .integer(Int64(node))], ref: ref)
        guard let id = resolved["object"]?["objectId"]?.stringValue else {
            throw BrowserAgentToolError("\(ref) could not be found on the page. Call browser_snapshot again.")
        }
        return id
    }

    /// Calls a function with the element as `this` and returns its JSON result.
    private func call(_ page: BrowserAgentPage, ref: String, node: Int, arguments: [JSONValue] = [],
                      function: String) async throws -> JSONValue {
        let objectID = try await objectID(ref: ref, node: node, on: page)
        let result = try await send(page, "Runtime.callFunctionOn", [
            "functionDeclaration": .string(function), "objectId": .string(objectID),
            "arguments": .array(arguments), "returnByValue": .bool(true)
        ], ref: ref)
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
        _ page: BrowserAgentPage, _ method: String, _ params: [String: JSONValue] = [:],
        timeout: Duration? = nil, ref: String? = nil
    ) async throws -> JSONValue {
        do {
            return try await sendUnlessDialogOpens(page, method, params, timeout: timeout ?? commandTimeout)
        } catch BrowserDevToolsError.protocolError(_, let error) {
            let message = error["message"]?.stringValue ?? error.readableText ?? "unknown error"
            if let ref, message.localizedCaseInsensitiveContains("node") {
                throw BrowserAgentToolError("\(ref) is stale: the page changed since the last snapshot. Call "
                    + "browser_snapshot again.")
            }
            throw BrowserAgentToolError("The browser refused \(method): \(message)")
        }
    }

    private func sendUnlessDialogOpens(
        _ page: BrowserAgentPage, _ method: String, _ params: [String: JSONValue], timeout: Duration
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
                    result = .success(try await page.cdp.send(method, params, timeout: timeout))
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
