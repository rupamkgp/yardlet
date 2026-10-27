import XCTest
@testable import NativeHarnessClient

/// The engine's accessibility tree on hand-made Chromium updates: delta rules, flattening, focus
/// and geometry. Recorded CEF output is covered by BrowserAccessibilityRecordingTests.
final class BrowserAccessibilityTreeTests: XCTestCase {
    typealias Node = BrowserAccessibilityNode
    typealias Key = BrowserAccessibilityKey

    private func node(_ id: Int, _ role: String, name: String? = nil, children: [Int]? = nil,
                      bounds: (Double, Double, Double, Double)? = nil, container: Int? = nil,
                      states: [String]? = nil) -> Node {
        var node = Node(id: id, role: role)
        node.name = name
        node.children = children
        node.bounds = bounds.map { BrowserRect(x: $0.0, y: $0.1, width: $0.2, height: $0.3) }
        node.container = container
        node.states = states
        return node
    }

    private func change(tree: String = "main", root: Int? = nil, clear: Int? = nil, parent: String? = nil,
                        focus: Int? = nil, title: String? = nil, _ nodes: [Node]) -> BrowserAccessibilityTreeChange {
        let data = root == nil && focus == nil && title == nil && parent == nil
            ? nil : BrowserAccessibilityTreeData(parent: parent, focus: focus, title: title)
        return BrowserAccessibilityTreeChange(tree: tree, updates: [
            BrowserAccessibilityUpdate(root: root, clear: clear, treeData: data, nodes: nodes)
        ])
    }

    /// root → [generic div → [heading → text, paragraph → [text, link → text]], button]
    private func page() -> BrowserAccessibilityTree {
        let tree = BrowserAccessibilityTree()
        tree.apply(change(root: 1, focus: 1, title: "Page", [
            node(1, "rootWebArea", name: "Page", children: [2, 7], bounds: (0, 0, 1600, 1200)),
            node(2, "genericContainer", children: [3, 5]),
            node(3, "heading", children: [4]),
            node(4, "staticText", name: "Welcome"),
            node(5, "paragraph", children: [6, 8]),
            node(6, "staticText", name: "Read the "),
            node(8, "link", name: "guide", children: [9]),
            node(9, "staticText", name: "guide"),
            node(7, "button", name: "Go", children: [10], bounds: (200, 400, 160, 60)),
            node(10, "staticText", name: "Go")
        ]))
        return tree
    }

    private func key(_ id: Int, _ tree: String = "main") -> Key { Key(tree: tree, id: id) }

    func testMeaninglessContainersFlattenAndLabelledLeavesKeepOnlyTheirLabel() {
        let tree = page()
        XCTAssertEqual(tree.exposedChildren(of: nil), [key(3), key(6), key(8), key(7)])
        XCTAssertEqual(tree.exposedChildren(of: key(3)), [], "a heading of plain text is a leaf")
        XCTAssertEqual(tree.label(of: key(3)), "Welcome", "its text becomes its label")
        XCTAssertEqual(tree.exposedChildren(of: key(7)), [], "a button's content is its label")
        XCTAssertEqual(tree.exposedParent(of: key(8)), nil, "a flattened parent means the page")
        XCTAssertEqual(tree.title, "Page")
    }

    func testChildrenChangesRemoveUnreachableNodesAndReportThem() {
        let tree = page()
        var button = node(7, "button", name: "Go", children: [10], bounds: (200, 400, 160, 60))
        button.name = "Go now"
        let summary = tree.apply(change([
            node(1, "rootWebArea", name: "Page", children: [7], bounds: (0, 0, 1600, 1200)), button
        ]))
        XCTAssertTrue(summary.structureChanged)
        XCTAssertEqual(summary.removed, Set([2, 3, 4, 5, 6, 8, 9].map { key($0) }))
        XCTAssertEqual(summary.nameChanged, [key(7)])
        XCTAssertNil(tree.node(key(4)))
        XCTAssertEqual(tree.exposedChildren(of: nil), [key(7)])
    }

    func testClearingANodeDropsItsDescendantsBeforeTheNewOnesArrive() {
        let tree = page()
        let summary = tree.apply(change(clear: 5, [
            node(5, "paragraph", children: [20]), node(20, "staticText", name: "Replaced")
        ]))
        XCTAssertTrue(summary.removed.isSuperset(of: [key(6), key(8), key(9)]))
        XCTAssertEqual(summary.added, [key(20)])
        XCTAssertEqual(tree.exposedChildren(of: nil), [key(3), key(20), key(7)])
    }

    func testValueCheckedAndFocusChangesAreReported() {
        let tree = BrowserAccessibilityTree()
        var field = node(2, "textField", name: "Email")
        var box = node(3, "checkBox", name: "Agree")
        box.checked = "false"
        tree.apply(change(root: 1, focus: 1, [node(1, "rootWebArea", children: [2, 3]), field, box]))
        field.value = "a@b.c"
        box.checked = "true"
        let summary = tree.apply(change(root: 1, focus: 2, [field, box]))
        XCTAssertEqual(summary.valueChanged, [key(2), key(3)])
        XCTAssertFalse(summary.structureChanged, "values alone do not change structure")
        XCTAssertTrue(summary.focusChanged)
        XCTAssertEqual(tree.focus, key(2))
    }

