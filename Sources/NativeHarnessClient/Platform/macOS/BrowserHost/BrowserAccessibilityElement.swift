import AppKit

/// Chromium role names → macOS accessibility roles, following Chrome's own Mac mapping
/// (`browser_accessibility_cocoa.mm`) where AppKit has the role.
enum BrowserAccessibilityRoles {
    static let heading = NSAccessibility.Role(rawValue: "AXHeading")

    static func isSelect(_ node: BrowserAccessibilityNode) -> Bool {
        ["comboBoxSelect", "popUpButton", "comboBoxMenuButton"].contains(node.role)
    }

    static func isTextInput(_ node: BrowserAccessibilityNode) -> Bool {
        ["textField", "searchBox", "textFieldWithComboBox"].contains(node.role)
            || node.has("richlyEditable") && node.has("editable")
    }

    static func role(for node: BrowserAccessibilityNode) -> NSAccessibility.Role {
        switch node.role {
        case "button": node.hasPopup == "menu" ? .menuButton : .button
        case "toggleButton", "checkBox", "switch": .checkBox
        case "link": .link
        case "radioButton", "tab": .radioButton
        case "radioGroup": .radioGroup
        case "textField":
            node.has("multiline") || node.has("richlyEditable") ? .textArea : .textField
        case "searchBox", "date", "dateTime", "inputTime": .textField
        case "textFieldWithComboBox": .comboBox
        case "comboBoxSelect", "popUpButton", "comboBoxMenuButton": .popUpButton
        case "heading": heading
        case "staticText", "listBoxOption", "term", "definition": .staticText
        case "image", "svgRoot", "canvas", "math": .image
        case "list", "directory", "descriptionList", "listBox": .list
        case "table", "grid", "treeGrid": .table
        case "row", "treeItem": .row
        case "cell", "gridCell", "columnHeader", "rowHeader": .cell
        case "column": .column
        case "slider": .slider
        case "spinButton": .incrementor
        case "progressIndicator": .progressIndicator
        case "meter": .levelIndicator
        case "scrollBar": .scrollBar
        case "splitter": .splitter
        case "tabList": .tabGroup
        case "menu", "menuListPopup": .menu
        case "menuBar": .menuBar
        case "menuItem", "menuItemCheckBox", "menuItemRadio", "menuListOption": .menuItem
        case "toolbar": .toolbar
        case "tree": .outline
        case "colorWell": .colorWell
        default: .group
        }
    }

    static func subrole(for node: BrowserAccessibilityNode) -> NSAccessibility.Subrole? {
        switch node.role {
        case "textField": node.has("protected") || node.inputType == "password" ? .secureTextField : nil
        case "searchBox": .searchField
        case "switch": .switch
        case "toggleButton": .toggle
        case "tab": NSAccessibility.Subrole(rawValue: "AXTabButton")
        case "treeItem": .outlineRow
        case "dialog", "alertDialog": .dialog
        case "banner", "header": NSAccessibility.Subrole(rawValue: "AXLandmarkBanner")
        case "navigation": NSAccessibility.Subrole(rawValue: "AXLandmarkNavigation")
        case "main": NSAccessibility.Subrole(rawValue: "AXLandmarkMain")
        case "contentInfo", "footer": NSAccessibility.Subrole(rawValue: "AXLandmarkContentInfo")
        case "complementary": NSAccessibility.Subrole(rawValue: "AXLandmarkComplementary")
        case "search": NSAccessibility.Subrole(rawValue: "AXLandmarkSearch")
        case "region": NSAccessibility.Subrole(rawValue: "AXLandmarkRegion")
        case "article": NSAccessibility.Subrole(rawValue: "AXDocumentArticle")
        case "alert": NSAccessibility.Subrole(rawValue: "AXApplicationAlert")
        case "status": NSAccessibility.Subrole(rawValue: "AXApplicationStatus")
        default: nil
        }
    }

    /// Spoken role names for roles AppKit does not describe itself; nil uses AppKit's.
    static func roleDescription(for node: BrowserAccessibilityNode) -> String? {
        if let custom = node.roleDescription, !custom.isEmpty { return custom }
        switch node.role {
        case "heading": return L10n.string("heading")
        case "banner", "header": return L10n.string("banner")
        case "navigation": return L10n.string("navigation")
        case "main": return L10n.string("main")
        case "contentInfo", "footer": return L10n.string("footer")
        case "complementary": return L10n.string("complementary")
        case "search": return L10n.string("search")
        case "region": return L10n.string("region")
        case "form": return L10n.string("form")
        case "article": return L10n.string("article")
        case "alert": return L10n.string("alert")
        case "dialog", "alertDialog": return L10n.string("dialog")
        default: return nil
        }
    }
}

