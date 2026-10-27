import Foundation

/// A JSON value for the Yardlet MCP server and its connection to the app. The app has its own
/// `JSONValue`; this module is shared with the `yardlet-mcp` executable, so it carries its own
/// small copy with the same wire form.
package enum ToolJSON: Codable, Equatable, Sendable {
    case object([String: ToolJSON])
    case array([ToolJSON])
    case string(String)
    case integer(Int64)
    case number(Double)
    case bool(Bool)
    case null

    package init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: ToolJSON].self) {
            self = .object(value)
        } else if let value = try? container.decode([ToolJSON].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    package subscript(key: String) -> ToolJSON? {
        guard case .object(let object) = self else { return nil }
        return object[key]
    }

    package var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    package var objectValue: [String: ToolJSON]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    package var arrayValue: [ToolJSON]? {
        guard case .array(let value) = self else { return nil }
        return value
    }
}