    func testANewMainDocumentReplacesTheOldTree() {
        let tree = page()
        let summary = tree.apply(change(tree: "next", root: 1, title: "Next", [node(1, "rootWebArea", children: [2]),
                                                                          node(2, "button", name: "Continue")]))
        XCTAssertTrue(summary.documentChanged)
        XCTAssertEqual(tree.mainTree, "next")
        XCTAssertNil(tree.node(key(7)), "the previous document's nodes are gone")
        XCTAssertTrue(summary.removed.contains(key(7)))
        XCTAssertEqual(tree.exposedChildren(of: nil), [key(2, "next")])
    }

    func testHiddenSubtreesAndIgnoredNodesAreNotExposed() {
        let tree = BrowserAccessibilityTree()
        tree.apply(change(root: 1, [
            node(1, "rootWebArea", children: [2, 4, 6]),
            node(2, "genericContainer", children: [3], states: ["invisible"]),
            node(3, "button", name: "Hidden"),
            node(4, "genericContainer", children: [5], states: ["ignored"]),
            node(5, "button", name: "Shown"),
            node(6, "listMarker", name: "•")
        ]))
        XCTAssertEqual(tree.exposedChildren(of: nil), [key(5)])
        XCTAssertFalse(tree.isShown(key(3)))
    }

    func testBoundsFollowOffsetContainersScrollAndFrames() {
        let tree = BrowserAccessibilityTree()
        var root = node(1, "rootWebArea", children: [2, 4], bounds: (0, 0, 1600, 1200))
        root.scrollY = 400
        var scroller = node(2, "genericContainer", children: [3], bounds: (100, 600, 800, 400))
        scroller.scrollX = 50
        var iframe = node(4, "iframe", bounds: (0, 1000, 600, 300))
        iframe.childTree = "frame"
        tree.apply(change(root: 1, [root, scroller, node(3, "button", name: "Inner", bounds: (10, 20, 100, 40), container: 2), iframe]))
        tree.apply(change(tree: "frame", root: 1, parent: "main", [
            node(1, "rootWebArea", children: [2], bounds: (0, 0, 600, 300)),
            node(2, "button", name: "Framed", bounds: (20, 30, 120, 50))
        ]))

        // Inside the scroller: its origin (100, 600) minus the page scroll (0, 400), minus its own scroll (50, 0).
        XCTAssertEqual(tree.pageBounds(of: key(3)), BrowserRect(x: 60, y: 220, width: 100, height: 40))
        // The iframe's document continues from the iframe's own position (0, 1000 − 400).
        XCTAssertEqual(tree.pageBounds(of: key(2, "frame")), BrowserRect(x: 20, y: 630, width: 120, height: 50))
        XCTAssertEqual(tree.exposedChildren(of: nil), [key(3), key(2, "frame")], "frames are lifted into the page")
        XCTAssertEqual(tree.exposedNode(at: (30, 640)), key(2, "frame"))

        // A location change moves one node without a tree update.
        tree.apply([BrowserAccessibilityLocation(tree: "main", id: 3, container: 2,
                                                 bounds: BrowserRect(x: 10, y: 120, width: 100, height: 40))])
        XCTAssertEqual(tree.pageBounds(of: key(3))?.y, 320)
    }

    func testPageScrollOverridesTheRootsOwnScrollUntilTheRootIsSentAgain() {
        let tree = BrowserAccessibilityTree()
        var root = node(1, "rootWebArea", children: [2], bounds: (0, 0, 1600, 1200))
        root.scrollY = 400
        tree.apply(change(root: 1, [root, node(2, "button", name: "Go", bounds: (0, 1000, 100, 40))]))
        XCTAssertEqual(tree.pageBounds(of: key(2))?.y, 600)
        // Chromium does not re-send the root for plain scrolling; the host's scroll offset wins.
        tree.setMainScroll(x: 0, y: 900)
        XCTAssertEqual(tree.pageBounds(of: key(2))?.y, 100)
        root.scrollY = 200
        tree.apply(change([root]))
        XCTAssertEqual(tree.pageBounds(of: key(2))?.y, 800, "a re-sent root is newer than the last offset")
    }

    func testSelectOptionsAreFoundUnderTheHiddenPopup() {
        let tree = BrowserAccessibilityTree()
        var first = node(4, "menuListOption", name: "Apple")
        first.selected = true
        tree.apply(change(root: 1, [
            node(1, "rootWebArea", children: [2]),
            node(2, "comboBoxSelect", name: "Fruit", children: [3]),
            node(3, "menuListPopup", children: [4, 5], states: ["invisible"]),
            first, node(5, "menuListOption", name: "Banana")
        ]))
        XCTAssertEqual(tree.exposedChildren(of: nil), [key(2)])
        XCTAssertEqual(tree.exposedChildren(of: key(2)), [])
        XCTAssertEqual(tree.options(of: key(2)), [key(4), key(5)])
    }
}