/// One exposed node of a browser panel's page. It keeps only its key; everything it reports is
/// read from the bridge's tree when asked, so it stays right as the page changes. AppKit calls
/// accessibility on the main thread, so each method runs on the main actor.
final class BrowserAccessibilityElement: NSAccessibilityElement {
    let key: BrowserAccessibilityKey
    private weak var bridge: BrowserAccessibilityBridge?

    static let scrollToVisible = NSAccessibility.Action(rawValue: "AXScrollToVisible")

    @MainActor
    init(key: BrowserAccessibilityKey, bridge: BrowserAccessibilityBridge) {
        self.key = key
        self.bridge = bridge
        super.init()
    }

    /// Runs `body` with the bridge, its tree and this element's node on the main actor.
    private func read<T>(
        _ fallback: T,
        _ body: @escaping @MainActor @Sendable (BrowserAccessibilityBridge, BrowserAccessibilityNode, BrowserAccessibilityKey) -> T
    ) -> T {
        let key = key
        let bridge = bridge
        nonisolated(unsafe) var result = fallback
        MainActor.assumeIsolated {
            guard let bridge, let node = bridge.tree.node(key) else { return }
            result = body(bridge, node, key)
        }
        return result
    }

    override func isAccessibilityElement() -> Bool { read(false) { _, _, _ in true } }

    override func accessibilityRole() -> NSAccessibility.Role? {
        read(.unknown) { _, node, _ in BrowserAccessibilityRoles.role(for: node) }
    }

    override func accessibilitySubrole() -> NSAccessibility.Subrole? {
        read(nil) { _, node, _ in BrowserAccessibilityRoles.subrole(for: node) }
    }

    override func accessibilityRoleDescription() -> String? {
        read(nil) { _, node, _ in
            if let description = BrowserAccessibilityRoles.roleDescription(for: node) { return description }
            return BrowserAccessibilityRoles.role(for: node).description(with: BrowserAccessibilityRoles.subrole(for: node))
        }
    }

    override func accessibilityLabel() -> String? {
        read(nil) { bridge, node, key in node.role == "staticText" ? nil : bridge.tree.label(of: key) }
    }

    override func accessibilityTitle() -> String? { nil }

    override func accessibilityHelp() -> String? {
        read(nil) { _, node, _ in node.description.flatMap { $0.isEmpty ? nil : $0 } }
    }

    override func accessibilityPlaceholderValue() -> String? { read(nil) { _, node, _ in node.placeholder } }

    override func accessibilityValue() -> Any? {
        read(nil) { bridge, node, key in BrowserAccessibilityElement.value(of: node, key: key, in: bridge.tree) }
    }

    @MainActor
    static func value(of node: BrowserAccessibilityNode, key: BrowserAccessibilityKey, in tree: BrowserAccessibilityTree) -> Any? {
        switch node.role {
        case "staticText":
            return node.name ?? ""
        case "checkBox", "switch", "toggleButton", "radioButton", "menuItemCheckBox", "menuItemRadio":
            switch node.checked {
            case "true": return 1
            case "mixed": return 2
            default: return 0
            }
        case "tab":
            return node.selected == true ? 1 : 0
        case "heading":
            return node.level ?? 0
        case "slider", "progressIndicator", "meter", "spinButton", "scrollBar":
            return node.rangeValue
        case "comboBoxSelect", "popUpButton", "comboBoxMenuButton":
            if let value = node.value, !value.isEmpty { return value }
            return tree.options(of: key).first { tree.node($0)?.selected == true }.flatMap { tree.node($0)?.name } ?? ""
        default:
            if BrowserAccessibilityRoles.isTextInput(node) {
                if let value = node.value { return value }
                return tree.isRichTextField(node) ? tree.text(of: key) : ""
            }
            return nil
        }
    }

    override func setAccessibilityValue(_ value: Any?) {
        let text = (value as? String) ?? ""
        read(()) { bridge, node, key in
            guard BrowserAccessibilityRoles.isTextInput(node), node.restriction == nil else { return }
            bridge.setValue(text, of: key)
        }
    }

