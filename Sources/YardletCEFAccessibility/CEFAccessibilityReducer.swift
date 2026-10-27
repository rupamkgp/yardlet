import Foundation

/// Turns CEF's accessibility values (`CefAccessibilityHandler`, written as JSON) into the smaller
/// shape of Yardlet's browser host contract: the `accessibilityTree` and `accessibilityLocations`
/// events (BrowserAccessibilityTreeChange and BrowserAccessibilityLocation in the app). The browser
/// host runs it on every change; Yardlet's tests run it on recorded CEF output.
///
/// Kept per node: role, name, value, description, placeholder, states, checked/selected/disabled,
/// heading level, table and set positions, range values, text selection, link URL, child tree,
/// children, bounds and offset container, scroll offset. Inline text boxes (one per
/// line of text, with per-character offsets) are dropped, which is most of CEF's output.
public enum CEFAccessibilityReducer {
    /// One `on_accessibility_tree_change` value → the `change` field of `accessibilityTree`, or nil
    /// when it carries nothing.
    public static func treeChange(_ value: Any) -> [String: Any]? {
        guard let dictionary = value as? [String: Any], let tree = dictionary["ax_tree_id"] as? String else {
            return nil
        }
        let updates = (dictionary["updates"] as? [[String: Any]] ?? []).map(update)
        let events: [[String: Any]] = (dictionary["events"] as? [[String: Any]] ?? []).compactMap { event in
            guard let type = event["event_type"] as? String else { return nil }
            var result: [String: Any] = ["type": type]
            if let id = int(event["id"]), id >= 0 { result["id"] = id }
            return result
        }
        guard !updates.isEmpty || !events.isEmpty else { return nil }
        var change: [String: Any] = ["tree": tree, "updates": updates]
        if !events.isEmpty { change["events"] = events }
        return change
    }

    /// One `on_accessibility_location_change` value → the `changes` of `accessibilityLocations`.
    public static func locationChanges(_ value: Any) -> [[String: Any]] {
        let items: [[String: Any]]
        if let list = value as? [[String: Any]] {
            items = list
        } else if let single = value as? [String: Any] {
            items = [single]
        } else {
            return []
        }
        return items.compactMap { item in
            guard let tree = item["ax_tree_id"] as? String, let id = int(item["id"]),
                  let location = item["new_location"] as? [String: Any],
                  let bounds = rect(location["bounds"] ?? location) else { return nil }
            var result: [String: Any] = ["tree": tree, "id": id, "bounds": bounds]
            if let container = int(location["offset_container_id"]), container > 0 { result["container"] = container }
            return result
        }
    }

    // MARK: Pieces

    static let keptStates: Set<String> = [
        "collapsed", "editable", "expanded", "focusable", "horizontal", "ignored", "invisible", "linked",
        "multiline", "multiselectable", "protected", "required", "richlyEditable", "vertical", "visited"
    ]

    /// CEF attribute name → field name in the contract, for integer attributes.
    static let integerAttributes: [String: String] = [
        "hierarchicalLevel": "level",
        "textSelStart": "selectionStart",
        "textSelEnd": "selectionEnd",
        "tableRowCount": "rowCount",
        "tableColumnCount": "columnCount",
        "tableRowIndex": "rowIndex",
        "tableColumnIndex": "columnIndex",
        "tableCellRowIndex": "rowIndex",
        "tableCellColumnIndex": "columnIndex",
        "tableCellRowSpan": "rowSpan",
        "tableCellColumnSpan": "columnSpan",
        "posInSet": "positionInSet",
        "setSize": "setSize",
        "activedescendantId": "activeDescendant"
    ]

    static let stringAttributes: [String: String] = [
        "name": "name",
        "value": "value",
        "description": "description",
        "placeholder": "placeholder",
        "url": "url",
        "roleDescription": "roleDescription",
        "inputType": "inputType",
        "childTreeId": "childTree",
        "keyShortcuts": "keyShortcuts"
    ]

    static let numberAttributes: [String: String] = [
        "valueForRange": "rangeValue",
        "minValueForRange": "rangeMinimum",
        "maxValueForRange": "rangeMaximum",
        "scrollX": "scrollX",
        "scrollY": "scrollY"
    ]

