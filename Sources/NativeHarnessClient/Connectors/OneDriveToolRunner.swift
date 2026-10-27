import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import YardletAgentTools

/// Runs one OneDrive tool call against Microsoft Graph and answers with compact JSON text. A file's
/// bytes come from the short-lived download address Graph gives in the item
/// (`@microsoft.graph.downloadUrl`), which carries its own authorization, so the account's token is
/// not sent there. Arguments are checked before any request; Graph's errors and a sign-in that
/// ended are thrown to the connector center.
struct OneDriveToolRunner {
    let api: GraphAPI
    /// Fetches the download address, without the account's token.
    let http: any ConnectorHTTPTransport

    typealias Problem = ConnectorToolArguments.Problem
    private typealias Arguments = ConnectorToolArguments
    private typealias Catalog = OneDriveToolCatalog

    static let textLimit = 100_000
    static let downloadLimit = 5 * 1_024 * 1_024
    static let uploadLimit = 4 * 1_024 * 1_024

    private static let fields = "id,name,size,file,folder,webUrl,createdDateTime,lastModifiedDateTime,lastModifiedBy,parentReference,remoteItem"

    /// Types read as text besides `text/*`.
    private static let textTypes: Set<String> = ["application/json", "application/xml", "application/javascript",
                                                 "application/x-yaml", "application/yaml", "application/x-sh",
                                                 "application/sql", "application/x-ndjson"]
    private static let textExtensions: Set<String> = ["txt", "md", "markdown", "csv", "tsv", "json", "xml", "html", "htm",
                                                      "yaml", "yml", "log", "ini", "toml", "swift", "py", "js", "ts",
                                                      "tsx", "jsx", "java", "kt", "go", "rs", "rb", "sh", "sql", "css"]

    func call(_ name: String, _ arguments: ToolJSON) async throws -> AgentToolResult {
        let arguments = arguments.objectValue ?? [:]
        do {
            switch name {
            case Catalog.searchFiles: return .text(Arguments.text(try await search(arguments)))
            case Catalog.listFolder: return .text(Arguments.text(try await list(arguments)))
            case Catalog.getFileMetadata:
                let id = try GraphAPI.segment(try Arguments.required(arguments, "itemId"))
                return .text(Arguments.text(Self.item(try await api.get(["me", "drive", "items", id],
                                                                        [URLQueryItem(name: "$select", value: Self.fields)]))))
            case Catalog.readFileContent: return .text(Arguments.text(try await read(arguments)))
            case Catalog.downloadFileContent: return .text(Arguments.text(try await download(arguments)))
            case Catalog.uploadFile: return .text(Arguments.text(try await upload(arguments)))
            case Catalog.createFolder: return .text(Arguments.text(try await createFolder(arguments)))
            default: return .error("Unknown tool: \(name)")
            }
        } catch let problem as Problem {
            return .error(problem.localizedDescription)
        } catch GraphAPI.Failure.invalidID(let id) {
            return .error("Not an ID OneDrive takes: \(id)")
        }
    }

    // MARK: Reading

    private func search(_ arguments: [String: ToolJSON]) async throws -> ToolJSON {
        let list: ToolJSON
        if let token = Arguments.string(arguments, "pageToken") {
            list = try await api.get(page: token)
        } else {
            // search(q='…'), a quote in the words doubled.
            let words = try Arguments.required(arguments, "query").replacingOccurrences(of: "'", with: "''")
            let encoded = words.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? words
            list = try await api.get(["me", "drive", "root", "search(q='\(encoded)')"], [
                URLQueryItem(name: "$top", value: String(Arguments.pageSize(arguments, range: 1...200, fallback: 25))),
                URLQueryItem(name: "$select", value: Self.fields)
            ])
        }
        return GraphShape.page(list, key: "files", Self.item)
    }

    private func list(_ arguments: [String: ToolJSON]) async throws -> ToolJSON {
        let list: ToolJSON
        if let token = Arguments.string(arguments, "pageToken") {
            list = try await api.get(page: token)
        } else {
            let folder = try Arguments.string(arguments, "folderId").map(GraphAPI.segment)
            list = try await api.get(folder.map { ["me", "drive", "items", $0, "children"] } ?? ["me", "drive", "root", "children"], [
                URLQueryItem(name: "$top", value: String(Arguments.pageSize(arguments, range: 1...200, fallback: 50))),
                URLQueryItem(name: "$select", value: Self.fields)
            ])
        }
        return GraphShape.page(list, key: "items", Self.item)
    }

    /// The item with its download address, which a folder or a file in another drive lacks.
    private func file(_ arguments: [String: ToolJSON]) async throws -> (item: ToolJSON, download: URL) {
        let id = try GraphAPI.segment(try Arguments.required(arguments, "itemId"))
        let item = try await api.get(["me", "drive", "items", id],
                                     [URLQueryItem(name: "$select", value: Self.fields + ",@microsoft.graph.downloadUrl")])
        guard item["folder"] == nil || item["folder"] == .null else { throw Problem.invalid("That item is a folder: use list_folder.") }
        guard let link = item["@microsoft.graph.downloadUrl"]?.stringValue, let url = URL(string: link), url.scheme == "https" else {
            throw Problem.invalid("OneDrive gave no download address for this item.")
        }
        return (item, url)
    }

