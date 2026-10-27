import Foundation

/// A node's identity across a page's frame trees (each frame document has its own tree).
struct BrowserAccessibilityKey: Hashable, Sendable {
    var tree: String
    var id: Int
}

/// What applying a change did, so a platform layer can post the right notifications.
struct BrowserAccessibilityChangeSummary: Equatable, Sendable {
    /// Nodes appeared or went away, children changed, or the page's main tree changed.
    var structureChanged = false
    var added: Set<BrowserAccessibilityKey> = []
    var removed: Set<BrowserAccessibilityKey> = []
    /// Existing nodes whose value, checked, selected or range value changed.
    var valueChanged: Set<BrowserAccessibilityKey> = []
    var nameChanged: Set<BrowserAccessibilityKey> = []
    var moved: Set<BrowserAccessibilityKey> = []
    var focusChanged = false
    var loadCompleted = false
    /// A new main document replaced the previous one.
    var documentChanged = false
}

/// The page's accessibility tree built from a host's `accessibilityTree` and
/// `accessibilityLocations` events, following Chromium's update rules. It also decides which nodes
/// a platform exposes: containers without meaning (generic `div`s, paragraphs, ignored nodes) are
/// flattened into their parent, hidden subtrees are skipped, and controls whose content is only
/// their label (buttons, check boxes, text fields) or only text (links, headings) are leaves.
/// Engine code: platform layers turn exposed nodes into their own accessibility objects.
final class BrowserAccessibilityTree {
    typealias Key = BrowserAccessibilityKey
    typealias Node = BrowserAccessibilityNode

    private struct FrameTree {
        var root: Int?
        var parent: String?
        var focus: Int?
        var focusedTree: String?
        var title: String?
        var url: String?
        var nodes: [Int: Node] = [:]
    }

    private var trees: [String: FrameTree] = [:]
    /// Child tree → the node hosting it (an iframe) in its parent tree.
    private var hosts: [String: Key] = [:]
    private var parents: [Key: Key] = [:]
    /// Trees dropped as stale; a frame whose parent is among them goes too. A frame whose parent
    /// has not arrived yet stays (Chromium may send an iframe's tree before the page's).
    private var droppedTrees: Set<String> = []
    /// The page's scroll offset in page pixels, newer than the root node's own scroll values
    /// (Chromium does not re-send the root for plain scrolling). Cleared when the root is re-sent.
    private(set) var mainScroll: (x: Double, y: Double)?
    private(set) var mainTree: String?

    var isEmpty: Bool { root == nil }
    var nodeCount: Int { trees.values.reduce(0) { $0 + $1.nodes.count } }
    var title: String? { mainTree.flatMap { trees[$0]?.title } }
    var url: String? { mainTree.flatMap { trees[$0]?.url } }

    var root: Key? {
        guard let mainTree, let root = trees[mainTree]?.root, trees[mainTree]?.nodes[root] != nil else { return nil }
        return Key(tree: mainTree, id: root)
    }

    /// The focused node: the main tree names the focused frame tree, which names its node.
    var focus: Key? {
        guard let mainTree, let main = trees[mainTree] else { return nil }
        let tree = main.focusedTree ?? mainTree
        guard let id = trees[tree]?.focus, trees[tree]?.nodes[id] != nil else { return nil }
        return Key(tree: tree, id: id)
    }

    func node(_ key: Key) -> Node? { trees[key.tree]?.nodes[key.id] }

    func reset() {
        trees = [:]
        hosts = [:]
        parents = [:]
        droppedTrees = []
        mainScroll = nil
        mainTree = nil
    }

    // MARK: Applying changes

