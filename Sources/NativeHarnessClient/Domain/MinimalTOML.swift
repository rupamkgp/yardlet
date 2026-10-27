import Foundation

/// Reads the part of TOML a Codex app automation file uses (`automation.toml`): `key = value` lines
/// with basic, literal and multi-line strings, integers, floats, booleans, arrays and inline tables,
/// comments, and `[table]` headers (their keys come back as `table.key`). It only reads; it is not a
/// general TOML library, and anything it does not understand ends the reading with an error.
enum MinimalTOML {
    indirect enum Value: Equatable, Sendable {
        case string(String)
        case integer(Int64)
        case float(Double)
        case bool(Bool)
        case array([Value])
        case table([String: Value])

        var string: String? { if case let .string(value) = self { value } else { nil } }
        var integer: Int64? { if case let .integer(value) = self { value } else { nil } }
        var bool: Bool? { if case let .bool(value) = self { value } else { nil } }
        var array: [Value]? { if case let .array(value) = self { value } else { nil } }
        var table: [String: Value]? { if case let .table(value) = self { value } else { nil } }
    }

    struct ParseError: Error, Equatable {
        let offset: Int
    }

    /// The document's keys, with a table's keys as `table.key`.
    static func parse(_ text: String) throws -> [String: Value] {
        var reader = Reader(Array(text.unicodeScalars))
        var result: [String: Value] = [:]
        var prefix = ""
        while true {
            reader.skipBlankLinesAndComments()
            guard let scalar = reader.peek else { break }
            if scalar == "[" {
                reader.advance()
                guard reader.peek != "[" else { throw ParseError(offset: reader.index) }
                reader.skipSpaces()
                let key = try reader.key()
                reader.skipSpaces()
                guard reader.take("]") else { throw ParseError(offset: reader.index) }
                prefix = key + "."
            } else {
                let key = try reader.key()
                reader.skipSpaces()
                guard reader.take("=") else { throw ParseError(offset: reader.index) }
                reader.skipSpaces()
                result[prefix + key] = try reader.value()
            }
            reader.skipSpaces()
            reader.skipComment()
            guard reader.peek == nil || reader.takeNewline() else { throw ParseError(offset: reader.index) }
        }
        return result
    }

    private struct Reader {
        let scalars: [Unicode.Scalar]
        var index = 0

        init(_ scalars: [Unicode.Scalar]) { self.scalars = scalars }

        var peek: Unicode.Scalar? { index < scalars.count ? scalars[index] : nil }
        func peek(_ offset: Int) -> Unicode.Scalar? { index + offset < scalars.count ? scalars[index + offset] : nil }
        mutating func advance(_ count: Int = 1) { index += count }

        mutating func take(_ scalar: Unicode.Scalar) -> Bool {
            guard peek == scalar else { return false }
            advance()
            return true
        }

        mutating func takeNewline() -> Bool {
            if take("\n") { return true }
            if peek == "\r", peek(1) == "\n" { advance(2); return true }
            return false
        }

        mutating func skipSpaces() {
            while peek == " " || peek == "\t" { advance() }
        }

        mutating func skipComment() {
            guard peek == "#" else { return }
            while let scalar = peek, scalar != "\n" { _ = scalar; advance() }
        }

        mutating func skipBlankLinesAndComments() {
            while true {
                skipSpaces()
                skipComment()
                if !takeNewline() { return }
            }
        }

        /// Whitespace, newlines and comments inside an array.
        mutating func skipInsideArray() {
            while true {
                skipSpaces()
                skipComment()
                if !takeNewline() { return }
            }
        }

        mutating func key() throws -> String {
            var parts: [String] = []
            repeat {
                skipSpaces()
                if peek == "\"" {
                    advance()
                    parts.append(try basicString())
                } else if peek == "'" {
                    advance()
                    parts.append(try literalString())
                } else {
                    var bare = ""
                    while let scalar = peek, scalar.properties.isAlphabetic || ("0"..."9").contains(scalar)
                            || scalar == "_" || scalar == "-" {
                        bare.unicodeScalars.append(scalar)
                        advance()
                    }
                    guard !bare.isEmpty else { throw ParseError(offset: index) }
                    parts.append(bare)
                }
                skipSpaces()
            } while take(".")
            return parts.joined(separator: ".")
        }

