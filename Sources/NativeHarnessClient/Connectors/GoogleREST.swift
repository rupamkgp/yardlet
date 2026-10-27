import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import YardletAgentTools

/// One Google REST API (Calendar v3, Drive v3, Docs, Sheets, Slides) for one account, through the account's
/// `GoogleAPISession`: JSON in and out, and the raw bytes a download or an upload needs. Nothing
/// here logs or keeps what a calendar or a drive holds; a failure carries Google's own error
/// message, never a request or response body.
struct GoogleREST: Sendable {
    let base: URL
    let session: GoogleAPISession

    enum Failure: Error, Equatable, LocalizedError {
        /// Google answered with an error: its HTTP status and its `error.message`.
        case http(status: Int, message: String)
        case unreadableAnswer
        /// An ID or name a request cannot carry (empty, too long, a line break), refused before it.
        case invalidID(String)
        /// An answer larger than a tool returns.
        case tooLarge(bytes: Int, limit: Int)

        var errorDescription: String? {
            switch self {
            case .http(let status, let message): message.isEmpty ? "HTTP \(status)" : "\(message) (HTTP \(status))"
            case .unreadableAnswer: "Google's answer could not be read."
            case .invalidID(let id): "Not an ID Google takes: \(id)"
            case .tooLarge(let bytes, let limit): "The content is \(bytes) bytes, over the \(limit) a tool returns."
            }
        }
    }

    /// An ID as one path segment, percent-encoded: calendar IDs are addresses with `@` and `#`
    /// (`en.south_korea#holiday@group.v.calendar.google.com`).
    static func segment(_ id: String) throws -> String {
        guard !id.isEmpty, id.count <= 1_024, !id.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { throw Failure.invalidID(id) }
        let unreserved = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return id.addingPercentEncoding(withAllowedCharacters: unreserved) ?? id
    }

    func get(_ path: [String], _ query: [URLQueryItem] = []) async throws -> ToolJSON {
        try await json("GET", path, query, body: nil)
    }

    func post(_ path: [String], _ body: ToolJSON, _ query: [URLQueryItem] = []) async throws -> ToolJSON {
        try await json("POST", path, query, body: body)
    }

    func patch(_ path: [String], _ body: ToolJSON, _ query: [URLQueryItem] = []) async throws -> ToolJSON {
        try await json("PATCH", path, query, body: body)
    }

    func put(_ path: [String], _ body: ToolJSON, _ query: [URLQueryItem] = []) async throws -> ToolJSON {
        try await json("PUT", path, query, body: body)
    }

    func delete(_ path: [String], _ query: [URLQueryItem] = []) async throws {
        _ = try await json("DELETE", path, query, body: nil)
    }

    /// A request's raw answer, for a download: the bytes, at most `limit`, and their type.
    func download(_ path: [String], _ query: [URLQueryItem], limit: Int) async throws -> (data: Data, mimeType: String?) {
        let (data, response) = try await send("GET", url(base, path, query), body: nil, contentType: nil, accept: "*/*")
        try Self.check(data, response)
        guard data.count <= limit else { throw Failure.tooLarge(bytes: data.count, limit: limit) }
        let type = response.value(forHTTPHeaderField: "Content-Type")?.split(separator: ";").first
            .map { $0.trimmingCharacters(in: .whitespaces) }
        return (data, type)
    }

    /// A multipart upload (`uploadType=multipart`): the metadata as JSON, then the content.
    func upload(method: String, to uploadBase: URL, _ path: [String], _ query: [URLQueryItem],
                metadata: ToolJSON, content: Data, contentType: String) async throws -> ToolJSON {
        let boundary = "yardlet-\(UUID().uuidString)"
        var body = Data()
        func line(_ text: String) { body.append(Data((text + "\r\n").utf8)) }
        line("--\(boundary)")
        line("Content-Type: application/json; charset=UTF-8")
        line("")
        body.append(try JSONEncoder().encode(metadata))
        line("")
        line("--\(boundary)")
        line("Content-Type: \(contentType)")
        line("")
        body.append(content)
        line("")
        line("--\(boundary)--")
        let target = url(uploadBase, path, [URLQueryItem(name: "uploadType", value: "multipart")] + query)
        let (data, response) = try await send(method, target, body: body,
                                              contentType: "multipart/related; boundary=\(boundary)",
                                              accept: "application/json")
        return try Self.decode(data, response)
    }

    // MARK: Requests

    private func json(_ method: String, _ path: [String], _ query: [URLQueryItem], body: ToolJSON?) async throws -> ToolJSON {
        let payload = try body.map { try JSONEncoder().encode($0) }
        let (data, response) = try await send(method, url(base, path, query), body: payload,
                                              contentType: payload == nil ? nil : "application/json",
                                              accept: "application/json")
        return try Self.decode(data, response)
    }

    private func url(_ base: URL, _ path: [String], _ query: [URLQueryItem]) -> URL {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        var prefix = components.percentEncodedPath
        if !prefix.hasSuffix("/") { prefix += "/" }
        components.percentEncodedPath = prefix + path.joined(separator: "/")
        if !query.isEmpty {
            components.queryItems = query
            // `+` would be a space to Google's query parser; a query that means a plus keeps it.
            components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        }
        return components.url!
    }

    private func send(_ method: String, _ url: URL, body: Data?, contentType: String?, accept: String)
        async throws -> (Data, HTTPURLResponse) {
        try await session.send {
            var request = URLRequest(url: url, timeoutInterval: 60)
            request.httpMethod = method
            request.setValue(accept, forHTTPHeaderField: "Accept")
            if let body {
                request.setValue(contentType, forHTTPHeaderField: "Content-Type")
                request.httpBody = body
            }
            return request
        }
    }

    private static func check(_ data: Data, _ response: HTTPURLResponse) throws {
        guard (200..<300).contains(response.statusCode) else {
            let message = (try? JSONDecoder().decode(ToolJSON.self, from: data))?["error"]?["message"]?.stringValue ?? ""
            throw Failure.http(status: response.statusCode, message: message)
        }
    }

    private static func decode(_ data: Data, _ response: HTTPURLResponse) throws -> ToolJSON {
        try check(data, response)
        if data.isEmpty { return .object([:]) }
        guard let json = try? JSONDecoder().decode(ToolJSON.self, from: data) else { throw Failure.unreadableAnswer }
        return json
    }
}

/// What the Calendar and Drive runners share: reading a tool's arguments, and the answer as
/// compact JSON text.
enum GoogleToolArguments {
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

/// The JSON Schema pieces the Calendar and Drive catalogs build their tools from, with MCP's
/// annotations (`readOnlyHint`, `destructiveHint`, `openWorldHint`).
enum GoogleToolSchema {
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