    @discardableResult
    func apply(_ change: BrowserAccessibilityTreeChange) -> BrowserAccessibilityChangeSummary {
        var summary = BrowserAccessibilityChangeSummary()
        let treeID = change.tree
        var frame = trees[treeID] ?? FrameTree()
        let focusBefore = focus
        var touched = false
        for update in change.updates {
            if let clear = update.clear, var cleared = frame.nodes[clear] {
                for descendant in descendants(of: clear, in: frame) {
                    frame.nodes[descendant] = nil
                    summary.removed.insert(Key(tree: treeID, id: descendant))
                }
                cleared.children = nil
                frame.nodes[clear] = cleared
                touched = true
            }
            if let data = update.treeData {
                frame.parent = data.parent
                frame.focus = data.focus
                frame.focusedTree = data.focusedTree
                frame.title = data.title
                frame.url = data.url
                if data.parent == nil, mainTree != treeID {
                    summary.documentChanged = mainTree != nil
                    mainTree = treeID
                    mainScroll = nil
                    touched = true
                }
            }
            if let root = update.root, frame.root != root {
                frame.root = root
                touched = true
            }
            for node in update.nodes {
                let key = Key(tree: treeID, id: node.id)
                if treeID == mainTree, node.id == frame.root, node.role == "rootWebArea" { mainScroll = nil }
                if let old = frame.nodes[node.id] {
                    if old.children != node.children || old.childTree != node.childTree || old.role != node.role
                        || old.has("invisible") != node.has("invisible") || old.has("ignored") != node.has("ignored") {
                        touched = true
                    }
                    if old.value != node.value || old.checked != node.checked || old.selected != node.selected
                        || old.rangeValue != node.rangeValue {
                        summary.valueChanged.insert(key)
                    }
                    if old.name != node.name { summary.nameChanged.insert(key) }
                    if old.bounds != node.bounds || old.scrollX != node.scrollX || old.scrollY != node.scrollY {
                        summary.moved.insert(key)
                    }
                    if let oldChild = old.childTree, oldChild != node.childTree, hosts[oldChild] == key {
                        hosts[oldChild] = nil
                    }
                } else {
                    summary.added.insert(key)
                    summary.removed.remove(key)
                    touched = true
                }
                if let childTree = node.childTree { hosts[childTree] = key }
                frame.nodes[node.id] = node
            }
        }
        // Without tree data yet, the first tree seen is taken as the main one.
        if mainTree == nil, frame.parent == nil, frame.root != nil { mainTree = treeID }
        trees[treeID] = frame
        if touched {
            summary.structureChanged = true
            sweep(treeID, into: &summary)
            dropStaleTrees(into: &summary)
        }
        for event in change.events ?? [] {
            if event.type == "loadComplete" { summary.loadCompleted = true }
            if event.type == "focus" || event.type == "blur" { summary.focusChanged = true }
        }
        if focus != focusBefore { summary.focusChanged = true }
        summary.valueChanged.subtract(summary.added)
        summary.nameChanged.subtract(summary.added)
        return summary
    }

    /// The page scrolled (page pixels).
    func setMainScroll(x: Double, y: Double) {
        mainScroll = (x, y)
    }

    @discardableResult
    func apply(_ locations: [BrowserAccessibilityLocation]) -> Set<Key> {
        var moved: Set<Key> = []
        for location in locations {
            guard var node = trees[location.tree]?.nodes[location.id] else { continue }
            node.bounds = location.bounds
            node.container = location.container
            trees[location.tree]?.nodes[location.id] = node
            moved.insert(Key(tree: location.tree, id: location.id))
        }
        return moved
    }

    private func descendants(of id: Int, in frame: FrameTree) -> [Int] {
        var result: [Int] = []
        var stack = frame.nodes[id]?.children ?? []
        var seen: Set<Int> = [id]
        while let next = stack.popLast() {
            guard seen.insert(next).inserted else { continue }
            result.append(next)
            stack += frame.nodes[next]?.children ?? []
        }
        return result
    }

    /// Removes nodes of `treeID` no longer reachable from its root and rebuilds their parents.
    private func sweep(_ treeID: String, into summary: inout BrowserAccessibilityChangeSummary) {
        guard var frame = trees[treeID] else { return }
        parents = parents.filter { $0.key.tree != treeID }
        var reachable: Set<Int> = []
        if let root = frame.root, frame.nodes[root] != nil {
            var stack = [root]
            reachable.insert(root)
            while let id = stack.popLast() {
                for child in frame.nodes[id]?.children ?? [] where frame.nodes[child] != nil {
                    guard reachable.insert(child).inserted else { continue }
                    parents[Key(tree: treeID, id: child)] = Key(tree: treeID, id: id)
                    stack.append(child)
                }
            }
        }
        for id in frame.nodes.keys where !reachable.contains(id) {
            let key = Key(tree: treeID, id: id)
            if let childTree = frame.nodes[id]?.childTree, hosts[childTree] == key { hosts[childTree] = nil }
            frame.nodes[id] = nil
            summary.removed.insert(key)
            summary.added.remove(key)
        }
        trees[treeID] = frame
    }

    /// Drops old main documents and frames whose parent tree was dropped.
    private func dropStaleTrees(into summary: inout BrowserAccessibilityChangeSummary) {
        var changed = true
        while changed {
            changed = false
            for (treeID, frame) in trees where treeID != mainTree {
                let orphaned = frame.parent.map { droppedTrees.contains($0) } ?? (mainTree != nil)
                guard orphaned else { continue }
                droppedTrees.insert(treeID)
                for id in frame.nodes.keys { summary.removed.insert(Key(tree: treeID, id: id)) }
                trees[treeID] = nil
                hosts[treeID] = nil
                parents = parents.filter { $0.key.tree != treeID }
                changed = true
            }
        }
    }