    private func bytes(_ url: URL, size: Int?) async throws -> Data {
        if let size, size > Self.downloadLimit { throw GraphAPI.Failure.tooLarge(bytes: size, limit: Self.downloadLimit) }
        let (data, response) = try await http.send(URLRequest(url: url, timeoutInterval: 60))
        guard (200..<300).contains(response.statusCode) else { throw GraphAPI.Failure.http(status: response.statusCode, message: "") }
        guard data.count <= Self.downloadLimit else { throw GraphAPI.Failure.tooLarge(bytes: data.count, limit: Self.downloadLimit) }
        return data
    }

    private func read(_ arguments: [String: ToolJSON]) async throws -> ToolJSON {
        let (item, url) = try await file(arguments)
        let name = item["name"]?.stringValue ?? ""
        let type = item["file"]?["mimeType"]?.stringValue?.lowercased() ?? ""
        let suffix = (name as NSString).pathExtension.lowercased()
        guard type.hasPrefix("text/") || Self.textTypes.contains(type) || Self.textExtensions.contains(suffix) else {
            throw Problem.invalid("\(name) is not a text file. Use download_file_content for its bytes.")
        }
        let data = try await bytes(url, size: ConnectorToolArguments.integer(item["size"]))
        let (text, cut) = GraphShape.cut(String(decoding: data, as: UTF8.self), Self.textLimit)
        var fields = Self.item(item).objectValue ?? [:]
        fields["content"] = .string(text)
        if cut { fields["contentTruncated"] = .bool(true) }
        return .object(fields)
    }

    private func download(_ arguments: [String: ToolJSON]) async throws -> ToolJSON {
        let (item, url) = try await file(arguments)
        let data = try await bytes(url, size: ConnectorToolArguments.integer(item["size"]))
        var fields = Arguments.pick(item, ["id", "name", "size"])
        fields["mimeType"] = item["file"]?["mimeType"] ?? .string("application/octet-stream")
        fields["contentBase64"] = .string(data.base64EncodedString())
        return .object(fields)
    }

    // MARK: Writing

    private func conflictBehavior(_ arguments: [String: ToolJSON]) throws -> String {
        let value = Arguments.string(arguments, "conflictBehavior") ?? "fail"
        guard Catalog.conflictBehaviors.contains(value) else { throw Problem.invalid("conflictBehavior is fail or rename.") }
        return value
    }

    /// A file or folder name OneDrive takes, refused before the request otherwise.
    private func itemName(_ arguments: [String: ToolJSON]) throws -> String {
        let name = try Arguments.required(arguments, "name")
        guard name.count <= 255, !name.contains(where: { "/\\:*?\"<>|".contains($0) }),
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw Problem.invalid("name cannot contain / \\ : * ? \" < > | or a line break.")
        }
        return name
    }

    private func upload(_ arguments: [String: ToolJSON]) async throws -> ToolJSON {
        let name = try itemName(arguments)
        let behavior = try conflictBehavior(arguments)
        let content: Data
        let defaultType: String
        if let base64 = Arguments.string(arguments, "contentBase64") {
            guard let data = Data(base64Encoded: base64) else { throw Problem.invalid("contentBase64 is not base64.") }
            content = data
            defaultType = "application/octet-stream"
        } else {
            content = Data((arguments["content"]?.stringValue ?? "").utf8)
            defaultType = "text/plain; charset=utf-8"
        }
        guard content.count <= Self.uploadLimit else { throw GraphAPI.Failure.tooLarge(bytes: content.count, limit: Self.uploadLimit) }
        let parent = try Arguments.string(arguments, "folderId").map(GraphAPI.segment)
        let target = try GraphAPI.segment(name)
        let path = parent.map { ["me", "drive", "items", "\($0):", "\(target):", "content"] }
            ?? ["me", "drive", "root:", "\(target):", "content"]
        let item = try await api.put(path, [URLQueryItem(name: "@microsoft.graph.conflictBehavior", value: behavior)],
                                     content: content, contentType: Arguments.string(arguments, "mimeType") ?? defaultType)
        return Self.item(item)
    }

    private func createFolder(_ arguments: [String: ToolJSON]) async throws -> ToolJSON {
        let name = try itemName(arguments)
        let behavior = try conflictBehavior(arguments)
        let parent = try Arguments.string(arguments, "parentFolderId").map(GraphAPI.segment)
        let item = try await api.post(parent.map { ["me", "drive", "items", $0, "children"] } ?? ["me", "drive", "root", "children"],
                                      .object(["name": .string(name), "folder": .object([:]),
                                               "@microsoft.graph.conflictBehavior": .string(behavior)]))
        return Self.item(item)
    }

    static func item(_ item: ToolJSON) -> ToolJSON {
        var fields = ConnectorToolArguments.pick(item, ["id", "name", "size", "webUrl", "createdDateTime", "lastModifiedDateTime"])
        if let folder = item["folder"], folder != .null {
            fields["isFolder"] = .bool(true)
            fields["childCount"] = folder["childCount"] ?? .null
        } else if let type = item["file"]?["mimeType"] {
            fields["mimeType"] = type
        }
        if let by = item["lastModifiedBy"]?["user"]?["displayName"] { fields["lastModifiedBy"] = by }
        if let parent = item["parentReference"]?["id"] { fields["parentId"] = parent }
        if let path = item["parentReference"]?["path"]?.stringValue {
            fields["folder"] = .string(path.replacingOccurrences(of: "/drive/root:", with: "").isEmpty ? "/"
                                       : path.replacingOccurrences(of: "/drive/root:", with: ""))
        }
        if item["remoteItem"] != nil, item["remoteItem"] != .null { fields["sharedFromAnotherDrive"] = .bool(true) }
        return .object(fields)
    }
}
