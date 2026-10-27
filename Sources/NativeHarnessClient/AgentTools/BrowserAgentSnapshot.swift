import Foundation

/// Turns a CDP `Accessibility.getFullAXTree` answer into the text an agent reads, and gives each
/// element it can act on a reference such as `@e3` that maps to the element's backend DOM node.
enum BrowserAgentSnapshot {
    struct Result: Equatable {
        var text: String
        /// Reference (`@e3`) → `backendDOMNodeId`.
        var refs: [String: Int]
        var isTruncated: Bool
    }

    /// Containers that only group other content; without a name they add a level and no meaning.
    private static let transparentRoles: Set<String> = [
        "generic", "none", "presentation", "GenericContainer", "LayoutTable", "LayoutTableRow",
        "LayoutTableCell", "Pre", "Ruby", "LineBreak"
    ]
    private static let valueRoles: Set<String> = [
        "textbox", "searchbox", "combobox", "spinbutton", "slider", "TextField", "ComboBoxMenuButton"
    ]
    private static let booleanProperties = ["checked", "pressed", "expanded", "selected", "disabled", "required",
                                            "focused", "readonly", "invalid"]

    static func render(nodes: [JSONValue], maximumLength: Int = 60_000) -> Result {
        var byID: [String: JSONValue] = [:]
        for node in nodes {
            if let id = node["nodeId"]?.stringValue { byID[id] = node }
        }
        let root = nodes.first { $0["parentId"] == nil } ?? nodes.first
        var renderer = Renderer(byID: byID, maximumLength: maximumLength)
        if let rootID = root?["nodeId"]?.stringValue {
            renderer.lines = renderer.visit(rootID, depth: 0, parentName: "")
        }
        var text = renderer.lines.joined(separator: "\n")
        if renderer.isTruncated {
            text += "\n… The page is larger than one snapshot; the rest was left out. Scroll, or read a part "
                + "with browser_evaluate."
        }
        return Result(text: text.isEmpty ? "(The page has no readable content.)" : text,
                      refs: renderer.refs, isTruncated: renderer.isTruncated)
    }

    private struct Renderer {
        let byID: [String: JSONValue]
        let maximumLength: Int
        var lines: [String] = []
        var refs: [String: Int] = [:]
        var length = 0
        var isTruncated = false

        init(byID: [String: JSONValue], maximumLength: Int) {
            self.byID = byID
            self.maximumLength = maximumLength
        }

        mutating func visit(_ id: String, depth: Int, parentName: String) -> [String] {
            guard !isTruncated, let node = byID[id] else { return [] }
            let role = node["role"]?["value"]?.stringValue ?? ""
            let name = BrowserAgentSnapshot.clean(node["name"]?["value"]?.stringValue ?? "")
            let children = node["childIds"]?.arrayValue?.compactMap(\.stringValue) ?? []
            let properties = BrowserAgentSnapshot.properties(of: node)

            if role == "InlineTextBox" { return [] }
            if role == "StaticText" {
                guard !name.isEmpty, name != parentName else { return [] }
                return emit(["\(indent(depth))- text: \(BrowserAgentSnapshot.quoted(name))"])
            }
            let isIgnored = node["ignored"]?.boolValue == true
            let isTransparent = transparentRoles.contains(role) && name.isEmpty && properties["focusable"] != "true"
            if isIgnored || isTransparent || role == "RootWebArea" || role.isEmpty {
                return children.flatMap { visit($0, depth: depth, parentName: role == "RootWebArea" ? name : parentName) }
            }

            var line = "\(indent(depth))- \(role)"
            if !name.isEmpty { line += " \(BrowserAgentSnapshot.quoted(name))" }
            if let level = properties["level"] { line += " [level=\(level)]" }
            for property in booleanProperties {
                guard let value = properties[property], value != "false" else { continue }
                line += value == "true" ? " [\(property)]" : " [\(property)=\(value)]"
            }
            if role == "link", let url = properties["url"], !url.isEmpty {
                line += " [url=\(String(url.prefix(200)))]"
            }
            if let backend = node["backendDOMNodeId"]?.integerValue {
                let ref = "@e\(refs.count + 1)"
                refs[ref] = Int(backend)
                line += " [ref=\(ref)]"
            }
            let value = BrowserAgentSnapshot.redactingMasked(BrowserAgentSnapshot.clean(node["value"]?["value"]?.stringValue
                ?? node["value"]?["value"]?.integerValue.map(String.init) ?? ""))
            if valueRoles.contains(role), !value.isEmpty {
                return emit([line + ": " + BrowserAgentSnapshot.quoted(value)])
                    + children.flatMap { visit($0, depth: depth + 1, parentName: value) }
                        .filter { !$0.hasPrefix(indent(depth + 1) + "- text:") }
            }
            guard let head = emit([line]).first else { return [] }
            let childLines = children.flatMap { visit($0, depth: depth + 1, parentName: name) }
            // A nameless element holding only text reads as one line.
            let textPrefix = indent(depth + 1) + "- text: "
            if name.isEmpty, !childLines.isEmpty, childLines.allSatisfy({ $0.hasPrefix(textPrefix) }) {
                let joined = childLines.map { String($0.dropFirst(textPrefix.count)) }.joined(separator: " ")
                return [head + ": " + joined]
            }
            return [head] + childLines
        }

        private mutating func emit(_ new: [String]) -> [String] {
            let added = new.reduce(0) { $0 + $1.count + 1 }
            guard length + added <= maximumLength else {
                isTruncated = true
                return []
            }
            length += added
            return new
        }

        private func indent(_ depth: Int) -> String { String(repeating: "  ", count: depth) }
    }

    fileprivate static func properties(of node: JSONValue) -> [String: String] {
        var result: [String: String] = [:]
        for property in node["properties"]?.arrayValue ?? [] {
            guard let name = property["name"]?.stringValue, let value = property["value"]?["value"] else { continue }
            switch value {
            case .bool(let flag): result[name] = flag ? "true" : "false"
            case .string(let text): result[name] = text
            case .integer(let number): result[name] = String(number)
            case .number(let number): result[name] = String(number)
            default: break
            }
        }
        return result
    }

    fileprivate static func clean(_ text: String) -> String {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.count > 300 ? String(collapsed.prefix(300)) + "…" : collapsed
    }

    /// Chromium shows a password field's value to accessibility as one bullet per character; even its
    /// length stays out of the result.
    fileprivate static func redactingMasked(_ value: String) -> String {
        !value.isEmpty && value.allSatisfy({ $0 == "•" || $0 == "●" }) ? "<redacted>" : value
    }

    fileprivate static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