    override func accessibilityNumberOfCharacters() -> Int {
        (accessibilityValue() as? String)?.utf16.count ?? 0
    }

    override func accessibilitySelectedTextRange() -> NSRange {
        read(NSRange(location: 0, length: 0)) { _, node, _ in
            guard let start = node.selectionStart, let end = node.selectionEnd else { return NSRange(location: 0, length: 0) }
            return NSRange(location: min(start, end), length: abs(end - start))
        }
    }

    override func accessibilityMinValue() -> Any? { read(nil) { _, node, _ in node.rangeMinimum } }
    override func accessibilityMaxValue() -> Any? { read(nil) { _, node, _ in node.rangeMaximum } }

    override func accessibilityURL() -> URL? {
        read(nil) { _, node, _ in node.role == "link" ? node.url.flatMap(URL.init(string:)) : nil }
    }

    override func isAccessibilityEnabled() -> Bool { read(false) { _, node, _ in node.restriction != "disabled" } }
    override func isAccessibilitySelected() -> Bool { read(false) { _, node, _ in node.selected ?? false } }
    override func isAccessibilityExpanded() -> Bool { read(false) { _, node, _ in node.has("expanded") } }
    override func isAccessibilityRequired() -> Bool { read(false) { _, node, _ in node.has("required") } }

    override func isAccessibilityFocused() -> Bool {
        read(false) { bridge, _, key in bridge.tree.focus == key && bridge.isViewFocused }
    }

    override func setAccessibilityFocused(_ focused: Bool) {
        guard focused else { return }
        read(()) { bridge, _, key in bridge.focus(key) }
    }

    override func accessibilityFrame() -> NSRect {
        read(.zero) { bridge, _, key in bridge.screenFrame(of: key) }
    }

    override func accessibilityParent() -> Any? {
        read(nil) { bridge, _, key in bridge.parent(of: key) }
    }

    override func accessibilityChildren() -> [Any]? {
        read([]) { bridge, _, key in bridge.children(of: key) }
    }

    override func accessibilityWindow() -> Any? { read(nil) { bridge, _, key in bridge.window } }
    override func accessibilityTopLevelUIElement() -> Any? { read(nil) { bridge, _, key in bridge.window } }

    override func accessibilityPerformPress() -> Bool {
        read(false) { bridge, _, key in
            bridge.press(key)
            return true
        }
    }

    // Tables.

    override func accessibilityRowCount() -> Int { read(0) { _, node, _ in node.rowCount ?? 0 } }
    override func accessibilityColumnCount() -> Int { read(0) { _, node, _ in node.columnCount ?? 0 } }

    override func accessibilityRows() -> [Any]? {
        read(nil) { bridge, node, key in
            guard BrowserAccessibilityRoles.role(for: node) == .table else { return nil }
            return bridge.tree.exposedChildren(of: key)
                .filter { bridge.tree.node($0).map(BrowserAccessibilityRoles.role(for:)) == .row }
                .map { bridge.element(for: $0) }
        }
    }

    override func accessibilityRowIndexRange() -> NSRange {
        read(NSRange(location: 0, length: 1)) { _, node, _ in NSRange(location: node.rowIndex ?? 0, length: node.rowSpan ?? 1) }
    }

    override func accessibilityColumnIndexRange() -> NSRange {
        read(NSRange(location: 0, length: 1)) { _, node, _ in
            NSRange(location: node.columnIndex ?? 0, length: node.columnSpan ?? 1)
        }
    }

    override func accessibilityIndex() -> Int {
        read(0) { _, node, _ in node.rowIndex ?? (node.positionInSet).map { $0 - 1 } ?? 0 }
    }

    // AXScrollToVisible (VoiceOver scrolls the page to the element it moves to) is an action
    // AppKit's typed API has no method for.

    override func accessibilityActionNames() -> [NSAccessibility.Action] {
        read([]) { _, node, _ in node.bounds != nil ? [.press, Self.scrollToVisible] : [.press] }
    }

    override func accessibilityPerformAction(_ action: NSAccessibility.Action) {
        if action == Self.scrollToVisible {
            read(()) { bridge, _, key in
                let key = key
                Task { @MainActor in await bridge.reveal(key) }
            }
        } else if action == .press {
            _ = accessibilityPerformPress()
        }
    }
}