    static func update(_ update: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [:]
        if let root = int(update["root_id"]), root >= 0 { result["root"] = root }
        if let clear = int(update["node_id_to_clear"]), clear >= 0 { result["clear"] = clear }
        if bool(update["has_tree_data"]) == true, let data = update["tree_data"] as? [String: Any] {
            var treeData: [String: Any] = [:]
            if let parent = data["parent_tree_id"] as? String, !parent.isEmpty { treeData["parent"] = parent }
            if let focus = int(data["focus_id"]), focus >= 0 { treeData["focus"] = focus }
            if let focused = data["focused_tree_id"] as? String, !focused.isEmpty { treeData["focusedTree"] = focused }
            if let title = data["title"] as? String, !title.isEmpty { treeData["title"] = title }
            if let url = data["url"] as? String, !url.isEmpty { treeData["url"] = url }
            if let loaded = bool(data["loaded"]) { treeData["loaded"] = loaded }
            result["treeData"] = treeData
        }
        result["nodes"] = (update["nodes"] as? [[String: Any]] ?? []).compactMap(node)
        return result
    }

    static func node(_ node: [String: Any]) -> [String: Any]? {
        guard let id = int(node["id"]), let role = node["role"] as? String, role != "inlineTextBox" else {
            return nil
        }
        var result: [String: Any] = ["id": id, "role": role]
        // Static text's children are its inline text boxes, which are not kept.
        if role != "staticText", let children = node["child_ids"] as? [Any] {
            let ids = children.compactMap(int)
            if !ids.isEmpty { result["children"] = ids }
        }
        if let bounds = rect(node["location"]) { result["bounds"] = bounds }
        if let container = int(node["offset_container_id"]), container > 0 { result["container"] = container }
        let states = stateNames(node["state"]).filter(keptStates.contains).sorted()
        if !states.isEmpty { result["states"] = states }

        guard let attributes = node["attributes"] as? [String: Any] else { return result }
        for (key, field) in stringAttributes {
            if let text = attributes[key] as? String, !text.isEmpty { result[field] = text }
        }
        for (key, field) in integerAttributes {
            if let number = int(attributes[key]) { result[field] = number }
        }
        for (key, field) in numberAttributes {
            if let number = double(attributes[key]), number != 0 || !field.hasPrefix("scroll") { result[field] = number }
        }
        if let checked = checkedState(attributes["checkedState"]) { result["checked"] = checked }
        if bool(attributes["selected"]) == true { result["selected"] = true }
        if let restriction = restriction(attributes["restriction"]) { result["restriction"] = restriction }
        if let popup = hasPopup(attributes["haspopup"] ?? attributes["hasPopup"]) { result["hasPopup"] = popup }
        if let invalid = attributes["invalidState"] as? String, invalid != "false", invalid != "none" { result["invalid"] = true }
        return result
    }

    /// CEF writes the state as a list of names; older builds wrote a dictionary of flags.
    static func stateNames(_ value: Any?) -> [String] {
        if let names = value as? [String] { return names }
        if let flags = value as? [String: Any] { return flags.compactMap { bool($0.value) == true ? $0.key : nil } }
        return []
    }

    static func checkedState(_ value: Any?) -> String? {
        if let text = value as? String {
            switch text {
            case "true", "mixed": return text
            case "false": return "false"
            default: return nil
            }
        }
        // ax::mojom::CheckedState: 1 false, 2 true, 3 mixed.
        switch int(value) {
        case 1: return "false"
        case 2: return "true"
        case 3: return "mixed"
        default: return nil
        }
    }

    /// ax::mojom::HasPopup, written as its number or its name.
    static func hasPopup(_ value: Any?) -> String? {
        if let text = value as? String { return text.isEmpty || text == "false" ? nil : text }
        let names = [1: "true", 2: "menu", 3: "listbox", 4: "tree", 5: "grid", 6: "dialog"]
        return int(value).flatMap { names[$0] }
    }

    static func restriction(_ value: Any?) -> String? {
        if let text = value as? String { return text == "disabled" || text == "readOnly" ? text : nil }
        // ax::mojom::Restriction: 1 read only, 2 disabled.
        switch int(value) {
        case 1: return "readOnly"
        case 2: return "disabled"
        default: return nil
        }
    }

    static func rect(_ value: Any?) -> [String: Any]? {
        guard let rect = value as? [String: Any], let x = double(rect["x"]), let y = double(rect["y"]),
              let width = double(rect["width"]), let height = double(rect["height"]) else { return nil }
        return ["x": x, "y": y, "width": width, "height": height]
    }

    static func int(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.intValue
    }

    static func double(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.doubleValue
    }

    static func bool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }
}
