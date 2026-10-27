import Foundation
import XCTest
@testable import NativeHarnessClient
@testable import YardletAgentTools

/// A CDP connection that answers from a script and records what was sent.
@MainActor
final class ScriptedCDP: BrowserAgentCDP {
    var sent: [(method: String, params: [String: JSONValue])] = []
    var eventLog: [(method: String, params: JSONValue)] = []
    var responders: [String: @MainActor ([String: JSONValue]) throws -> JSONValue] = [:]
    /// Events that arrive once a method has been sent.
    var eventsAfter: [String: [(method: String, params: JSONValue)]] = [:]
    /// Methods whose answer does not come until `resumeSuspended()`, like a page paused on a dialog.
    var suspendOn: Set<String> = []
    private var suspended: [CheckedContinuation<Void, Never>] = []

    func resumeSuspended() {
        let waiting = suspended
        suspended = []
        waiting.forEach { $0.resume() }
    }
    var pageURL = "https://example.com/"
    var pageTitle = "Example Domain"
    var bodyTexts: [String] = [""]
    var pixelRatio: Double = 1

    func send(_ method: String, _ params: [String: JSONValue], timeout: Duration) async throws -> JSONValue {
        sent.append((method, params))
        eventLog += eventsAfter[method] ?? []
        if suspendOn.contains(method) {
            await withCheckedContinuation { suspended.append($0) }
        }
        if let responder = responders[method] { return try responder(params) }
        if method == "Runtime.evaluate", let expression = params["expression"]?.stringValue {
            if expression.contains("location.href") {
                return Self.value(.array([.string(pageURL), .string(pageTitle)]))
            }
            if expression == "devicePixelRatio" { return Self.value(.number(pixelRatio)) }
            if expression.contains("innerText") {
                let text = bodyTexts.count > 1 ? bodyTexts.removeFirst() : bodyTexts.first ?? ""
                return Self.value(.string(text))
            }
            if expression.contains("scrollX") {
                return Self.value(.array([.integer(0), .integer(400), .integer(1280), .integer(5000)]))
            }
        }
        return .object([:])
    }

    var methods: [String] { sent.map(\.method) }

    func params(of method: String) -> [[String: JSONValue]] {
        sent.filter { $0.method == method }.map(\.params)
    }

    static func value(_ value: JSONValue) -> JSONValue {
        .object(["result": .object(["type": .string("object"), "value": value])])
    }

    static func missingNode(_ method: String) -> BrowserDevToolsError {
        .protocolError(method, .object(["code": .integer(-32000), "message": .string("No node with given id found")]))
    }
}

@MainActor
final class BrowserAgentToolsTests: XCTestCase {
    private var cdp: ScriptedCDP!
    private var page: BrowserAgentPage!
    private var tools: BrowserAgentTools!

    /// Host commands the page sent (dialog and file chooser answers).
    private var hostCommands: [BrowserHostCommand] = []
    /// The files outside the task's folders the tools asked about, and the answer they get.
    private var askedFiles: [String] = []
    private var allowsFiles = false

    override func setUp() async throws {
        cdp = ScriptedCDP()
        hostCommands = []
        page = BrowserAgentPage(cdp: cdp, tabID: 4) { [unowned self] in self.hostCommands.append($0) }
        let page = page!
        tools = BrowserAgentTools(usesMacEditingCommands: true, pages: { _ in page })
        tools.pollInterval = .milliseconds(5)
    }

    private func run(_ tool: String, _ arguments: [String: JSONValue] = [:]) async -> AgentToolResult {
        await tools.run(tool: tool, arguments: .object(arguments), sessionID: UUID())
    }

    /// The page from the snapshot test: a heading, a text field, a button, a paragraph, a link.
    private func loadSnapshot() async -> AgentToolResult {
        func node(_ id: String, _ role: String, _ name: String = "", children: [String] = [], backend: Int64? = nil,
                  properties: [(String, JSONValue)] = [], value: String? = nil, ignored: Bool = false) -> JSONValue {
            var fields: [String: JSONValue] = [
                "nodeId": .string(id), "ignored": .bool(ignored),
                "role": .object(["type": .string("role"), "value": .string(role)]),
                "name": .object(["type": .string("computedString"), "value": .string(name)]),
                "childIds": .array(children.map { .string($0) }),
                "properties": .array(properties.map { .object(["name": .string($0.0), "value": .object(["value": $0.1])]) })
            ]
            if id != "1" { fields["parentId"] = .string("1") }
            if let backend { fields["backendDOMNodeId"] = .integer(backend) }
            if let value { fields["value"] = .object(["type": .string("string"), "value": .string(value)]) }
            return .object(fields)
        }
        cdp.responders["Accessibility.getFullAXTree"] = { _ in
            .object(["nodes": .array([
                node("1", "RootWebArea", "Example Domain", children: ["2", "3", "7", "9", "10"], backend: 1,
                     properties: [("url", .string("https://example.com/"))]),
                node("2", "heading", "Welcome", children: ["2a"], backend: 10, properties: [("level", .integer(1))]),
                node("2a", "StaticText", "Welcome", backend: 20),
                node("3", "generic", children: ["4", "5"], backend: 11),
                node("4", "textbox", "Name", backend: 12, properties: [("focusable", .bool(true)), ("required", .bool(true))], value: "Ada"),
                node("5", "button", "Send", children: ["6"], backend: 13),
                node("6", "StaticText", "Send", backend: 21),
                node("7", "paragraph", children: ["8"], backend: 14),
                node("8", "StaticText", "Hello   world", backend: 22),
                node("9", "link", "Docs", backend: 15, properties: [("url", .string("https://example.com/docs"))]),
                node("10", "none", "hidden", ignored: true)
            ])])
        }
        return await run(AgentToolCatalog.snapshot)
    }

    // MARK: - Navigate

    func testNavigateLoadsTheAddressAndWaitsForTheLoadEvent() async {
        cdp.responders["Page.navigate"] = { _ in .object(["frameId": .string("F"), "loaderId": .string("L")]) }
        cdp.eventsAfter["Page.navigate"] = [("Page.loadEventFired", .object(["timestamp": .number(1)]))]
        let result = await run(AgentToolCatalog.navigate, ["url": .string("example.com")])
        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(result.text, "Loaded https://example.com/\nTitle: Example Domain")
        XCTAssertEqual(Array(cdp.methods.prefix(5)),
                       ["Page.enable", "Runtime.enable", "Log.enable", "Page.getFrameTree", "Page.navigate"])
        XCTAssertEqual(cdp.params(of: "Page.navigate").first?["url"], .string("https://example.com"))
    }

