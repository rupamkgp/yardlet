import AppKit
import XCTest
import YardletCEFAccessibility
@testable import NativeHarnessClient

/// Recorded CEF output (Fixtures/cef-accessibility-qa-page.json, the QA server's /a11y page) through
/// the host's reducer, the engine tree and the macOS elements.
final class BrowserAccessibilityRecordingTests: XCTestCase {
    struct Recorded {
        var kind: String
        var raw: Any
        var rawBytes: Int
    }

    static func recording() throws -> [Recorded] {
        let url = URL(filePath: #filePath).deletingLastPathComponent()
            .appending(path: "Fixtures/cef-accessibility-qa-page.json")
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let events = try XCTUnwrap(fixture["events"] as? [[String: Any]])
        return try events.map { event in
            let value = try XCTUnwrap(event["value"])
            let bytes = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]).count
            return Recorded(kind: event["kind"] as? String ?? "", raw: value, rawBytes: bytes)
        }
    }

    /// The host's work: reduce, then the JSON the event carries, decoded as Yardlet decodes it.
    static func events(from recording: [Recorded]) throws -> [BrowserHostEvent] {
        try recording.compactMap { recorded in
            if recorded.kind == "tree" {
                guard let change = CEFAccessibilityReducer.treeChange(recorded.raw) else { return nil }
                let data = try JSONSerialization.data(withJSONObject: ["accessibilityTree": ["tab": 1, "change": change]])
                return try JSONDecoder().decode(BrowserHostEvent.self, from: data)
            }
            let changes = CEFAccessibilityReducer.locationChanges(recorded.raw)
            let data = try JSONSerialization.data(withJSONObject: ["accessibilityLocations": ["tab": 1, "changes": changes]])
            return try JSONDecoder().decode(BrowserHostEvent.self, from: data)
        }
    }

    static func tree(from events: [BrowserHostEvent]) -> BrowserAccessibilityTree {
        let tree = BrowserAccessibilityTree()
        for event in events {
            switch event {
            case .accessibilityTree(_, let change): tree.apply(change)
            case .accessibilityLocations(_, let changes): tree.apply(changes)
            default: break
            }
        }
        return tree
    }

    static func find(_ tree: BrowserAccessibilityTree, role: String, label: String) -> BrowserAccessibilityKey? {
        tree.exposedNodes().first { tree.node($0)?.role == role && tree.label(of: $0) == label }
    }

    /// The host builds these by hand (BrowserHost.swift); the shapes must match the Codable enums.
    func testAccessibilityCommandAndScrollEventWireShape() throws {
        let command = try JSONEncoder().encode(BrowserHostCommand.accessibility(tab: 3, isEnabled: true))
        XCTAssertEqual(try JSONSerialization.jsonObject(with: command) as? NSDictionary,
                       ["accessibility": ["tab": 3, "isEnabled": true]] as NSDictionary)
        let scroll = try JSONSerialization.data(withJSONObject: ["scrollOffset": ["tab": 3, "x": 0, "y": 200.5]])
        XCTAssertEqual(try JSONDecoder().decode(BrowserHostEvent.self, from: scroll), .scrollOffset(tab: 3, x: 0, y: 200.5))
        XCTAssertEqual(BrowserHostEvent.scrollOffset(tab: 3, x: 0, y: 1).tab, 3)
    }

    func testReducerKeepsTheContractAndDropsInlineTextBoxes() throws {
        let recording = try Self.recording()
        let page = try XCTUnwrap(recording.max { $0.rawBytes < $1.rawBytes })
        let change = try XCTUnwrap(CEFAccessibilityReducer.treeChange(page.raw))
        let trimmedBytes = try JSONSerialization.data(withJSONObject: change).count
        XCTAssertLessThan(trimmedBytes * 2, page.rawBytes, "the host sends less than half of CEF's output")

        let decoded = try JSONDecoder().decode(BrowserAccessibilityTreeChange.self,
                                               from: JSONSerialization.data(withJSONObject: change))
        let nodes = decoded.updates.flatMap(\.nodes)
        XCTAssertFalse(nodes.contains { $0.role == "inlineTextBox" })
        XCTAssertTrue(nodes.filter { $0.role == "staticText" }.allSatisfy { $0.children == nil })
        XCTAssertEqual(decoded.updates.first?.treeData?.title, "Accessibility QA")

        let box = try XCTUnwrap(nodes.first { $0.name == "Positioned box" })
        XCTAssertEqual(box.role, "button")
        XCTAssertEqual(box.bounds, BrowserRect(x: 800, y: 240, width: 400, height: 80), "device pixels at scale 2")
        let select = try XCTUnwrap(nodes.first { $0.role == "comboBoxSelect" })
        XCTAssertEqual(select.hasPopup, "menu")
        XCTAssertEqual(select.value, "Apple")
        XCTAssertEqual(nodes.first { $0.role == "checkBox" }?.checked, "false")
        let email = try XCTUnwrap(nodes.first { $0.name == "Email" && $0.role == "textField" })
        XCTAssertEqual(email.placeholder, "you@example.com")
        XCTAssertEqual(email.inputType, "email")
        XCTAssertTrue(email.has("focusable") && email.has("editable"))
        XCTAssertEqual(nodes.first { $0.role == "heading" }?.level, 1)
        XCTAssertNotNil(nodes.first { $0.role == "iframe" }?.childTree)
    }

    func testRecordedPageBuildsTheExposedTree() throws {
        let tree = Self.tree(from: try Self.events(from: Self.recording()))
        XCTAssertEqual(tree.title, "Accessibility QA")
        let roles = tree.exposedNodes().compactMap { tree.node($0)?.role }
        for role in ["header", "navigation", "main", "heading", "link", "textField", "checkBox", "radioButton",
                     "comboBoxSelect", "button", "list", "listItem", "table", "row", "cell", "columnHeader", "image"] {
            XCTAssertTrue(roles.contains(role), "\(role) is exposed")
        }
        for role in ["genericContainer", "paragraph", "labelText", "inlineTextBox", "listMarker", "rootWebArea", "form"] {
            XCTAssertFalse(roles.contains(role), "\(role) is flattened or skipped")
        }
        // The iframe's tree came before the page's and is kept, lifted into the page.
        let inner = try XCTUnwrap(Self.find(tree, role: "button", label: "Inner button"))
        XCTAssertNotEqual(inner.tree, tree.mainTree)
        let select = try XCTUnwrap(Self.find(tree, role: "comboBoxSelect", label: "Fruit"))
        XCTAssertEqual(tree.options(of: select).compactMap { tree.node($0)?.name }, ["Apple", "Banana", "Cherry"])
        XCTAssertEqual(tree.exposedChildren(of: select), [], "options are offered by the select, not as children")
    }

    func testRecordedScrollMovesPageBounds() throws {
        let events = try Self.events(from: Self.recording())
        let tree = Self.tree(from: Array(events.prefix(2)))
        let box = try XCTUnwrap(Self.find(tree, role: "button", label: "Positioned box"))
        XCTAssertEqual(tree.pageBounds(of: box), BrowserRect(x: 800, y: 240, width: 400, height: 80))
        for event in events.dropFirst(2) {
            if case .accessibilityTree(_, let change) = event { tree.apply(change) }
        }
        // The last root update scrolled the page by 200 CSS px (400 device px).
        XCTAssertEqual(tree.pageBounds(of: box), BrowserRect(x: 800, y: -160, width: 400, height: 80))
        let iframeButton = try XCTUnwrap(Self.find(tree, role: "button", label: "Inner button"))
        let frameBounds = try XCTUnwrap(tree.pageBounds(of: iframeButton))
        XCTAssertGreaterThan(frameBounds.y, 1000, "the frame's content sits below the iframe's top")
    }
}

