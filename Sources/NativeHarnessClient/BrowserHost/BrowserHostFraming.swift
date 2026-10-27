import Foundation

/// Stream framing for browser host messages: a 4-byte big-endian length, then that many bytes of
/// UTF-8 JSON. Used by any byte-stream transport (a pipe on macOS, a named pipe on Windows).
enum BrowserHostFraming {
    static let maximumMessageLength = 64 * 1024 * 1024

    static func frame<T: Encodable>(_ message: T, encoder: JSONEncoder = JSONEncoder()) throws -> Data {
        let body = try encoder.encode(message)
        var length = UInt32(body.count).bigEndian
        var data = Data(bytes: &length, count: 4)
        data.append(body)
        return data
    }
}

enum BrowserHostFramingError: Error, Equatable {
    case messageTooLong(Int)
}

/// Collects bytes from a stream and returns each complete message body.
struct BrowserHostFrameReader {
    private var buffer = Data()

    mutating func append(_ bytes: Data) throws -> [Data] {
        buffer.append(bytes)
        var messages: [Data] = []
        while buffer.count >= 4 {
            let start = buffer.startIndex
            let length = buffer[start..<start + 4].reduce(0) { ($0 << 8) | Int($1) }
            guard length <= BrowserHostFraming.maximumMessageLength else {
                throw BrowserHostFramingError.messageTooLong(length)
            }
            guard buffer.count >= 4 + length else { break }
            messages.append(Data(buffer[start + 4..<start + 4 + length]))
            buffer.removeSubrange(start..<start + 4 + length)
        }
        return messages
    }
}
