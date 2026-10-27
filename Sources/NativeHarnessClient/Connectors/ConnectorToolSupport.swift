import Foundation
import YardletAgentTools

/// What the tool runners of Yardlet's own servers share (Google's, Microsoft's): reading a tool's
/// arguments, and the answer as compact JSON text.
enum ConnectorToolArguments {
    enum Problem: Error, Equatable, LocalizedError {
        case missing(String)
        case invalid(String)

        var errorDescription: String? {
            switch self {
            case .missing(let name): "\(name) is required."
            case .invalid(let reason): reason
            }
        }
    }

    static func text(_ json: ToolJSON) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(json)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    static func string(_ arguments: [String: ToolJSON], _ name: String) -> String? {
        guard let value = arguments[name]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty
        else { return nil }
        return value
    }

    static func required(_ arguments: [String: ToolJSON], _ name: String) throws -> String {
        guard let value = string(arguments, name) else { throw Problem.missing(name) }
        return value
    }

    /// A list of strings; one string alone is a list of one.
    static func strings(_ arguments: [String: ToolJSON], _ name: String) throws -> [String] {
        switch arguments[name] {
        case nil, .null?: return []
        case .string(let value)?: return value.isEmpty ? [] : [value]
        case .array(let values)?:
            return try values.map {
                guard let text = $0.stringValue else { throw Problem.invalid("\(name) takes strings.") }
                return text
            }
        default: throw Problem.invalid("\(name) takes a list of strings.")
        }
    }

    static func integer(_ value: ToolJSON?) -> Int? {
        switch value {
        case .integer(let number)?: Int(number)
        case .number(let number)?: Int(number)
        case .string(let text)?: Int(text)
        default: nil
        }
    }

    static func bool(_ value: ToolJSON?) -> Bool? {
        switch value {
        case .bool(let flag)?: flag
        case .string(let text)?: ["true", "1", "yes"].contains(text.lowercased()) ? true
            : ["false", "0", "no"].contains(text.lowercased()) ? false : nil
        default: nil
        }
    }

    /// A page size within `range`, or `fallback`.
    static func pageSize(_ arguments: [String: ToolJSON], _ name: String = "pageSize", range: ClosedRange<Int>, fallback: Int) -> Int {
        integer(arguments[name]).map { min(max($0, range.lowerBound), range.upperBound) } ?? fallback
    }

    /// Fields copied from Google's object as they are, when present.
    static func pick(_ object: ToolJSON?, _ keys: [String]) -> [String: ToolJSON] {
        var fields: [String: ToolJSON] = [:]
        for key in keys { if let value = object?[key], value != .null { fields[key] = value } }
        return fields
    }

    static func string(_ value: String?) -> ToolJSON? {
        value.map(ToolJSON.string)
    }
}

/// The JSON Schema pieces the catalogs of Yardlet's own servers build their tools from, with MCP's
/// annotations (`readOnlyHint`, `destructiveHint`, `openWorldHint`).
enum ConnectorToolSchema {
    static func tool(_ name: String, _ title: String, _ description: String,
                     properties: [String: ToolJSON], required: [String] = [],
                     readOnly: Bool, destructive: Bool = false, openWorld: Bool = false) -> ToolJSON {
        var schema: [String: ToolJSON] = ["type": .string("object"), "properties": .object(properties),
                                          "additionalProperties": .bool(false)]
        if !required.isEmpty { schema["required"] = .array(required.map { .string($0) }) }
        return .object([
            "name": .string(name),
            "title": .string(title),
            "description": .string(description),
            "inputSchema": .object(schema),
            "annotations": .object([
                "title": .string(title),
                "readOnlyHint": .bool(readOnly),
                "destructiveHint": .bool(destructive),
                "openWorldHint": .bool(openWorld)
            ])
        ])
    }

    static func string(_ description: String) -> ToolJSON {
        .object(["type": .string("string"), "description": .string(description)])
    }

    static func boolean(_ description: String) -> ToolJSON {
        .object(["type": .string("boolean"), "description": .string(description)])
    }

    static func enumeration(_ description: String, _ values: [String]) -> ToolJSON {
        .object(["type": .string("string"), "enum": .array(values.map(ToolJSON.string)), "description": .string(description)])
    }

    static func integer(_ description: String, _ range: ClosedRange<Int>) -> ToolJSON {
        .object(["type": .string("integer"), "minimum": .integer(Int64(range.lowerBound)),
                 "maximum": .integer(Int64(range.upperBound)), "description": .string(description)])
    }

    static func stringArray(_ description: String) -> ToolJSON {
        .object(["type": .string("array"), "items": .object(["type": .string("string")]), "description": .string(description)])
    }
}
