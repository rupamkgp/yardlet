import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import YardletAgentTools

/// The Gmail REST API (developers.google.com/workspace/gmail/api/reference/rest) for one account,
/// JSON in and out, through the account's `GoogleAPISession`. Nothing here logs or keeps what a
/// mailbox holds; a failure carries Google's own error message, never a request or response body.
struct GmailAPI: Sendable {
    /// `https://gmail.googleapis.com/gmail/v1/`.
    let base: URL
    let session: GoogleAPISession

    enum Failure: Error, Equatable, LocalizedError {
        /// Google answered with an error: its HTTP status and its `error.message`.
        case http(status: Int, message: String)
        case unreadableAnswer
        /// An ID with characters Gmail's IDs do not have, refused before any request.
        case invalidID(String)

        var errorDescription: String? {
            switch self {
            case .http(let status, let message): message.isEmpty ? "HTTP \(status)" : "\(message) (HTTP \(status))"
            case .unreadableAnswer: "Gmail's answer could not be read."
            case .invalidID(let id): "Not a Gmail ID: \(id)"
            }
        }
    }

    func profile() async throws -> ToolJSON {
        try await get("users/me/profile")
    }

    func get(_ path: String, _ query: [URLQueryItem] = []) async throws -> ToolJSON {
        try await send(method: "GET", path: path, query: query, body: nil)
    }

    func post(_ path: String, _ body: ToolJSON) async throws -> ToolJSON {
        try await send(method: "POST", path: path, query: [], body: body)
    }

    /// A Gmail ID as a path segment: message, thread, draft, and label IDs are letters, digits,
    /// `_`, `-`, `:`, and `.`.
    static func segment(_ id: String) throws -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-:.")
        guard !id.isEmpty, id.count <= 256, id.unicodeScalars.allSatisfy(allowed.contains) else {
            throw Failure.invalidID(id)
        }
        return id
    }

    private func send(method: String, path: String, query: [URLQueryItem], body: ToolJSON?) async throws -> ToolJSON {
        var components = URLComponents(url: base.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            components.queryItems = query
            // `+` is a space to Google's query parser; Gmail's `+word` operator needs it kept.
            components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        }
        let url = components.url!
        let payload = try body.map { try JSONEncoder().encode($0) }
        let (data, response) = try await session.send {
            var request = URLRequest(url: url, timeoutInterval: 30)
            request.httpMethod = method
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if let payload {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = payload
            }
            return request
        }
        guard (200..<300).contains(response.statusCode) else {
            let message = (try? JSONDecoder().decode(ToolJSON.self, from: data))?["error"]?["message"]?.stringValue ?? ""
            throw Failure.http(status: response.statusCode, message: message)
        }
        if data.isEmpty { return .object([:]) }
        guard let json = try? JSONDecoder().decode(ToolJSON.self, from: data) else { throw Failure.unreadableAnswer }
        return json
    }
}

/// A Gmail message resource read into the fields the tools return: headers by name, the date in
/// the Mac's time zone, the plain-text and HTML bodies decoded with their charset, and the
/// attachments' names.
struct GmailMessage {
    let json: ToolJSON

    var id: String? { json["id"]?.stringValue }
    var threadId: String? { json["threadId"]?.stringValue }
    var labelIds: [String] { json["labelIds"]?.arrayValue?.compactMap(\.stringValue) ?? [] }
    var snippet: String? { json["snippet"]?.stringValue.map(GmailText.decodeEntities) }

    /// A header's value; names are case-insensitive (`Message-ID`, `Message-Id`).
    func header(_ name: String) -> String? {
        let wanted = name.lowercased()
        return json["payload"]?["headers"]?.arrayValue?.first {
            $0["name"]?.stringValue?.lowercased() == wanted
        }?["value"]?.stringValue
    }

