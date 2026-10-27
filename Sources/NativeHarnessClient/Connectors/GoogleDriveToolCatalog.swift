import Foundation
import YardletAgentTools

/// Yardlet's own Google Drive server: the tools it offers each signed-in Google account, named and
/// shaped as the claude.ai Google Drive connector names them (`search_files`, `list_recent_files`,
/// `get_file_metadata`, `get_file_permissions`, `read_file_content`, `download_file_content`,
/// `create_file`, `copy_file`, which are Google's Drive MCP server's), plus `update_file` for
/// changing a file it created, over the public Drive API v3, and the Docs, Sheets, and Slides tools
/// for what is inside those files (`GoogleEditorsToolCatalog`). Each reaches a harness under the
/// account's slug (`drive_search_files`).
///
/// Two scopes: `drive.readonly` (restricted) reads every file, and `drive.file` (non-sensitive)
/// creates files and changes the ones Yardlet created; Yardlet never asks for full `drive`, so it
/// cannot change or delete the person's other files. Creating, copying, and changing a file ask
/// before every call through the harness's own approval (`approvalRequired`).
enum GoogleDriveToolCatalog {
    static let searchFiles = "search_files"
    static let listRecentFiles = "list_recent_files"
    static let getFileMetadata = "get_file_metadata"
    static let getFilePermissions = "get_file_permissions"
    static let readFileContent = "read_file_content"
    static let downloadFileContent = "download_file_content"
    static let createFile = "create_file"
    static let copyFile = "copy_file"
    static let updateFile = "update_file"

    static let readScope = "https://www.googleapis.com/auth/drive.readonly"
    static let fileScope = "https://www.googleapis.com/auth/drive.file"
    static let scopes = [readScope, fileScope]

    static let approvalRequired: Set<String> = Set([createFile, copyFile, updateFile])
        .union(GoogleEditorsToolCatalog.approvalRequired)

    static let document = "application/vnd.google-apps.document"
    static let spreadsheet = "application/vnd.google-apps.spreadsheet"
    static let presentation = "application/vnd.google-apps.presentation"
    static let folder = "application/vnd.google-apps.folder"

    static let tools: [ToolJSON] = [
        tool(searchFiles, "Search files",
             "Searches Drive with a query (title contains 'plan' and mimeType = '\(document)'). Terms: title, fullText, "
                + "mimeType, modifiedTime, parentId, owner, sharedWithMe, starred. Plain words search the full text.",
             properties: [
                "query": string("The query: query_term operator value clauses joined by and, or, not; strings in single quotes."),
                "pageSize": integer("Files per page, 1 to 100. Defaults to 10.", 1...100),
                "pageToken": string("nextPageToken from the previous page.")
             ], readOnly: true),
        tool(listRecentFiles, "List recent files",
             "Lists the account's files, latest first, by recency (default), lastModified, or lastModifiedByMe.",
             properties: [
                "orderBy": .object(["type": .string("string"), "enum": .array(["recency", "lastModified", "lastModifiedByMe"].map(ToolJSON.string)),
                                    "description": .string("The order: recency, lastModified, or lastModifiedByMe.")]),
                "pageSize": integer("Files per page, 1 to 100. Defaults to 10.", 1...100),
                "pageToken": string("nextPageToken from the previous page.")
             ], readOnly: true),
        tool(getFileMetadata, "Get file metadata",
             "Gets a file's title, type, size, owner, folder, times, and link.",
             properties: ["fileId": fileID], required: ["fileId"], readOnly: true),
        tool(getFilePermissions, "Get file permissions",
             "Lists who can reach a file and with which role.",
             properties: ["fileId": fileID], required: ["fileId"], readOnly: true),
        tool(readFileContent, "Read file content",
             "Reads a file as text: a Google Doc as Markdown, a Sheet's first sheet as CSV, Slides as text, and text files "
                + "as they are. Very long content is cut.",
             properties: [
                "fileId": fileID,
                "includeComments": .object(["type": .string("boolean"),
                                            "description": .string("Adds the file's comment threads after its content.")])
             ], required: ["fileId"], readOnly: true),
        tool(downloadFileContent, "Download file content",
             "Downloads a file's bytes as base64, up to 5 MB. A Google Doc, Sheet, or Slides file is exported, as text "
                + "unless exportMimeType names another type.",
             properties: [
                "fileId": fileID,
                "exportMimeType": string("For a Google Doc, Sheet, or Slides file: the type to export to (application/pdf)."),
                "revisionId": string("A revision's ID for an earlier version of a file that is not a Google type.")
             ], required: ["fileId"], readOnly: true),
        tool(createFile, "Create file",
             "Creates a file from textContent or base64Content, or an empty Google Doc, Sheet, Slides, or folder by "
                + "mimeType. Text, CSV, and Office content becomes the Google type unless disableConversionToGoogleType.",
             properties: [
                "title": string("The file's title."),
                "textContent": string("UTF-8 text content."),
                "base64Content": string("Base64 content for anything that is not UTF-8 text."),
                "contentMimeType": string("The content's type (text/plain, text/csv, text/markdown, application/pdf). "
                    + "Defaults to text/plain for textContent."),
                "mimeType": string("Without content: \(document), \(spreadsheet), \(presentation), or \(folder)."),
                "parentId": string("The folder to create it in. Defaults to My Drive."),
                "disableConversionToGoogleType": .object(["type": .string("boolean"),
                                                          "description": .string("Keeps the content's own type.")])
             ], required: ["title"], readOnly: false, openWorld: true),
        tool(copyFile, "Copy file",
             "Copies a file, with a new title and folder if given; the copy is 'Copy of' the title in the same folder otherwise.",
             properties: [
                "fileId": fileID,
                "title": string("The copy's title."),
                "parentId": string("The folder for the copy.")
             ], required: ["fileId"], readOnly: false, openWorld: true),
        tool(updateFile, "Update file",
             "Renames, moves, or replaces the content of a file this connector created or copied; Drive lets Yardlet "
                + "change only those.",
             properties: [
                "fileId": fileID,
                "title": string("A new title."),
                "description": string("A new description."),
                "textContent": string("New UTF-8 text content, in place of the old."),
                "base64Content": string("New base64 content, in place of the old."),
                "contentMimeType": string("The new content's type. Defaults to text/plain for textContent."),
                "parentId": string("The folder to move it to.")
             ], required: ["fileId"], readOnly: false, destructive: true, openWorld: true)
    ] + GoogleEditorsToolCatalog.tools

    // MARK: Schema pieces

    private static var fileID: ToolJSON {
        string("The file's ID, from search_files or list_recent_files, or in its Drive link.")
    }

    private static func string(_ description: String) -> ToolJSON { ConnectorToolSchema.string(description) }

    private static func boolean(_ description: String) -> ToolJSON { ConnectorToolSchema.boolean(description) }

    private static func integer(_ description: String, _ range: ClosedRange<Int>) -> ToolJSON {
        ConnectorToolSchema.integer(description, range)
    }

    private static func tool(_ name: String, _ title: String, _ description: String,
                             properties: [String: ToolJSON], required: [String] = [],
                             readOnly: Bool, destructive: Bool = false, openWorld: Bool = false) -> ToolJSON {
        ConnectorToolSchema.tool(name, title, description, properties: properties, required: required,
                              readOnly: readOnly, destructive: destructive, openWorld: openWorld)
    }
}