        mutating func value() throws -> Value {
            guard let scalar = peek else { throw ParseError(offset: index) }
            switch scalar {
            case "\"":
                if peek(1) == "\"", peek(2) == "\"" {
                    advance(3)
                    return .string(try multilineBasicString())
                }
                advance()
                return .string(try basicString())
            case "'":
                if peek(1) == "'", peek(2) == "'" {
                    advance(3)
                    return .string(try multilineLiteralString())
                }
                advance()
                return .string(try literalString())
            case "[":
                advance()
                var values: [Value] = []
                while true {
                    skipInsideArray()
                    if take("]") { return .array(values) }
                    values.append(try value())
                    skipInsideArray()
                    if take(",") { continue }
                    skipInsideArray()
                    guard take("]") else { throw ParseError(offset: index) }
                    return .array(values)
                }
            case "{":
                advance()
                var table: [String: Value] = [:]
                skipSpaces()
                if take("}") { return .table(table) }
                while true {
                    skipSpaces()
                    let key = try key()
                    skipSpaces()
                    guard take("=") else { throw ParseError(offset: index) }
                    skipSpaces()
                    table[key] = try value()
                    skipSpaces()
                    if take(",") { continue }
                    guard take("}") else { throw ParseError(offset: index) }
                    return .table(table)
                }
            default:
                return try bareValue()
            }
        }

        mutating func bareValue() throws -> Value {
            var text = ""
            while let scalar = peek, !" \t\r\n,]}#".unicodeScalars.contains(scalar) {
                text.unicodeScalars.append(scalar)
                advance()
            }
            switch text {
            case "true": return .bool(true)
            case "false": return .bool(false)
            default:
                let digits = text.replacingOccurrences(of: "_", with: "")
                if let integer = Int64(digits) { return .integer(integer) }
                if let float = Double(digits) { return .float(float) }
                throw ParseError(offset: index)
            }
        }

        mutating func escape() throws -> String {
            guard let scalar = peek else { throw ParseError(offset: index) }
            advance()
            switch scalar {
            case "b": return "\u{08}"
            case "t": return "\t"
            case "n": return "\n"
            case "f": return "\u{0C}"
            case "r": return "\r"
            case "e": return "\u{1B}"
            case "\"": return "\""
            case "\\": return "\\"
            case "u", "U":
                let count = scalar == "u" ? 4 : 8
                var hex = ""
                for _ in 0..<count {
                    guard let digit = peek else { throw ParseError(offset: index) }
                    hex.unicodeScalars.append(digit)
                    advance()
                }
                guard let code = UInt32(hex, radix: 16), let value = Unicode.Scalar(code) else {
                    throw ParseError(offset: index)
                }
                return String(Character(value))
            default:
                throw ParseError(offset: index)
            }
        }

        mutating func basicString() throws -> String {
            var text = ""
            while let scalar = peek {
                advance()
                switch scalar {
                case "\"": return text
                case "\\": text += try escape()
                case "\n": throw ParseError(offset: index)
                default: text.unicodeScalars.append(scalar)
                }
            }
            throw ParseError(offset: index)
        }

        mutating func literalString() throws -> String {
            var text = ""
            while let scalar = peek {
                advance()
                if scalar == "'" { return text }
                if scalar == "\n" { throw ParseError(offset: index) }
                text.unicodeScalars.append(scalar)
            }
            throw ParseError(offset: index)
        }

        mutating func multilineBasicString() throws -> String {
            _ = takeNewline()
            var text = ""
            while let scalar = peek {
                if scalar == "\"", peek(1) == "\"", peek(2) == "\"" {
                    advance(3)
                    // Up to two quotes may close the string's content.
                    while peek == "\"" { text.append("\""); advance() }
                    return text
                }
                advance()
                if scalar == "\\" {
                    // A backslash at a line's end trims the newline and the next line's indent.
                    if peek == "\n" || peek == "\r" || peek == " " || peek == "\t" {
                        while let next = peek, next == " " || next == "\t" || next == "\n" || next == "\r" { _ = next; advance() }
                    } else {
                        text += try escape()
                    }
                } else {
                    text.unicodeScalars.append(scalar)
                }
            }
            throw ParseError(offset: index)
        }

        mutating func multilineLiteralString() throws -> String {
            _ = takeNewline()
            var text = ""
            while let scalar = peek {
                if scalar == "'", peek(1) == "'", peek(2) == "'" {
                    advance(3)
                    while peek == "'" { text.append("'"); advance() }
                    return text
                }
                advance()
                text.unicodeScalars.append(scalar)
            }
            throw ParseError(offset: index)
        }
    }
}
