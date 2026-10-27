import Foundation
@testable import NativeHarnessClient
@testable import YardletAgentTools

/// Google's sign-in and Gmail API (`FakeGoogle`) with the Calendar API v3 and the Drive API v3 for
/// a couple of accounts, as their references describe requests and answers. Each call is answered
/// for the account its bearer token belongs to. Nothing leaves the machine.
final class FakeGoogleWorkspace: ConnectorHTTPTransport, @unchecked Sendable {
    static let endpoints = GoogleOAuth.Endpoints(
        authorization: FakeGoogle.endpoints.authorization,
        token: FakeGoogle.endpoints.token,
        gmailAPI: FakeGoogle.endpoints.gmailAPI,
        calendarAPI: URL(string: "https://calendar.google.test/calendar/v3/")!,
        driveAPI: URL(string: "https://drive.google.test/drive/v3/")!,
        driveUpload: URL(string: "https://drive.google.test/upload/drive/v3/")!)

    static let holidays = "ko.south_korea#holiday@group.v.calendar.google.com"
    static let allScopes = GoogleOAuth.scope(for: LocalConnectorService.allCases)

    /// One request as the fake saw it: method, path as sent (percent-encoded), query, and body.
    struct Seen {
        var method: String
        var path: String
        var query: [String: [String]]
        var body: Data?
        var account: String?

        func value(_ name: String) -> String? { query[name]?.first }
        var json: ToolJSON? { body.flatMap { try? JSONDecoder().decode(ToolJSON.self, from: $0) } }
    }

    let google: FakeGoogle
    private let lock = NSLock()
    private var seen: [Seen] = []
    private var created = 0
    /// Files this fake's Drive says Yardlet created, which `drive.file` lets it change.
    private var appFiles: Set<String> = ["app-note"]

    init(granting scope: String? = FakeGoogleWorkspace.allScopes) {
        google = FakeGoogle()
        google.grantedScope = scope
    }

    var requests: [Seen] { lock.withLock { seen } }

    /// Calendar and Drive requests, in order.
    func calls(_ method: String? = nil, _ path: String? = nil) -> [Seen] {
        requests.filter { (method == nil || $0.method == method) && (path == nil || $0.path == path) }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url, let host = url.host(), host == "calendar.google.test" || host == "drive.google.test" else {
            return try await google.send(request)
        }
        let account = google.account(of: request)
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var query: [String: [String]] = [:]
        for item in components?.queryItems ?? [] { query[item.name, default: []].append(item.value ?? "") }
        let entry = Seen(method: request.httpMethod ?? "GET", path: components?.percentEncodedPath ?? url.path(),
                         query: query, body: request.httpBody, account: account)
        lock.withLock { seen.append(entry) }
        guard let account else {
            return reply(url, 401, ["error": .object(["code": .integer(401), "message": .string("Request had invalid authentication credentials.")])])
        }
        if host == "calendar.google.test" { return calendar(url, entry, account: account) }
        return drive(url, entry, account: account, contentType: request.value(forHTTPHeaderField: "Content-Type"))
    }

    // MARK: Calendar

    static func event(_ id: String, account: String, invited: Bool = true) -> [String: ToolJSON] {
        var attendees: [ToolJSON] = [
            .object(["email": .string("bob@example.com"), "responseStatus": .string("accepted"), "organizer": .bool(true)])
        ]
        if invited {
            attendees.append(.object(["email": .string(account), "responseStatus": .string("needsAction"), "self": .bool(true)]))
        }
        return [
            "id": .string(id), "summary": .string("Design review \(id)"), "status": .string("confirmed"),
            "htmlLink": .string("https://calendar.google.com/event?eid=\(id)"),
            "start": .object(["dateTime": .string("2026-10-21T10:00:00+09:00"), "timeZone": .string("Asia/Seoul")]),
            "end": .object(["dateTime": .string("2026-10-21T11:00:00+09:00"), "timeZone": .string("Asia/Seoul")]),
            "organizer": .object(["email": .string("bob@example.com")]),
            "attendees": .array(attendees),
            "hangoutLink": .string("https://meet.google.com/abc-defg-hij"),
            "description": .string("Agenda: the new setup assistant"),
            "transparency": .string("opaque"),
            "etag": .string("\"3381\""), "iCalUID": .string("\(id)@google.com")
        ]
    }