    func testNavigateReportsAFailedLoadAndRefusesAddressesOutsideThePolicy() async {
        cdp.responders["Page.navigate"] = { _ in .object(["frameId": .string("F"), "errorText": .string("net::ERR_NAME_NOT_RESOLVED")]) }
        let failed = await run(AgentToolCatalog.navigate, ["url": .string("https://nowhere.invalid")])
        XCTAssertTrue(failed.isError)
        XCTAssertTrue(failed.text.contains("net::ERR_NAME_NOT_RESOLVED"), failed.text)

        for refused in ["javascript:alert(1)", "chrome://settings", "ftp://example.com/file"] {
            let result = await run(AgentToolCatalog.navigate, ["url": .string(refused)])
            XCTAssertTrue(result.isError, refused)
        }
        XCTAssertEqual(cdp.params(of: "Page.navigate").count, 1,
                       "The panel's address rule applies before anything reaches the browser")
        cdp.responders["Page.navigate"] = { _ in .object(["frameId": .string("F")]) }
        _ = await run(AgentToolCatalog.navigate, ["url": .string("localhost:3000/app")])
        XCTAssertEqual(cdp.params(of: "Page.navigate").last?["url"], .string("http://localhost:3000/app"))
    }

    /// A file outside the task's folders, read after `..`, escapes and symbolic links, opens only when the app
    /// says so: at once for a task that runs without asking, on the person's answer otherwise
    /// (`AppModel.allowsBrowserFile`). A file the page brings in itself (a link, a script, an iframe) is asked
    /// about before the next tool reads the page, and one the task was let open is not asked about again.
    func testAFileOutsideTheTasksFoldersOpensOnlyWhenAllowed() async throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "agent-files-\(UUID().uuidString)")
        let root = base.appending(path: "work"), secret = base.appending(path: "secret")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secret, withIntermediateDirectories: true)
        try Data("<p>hi</p>".utf8).write(to: root.appending(path: "page.html"))
        try Data("key".utf8).write(to: secret.appending(path: "key.txt"))
        try FileManager.default.createSymbolicLink(at: root.appending(path: "link"), withDestinationURL: secret)
        defer { try? FileManager.default.removeItem(at: base) }
        tools.workspaceRoots = { _ in [root] }
        tools.allowsFileOutsideFolders = { [unowned self] _, path in
            askedFiles.append(path)
            return allowsFiles
        }
        let task = UUID()
        func run(_ tool: String, _ arguments: [String: JSONValue] = [:]) async -> AgentToolResult {
            await tools.run(tool: tool, arguments: .object(arguments), sessionID: task)
        }
        cdp.responders["Page.navigate"] = { _ in .object(["frameId": .string("F")]) }
        let rootPath = root.path(percentEncoded: false)
        let key = secret.appending(path: "key.txt").resolvingSymlinksInPath().path(percentEncoded: false)

        let inside = await run(AgentToolCatalog.navigate, ["url": .string(root.appending(path: "page.html").absoluteString)])
        XCTAssertFalse(inside.isError, inside.text)
        XCTAssertTrue(askedFiles.isEmpty, "A file in the task's folders opens without asking")

        for escape in [rootPath + "/../secret/key.txt", root.appending(path: "link/key.txt").absoluteString,
                       "file://" + rootPath + "/%2e%2e/secret/key.txt", "file://" + rootPath + "/..\\secret/key.txt"] {
            let refused = await run(AgentToolCatalog.navigate, ["url": .string(escape)])
            XCTAssertEqual(refused.text, "The person did not allow opening \(key).", escape)
        }
        XCTAssertEqual(askedFiles, [key, key, key, key])
        XCTAssertEqual(cdp.params(of: "Page.navigate").count, 1, "A refused file is not opened")

        allowsFiles = true
        let allowed = await run(AgentToolCatalog.navigate, ["url": .string(root.appending(path: "link/key.txt").absoluteString)])
        XCTAssertFalse(allowed.isError, allowed.text)
        XCTAssertEqual(cdp.params(of: "Page.navigate").count, 2)
        // The page shows that file now; reading it asks no more.
        cdp.eventLog.append(("Page.frameNavigated", .object(["frame": .object(["id": .string("F"), "url": .string("file://" + key)])])))
        let console = await run(AgentToolCatalog.consoleMessages)
        XCTAssertFalse(console.isError, console.text)
        XCTAssertEqual(askedFiles.count, 5)

        allowsFiles = false
        let other = secret.resolvingSymlinksInPath().appending(path: "other.txt").path(percentEncoded: false)
        cdp.eventLog.append(("Page.frameNavigated", .object(["frame": .object([
            "id": .string("C"), "parentId": .string("F"), "url": .string(URL(filePath: other).absoluteString)
        ])])))
        let read = await run(AgentToolCatalog.snapshot)
        XCTAssertEqual(read.text, "The page shows \(other), a file outside this task's folders, and the person did not allow opening it.")
        XCTAssertFalse(cdp.methods.contains("Accessibility.getFullAXTree"), "Nothing of the page is read")
        XCTAssertEqual(askedFiles.last, other)

        // Once the page moves on, its files go with it.
        cdp.eventLog.append(("Page.frameNavigated", .object(["frame": .object(["id": .string("F"), "url": .string("https://example.com/")])])))
        let moved = await run(AgentToolCatalog.consoleMessages)
        XCTAssertFalse(moved.isError, moved.text)
        XCTAssertEqual(askedFiles.count, 6)
        XCTAssertNil(BrowserAgentWorkspaceFile.realPath(ofFileAddress: "https://example.com/"))
    }

    /// The host checks every navigation, the agent's included, and says so with an event.
    func testANavigationTheHostBlocksIsAnErrorAndAPageLedOneIsANotice() async {
        let page = page!
        cdp.responders["Page.navigate"] = { params in
            page.receive(.navigationBlocked(tab: 4, url: params["url"]?.stringValue ?? ""))
            return .object(["frameId": .string("F"), "errorText": .string("net::ERR_ABORTED")])
        }
        let blocked = await run(AgentToolCatalog.navigate, ["url": .string("data:text/html,hi")])
        XCTAssertTrue(blocked.isError)
        XCTAssertEqual(blocked.text, "The browser's address policy blocked data:text/html,hi.")

        cdp.responders["Input.dispatchMouseEvent"] = { params in
            if params["type"] == .string("mouseReleased") { page.receive(.navigationBlocked(tab: 4, url: "chrome://settings")) }
            return .object([:])
        }
        let clicked = await run(AgentToolCatalog.click, ["x": .number(1), "y": .number(1)])
        XCTAssertFalse(clicked.isError)
        XCTAssertTrue(clicked.text.contains("The page tried to open chrome://settings, which the browser's address policy blocks."),
                      clicked.text)

        // A refusal that arrives after the tool answered is named by the next result, once.
        page.receive(.navigationBlocked(tab: 4, url: "ftp://example.com/late"))
        let next = await run(AgentToolCatalog.consoleMessages)
        XCTAssertTrue(next.text.contains("ftp://example.com/late"), next.text)
        let after = await run(AgentToolCatalog.consoleMessages)
        XCTAssertFalse(after.text.contains("ftp://example.com/late"), after.text)
    }

    // MARK: - Dialogs and file choosers

    private func dialog(_ kind: BrowserJavaScriptDialog.Kind, _ message: String, id: Int = 3) -> BrowserHostEvent {
        .javaScriptDialog(tab: 4, dialog: BrowserJavaScriptDialog(
            id: id, kind: kind, message: message, defaultPrompt: kind == .prompt ? "Ada" : "",
            origin: "https://example.com", isReload: false
        ))
    }

    func testADialogThatOpensDuringAToolEndsItsWaitAndPausesTheOtherTools() async throws {
        cdp.suspendOn = ["Runtime.evaluate"]
        let running = Task { await run(AgentToolCatalog.evaluate, ["function": .string("() => confirm('Delete?')")]) }
        try await Task.sleep(for: .milliseconds(30))
        page.receive(dialog(.confirm, "Delete?"))
        let interrupted = await running.value
        XCTAssertFalse(interrupted.isError)
        XCTAssertEqual(interrupted.text, "A JavaScript confirm dialog from https://example.com is open: “Delete?”. It "
            + "opened during browser_evaluate. The page is paused until you answer it with browser_handle_dialog.")

        let refused = await run(AgentToolCatalog.snapshot)
        XCTAssertTrue(refused.isError)
        XCTAssertTrue(refused.text.contains("answer it with browser_handle_dialog"), refused.text)
        let console = await run(AgentToolCatalog.consoleMessages)
        XCTAssertFalse(console.isError, "Reading the console needs no page")
        XCTAssertTrue(console.text.contains("confirm dialog"), "Every result says a dialog is open")

        let answered = await run(AgentToolCatalog.handleDialog, ["accept": .bool(false)])
        XCTAssertEqual(answered.text, "Dismissed the confirm dialog “Delete?”.")
        XCTAssertEqual(hostCommands.last, .javaScriptDialogResult(tab: 4, dialog: 3, accepted: false, text: nil))
        let none = await run(AgentToolCatalog.handleDialog, ["accept": .bool(true)])
        XCTAssertTrue(none.isError)
        cdp.resumeSuspended()
    }

    func testAPromptTakesTextAndADialogTheHostWithdrawsIsForgotten() async {
        page.receive(dialog(.prompt, "Your name?", id: 9))
        let answered = await run(AgentToolCatalog.handleDialog, ["accept": .bool(true), "promptText": .string("Grace")])
        XCTAssertEqual(answered.text, "Accepted the prompt dialog “Your name?”.")
        XCTAssertEqual(hostCommands.last, .javaScriptDialogResult(tab: 4, dialog: 9, accepted: true, text: "Grace"))

        page.receive(dialog(.beforeUnload, "Leave site?", id: 10))
        page.receive(.javaScriptDialogReset(tab: 4))
        let afterReset = await run(AgentToolCatalog.consoleMessages)
        XCTAssertFalse(afterReset.text.contains("dialog"), afterReset.text)
    }

    func testABatchStopsWithoutErrorWhenADialogOpens() async throws {
        cdp.responders["Input.dispatchMouseEvent"] = { [unowned self] params in
            if params["type"] == .string("mouseReleased") { self.page.receive(self.dialog(.alert, "Saved")) }
            return .object([:])
        }
        let result = await run(AgentToolCatalog.batch, ["actions": .array([
            .object(["name": .string("browser_click"), "input": .object(["x": .number(1), "y": .number(1)])]),
            .object(["name": .string("browser_snapshot")])
        ])])
        XCTAssertFalse(result.isError, result.text)
        XCTAssertTrue(result.text.contains("alert dialog from https://example.com is open: “Saved”"), result.text)
        XCTAssertTrue(result.text.hasSuffix("Stopped after action 1 because a dialog is open; 1 later action was not run."),
                      result.text)
    }

    func testFileUploadsComeOnlyFromTheTasksFolders() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "agent-upload-\(UUID().uuidString)")
        let outside = FileManager.default.temporaryDirectory.appending(path: "agent-outside-\(UUID().uuidString).txt")
        try FileManager.default.createDirectory(at: root.appending(path: "docs"), withIntermediateDirectories: true)
        try Data("a".utf8).write(to: root.appending(path: "docs/a.txt"))
        try Data("b".utf8).write(to: root.appending(path: "b.txt"))
        try Data("secret".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: root.appending(path: "escape.txt"), withDestinationURL: outside)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        tools.workspaceRoots = { _ in [root] }

        let noChooser = await run(AgentToolCatalog.fileUpload, ["paths": .array([.string("b.txt")])])
        XCTAssertTrue(noChooser.isError)

        page.receive(.fileDialog(tab: 4, dialog: BrowserFileDialog(id: 5, mode: .open, title: "Upload", defaultPath: "", extensions: [])))
        let notice = await run(AgentToolCatalog.consoleMessages)
        XCTAssertTrue(notice.text.contains("A file chooser “Upload” is open"), notice.text)
        for refused in [outside.path(percentEncoded: false), "escape.txt", "../\(outside.lastPathComponent)", "docs", "missing.txt"] {
            let result = await run(AgentToolCatalog.fileUpload, ["paths": .array([.string(refused)])])
            XCTAssertTrue(result.isError, refused)
        }
        let two = await run(AgentToolCatalog.fileUpload, ["paths": .array([.string("b.txt"), .string("docs/a.txt")])])
        XCTAssertTrue(two.text.contains("takes one file"), two.text)
        XCTAssertTrue(hostCommands.isEmpty, "Nothing outside the rules reaches the page")

        let chosen = await run(AgentToolCatalog.fileUpload, ["paths": .array([.string("docs/a.txt")])])
        XCTAssertEqual(chosen.text, "Gave the file chooser “a.txt”.")
        let expected = root.appending(path: "docs/a.txt").resolvingSymlinksInPath().path(percentEncoded: false)
        XCTAssertEqual(hostCommands.last, .fileDialogResult(tab: 4, dialog: 5, paths: [expected]))

        page.receive(.fileDialog(tab: 4, dialog: BrowserFileDialog(id: 6, mode: .openMultiple, title: "", defaultPath: "", extensions: [])))
        let cancelled = await run(AgentToolCatalog.fileUpload, [:])
        XCTAssertEqual(cancelled.text, "Cancelled the file chooser.")
        XCTAssertEqual(hostCommands.last, .fileDialogResult(tab: 4, dialog: 6, paths: nil))
        XCTAssertTrue(BrowserAgentWorkspaceFile.contains(URL(filePath: "/work/app"), URL(filePath: "/work/app/x")))
        XCTAssertFalse(BrowserAgentWorkspaceFile.contains(URL(filePath: "/work/app"), URL(filePath: "/work/application/x")))
    }

    // MARK: - Snapshot and references

    func testSnapshotRendersTheTreeAndGivesActionableElementsReferences() async {
        let result = await loadSnapshot()
        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(result.text, """
            Page URL: https://example.com/
            Page title: Example Domain

            - heading "Welcome" [level=1] [ref=@e1]
            - textbox "Name" [required] [ref=@e2]: "Ada"
            - button "Send" [ref=@e3]
            - paragraph: "Hello world"
            - link "Docs" [url=/docs] [ref=@e4]
            """, "references only on what an agent acts on; a link on the page's own site reads as its path")
        XCTAssertEqual(page.refs, ["@e1": .init(node: 10), "@e2": .init(node: 12), "@e3": .init(node: 13), "@e4": .init(node: 15)])
    }

    /// Each frame's tree goes under the iframe that holds it; a frame from another site says its origin, and its
    /// elements' references carry its session. Separators and a container's name taken from its own text go.
    func testSnapshotPlacesEachFramesTreeUnderItsIframe() {
        func node(_ id: String, _ role: String, _ name: String = "", parent: String? = nil, children: [String] = [],
                  backend: Int64? = nil, url: String? = nil, fromContents: Bool = false) -> JSONValue {
            var fields: [String: JSONValue] = [
                "nodeId": .string(id), "role": .object(["value": .string(role)]),
                "name": .object(["value": .string(name), "sources": .array(fromContents
                    ? [.object(["type": .string("contents"), "value": .object(["value": .string(name)])])] : [])]),
                "childIds": .array(children.map { .string($0) }),
                "properties": .array(url.map { [.object(["name": .string("url"), "value": .object(["value": .string($0)])])] } ?? [])
            ]
            if let parent { fields["parentId"] = .string(parent) }
            if let backend { fields["backendDOMNodeId"] = .integer(backend) }
            return .object(fields)
        }
        let page = BrowserAgentSnapshot.Frame(nodes: [
            node("1", "RootWebArea", "Shop", children: ["2", "3", "4"], backend: 1, url: "https://shop.test/cart"),
            node("2", "cell", "Total | 10", parent: "1", children: ["2a", "2b", "2c"], backend: 2, fromContents: true),
            node("2a", "StaticText", "Total", parent: "2"), node("2b", "StaticText", "|", parent: "2"),
            node("2c", "StaticText", "10", parent: "2"),
            node("3", "Iframe", "Card", parent: "1", backend: 3),
            node("4", "Iframe", "Hidden ad", parent: "1", backend: 4)
        ], children: [3: 1])
        let card = BrowserAgentSnapshot.Frame(nodes: [
            node("1", "RootWebArea", "Card", children: ["2"], backend: 1, url: "https://pay.test/frame?secret=x"),
            node("2", "textbox", "Card number", parent: "1", backend: 3)
        ], session: "S1")
        let rendered = BrowserAgentSnapshot.render(frames: [page, card])
        XCTAssertEqual(rendered.text, """
            - cell: "Total 10"
            - Iframe "Card" [origin=https://pay.test] [ref=@e1]
              - textbox "Card number" [ref=@e2]
            - Iframe "Hidden ad" [ref=@e3]
            """)
        XCTAssertEqual(rendered.refs["@e2"], BrowserAgentSnapshot.Ref(node: 3, session: "S1"),
                       "the same backend id in another process is a different element")
        XCTAssertEqual(rendered.refs["@e1"], BrowserAgentSnapshot.Ref(node: 3, session: nil))
    }

    func testReferencesNeedASnapshotAndExpireWithTheNextOneOrANavigation() async {
        let beforeSnapshot = await run(AgentToolCatalog.click, ["ref": .string("@e1")])
        XCTAssertTrue(beforeSnapshot.isError)
        XCTAssertTrue(beforeSnapshot.text.contains("Call browser_snapshot first"), beforeSnapshot.text)

        _ = await loadSnapshot()
        let unknown = await run(AgentToolCatalog.click, ["ref": .string("@e99")])
        XCTAssertTrue(unknown.isError)
        XCTAssertTrue(unknown.text.contains("not in the latest snapshot"), unknown.text)

        cdp.responders["DOM.scrollIntoViewIfNeeded"] = { _ in throw ScriptedCDP.missingNode("DOM.scrollIntoViewIfNeeded") }
        let stale = await run(AgentToolCatalog.click, ["ref": .string("@e3")])
        XCTAssertTrue(stale.isError)
        XCTAssertTrue(stale.text.contains("@e3 is stale"), stale.text)
        XCTAssertFalse(cdp.methods.contains("Input.dispatchMouseEvent"), "A stale reference clicks nothing")

        cdp.responders["Page.navigate"] = { _ in .object(["frameId": .string("F")]) }
        _ = await run(AgentToolCatalog.navigate, ["url": .string("https://example.com/#top")])
        let afterNavigation = await run(AgentToolCatalog.click, ["ref": .string("@e3")])
        XCTAssertTrue(afterNavigation.text.contains("not in the latest snapshot"), afterNavigation.text)
    }

    /// A link the agent clicked navigates without the navigate tool. The old document can stay
    /// alive in the back/forward cache and still answer for its nodes, so the navigation itself
    /// has to end the references.
    func testAMainFrameNavigationAfterTheSnapshotMakesItsReferencesStale() async {
        _ = await loadSnapshot()
        cdp.responders["DOM.getContentQuads"] = { _ in
            .object(["quads": .array([.array([0, 0, 10, 0, 10, 10, 0, 10].map { .number($0) })])])
        }
        cdp.eventLog.append(("Page.frameNavigated", .object(["frame": .object(["id": .string("child"), "parentId": .string("main")])])))
        let afterFrame = await run(AgentToolCatalog.click, ["ref": .string("@e3")])
        XCTAssertFalse(afterFrame.isError, "An iframe navigating leaves the page's references alone")

        cdp.eventLog.append(("Page.frameNavigated", .object(["frame": .object(["id": .string("main"), "url": .string("https://example.com/second")])])))
        cdp.sent = []
        let afterNavigation = await run(AgentToolCatalog.click, ["ref": .string("@e3")])
        XCTAssertTrue(afterNavigation.isError)
        XCTAssertTrue(afterNavigation.text.contains("@e3 is stale: the page navigated"), afterNavigation.text)
        XCTAssertFalse(cdp.methods.contains("Input.dispatchMouseEvent"), "Nothing is clicked at the old position")
    }

    // MARK: - Input

    func testClickByReferenceUsesTheElementCentreAndTrustedMouseEvents() async throws {
        _ = await loadSnapshot()
        cdp.responders["DOM.getContentQuads"] = { _ in
            .object(["quads": .array([.array([10, 20, 110, 20, 110, 60, 10, 60].map { .number($0) })])])
        }
        let result = await run(AgentToolCatalog.click, ["ref": .string("@e3")])
        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(result.text, "Clicked @e3 at (60, 40).")
        XCTAssertEqual(cdp.params(of: "DOM.scrollIntoViewIfNeeded").first?["backendNodeId"], .integer(13))
        let mouse = cdp.params(of: "Input.dispatchMouseEvent")
        XCTAssertEqual(mouse.map { $0["type"]?.stringValue }, ["mouseMoved", "mousePressed", "mouseReleased"])
        XCTAssertEqual(mouse[1]["x"], .number(60))
        XCTAssertEqual(mouse[1]["y"], .number(40))
        XCTAssertEqual(mouse[1]["button"], .string("left"))
        XCTAssertEqual(mouse[1]["clickCount"], .integer(1))
        XCTAssertEqual(mouse[1]["buttons"], .integer(1))
    }

    func testClickAtAPointCanDoubleClickWithAnotherButtonAndModifiers() async {
        let result = await run(AgentToolCatalog.click, [
            "x": .number(5), "y": .number(6), "doubleClick": .bool(true), "button": .string("right"),
            "modifiers": .array([.string("Shift"), .string("Meta")])
        ])
        XCTAssertFalse(result.isError, result.text)
        let mouse = cdp.params(of: "Input.dispatchMouseEvent")
        XCTAssertEqual(mouse.map { $0["type"]?.stringValue }, ["mouseMoved", "mousePressed", "mouseReleased", "mousePressed", "mouseReleased"])
        XCTAssertEqual(mouse[3]["clickCount"], .integer(2))
        XCTAssertEqual(mouse[3]["button"], .string("right"))
        XCTAssertEqual(mouse[3]["modifiers"], .integer(12))
        let missing = await run(AgentToolCatalog.click, [:])
        XCTAssertTrue(missing.isError)
    }

    func testTypeFocusesSelectsTheOldTextInsertsTrustedTextAndSubmits() async {
        _ = await loadSnapshot()
        cdp.responders["DOM.resolveNode"] = { _ in .object(["object": .object(["objectId": .string("obj-12")])]) }
        cdp.responders["Runtime.callFunctionOn"] = { _ in ScriptedCDP.value(.string("field")) }
        let result = await run(AgentToolCatalog.type, ["ref": .string("@e2"), "text": .string("Grace"), "submit": .bool(true)])
        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(result.text, "Typed 5 characters into @e2 and pressed Enter.")
        XCTAssertEqual(cdp.params(of: "DOM.focus").first?["backendNodeId"], .integer(12))
        XCTAssertEqual(cdp.params(of: "Runtime.callFunctionOn").first?["objectId"], .string("obj-12"))
        XCTAssertEqual(cdp.params(of: "Input.insertText").first?["text"], .string("Grace"))
        let keys = cdp.params(of: "Input.dispatchKeyEvent")
        XCTAssertEqual(keys.map { $0["type"]?.stringValue }, ["keyDown", "keyUp"])
        XCTAssertEqual(keys[0]["key"], .string("Enter"))
        XCTAssertEqual(keys[0]["text"], .string("\r"))
        XCTAssertEqual(keys[0]["windowsVirtualKeyCode"], .integer(13))
    }

    func testTypeRefusesAnElementThatIsNotATextField() async {
        _ = await loadSnapshot()
        cdp.responders["DOM.resolveNode"] = { _ in .object(["object": .object(["objectId": .string("obj-13")])]) }
        cdp.responders["Runtime.callFunctionOn"] = { _ in ScriptedCDP.value(.string("other")) }
        let result = await run(AgentToolCatalog.type, ["ref": .string("@e3"), "text": .string("x")])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("not an editable text field"), result.text)
        XCTAssertTrue(cdp.params(of: "Input.insertText").isEmpty)
    }

    func testPressKeyHoldsModifiersAndCarriesMacEditingCommands() async {
        let result = await run(AgentToolCatalog.pressKey, ["key": .string("Meta+a")])
        XCTAssertFalse(result.isError, result.text)
        let keys = cdp.params(of: "Input.dispatchKeyEvent")
        XCTAssertEqual(keys.map { $0["type"]?.stringValue }, ["rawKeyDown", "rawKeyDown", "keyUp", "keyUp"])
        XCTAssertEqual(keys.map { $0["key"]?.stringValue }, ["Meta", "a", "a", "Meta"])
        XCTAssertEqual(keys.map { $0["modifiers"] }, [.integer(4), .integer(4), .integer(4), .integer(0)])
        XCTAssertEqual(keys[1]["commands"], .array([.string("selectAll")]))
        XCTAssertNil(keys[1]["text"], "A shortcut types nothing")

        cdp.sent = []
        _ = await run(AgentToolCatalog.pressKey, ["key": .string("Backspace")])
        XCTAssertEqual(cdp.params(of: "Input.dispatchKeyEvent").first?["commands"], .array([.string("deleteBackward")]))

        let unknown = await run(AgentToolCatalog.pressKey, ["key": .string("Hyper+x")])
        XCTAssertTrue(unknown.isError)
    }

    func testKeyNamesParseLikeAPlaywrightKeyboard() throws {
        let shiftTab = try XCTUnwrap(BrowserAgentKeyPress.parse("Shift+Tab"))
        XCTAssertEqual(shiftTab.key.keyCode, 9)
        XCTAssertEqual(shiftTab.modifierBits, 8)
        let shiftedLetter = try XCTUnwrap(BrowserAgentKeyPress.parse("Shift+a"))
        XCTAssertEqual(shiftedLetter.key.key, "A")
        XCTAssertEqual(shiftedLetter.key.text, "A")
        XCTAssertEqual(shiftedLetter.key.code, "KeyA")
        XCTAssertEqual(BrowserAgentKeyPress.parse("Esc")?.key.keyCode, 27)
        XCTAssertEqual(BrowserAgentKeyPress.parse("Meta++")?.key.code, "Equal")
        XCTAssertEqual(BrowserAgentKeyPress.parse("?")?.key.code, "Slash")
        XCTAssertEqual(BrowserAgentKeyPress.parse("한")?.key.text, "한")
        XCTAssertEqual(BrowserAgentKeyPress.parse("Shift+Meta+z")?.macEditingCommands, ["redo"])
        XCTAssertEqual(BrowserAgentKeyPress.parse("Alt+ArrowLeft")?.macEditingCommands, ["moveWordLeft"])
        XCTAssertNil(BrowserAgentKeyPress.parse(""))
        XCTAssertNil(BrowserAgentKeyPress.parse("Enterprise"))
    }

    func testScrollSendsAWheelEventAtThePageCentreAndReportsThePosition() async {
        cdp.responders["Page.getLayoutMetrics"] = { _ in
            .object(["cssVisualViewport": .object(["clientWidth": .number(1000), "clientHeight": .number(600),
                                                     "pageX": .number(0), "pageY": .number(0)])])
        }
        let result = await run(AgentToolCatalog.scroll, ["deltaY": .number(400)])
        XCTAssertFalse(result.isError, result.text)
        let wheel = cdp.params(of: "Input.dispatchMouseEvent").first
        XCTAssertEqual(wheel?["type"], .string("mouseWheel"))
        XCTAssertEqual(wheel?["x"], .number(500))
        XCTAssertEqual(wheel?["y"], .number(300))
        XCTAssertEqual(wheel?["deltaY"], .number(400))
        XCTAssertEqual(result.text, "Scrolled. The page is at x=0, y=400 of 1280×5000.")
    }

    func testSelectOptionPassesTheValuesAndNamesTheOptionsWhenOneIsMissing() async {
        _ = await loadSnapshot()
        cdp.responders["DOM.resolveNode"] = { _ in .object(["object": .object(["objectId": .string("obj")])]) }
        cdp.responders["Runtime.callFunctionOn"] = { params in
            let wanted = params["arguments"]?.arrayValue?.first?["value"]?.arrayValue?.first?.stringValue
            return wanted == "Blue"
                ? ScriptedCDP.value(.object(["selected": .array([.string("Blue")])]))
                : ScriptedCDP.value(.object(["error": .string("has no option \"Pink\""),
                                             "options": .array([.string("Red"), .string("Blue")])]))
        }
        let chosen = await run(AgentToolCatalog.selectOption, ["ref": .string("@e2"), "values": .array([.string("Blue")])])
        XCTAssertEqual(chosen.text, "Selected \"Blue\" in @e2.")
        let missing = await run(AgentToolCatalog.selectOption, ["ref": .string("@e2"), "values": .array([.string("Pink")])])
        XCTAssertTrue(missing.isError)
        XCTAssertTrue(missing.text.contains("Options: Red, Blue"), missing.text)
    }

    // MARK: - Reading the page

    func testWaitForLooksAgainUntilTheTextAppearsAndFailsAfterItsTimeout() async {
        cdp.bodyTexts = ["Loading", "Loading", "Saved"]
        let appeared = await run(AgentToolCatalog.waitFor, ["text": .string("Saved")])
        XCTAssertEqual(appeared.text, "\"Saved\" appeared.")

        cdp.bodyTexts = ["Loading"]
        let timedOut = await run(AgentToolCatalog.waitFor, ["text": .string("Saved"), "timeout": .number(0.05)])
        XCTAssertTrue(timedOut.isError)
        XCTAssertTrue(timedOut.text.contains("it did not"), timedOut.text)

        let gone = await run(AgentToolCatalog.waitFor, ["textGone": .string("Spinner")])
        XCTAssertEqual(gone.text, "\"Spinner\" is gone.")
        let nothing = await run(AgentToolCatalog.waitFor, [:])
        XCTAssertTrue(nothing.isError)
    }

    func testScreenshotIsAnImageAtOneImagePixelPerCSSPixel() async throws {
        cdp.pixelRatio = 2
        cdp.responders["Page.getLayoutMetrics"] = { _ in
            .object([
                "cssVisualViewport": .object(["clientWidth": .number(1280), "clientHeight": .number(800),
                                              "pageX": .number(0), "pageY": .number(120)]),
                "cssContentSize": .object(["width": .number(1280), "height": .number(3000)])
            ])
        }
        cdp.responders["Page.captureScreenshot"] = { _ in .object(["data": .string("iVBORw0KGgo=")]) }
        let result = await run(AgentToolCatalog.screenshot)
        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(result.content.first, .image(data: "iVBORw0KGgo=", mimeType: "image/png"))
        let clip = try XCTUnwrap(cdp.params(of: "Page.captureScreenshot").first?["clip"])
        XCTAssertEqual(clip["y"], .number(120))
        XCTAssertEqual(clip["width"], .number(1280))
        XCTAssertEqual(clip["scale"], .number(0.5))

        _ = await run(AgentToolCatalog.screenshot, ["fullPage": .bool(true), "format": .string("jpeg")])
        let full = try XCTUnwrap(cdp.params(of: "Page.captureScreenshot").last)
        XCTAssertEqual(full["captureBeyondViewport"], .bool(true))
        XCTAssertEqual(full["format"], .string("jpeg"))
        XCTAssertEqual(full["clip"]?["height"], .number(3000))

        // CEF's windowless view does not grow for Chromium's capture, so the tab is drawn at the page's size
        // for it: the layout viewport held first, the view back before the hold ends, and no more than a GPU
        // texture's 16,384 device pixels.
        let viewport = BrowserViewport(width: 1280, height: 800, scale: 2)
        page.viewport = { [unowned self] in
            self.hostCommands.reversed().lazy.compactMap { if case .resize(_, let size) = $0 { size } else { nil } }.first ?? viewport
        }
        cdp.responders["Page.getLayoutMetrics"] = { _ in
            .object([
                "cssVisualViewport": .object(["clientWidth": .number(1280), "clientHeight": .number(800)]),
                "cssContentSize": .object(["width": .number(1280), "height": .number(20_000)])
            ])
        }
        var commandsAt: [String: Int] = [:]
        for method in ["Emulation.setDeviceMetricsOverride", "Page.captureScreenshot", "Emulation.clearDeviceMetricsOverride"] {
            cdp.responders[method] = { [unowned self] _ in
                commandsAt[method] = self.hostCommands.count
                return .object(["data": .string("iVBORw0KGgo=")])
            }
        }
        let tall = await run(AgentToolCatalog.screenshot, ["fullPage": .bool(true)])
        XCTAssertEqual(commandsAt, ["Emulation.setDeviceMetricsOverride": 0, "Page.captureScreenshot": 1,
                                    "Emulation.clearDeviceMetricsOverride": 2])
        XCTAssertEqual(cdp.params(of: "Emulation.setDeviceMetricsOverride").last?["height"], .integer(800))
        XCTAssertEqual(hostCommands, [.resize(tab: 4, viewport: BrowserViewport(width: 1280, height: 8190, scale: 2)),
                                      .resize(tab: 4, viewport: viewport)])
        XCTAssertEqual(cdp.params(of: "Page.captureScreenshot").last?["clip"]?["height"], .number(8190))
        XCTAssertTrue(tall.text.contains("The page is 20000 CSS pixels tall; this is its top."), tall.text)
    }

    func testConsoleMessagesListConsoleCallsLogEntriesAndUncaughtErrors() async {
        cdp.eventLog = [
            ("Runtime.consoleAPICalled", .object(["type": .string("log"), "args": .array([
                .object(["type": .string("string"), "value": .string("ready")]),
                .object(["type": .string("number"), "value": .integer(3)])
            ])])),
            ("Runtime.exceptionThrown", .object(["exceptionDetails": .object([
                "text": .string("Uncaught"), "exception": .object(["description": .string("TypeError: x is undefined")])
            ])])),
            ("Log.entryAdded", .object(["entry": .object([
                "level": .string("error"), "text": .string("Failed to load resource"), "url": .string("https://example.com/a.js")
            ])])),
            ("Page.loadEventFired", .object([:]))
        ]
        let all = await run(AgentToolCatalog.consoleMessages)
        XCTAssertEqual(all.text, """
            [log] ready 3
            [uncaught] TypeError: x is undefined
            [error] Failed to load resource (https://example.com/a.js)
            """)
        let errors = await run(AgentToolCatalog.consoleMessages, ["onlyErrors": .bool(true)])
        XCTAssertFalse(errors.text.contains("ready"))
    }

    func testEvaluateReturnsTheResultAsJSONAndReportsWhatTheFunctionThrew() async {
        cdp.responders["Runtime.evaluate"] = { params in
            let expression = params["expression"]?.stringValue ?? ""
            if expression.contains("boom") {
                return .object(["result": .object(["type": .string("object")]),
                                "exceptionDetails": .object(["text": .string("Uncaught"),
                                                             "exception": .object(["description": .string("Error: boom")])])])
            }
            return ScriptedCDP.value(.object(["count": .integer(2)]))
        }
        let value = await run(AgentToolCatalog.evaluate, ["function": .string("() => ({ count: 2 })")])
        XCTAssertFalse(value.isError, value.text)
        XCTAssertTrue(value.text.contains("\"count\" : 2"), value.text)
        let sent = cdp.params(of: "Runtime.evaluate").first
        XCTAssertEqual(sent?["awaitPromise"], .bool(true))
        XCTAssertEqual(sent?["returnByValue"], .bool(true))
        XCTAssertTrue(sent?["expression"]?.stringValue?.contains("() => ({ count: 2 })") == true)

        let thrown = await run(AgentToolCatalog.evaluate, ["function": .string("() => { throw new Error('boom') }")])
        XCTAssertTrue(thrown.isError)
        XCTAssertTrue(thrown.text.contains("Error: boom"), thrown.text)
    }

    /// The vault's values reach the page and nothing the model reads: not the fill's result, not a later
    /// snapshot that echoes one, and browser_evaluate waits while a filled field still holds one
    /// (docs/BROWSER_VAULT_DESIGN.md §5.3).
    func testAVaultFillKeepsItsValuesOutOfResultsAndPausesEvaluateWhileTheyAreOnThePage() async {
        let item = VaultItem(name: "Example", sites: ["example.com"], username: "ada", policy: .always)
        tools.vault = VaultCenter(environment: VaultCenter.Environment(
            secrets: InMemoryVaultSecretStore([item.id: VaultSecret(password: "correct-horse-battery")]),
            repository: InMemoryVaultRepository(items: [item]), hmac: MacVault.hmac, isAllowedBuild: true,
            defaults: .vaultTests()))
        _ = await loadSnapshot()
        var stillFilled = true
        cdp.responders["Page.getFrameTree"] = { _ in
            .object(["frameTree": .object(["frame": .object([
                "id": .string("main"), "loaderId": .string("doc-1"), "url": .string("https://www.example.com/login"),
                "securityOrigin": .string("https://www.example.com")
            ])])])
        }
        cdp.responders["Page.createIsolatedWorld"] = { _ in .object(["executionContextId": .integer(7)]) }
        cdp.responders["DOM.resolveNode"] = { _ in .object(["object": .object(["objectId": .string("field")])]) }
        cdp.responders["Runtime.callFunctionOn"] = { params in
            let function = params["functionDeclaration"]?.stringValue ?? ""
            if function.contains("ownerDocument === document") { return ScriptedCDP.value(.bool(true)) }
            return ScriptedCDP.value(.object(["kinds": .array([.string("password"), .string("username")])]))
        }
        cdp.responders["Runtime.evaluate"] = { params in
            if params["contextId"] != nil { return ScriptedCDP.value(.bool(stillFilled)) }
            return ScriptedCDP.value(.array([.string("https://www.example.com/login"), .string("Sign in")]))
        }

        let filled = await run(VaultToolCatalog.fillCredential, ["ref": .string("@e2")])
        XCTAssertFalse(filled.isError, filled.text)
        XCTAssertFalse(filled.text.contains("correct-horse-battery"), filled.text)
        XCTAssertTrue(filled.text.contains("the username and password of “Example”"), filled.text)
        let fill = cdp.params(of: "Runtime.callFunctionOn").last
        XCTAssertEqual(fill?["objectId"], .string("field"))
        XCTAssertTrue(fill?["arguments"]?.arrayValue?.contains(.object(["value": .string("correct-horse-battery")])) == true)

        func axNode(_ id: String, _ role: String, _ name: String, parent: String?, children: [String] = [],
                    value: String? = nil) -> JSONValue {
            var fields: [String: JSONValue] = [
                "nodeId": .string(id), "ignored": .bool(false), "backendDOMNodeId": .integer(Int64(id) ?? 0),
                "childIds": .array(children.map { .string($0) }), "role": .object(["value": .string(role)]),
                "name": .object(["value": .string(name)])
            ]
            if let parent { fields["parentId"] = .string(parent) }
            if let value { fields["value"] = .object(["value": .string(value)]) }
            return .object(fields)
        }
        cdp.responders["Accessibility.getFullAXTree"] = { _ in
            .object(["nodes": .array([
                axNode("1", "RootWebArea", "Sign in", parent: nil, children: ["2", "3"]),
                axNode("2", "paragraph", "", parent: "1", children: ["4"]),
                axNode("4", "StaticText", "Signed in with correct-horse-battery", parent: "2"),
                axNode("3", "textbox", "Password", parent: "1", value: "•••••••••••••••••••••")
            ])])
        }
        let echoed = await run(AgentToolCatalog.snapshot)
        XCTAssertFalse(echoed.text.contains("correct-horse-battery"), echoed.text)
        XCTAssertTrue(echoed.text.contains("[saved value]"), echoed.text)
        XCTAssertTrue(echoed.text.contains("textbox \"Password\" [ref=@e1]: \"<redacted>\""), echoed.text)

        let paused = await run(AgentToolCatalog.evaluate, ["function": .string("() => 1")])
        XCTAssertTrue(paused.isError)
        XCTAssertTrue(paused.text.contains("password manager"), paused.text)
        stillFilled = false
        let resumed = await run(AgentToolCatalog.evaluate, ["function": .string("() => 1")])
        XCTAssertFalse(resumed.isError, resumed.text)

        let elsewhere = await run(VaultToolCatalog.fillCredential, ["ref": .string("@e2"), "item": .string("Other")])
        XCTAssertTrue(elsewhere.isError)

        // A field in a frame from another site is not the page's own, whatever its site.
        page.replaceRefs(["@e9": .init(node: 3, session: "frame-session")], eventMark: cdp.eventLog.count)
        let framed = await run(VaultToolCatalog.fillCredential, ["ref": .string("@e9")])
        XCTAssertTrue(framed.isError && framed.text.contains("inside a frame"), framed.text)
    }

    func testEvaluateWithAReferencePassesTheElement() async {
        _ = await loadSnapshot()
        cdp.responders["DOM.resolveNode"] = { _ in .object(["object": .object(["objectId": .string("obj-15")])]) }
        cdp.responders["Runtime.callFunctionOn"] = { _ in ScriptedCDP.value(.string("Docs")) }
        let result = await run(AgentToolCatalog.evaluate, ["function": .string("(element) => element.textContent"), "ref": .string("@e4")])
        XCTAssertEqual(result.text, "\"Docs\"")
        let call = cdp.params(of: "Runtime.callFunctionOn").first
        XCTAssertEqual(call?["objectId"], .string("obj-15"))
        XCTAssertEqual(call?["arguments"], .array([.object(["objectId": .string("obj-15")])]))
    }

    // MARK: - Resize

    private var emulations: [BrowserViewportEmulation?] = []
    private var colorSchemes: [String?] = []

    func testResizeEmulatesPresetsAndCustomSizesKeepsTheColorSchemeApartAndRefusesHalfASize() async {
        page.emulate = { [unowned self] in emulations.append($0) }
        page.emulateColorScheme = { [unowned self] in colorSchemes.append($0) }

        let phone = await run(AgentToolCatalog.resize, ["preset": .string("mobile")])
        XCTAssertFalse(phone.isError, phone.text)
        XCTAssertTrue(phone.text.hasPrefix("Viewport set to 375x812 (mobile) on this tab"), phone.text)
        XCTAssertEqual(emulations.last, BrowserViewportEmulation(width: 375, height: 812, owner: .agent))
        XCTAssertEqual(emulations.last??.mobile, true)
        XCTAssertEqual(emulations.last??.deviceMetrics["deviceScaleFactor"], .integer(2))

        _ = await run(AgentToolCatalog.resize, ["width": .number(1000.4), "height": .integer(700)])
        XCTAssertEqual(emulations.last, BrowserViewportEmulation(width: 1000, height: 700, owner: .agent))
        XCTAssertEqual(emulations.last??.mobile, false, "768 and wider is not a phone")

        let desktop = await run(AgentToolCatalog.resize, ["preset": .string("desktop"), "colorScheme": .string("dark")])
        XCTAssertEqual(emulations.count, 3)
        XCTAssertNil(emulations.last ?? nil)
        XCTAssertEqual(colorSchemes, ["dark"])
        XCTAssertTrue(desktop.text.contains("cleared") && desktop.text.contains("Color scheme emulation set to dark"), desktop.text)

        page.emulation = { BrowserViewportEmulation(BrowserViewportEmulation.tablet, owner: .person) }
        let over = await run(AgentToolCatalog.resize, ["preset": .string("mobile")])
        XCTAssertTrue(over.text.contains("replaced the 768x1024 size the person picked"), over.text)

        for (arguments, error) in [(["width": JSONValue.integer(500)], "needs both width and height"),
                                   (["width": .integer(0), "height": .integer(10)], "needs both width and height"),
                                   (["preset": .string("watch")], "Unknown preset"),
                                   (["colorScheme": .string("sepia")], "Unknown colorScheme"),
                                   ([:], "Provide a preset")] {
            let refused = await run(AgentToolCatalog.resize, arguments)
            XCTAssertTrue(refused.isError && refused.text.contains(error), refused.text)
        }
        XCTAssertEqual(emulations.count, 4, "a refused call changes nothing")

        // The panel fits a larger size in, scaled down, across the middle and from the top; a smaller one is centered.
        let large = BrowserViewportEmulation.pageFrame(for: CGSize(width: 1600, height: 1000), in: CGSize(width: 659, height: 426))
        XCTAssertEqual(large.scale, 659.0 / 1600, accuracy: 0.0001)
        XCTAssertEqual(large.origin, .zero)
        let small = BrowserViewportEmulation.pageFrame(for: CGSize(width: 375, height: 812), in: CGSize(width: 659, height: 900))
        XCTAssertEqual(small.scale, 1)
        XCTAssertEqual(small.origin, CGPoint(x: 142, y: 0))
    }

    // MARK: - Batch

    func testBatchRunsInOrderAndStopsAtTheFirstFailure() async {
        cdp.responders["Page.navigate"] = { _ in .object(["frameId": .string("F")]) }
        let result = await run(AgentToolCatalog.batch, ["actions": .array([
            .object(["name": .string("browser_navigate"), "input": .object(["url": .string("https://example.com")])]),
            .object(["name": .string("browser_click"), "input": .object(["ref": .string("@e5")])]),
            .object(["name": .string("browser_snapshot")])
        ])])
        XCTAssertTrue(result.isError)
        XCTAssertEqual(result.content.count, 3)
        XCTAssertTrue(result.text.hasPrefix("1. browser_navigate: Loaded https://example.com/"), result.text)
        XCTAssertTrue(result.text.contains("2. browser_click failed: There is no snapshot yet"), result.text)
        XCTAssertTrue(result.text.hasSuffix("Stopped at action 2; 1 later action was not run."), result.text)
        XCTAssertFalse(cdp.methods.contains("Accessibility.getFullAXTree"), "Nothing after the failure runs")
    }

    func testBatchCarriesImagesAndRefusesNestingAndUnknownTools() async {
        cdp.responders["Page.getLayoutMetrics"] = { _ in
            .object(["cssVisualViewport": .object(["clientWidth": .number(10), "clientHeight": .number(10)])])
        }
        cdp.responders["Page.captureScreenshot"] = { _ in .object(["data": .string("AAAA")]) }
        let shots = await run(AgentToolCatalog.batch, ["actions": .array([
            .object(["name": .string("browser_screenshot")]),
            .object(["name": .string("browser_wait_for"), "input": .object(["time": .number(0)])])
        ])])
        XCTAssertFalse(shots.isError, shots.text)
        XCTAssertEqual(shots.content.first, .image(data: "AAAA", mimeType: "image/png"))

        let nested = await run(AgentToolCatalog.batch, ["actions": .array([
            .object(["name": .string("browser_batch"), "input": .object(["actions": .array([])])])
        ])])
        XCTAssertTrue(nested.isError)
        XCTAssertTrue(nested.text.contains("cannot contain another batch"), nested.text)
        let unknown = await run(AgentToolCatalog.batch, ["actions": .array([.object(["name": .string("browser_fly")])])])
        XCTAssertTrue(unknown.isError)
        let empty = await run(AgentToolCatalog.batch, ["actions": .array([])])
        XCTAssertTrue(empty.isError)
    }

    // MARK: - Engine errors

    func testTheBrowserEnginesAbsenceAndCDPTimeoutsReadAsErrors() async {
        let unavailable = BrowserAgentTools(usesMacEditingCommands: false, pages: { _ in
            throw BrowserAgentToolError("This Yardlet build has no browser engine, so the browser tools are unavailable.")
        })
        let result = await unavailable.run(tool: AgentToolCatalog.snapshot, arguments: .object([:]), sessionID: UUID())
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("no browser engine"))

        cdp.responders["Accessibility.getFullAXTree"] = { _ in throw BrowserDevToolsError.timedOut("Accessibility.getFullAXTree") }
        let timedOut = await run(AgentToolCatalog.snapshot)
        XCTAssertTrue(timedOut.isError)
        XCTAssertEqual(timedOut.text, "The browser did not answer Accessibility.getFullAXTree in time.")
    }

    func testAToolSaysWhenThePageOpenedANewTab() async {
        page.receive(.openedTab(tab: 4, newTab: 9, url: "https://b.test/"))
        page.receive(.openedTab(tab: 4, newTab: nil, url: "https://c.test/"))
        let result = await run(AgentToolCatalog.consoleMessages)
        let text = result.content.compactMap { if case .text(let text) = $0 { text } else { nil } }.joined(separator: "\n")
        XCTAssertTrue(text.contains("The page opened https://b.test/ in a new tab (tabId \"9\")"), text)
        XCTAssertTrue(text.contains("https://c.test/ in place"), text)
        let next = await run(AgentToolCatalog.consoleMessages)
        XCTAssertFalse(next.content.contains { if case .text(let text) = $0 { text.contains("opened") } else { false } }, "said once")
    }
}