/// The macOS side: lazy enabling, NSAccessibility roles and values, screen frames, hit testing and
/// AXPress through the panel's mouse input.
@MainActor
final class BrowserAccessibilityBridgeTests: XCTestCase {
    private final class FakeConnection: BrowserHostConnection {
        var eventHandler: ((BrowserHostEvent) -> Void)?
        var sent: [BrowserHostCommand] = []
        func send(_ command: BrowserHostCommand) { sent.append(command) }
        func terminate() {}
    }

    private var connection = FakeConnection()
    private var window: NSWindow?
    private var client: BrowserHostClient?

    private func makeBridge() throws -> (BrowserAccessibilityBridge, BrowserHostView, BrowserTab) {
        let client = BrowserHostClient(idleGrace: .seconds(60)) { [unowned self] in
            self.connection
        }
        self.client = client
        let tab = try client.openTab(url: "about:blank", viewport: BrowserViewport(width: 1200, height: 3000, scale: 2))
        // Tall enough that every element of the recorded page is on screen (no scrolling needed).
        let view = BrowserHostView(frame: NSRect(x: 0, y: 0, width: 1200, height: 3000))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1200, height: 3000), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = view
        self.window = window
        let bridge = BrowserAccessibilityBridge(tab: tab, view: view)
        view.accessibilitySource = bridge
        return (bridge, view, tab)
    }

    private var accessibilityCommands: [Bool] {
        connection.sent.compactMap { if case .accessibility(_, let enabled) = $0 { enabled } else { nil } }
    }

    func testTreeTurnsOnAtTheFirstQueryAndOffWhenStopped() throws {
        let (bridge, view, _) = try makeBridge()
        bridge.start()
        XCTAssertTrue(accessibilityCommands.isEmpty || NSWorkspace.shared.isVoiceOverEnabled,
                      "nothing asked yet, so the page does no accessibility work")
        _ = view.accessibilityChildren()
        XCTAssertEqual(accessibilityCommands.last, true)
        XCTAssertTrue(bridge.isEnabled)
        bridge.stop()
        XCTAssertEqual(accessibilityCommands.last, false)
        XCTAssertTrue(bridge.tree.isEmpty)
    }

    func testRecordedPageBecomesNSAccessibilityElements() throws {
        let (bridge, view, _) = try makeBridge()
        _ = view.accessibilityChildren()
        for event in try BrowserAccessibilityRecordingTests.events(from: BrowserAccessibilityRecordingTests.recording()).prefix(2) {
            bridge.handle(event)
        }
        XCTAssertEqual(view.accessibilityLabel(), "Accessibility QA")
        let tree = bridge.tree
        func element(_ role: String, _ label: String) throws -> BrowserAccessibilityElement {
            bridge.element(for: try XCTUnwrap(BrowserAccessibilityRecordingTests.find(tree, role: role, label: label), "\(role) \(label)"))
        }

        let heading = try element("heading", "Accessibility QA")
        XCTAssertEqual(heading.accessibilityRole()?.rawValue, "AXHeading")
        XCTAssertEqual(heading.accessibilityValue() as? Int, 1)
        XCTAssertEqual(heading.accessibilityRoleDescription(), L10n.string("heading"))
        let email = try element("textField", "Email")
        XCTAssertEqual(email.accessibilityRole(), .textField)
        XCTAssertEqual(email.accessibilityPlaceholderValue(), "you@example.com")
        XCTAssertEqual(email.accessibilityValue() as? String, "")
        XCTAssertEqual(try element("textField", "Notes").accessibilityRole(), .textArea)
        XCTAssertEqual(try element("checkBox", "I agree").accessibilityValue() as? Int, 0)
        XCTAssertEqual(try element("radioButton", "Small").accessibilityValue() as? Int, 1)
        let fruit = try element("comboBoxSelect", "Fruit")
        XCTAssertEqual(fruit.accessibilityRole(), .popUpButton)
        XCTAssertEqual(fruit.accessibilityValue() as? String, "Apple")
        XCTAssertEqual(try element("link", "Second page").accessibilityRole(), .link)
        XCTAssertEqual(try element("image", "Yardlet logo").accessibilityRole(), .image)
        let navigation = try element("navigation", "Primary")
        XCTAssertEqual(navigation.accessibilitySubrole()?.rawValue, "AXLandmarkNavigation")
        let table = try element("table", "Scores")
        XCTAssertEqual(table.accessibilityRole(), .table)
        XCTAssertEqual(table.accessibilityRows()?.count, 3)
        XCTAssertTrue(heading.accessibilityParent() as AnyObject === bridge.element(for: tree.exposedParent(of: heading.key)!),
                      "a heading inside main has the main landmark as its parent")

        // Frames: page device pixels ÷ the view's scale, placed in the window, on screen.
        let box = try element("button", "Positioned box")
        let window = try XCTUnwrap(view.window)
        let scale = view.viewport.scale
        let expected = window.convertToScreen(view.convert(NSRect(x: 800 / scale, y: 240 / scale, width: 400 / scale,
                                                                  height: 80 / scale), to: nil))
        XCTAssertEqual(box.accessibilityFrame(), expected)
        let hit = view.accessibilityHitTest(NSPoint(x: expected.midX, y: expected.midY)) as? BrowserAccessibilityElement
        XCTAssertEqual(hit?.key, box.key)
    }

    func testPressClicksTheElementCenterWithThePanelsMouse() async throws {
        let (bridge, view, tab) = try makeBridge()
        _ = view.accessibilityChildren()
        for event in try BrowserAccessibilityRecordingTests.events(from: BrowserAccessibilityRecordingTests.recording()).prefix(2) {
            bridge.handle(event)
        }
        let press = bridge.element(for: try XCTUnwrap(BrowserAccessibilityRecordingTests.find(bridge.tree, role: "button", label: "Press me")))
        XCTAssertTrue(press.accessibilityPerformPress())
        for _ in 0..<50 where connection.sent.filter({ if case .mouse = $0 { true } else { false } }).count < 3 {
            try await Task.sleep(for: .milliseconds(10))
        }
        let mouse = connection.sent.compactMap { if case .mouse(let id, let input) = $0, id == tab.id { input } else { nil } }
        XCTAssertEqual(mouse.map(\.kind), [.move, .down, .up])
        guard mouse.count == 3 else { return }
        let scale = view.viewport.scale
        let center = NSPoint(x: (48 + 144.59375 / 2) / scale, y: (821.765625 + 43 / 2) / scale)
        XCTAssertEqual(mouse.last?.x ?? 0, center.x, accuracy: 0.01)
        XCTAssertEqual(mouse.last?.y ?? 0, center.y, accuracy: 0.01)
        XCTAssertEqual(mouse[1].button, .left)
    }
}
