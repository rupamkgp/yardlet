import Foundation
import YardletAgentTools

/// Yardlet's own OneDrive server: the tools it offers each signed-in Microsoft account, over
/// Microsoft Graph's drive API (learn.microsoft.com/graph/api/resources/onedrive). Names and
/// arguments follow Yardlet's Google Drive tools where the two mean the same (`search_files`,
/// `get_file_metadata`, `read_file_content`, `download_file_content`). Each reaches a harness under
/// the account's slug (`onedrive_search_files`).
///
/// One delegated permission that needs no administrator's consent, `Files.ReadWrite`. Graph has no
/// narrower permission that writes only new files without a file picker, so the code keeps the
/// writes to new files and folders: uploads never replace a file (`conflictBehavior` is `fail` or
/// `rename`), and there is no delete, move, or sharing. Both writes ask the person before every
/// call through the harness's own approval (`approvalRequired`).
enum OneDriveToolCatalog {
    static let searchFiles = "search_files"
    static let listFolder = "list_folder"
    static let getFileMetadata = "get_file_metadata"
    static let readFileContent = "read_file_content"
    static let downloadFileContent = "download_file_content"
    static let uploadFile = "upload_file"
    static let createFolder = "create_folder"

    static let scopes = ["Files.ReadWrite"]

    static let approvalRequired: Set<String> = [uploadFile, createFolder]

    static let conflictBehaviors = ["fail", "rename"]

    private typealias Schema = ConnectorToolSchema

    private static let itemID = Schema.string("An item's ID from another OneDrive tool.")
    private static let pageToken = Schema.string("nextPageToken from the previous page.")

    static let tools: [ToolJSON] = [
        Schema.tool(searchFiles, "Search files",
                    "Searches the drive's file names, metadata, and content for words, including files shared with the account.",
                    properties: [
                        "query": Schema.string("Words to look for."),
                        "pageSize": Schema.integer("Items per page, 1 to 200. Defaults to 25.", 1...200),
                        "pageToken": pageToken
                    ], required: ["query"], readOnly: true),
        Schema.tool(listFolder, "List folder",
                    "Lists the files and folders in a folder, the drive's top folder by default.",
                    properties: [
                        "folderId": Schema.string("A folder's ID. Defaults to the top folder."),
                        "pageSize": Schema.integer("Items per page, 1 to 200. Defaults to 50.", 1...200),
                        "pageToken": pageToken
                    ], readOnly: true),
        Schema.tool(getFileMetadata, "Get file metadata",
                    "Reads an item's name, type, size, folder, link, and who changed it last.",
                    properties: ["itemId": itemID], required: ["itemId"], readOnly: true),
        Schema.tool(readFileContent, "Read file content",
                    "Reads a text file (txt, md, csv, json, xml, html, code) as text, up to 100,000 characters. Word, "
                        + "Excel, PowerPoint, PDF, and images: use download_file_content.",
                    properties: ["itemId": itemID], required: ["itemId"], readOnly: true),
        Schema.tool(downloadFileContent, "Download file content",
                    "Downloads a file of up to 5 MB as base64, with its name and type.",
                    properties: ["itemId": itemID], required: ["itemId"], readOnly: true),
        Schema.tool(uploadFile, "Upload file",
                    "Creates a new file of up to 4 MB in a folder. It never replaces a file: with the same name it fails, "
                        + "or with conflictBehavior rename gets a new name.",
                    properties: [
                        "name": Schema.string("The new file's name, such as notes.md."),
                        "folderId": Schema.string("The folder to put it in. Defaults to the top folder."),
                        "content": Schema.string("Text content."),
                        "contentBase64": Schema.string("Binary content as base64, in place of content."),
                        "mimeType": Schema.string("Its type. Defaults to text/plain for content, application/octet-stream otherwise."),
                        "conflictBehavior": Schema.enumeration("fail (default) or rename.", conflictBehaviors)
                    ], required: ["name"], readOnly: false, openWorld: true),
        Schema.tool(createFolder, "Create folder",
                    "Creates a folder. With the same name already there it fails, or with conflictBehavior rename gets a new name.",
                    properties: [
                        "name": Schema.string("The folder's name."),
                        "parentFolderId": Schema.string("The folder to create it in. Defaults to the top folder."),
                        "conflictBehavior": Schema.enumeration("fail (default) or rename.", conflictBehaviors)
                    ], required: ["name"], readOnly: false, openWorld: true)
    ]
}