    /// `internalDate` (milliseconds since 1970) as local ISO 8601.
    var date: String? {
        let raw: Double? = switch json["internalDate"] {
        case .string(let text)?: Double(text)
        case .integer(let value)?: Double(value)
        case .number(let value)?: value
        default: nil
        }
        guard let raw else { return header("Date") }
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .autoupdatingCurrent
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date(timeIntervalSince1970: raw / 1000))
    }

    /// The fields one format returns.
    func output(_ format: GmailToolCatalog.Format, bodyLimit: Int = GmailText.bodyLimit) -> ToolJSON {
        var fields: [String: ToolJSON] = [:]
        func put(_ key: String, _ value: String?) {
            if let value, !value.isEmpty { fields[key] = .string(value) }
        }
        put("id", id)
        put("threadId", threadId)
        put("date", date)
        put("from", header("From"))
        put("to", header("To"))
        put("cc", header("Cc"))
        put("bcc", header("Bcc"))
        fields["labelIds"] = .array(labelIds.map { .string($0) })
        fields["unread"] = .bool(labelIds.contains("UNREAD"))
        guard format != .metadataOnly else { return .object(fields) }
        put("subject", header("Subject"))
        put("snippet", snippet)
        guard format == .plainText || format == .fullContent else { return .object(fields) }
        let parts = GmailMessage.parts(json["payload"])
        let plain = parts.plain ?? parts.html.map(GmailText.plainText(fromHTML:))
        put("body", plain.map { GmailText.limited($0, to: bodyLimit) })
        if format == .fullContent { put("htmlBody", parts.html.map { GmailText.limited($0, to: bodyLimit) }) }
        if !parts.attachments.isEmpty { fields["attachments"] = .array(parts.attachments) }
        return .object(fields)
    }

    /// The first plain-text and HTML parts, and the attachments, from a payload's part tree.
    static func parts(_ payload: ToolJSON?) -> (plain: String?, html: String?, attachments: [ToolJSON]) {
        var plain: String?
        var html: String?
        var attachments: [ToolJSON] = []
        func walk(_ part: ToolJSON, depth: Int) {
            guard depth < 32 else { return }
            let mimeType = part["mimeType"]?.stringValue?.lowercased() ?? ""
            let filename = part["filename"]?.stringValue ?? ""
            let body = part["body"]
            if !filename.isEmpty, !mimeType.hasPrefix("multipart/") {
                var item: [String: ToolJSON] = ["filename": .string(filename), "mimeType": .string(mimeType)]
                if let size = body?["size"] { item["size"] = size }
                attachments.append(.object(item))
            } else if let data = body?["data"]?.stringValue, let decoded = decode(data, charset: charset(of: part)) {
                if mimeType == "text/plain", plain == nil { plain = decoded }
                if mimeType == "text/html", html == nil { html = decoded }
            }
            for child in part["parts"]?.arrayValue ?? [] { walk(child, depth: depth + 1) }
        }
        if let payload { walk(payload, depth: 0) }
        return (plain, html, attachments)
    }

    private static func charset(of part: ToolJSON) -> String? {
        let contentType = part["headers"]?.arrayValue?.first {
            $0["name"]?.stringValue?.lowercased() == "content-type"
        }?["value"]?.stringValue ?? ""
        guard let range = contentType.range(of: "charset=", options: .caseInsensitive) else { return nil }
        let rest = contentType[range.upperBound...]
        let value = rest.prefix { $0 != ";" }.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
        return value.isEmpty ? nil : value
    }

    /// A part's `body.data`: base64url of the decoded content, in the part's own charset.
    static func decode(_ base64URL: String, charset: String?) -> String? {
        var text = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        text = text.filter { !$0.isWhitespace }
        while text.count % 4 != 0 { text.append("=") }
        guard let data = Data(base64Encoded: text) else { return nil }
        if let charset {
            let cf = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
            if cf != kCFStringEncodingInvalidId,
               let decoded = String(data: data, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))) {
                return decoded
            }
        }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }
}

/// Text conversions for message bodies.
enum GmailText {
    /// The longest body one message returns, in characters; the rest is cut with a note.
    static let bodyLimit = 40_000

    static func limited(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "\n[… \(text.count - limit) more characters]"
    }

    /// Readable text from an HTML body: no scripts or styles, line breaks where blocks end.
    static func plainText(fromHTML html: String) -> String {
        var text = html
        func replace(_ pattern: String, _ template: String) {
            text = text.replacingOccurrences(of: pattern, with: template, options: [.regularExpression, .caseInsensitive])
        }
        replace("<(script|style|head)[^>]*>[\\s\\S]*?</\\1>", "")
        replace("<br\\s*/?>", "\n")
        replace("</(p|div|li|tr|h[1-6]|blockquote|table)>", "\n")
        replace("<li[^>]*>", "• ")
        replace("<[^>]+>", "")
        text = decodeEntities(text)
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        var result: [String] = []
        for line in lines where !(line.isEmpty && (result.last?.isEmpty ?? true)) { result.append(line) }
        return result.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The HTML entities snippets and bodies carry: named basics and numeric references.
    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let named = ["&nbsp;": " ", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&apos;": "'", "&#39;": "'"]
        var result = text
        for (entity, value) in named { result = result.replacingOccurrences(of: entity, with: value) }
        let pattern = try! NSRegularExpression(pattern: "&#(x[0-9a-fA-F]+|[0-9]+);")
        let source = result as NSString
        var output = ""
        var last = 0
        for match in pattern.matches(in: result, range: NSRange(location: 0, length: source.length)) {
            output += source.substring(with: NSRange(location: last, length: match.range.location - last))
            let digits = source.substring(with: match.range(at: 1))
            let value = digits.hasPrefix("x") ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits)
            if let value, let scalar = Unicode.Scalar(value) { output.append(Character(scalar)) }
            else { output += source.substring(with: match.range) }
            last = match.range.location + match.range.length
        }
        output += source.substring(from: last)
        return output.replacingOccurrences(of: "&amp;", with: "&")
    }
}

