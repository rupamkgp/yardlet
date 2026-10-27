import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import YardletAgentTools

/// One Google REST API (Calendar v3, Drive v3, Docs, Sheets, Slides, Analytics, Ads) for one
/// account, through the account's `OAuthAPISession`: JSON in and out, and the raw bytes a download
/// or an upload needs. Nothing here logs or keeps what a calendar or a drive holds; a failure
/// carries Google's own error message, never a request or response body.
struct GoogleREST: Sendable {
    let base: URL
    let session: OAuthAPISession
    /// Headers every request carries besides the token (Google Ads' `login-customer-id`).
    var headers: [String: String] = [:]

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
        if !path.isEmpty {
            var prefix = components.percentEncodedPath
            if !prefix.hasSuffix("/") { prefix += "/" }
            components.percentEncodedPath = prefix + path.joined(separator: "/")
        }
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
            for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
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