    // MARK: Structure a platform exposes

    /// Roles flattened into their parent unless they carry a name or can take focus.
    static let flattenedRoles: Set<String> = [
        "none", "genericContainer", "paragraph", "labelText", "abbr", "time", "mark", "strong", "emphasis",
        "subscript", "superscript", "code", "ruby", "rubyAnnotation", "section", "group", "iframe",
        "iframePresentational", "rootWebArea", "rowGroup", "unknown", "div", "span", "blockquote", "pre",
        "contentDeletion", "contentInsertion", "legend", "caption", "form", "sectionHeader", "sectionFooter"
    ]

    /// Roles never exposed, with their subtrees.
    static let skippedRoles: Set<String> = ["listMarker", "lineBreak", "caret", "inlineTextBox", "menuListPopup"]

    /// Roles whose content is only their label or value; their children are not exposed.
    static let leafRoles: Set<String> = [
        "button", "toggleButton", "checkBox", "radioButton", "switch", "image", "meter", "progressIndicator",
        "scrollBar", "slider", "splitter", "tab", "menuItemCheckBox", "menuItemRadio", "menuListOption",
        "listBoxOption", "textField", "searchBox", "textFieldWithComboBox", "spinButton", "comboBoxSelect",
        "popUpButton", "comboBoxMenuButton", "colorWell", "date", "dateTime", "inputTime", "staticText",
        "math", "svgRoot", "canvas"
    ]

    /// Roles whose children are dropped when they are only text (the text is the label).
    static let textCollapsingRoles: Set<String> = [
        "link", "heading", "listItem", "cell", "gridCell", "columnHeader", "rowHeader", "menuItem", "term",
        "definition", "label", "status", "alert", "tooltip", "treeItem", "listBoxOption"
    ]

    func isHidden(_ node: Node) -> Bool {
        node.has("invisible") || Self.skippedRoles.contains(node.role)
    }

    func isExposed(_ node: Node) -> Bool {
        if node.has("ignored") { return false }
        guard Self.flattenedRoles.contains(node.role) else { return true }
        // A frame's document is always lifted into the page around it.
        if node.role == "rootWebArea" || node.role.hasPrefix("iframe") { return false }
        return !(node.name ?? "").isEmpty || node.has("focusable")
    }

    /// Children in document order, including a hosted frame's root.
    func childKeys(of key: Key) -> [Key] {
        guard let node = node(key) else { return [] }
        var keys = (node.children ?? []).map { Key(tree: key.tree, id: $0) }
        if let childTree = node.childTree, let root = trees[childTree]?.root, trees[childTree]?.nodes[root] != nil {
            keys.append(Key(tree: childTree, id: root))
        }
        return keys
    }

    /// The exposed children of `key` (the page's root when nil), with flattened containers'
    /// children lifted into place.
    func exposedChildren(of key: Key?) -> [Key] {
        guard let key = key ?? root, let node = node(key) else { return [] }
        if key != root, Self.leafRoles.contains(node.role) || isRichTextField(node) { return [] }
        var result: [Key] = []
        appendExposed(childKeys(of: key), into: &result, depth: 0)
        if Self.textCollapsingRoles.contains(node.role),
           result.allSatisfy({ self.node($0)?.role == "staticText" }) {
            return []
        }
        return result
    }

    private func appendExposed(_ keys: [Key], into result: inout [Key], depth: Int) {
        guard depth < 256 else { return }
        for key in keys {
            guard let node = node(key), !isHidden(node) else { continue }
            if isExposed(node) {
                result.append(key)
            } else {
                appendExposed(childKeys(of: key), into: &result, depth: depth + 1)
            }
        }
    }

    /// The nearest exposed ancestor; nil when that is the page itself.
    func exposedParent(of key: Key) -> Key? {
        var current = key
        var steps = 0
        while let parent = parent(of: current), steps < 1024 {
            if parent == root { return nil }
            if let node = node(parent), isExposed(node) { return parent }
            current = parent
            steps += 1
        }
        return nil
    }

    func parent(of key: Key) -> Key? {
        if let parent = parents[key] { return parent }
        if let root = trees[key.tree]?.root, root == key.id { return hosts[key.tree] }
        return nil
    }