    private func calendar(_ url: URL, _ call: Seen, account: String) -> (Data, HTTPURLResponse) {
        let path = call.path.replacingOccurrences(of: "/calendar/v3/", with: "")
        switch (call.method, path) {
        case ("GET", "users/me/calendarList"):
            return reply(url, 200, ["items": .array([
                .object(["id": .string(account), "summary": .string(account), "timeZone": .string("Asia/Seoul"),
                         "accessRole": .string("owner"), "primary": .bool(true), "etag": .string("\"1\"")]),
                .object(["id": .string(Self.holidays), "summary": .string("Holidays in South Korea"),
                         "summaryOverride": .string("공휴일"), "timeZone": .string("Asia/Seoul"), "accessRole": .string("reader")])
            ]), "nextPageToken": .string("calendars-2")])
        case ("GET", "users/me/calendarList/primary"):
            return reply(url, 200, ["id": .string(account), "timeZone": .string("Asia/Seoul"), "primary": .bool(true)])
        case ("POST", "freeBusy"):
            return reply(url, 200, ["calendars": .object([
                "primary": .object(["busy": .array([
                    .object(["start": .string("2026-10-21T00:00:00Z"), "end": .string("2026-10-21T01:30:00Z")])
                ])]),
                "bob@example.com": .object(["busy": .array([
                    .object(["start": .string("2026-10-21T01:00:00Z"), "end": .string("2026-10-21T02:10:00Z")])
                ])]),
                "nobody@example.com": .object(["errors": .array([.object(["domain": .string("global"), "reason": .string("notFound")])]),
                                               "busy": .array([])])
            ])])
        default:
            break
        }
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count >= 3, parts[0] == "calendars", parts[2] == "events" else { return notFound(url) }
        let calendar = parts[1].removingPercentEncoding ?? parts[1]
        switch (call.method, parts.count) {
        case ("GET", 3):
            return reply(url, 200, ["items": .array([.object(Self.event("e1", account: account)),
                                                     .object(Self.event("e2", account: account))]),
                                    "nextPageToken": .string("events-2"), "timeZone": .string("Asia/Seoul"),
                                    "summary": .string(calendar)])
        case ("POST", 3):
            var event = call.json?.objectValue ?? [:]
            let id = lock.withLock { created += 1; return "new-\(created)" }
            event["id"] = .string(id)
            event["status"] = .string("confirmed")
            event["htmlLink"] = .string("https://calendar.google.com/event?eid=\(id)")
            if event["conferenceData"] != nil, call.value("conferenceDataVersion") == "1" {
                event["hangoutLink"] = .string("https://meet.google.com/new-meet-\(id)")
            }
            return reply(url, 200, event)
        case ("GET", 4):
            switch parts[3] {
            case "e1": return reply(url, 200, Self.event("e1", account: account))
            case "not-invited": return reply(url, 200, Self.event("not-invited", account: account, invited: false))
            default: return notFound(url)
            }
        case ("PATCH", 4):
            guard parts[3] == "e1" || parts[3] == "not-invited" else { return notFound(url) }
            var event = Self.event(parts[3], account: account)
            for (key, value) in call.json?.objectValue ?? [:] { event[key] = value }
            return reply(url, 200, event)
        case ("DELETE", 4):
            guard parts[3] == "e1" else { return notFound(url) }
            return (Data(), HTTPURLResponse(url: url, statusCode: 204, httpVersion: "HTTP/1.1", headerFields: [:])!)
        default:
            return notFound(url)
        }
    }

    // MARK: Drive

    static let document = GoogleDriveToolCatalog.document
    static let spreadsheet = GoogleDriveToolCatalog.spreadsheet

    static func file(_ id: String, name: String, mimeType: String, size: Int? = nil) -> [String: ToolJSON] {
        var file: [String: ToolJSON] = [
            "id": .string(id), "name": .string(name), "mimeType": .string(mimeType),
            "createdTime": .string("2026-10-01T00:00:00.000Z"), "modifiedTime": .string("2026-10-18T09:30:00.000Z"),
            "owners": .array([.object(["emailAddress": .string("person@example.test"), "displayName": .string("Person")])]),
            "parents": .array([.string("folder-1")]),
            "webViewLink": .string("https://drive.google.com/file/d/\(id)/view"),
            "starred": .bool(false), "shared": .bool(true)
        ]
        if let size { file["size"] = .string(String(size)) }
        return file
    }