/// An RFC 5322 message for a draft or a send, as `raw` (base64url): UTF-8 bodies in base64, a
/// non-ASCII subject or display name as RFC 2047 encoded words, and a reply's `In-Reply-To` and
/// `References`. Gmail fills `From` with the signed-in account.
struct GmailOutgoingMessage: Equatable {
    var to: [String] = []
    var cc: [String] = []
    var bcc: [String] = []
    var subject = ""
    var body: String?
    var htmlBody: String?
    var inReplyTo: String?
    var references: String?
    var boundary = "yardlet-" + UUID().uuidString.lowercased()

    enum Problem: Error, Equatable, LocalizedError {
        case invalidAddress(String)
        case noRecipients

        var errorDescription: String? {
            switch self {
            case .invalidAddress(let address): "Not an email address: \(address)"
            case .noRecipients: "Give at least one recipient in to, cc, or bcc."
            }
        }
    }

    /// Plain addresses or `Name <address>`, one line each.
    static func validated(_ addresses: [String]) throws -> [String] {
        try addresses.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.map { address in
            // By scalar: "\r\n" is one Character, neither "\r" nor "\n".
            guard address.contains("@"),
                  !address.unicodeScalars.contains(where: { CharacterSet.newlines.contains($0) || $0 == "," }) else {
                throw Problem.invalidAddress(address)
            }
            return address
        }
    }

    var hasRecipients: Bool { !(to.isEmpty && cc.isEmpty && bcc.isEmpty) }

    var mime: String {
        var lines: [String] = []
        if !to.isEmpty { lines.append("To: " + to.map(Self.encodedAddress).joined(separator: ", ")) }
        if !cc.isEmpty { lines.append("Cc: " + cc.map(Self.encodedAddress).joined(separator: ", ")) }
        if !bcc.isEmpty { lines.append("Bcc: " + bcc.map(Self.encodedAddress).joined(separator: ", ")) }
        lines.append("Subject: " + Self.encodedWords(Self.oneLine(subject)))
        if let inReplyTo { lines.append("In-Reply-To: " + Self.oneLine(inReplyTo)) }
        if let references { lines.append("References: " + Self.oneLine(references)) }
        lines.append("MIME-Version: 1.0")
        let plain = body ?? htmlBody.map(GmailText.plainText(fromHTML:)) ?? ""
        if let htmlBody {
            lines.append("Content-Type: multipart/alternative; boundary=\"\(boundary)\"")
            lines.append("")
            lines += ["--\(boundary)"] + Self.part("text/plain", plain)
            lines += ["--\(boundary)"] + Self.part("text/html", htmlBody)
            lines.append("--\(boundary)--")
        } else {
            lines += Self.part("text/plain", plain)
        }
        return lines.joined(separator: "\r\n")
    }

    /// The message as Gmail's `raw` field takes it.
    var raw: String { ConnectorOAuth.base64URL(Data(mime.utf8)) }

    private static func part(_ type: String, _ text: String) -> [String] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n")
        return ["Content-Type: \(type); charset=\"UTF-8\"", "Content-Transfer-Encoding: base64", "",
                Data(normalized.utf8).base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn,
                                                                     .endLineWithLineFeed]), ""]
    }

    private static func oneLine(_ text: String) -> String {
        text.components(separatedBy: .newlines).joined(separator: " ")
    }

    /// `Name <address>` with a non-ASCII name as encoded words; the address as it is.
    static func encodedAddress(_ address: String) -> String {
        guard address.unicodeScalars.contains(where: { !$0.isASCII }),
              let open = address.lastIndex(of: "<"), address.hasSuffix(">") else { return address }
        let name = address[..<open].trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"")))
        return encodedWords(name) + " " + address[open...]
    }

    /// RFC 2047 `=?UTF-8?B?…?=` words of at most 45 bytes each (75 characters encoded), folded
    /// onto continuation lines; ASCII text as it is.
    static func encodedWords(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: { !$0.isASCII }) else { return text }
        var words: [String] = []
        var chunk = ""
        for character in text {
            if chunk.utf8.count + String(character).utf8.count > 45 {
                words.append(chunk)
                chunk = ""
            }
            chunk.append(character)
        }
        if !chunk.isEmpty { words.append(chunk) }
        return words.map { "=?UTF-8?B?\(Data($0.utf8).base64EncodedString())?=" }.joined(separator: "\r\n ")
    }
}