    /// Whether `key` and all its ancestors are shown (a node under a hidden subtree is not).
    func isShown(_ key: Key) -> Bool {
        var current: Key? = key
        var steps = 0
        while let key = current, steps < 1024 {
            guard let node = node(key) else { return false }
            if isHidden(node) { return false }
            current = parent(of: key)
            steps += 1
        }
        return true
    }

    /// A contenteditable region: a text field whose content is the page's own nodes.
    func isRichTextField(_ node: Node) -> Bool {
        node.has("richlyEditable") && (node.role == "textField" || node.role == "textFieldWithComboBox"
            || node.role == "searchBox" || node.has("editable") && node.role == "genericContainer")
    }

    /// The text of a node's subtree (static text in document order), up to `limit` characters.
    func text(of key: Key, limit: Int = 2000) -> String {
        var parts: [String] = []
        var length = 0
        func visit(_ key: Key, depth: Int) {
            guard length < limit, depth < 256, let node = node(key), !isHidden(node) else { return }
            if node.role == "staticText" {
                let text = node.name ?? ""
                parts.append(text)
                length += text.count
                return
            }
            for child in childKeys(of: key) { visit(child, depth: depth + 1) }
        }
        visit(key, depth: 0)
        return String(parts.joined().prefix(limit))
    }

    /// The label a platform shows: the node's name, else the text of a text-only node.
    func label(of key: Key) -> String? {
        guard let node = node(key) else { return nil }
        if let name = node.name, !name.isEmpty { return name }
        if Self.textCollapsingRoles.contains(node.role), exposedChildren(of: key).isEmpty {
            let text = self.text(of: key).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
        return nil
    }

    /// Options of a `<select>` (its popup's `menuListOption`s), in order.
    func options(of key: Key) -> [Key] {
        var result: [Key] = []
        func visit(_ key: Key, depth: Int) {
            guard depth < 8 else { return }
            for child in childKeys(of: key) {
                guard let node = node(child) else { continue }
                if node.role == "menuListOption" || node.role == "listBoxOption" { result.append(child) }
                else { visit(child, depth: depth + 1) }
            }
        }
        visit(key, depth: 0)
        return result
    }

    // MARK: Geometry

    /// Bounds in page pixels relative to the main frame's viewport, following Chromium's rule: add
    /// each offset container's bounds and take off its scroll offset, up to the frame's root, then
    /// continue from the iframe hosting the frame.
    func pageBounds(of key: Key) -> BrowserRect? {
        pageBounds(of: key, depth: 0)
    }

    private func pageBounds(of key: Key, depth: Int) -> BrowserRect? {
        guard depth < 16, let start = node(key), var rect = start.bounds, let frame = trees[key.tree] else {
            return nil
        }
        var node = start
        var steps = 0
        while steps < 1024 {
            steps += 1
            let containerID = node.container ?? (node.id == frame.root ? nil : frame.root)
            guard let containerID, containerID != node.id, let container = frame.nodes[containerID] else { break }
            if let bounds = container.bounds {
                rect.x += bounds.x
                rect.y += bounds.y
            }
            if key.tree == mainTree, containerID == frame.root, let mainScroll {
                rect.x -= mainScroll.x
                rect.y -= mainScroll.y
            } else {
                rect.x -= container.scrollX ?? 0
                rect.y -= container.scrollY ?? 0
            }
            node = container
        }
        if let host = hosts[key.tree], let hostBounds = pageBounds(of: host, depth: depth + 1) {
            rect.x += hostBounds.x
            rect.y += hostBounds.y
        }
        return rect
    }

    /// The smallest exposed node whose bounds contain a page point (the later one on ties).
    /// Every node is checked: positioned content often lies outside its parent's bounds.
    func exposedNode(at point: (x: Double, y: Double)) -> Key? {
        var found: (key: Key, area: Double)?
        for key in exposedNodes() {
            guard let bounds = pageBounds(of: key), point.x >= bounds.x, point.x < bounds.x + bounds.width,
                  point.y >= bounds.y, point.y < bounds.y + bounds.height else { continue }
            let area = bounds.width * bounds.height
            if found.map({ area <= $0.area }) ?? true { found = (key, area) }
        }
        return found?.key
    }

    /// Every exposed node in document order (for dumps and counts).
    func exposedNodes(limit: Int = .max) -> [Key] {
        var result: [Key] = []
        func visit(_ keys: [Key], depth: Int) {
            for key in keys where result.count < limit && depth < 256 {
                result.append(key)
                visit(exposedChildren(of: key), depth: depth + 1)
            }
        }
        visit(exposedChildren(of: nil), depth: 0)
        return result
    }
}