    static let files: [String: [String: ToolJSON]] = [
        "doc-1": file("doc-1", name: "Launch plan", mimeType: document),
        "sheet-1": file("sheet-1", name: "Budget", mimeType: spreadsheet),
        "slides-1": file("slides-1", name: "Kickoff", mimeType: GoogleDriveToolCatalog.presentation),
        "notes-1": file("notes-1", name: "notes.md", mimeType: "text/markdown", size: 24),
        "pdf-1": file("pdf-1", name: "contract.pdf", mimeType: "application/pdf", size: 8),
        "huge-1": file("huge-1", name: "video.mov", mimeType: "video/quicktime", size: 900_000_000),
        "app-note": file("app-note", name: "Yardlet note", mimeType: document)
    ]

    static let pdfBytes = Data([0x25, 0x50, 0x44, 0x46, 0x2D, 0x31, 0x2E, 0x37])

    private func drive(_ url: URL, _ call: Seen, account: String, contentType: String?) -> (Data, HTTPURLResponse) {
        let upload = call.path.hasPrefix("/upload/drive/v3/")
        let path = call.path.replacingOccurrences(of: upload ? "/upload/drive/v3/" : "/drive/v3/", with: "")
        let parts = path.split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) }
        switch (call.method, parts.first, parts.count) {
        case ("GET", "about"?, 1):
            return reply(url, 200, ["user": .object(["emailAddress": .string(account), "displayName": .string("Person")])])
        case ("GET", "files"?, 1):
            return reply(url, 200, ["files": .array([.object(Self.files["doc-1"]!), .object(Self.files["sheet-1"]!)]),
                                    "nextPageToken": .string("files-2")])
        case ("POST", "files"?, 1):
            let id = lock.withLock { created += 1; appFiles.insert("made-\(created)"); return "made-\(created)" }
            var metadata: [String: ToolJSON]
            var content: String?
            if upload {
                guard call.value("uploadType") == "multipart", contentType?.hasPrefix("multipart/related; boundary=") == true,
                      let (json, body) = Self.multipart(call.body, contentType: contentType!) else { return badRequest(url) }
                metadata = json
                content = body
            } else {
                metadata = call.json?.objectValue ?? [:]
            }
            var file = Self.file(id, name: metadata["name"]?.stringValue ?? "Untitled",
                                 mimeType: metadata["mimeType"]?.stringValue ?? "application/octet-stream")
            if let parents = metadata["parents"] { file["parents"] = parents }
            if let content { file["size"] = .string(String(content.utf8.count)) }
            return reply(url, 200, file)
        case (_, "files"?, _):
            break
        default:
            return notFound(url)
        }
        let id = parts[1]
        let madeHere = lock.withLock { appFiles.contains(id) }
        guard var file = Self.files[id] ?? (madeHere ? Self.file(id, name: "Made by Yardlet", mimeType: Self.document) : nil)
        else { return notFound(url) }
        switch (call.method, parts.count, parts.count > 2 ? parts[2] : nil) {
        case ("GET", 2, nil):
            if call.value("alt") == "media" {
                switch id {
                case "notes-1": return (Data("# Notes\n- ship it\n".utf8), Self.ok(url, type: "text/markdown"))
                case "pdf-1": return (Self.pdfBytes, Self.ok(url, type: "application/pdf"))
                default: return reply(url, 403, ["error": .object(["message": .string("Only files with binary content can be downloaded.")])])
                }
            }
            return reply(url, 200, file)
        case ("GET", 3, "export"?):
            switch (id, call.value("mimeType")) {
            case ("doc-1", "text/markdown"?): return (Data("# Launch plan\n\n1. Ship\n".utf8), Self.ok(url, type: "text/markdown"))
            case ("doc-1", "text/plain"?): return (Data("Launch plan\n1. Ship\n".utf8), Self.ok(url, type: "text/plain"))
            case ("doc-1", "application/pdf"?): return (Self.pdfBytes, Self.ok(url, type: "application/pdf"))
            case ("sheet-1", "text/csv"?): return (Data("item,cost\nservers,120\n".utf8), Self.ok(url, type: "text/csv"))
            case ("slides-1", "text/plain"?): return (Data("Kickoff\nGoals".utf8), Self.ok(url, type: "text/plain"))
            default: return badRequest(url)
            }
        case ("GET", 3, "permissions"?):
            return reply(url, 200, ["permissions": .array([
                .object(["id": .string("p1"), "type": .string("user"), "role": .string("owner"),
                         "emailAddress": .string("person@example.test"), "displayName": .string("Person")]),
                .object(["id": .string("p2"), "type": .string("domain"), "role": .string("reader"), "domain": .string("company.test")])
            ])])
        case ("GET", 3, "comments"?):
            return reply(url, 200, ["comments": .array([.object([
                "id": .string("c1"), "content": .string("Is this the final date?"), "resolved": .bool(false),
                "quotedFileContent": .object(["value": .string("1. Ship")]),
                "author": .object(["displayName": .string("Bob")]), "modifiedTime": .string("2026-10-18T10:00:00Z"),
                "replies": .array([.object(["content": .string("Yes."), "author": .object(["displayName": .string("Person")])])])
            ])])])
        case ("POST", 3, "copy"?):
            let copy = lock.withLock { created += 1; appFiles.insert("copy-\(created)"); return "copy-\(created)" }
            let body = call.json?.objectValue ?? [:]
            var made = Self.file(copy, name: body["name"]?.stringValue ?? "Copy of \(file["name"]?.stringValue ?? "")",
                                 mimeType: file["mimeType"]?.stringValue ?? Self.document)
            if let parents = body["parents"] { made["parents"] = parents }
            return reply(url, 200, made)
        case ("PATCH", 2, nil):
            // `drive.file` reaches only files the app created or copied.
            guard madeHere else {
                return reply(url, 403, ["error": .object(["code": .integer(403),
                    "message": .string("The user has not granted the app 123 write access to the file \(id).")])])
            }
            var metadata = call.json?.objectValue ?? [:]
            if upload {
                guard let (json, _) = Self.multipart(call.body, contentType: contentType ?? "") else { return badRequest(url) }
                metadata = json
            }
            for (key, value) in metadata { file[key] = value }
            if let add = call.value("addParents") { file["parents"] = .array([.string(add)]) }
            return reply(url, 200, file)
        default:
            return notFound(url)
        }
    }

    /// A `multipart/related` upload's JSON metadata and its content as text.
    static func multipart(_ body: Data?, contentType: String) -> ([String: ToolJSON], String)? {
        guard let body, let boundary = contentType.components(separatedBy: "boundary=").last else { return nil }
        let text = String(decoding: body, as: UTF8.self)
        // Before the first boundary nothing; after the last, `--`. Each part is CRLF, its headers,
        // a blank line, its content, and the CRLF before the next boundary.
        let sections = text.components(separatedBy: "--\(boundary)").dropFirst().filter { !$0.hasPrefix("--") }
        guard sections.count == 2 else { return nil }
        func content(_ section: String) -> String {
            var part = section
            if part.hasPrefix("\r\n") { part.removeFirst() }
            if part.hasSuffix("\r\n") { part.removeLast() }
            return part.components(separatedBy: "\r\n\r\n").dropFirst().joined(separator: "\r\n\r\n")
        }
        guard let metadata = try? JSONDecoder().decode(ToolJSON.self, from: Data(content(sections[0]).utf8)).objectValue else { return nil }
        return (metadata, content(sections[1]))
    }

    // MARK: Answers

    private func reply(_ url: URL, _ status: Int, _ body: [String: ToolJSON]) -> (Data, HTTPURLResponse) {
        ((try? JSONEncoder().encode(ToolJSON.object(body))) ?? Data(), Self.ok(url, status: status))
    }

    private func notFound(_ url: URL) -> (Data, HTTPURLResponse) {
        reply(url, 404, ["error": .object(["code": .integer(404), "message": .string("Not Found")])])
    }

    private func badRequest(_ url: URL) -> (Data, HTTPURLResponse) {
        reply(url, 400, ["error": .object(["code": .integer(400), "message": .string("Bad Request")])])
    }

    private static func ok(_ url: URL, status: Int = 200, type: String = "application/json") -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": type])!
    }
}
