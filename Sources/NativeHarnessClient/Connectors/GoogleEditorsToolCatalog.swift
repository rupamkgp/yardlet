import Foundation
import YardletAgentTools

/// The Google Drive connector's tools for what is inside a Google Doc, Sheet, or Slides file, named
/// and shaped as Google's own Docs, Sheets, and Slides MCP servers name them (`read_doc`,
/// `update_doc`; `get_spreadsheet`, `get_values`, `update_values`, `update_formulas`,
/// `insert_dimension`, `update_spreadsheet`; `read_presentation`, `read_slide_page`,
/// `read_slide_page_thumbnail`, `update_presentation`), over the public Docs API v1, Sheets API v4,
/// and Slides API v1. They reach a harness under the Drive connector's slug (`drive_read_doc`).
///
/// No scope beyond the Drive connector's own: every read method here takes `drive.readonly` and
/// every write method `drive.file` (the methods' "Authorization scopes"), so Yardlet reads every
/// file and changes only the Docs, Sheets, and Slides it created or copied (docs/CONNECTORS.md, "Google").
/// Each write asks before every call, as Drive's do.
enum GoogleEditorsToolCatalog {
    static let readDoc = "read_doc"
    static let updateDoc = "update_doc"
    static let getSpreadsheet = "get_spreadsheet"
    static let getValues = "get_values"
    static let updateValues = "update_values"
    static let updateFormulas = "update_formulas"
    static let insertDimension = "insert_dimension"
    static let updateSpreadsheet = "update_spreadsheet"
    static let readPresentation = "read_presentation"
    static let readSlidePage = "read_slide_page"
    static let readSlidePageThumbnail = "read_slide_page_thumbnail"
    static let updatePresentation = "update_presentation"

    static let approvalRequired: Set<String> = [updateDoc, updateValues, updateFormulas, insertDimension,
                                                updateSpreadsheet, updatePresentation]

    static let names: Set<String> = Set(tools.compactMap { $0["name"]?.stringValue })

    /// The APIs these tools call, which a Google Cloud project turns on beside Drive's.
    static let apiIDs = ["docs.googleapis.com", "sheets.googleapis.com", "slides.googleapis.com"]

    static let tools: [ToolJSON] = [
        // Docs
        tool(readDoc, "Read document",
             "Reads a Google Doc's structure: each paragraph with its style (HEADING_1…) and text, lists, and tables "
                + "cell by cell, with the UTF-16 indexes update_doc takes. A long document comes in parts.",
             properties: [
                "documentId": id("document"),
                "tabId": string("A tab's ID from tabs, for a document with tabs. Defaults to the first tab."),
                "startIndex": integer("Where to go on reading: nextStartIndex from the previous part.", 0...Int(Int32.max)),
                "commentsIncluded": boolean("Adds the document's comment threads.")
             ], required: ["documentId"], readOnly: true),
        tool(updateDoc, "Update document",
             "Applies Docs API batchUpdate requests in order, all or none: insertText, deleteContentRange, replaceAllText, "
                + "updateParagraphStyle, createParagraphBullets, insertTable, and others. Changes only Docs this connector "
                + "created or copied.",
             properties: [
                "documentId": id("document"),
                "requests": requests("documents.batchUpdate Request objects (developers.google.com/workspace/docs/api/"
                    + "reference/rest/v1/documents/request). Indexes are UTF-16, as read_doc gives them; editing from the "
                    + "end of the document first keeps the earlier indexes."),
                "writeControl": object("{\"requiredRevisionId\": revisionId from read_doc} refuses the change if the "
                    + "document changed since; {\"writeMode\": \"SUGGEST\"} makes it suggestions.")
             ], required: ["documentId", "requests"], readOnly: false, destructive: true, openWorld: true),
        // Sheets
        tool(getSpreadsheet, "Get spreadsheet",
             "Gets a spreadsheet's title, locale, time zone, and its sheets with IDs, sizes, and frozen rows. With fields "
                + "or includeGridData it returns the Sheets API's JSON instead.",
             properties: [
                "spreadsheetId": id("spreadsheet"),
                "ranges": stringArray("A1 ranges to limit the answer to (Sheet1!A1:C10)."),
                "includeGridData": boolean("Returns the cells' data and formats too; give ranges to keep it small."),
                "fields": stringArray("Field masks (sheets.properties.title, sheets.data.rowData.values.formattedValue)."),
                "commentsIncluded": boolean("Adds the spreadsheet's comment threads.")
             ], required: ["spreadsheetId"], readOnly: true),
        tool(getValues, "Get values",
             "Reads a range's cells as rows (Sheet1!A1:D50, or a sheet's name for all of it). valueRenderOption FORMULA "
                + "gives the formulas. A large range comes in parts: nextRange goes on.",
             properties: [
                "spreadsheetId": id("spreadsheet"),
                "range": string("The range in A1 notation."),
                "valueRenderOption": GoogleToolSchema.enumeration(
                    "FORMATTED_VALUE (default) as shown, UNFORMATTED_VALUE as numbers, or FORMULA.",
                    ["FORMATTED_VALUE", "UNFORMATTED_VALUE", "FORMULA"])
             ], required: ["spreadsheetId", "range"], readOnly: true),
        tool(updateValues, "Update values",
             "Writes rows of values to a range as they are: numbers stay numbers and text stays text, even with a leading "
                + "=. Changes only Sheets this connector created or copied.",
             properties: [
                "spreadsheetId": id("spreadsheet"),
                "range": string("The range in A1 notation (Sheet1!A1:B2)."),
                "values": rows("Rows of cells: strings, numbers, or booleans; null leaves a cell as it is, \"\" empties it.")
             ], required: ["spreadsheetId", "range", "values"], readOnly: false, destructive: true, openWorld: true),
        tool(updateFormulas, "Update formulas",
             "Writes rows of formulas (=SUM(B2:B9)) to a range, parsed as if typed in Sheets, as values typed there are. "
                + "Changes only Sheets this connector created or copied.",
             properties: [
                "spreadsheetId": id("spreadsheet"),
                "range": string("The range in A1 notation (Sheet1!C2:C9)."),
                "formulas": rows("Rows of formulas or typed values; null leaves a cell as it is.")
             ], required: ["spreadsheetId", "range", "formulas"], readOnly: false, destructive: true, openWorld: true),
        tool(insertDimension, "Insert rows or columns",
             "Inserts empty rows or columns into a sheet from startIndex up to endIndex (0-based, endIndex not included).",
             properties: [
                "spreadsheetId": id("spreadsheet"),
                "sheetId": integer("The sheet's ID from get_spreadsheet (not its name).", 0...Int(Int32.max)),
                "dimension": GoogleToolSchema.enumeration("ROWS or COLUMNS.", ["ROWS", "COLUMNS"]),
                "startIndex": integer("The first new row or column, 0-based.", 0...Int(Int32.max)),
                "endIndex": integer("One past the last new row or column.", 1...Int(Int32.max)),
                "inheritFromBefore": boolean("Takes the format of the row or column before (true) or after (false).")
             ], required: ["spreadsheetId", "sheetId", "dimension", "startIndex", "endIndex"],
             readOnly: false, openWorld: true),
        tool(updateSpreadsheet, "Update spreadsheet",
             "Applies Sheets API batchUpdate requests in order, all or none: addSheet, deleteSheet, updateSheetProperties, "
                + "repeatCell, mergeCells, sortRange, and others. Changes only Sheets this connector created or copied.",
             properties: [
                "spreadsheetId": id("spreadsheet"),
                "requests": requests("spreadsheets.batchUpdate Request objects (developers.google.com/workspace/sheets/api/"
                    + "reference/rest/v4/spreadsheets/request). Sheets go by sheetId from get_spreadsheet.")
             ], required: ["spreadsheetId", "requests"], readOnly: false, destructive: true, openWorld: true),
        // Slides
        tool(readPresentation, "Read presentation",
             "Reads a presentation's slides in order: each slide's ID, layout, and its shapes, tables, and images with IDs "
                + "and text, and speaker notes. A long deck comes in parts. fields returns the Slides API's JSON instead.",
             properties: [
                "presentationId": id("presentation"),
                "startSlide": integer("Where to go on reading: nextStartSlide from the previous part (0-based).", 0...10_000),
                "fields": stringArray("Field masks (slides.pageElements(objectId,shape.text)) for the Slides API's own JSON."),
                "commentsIncluded": boolean("Adds the presentation's comment threads.")
             ], required: ["presentationId"], readOnly: true),
        tool(readSlidePage, "Read slide",
             "Reads one slide, layout, or master: its elements with IDs, kinds, placeholders, size, position, and text. "
                + "fields returns the Slides API's JSON instead.",
             properties: [
                "presentationId": id("presentation"),
                "pageId": string("The slide's objectId from read_presentation."),
                "fields": stringArray("Field masks (pageElements(objectId,shape.text)) for the Slides API's own JSON.")
             ], required: ["presentationId", "pageId"], readOnly: true),
        tool(readSlidePageThumbnail, "Read slide thumbnail",
             "Renders one slide as a PNG image and returns the image with its size.",
             properties: [
                "presentationId": id("presentation"),
                "pageId": string("The slide's objectId from read_presentation."),
                "thumbnailProperties": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "thumbnailSize": GoogleToolSchema.enumeration(
                            "SMALL (200 px wide), MEDIUM (800 px, the default), or LARGE (1600 px).",
                            ["SMALL", "MEDIUM", "LARGE"])
                    ]),
                    "description": .string("The image's size.")
                ])
             ], required: ["presentationId", "pageId"], readOnly: true),
        tool(updatePresentation, "Update presentation",
             "Applies Slides API batchUpdate requests in order, all or none: createSlide, insertText, deleteText, "
                + "replaceAllText, createShape, updateTextStyle, deleteObject, and others. Changes only Slides this connector "
                + "created or copied.",
             properties: [
                "presentationId": id("presentation"),
                "requests": requests("presentations.batchUpdate Request objects (developers.google.com/workspace/slides/api/"
                    + "reference/rest/v1/presentations/request), with objectIds from read_presentation."),
                "writeControl": object("{\"requiredRevisionId\": revisionId from read_presentation} refuses the change if "
                    + "the presentation changed since.")
             ], required: ["presentationId", "requests"], readOnly: false, destructive: true, openWorld: true)
    ]

    // MARK: Schema pieces

    private static func id(_ kind: String) -> ToolJSON {
        string("The \(kind)'s ID: its Drive file ID from search_files, or the part after /d/ in its link.")
    }

    private static func requests(_ description: String) -> ToolJSON {
        .object(["type": .string("array"), "items": .object(["type": .string("object")]), "minItems": .integer(1),
                 "description": .string(description)])
    }

    private static func rows(_ description: String) -> ToolJSON {
        .object(["type": .string("array"), "items": .object(["type": .string("array"), "items": .object([:])]),
                 "description": .string(description)])
    }

    private static func object(_ description: String) -> ToolJSON {
        .object(["type": .string("object"), "description": .string(description)])
    }

    private static func string(_ description: String) -> ToolJSON { GoogleToolSchema.string(description) }

    private static func boolean(_ description: String) -> ToolJSON { GoogleToolSchema.boolean(description) }

    private static func stringArray(_ description: String) -> ToolJSON { GoogleToolSchema.stringArray(description) }

    private static func integer(_ description: String, _ range: ClosedRange<Int>) -> ToolJSON {
        GoogleToolSchema.integer(description, range)
    }

    private static func tool(_ name: String, _ title: String, _ description: String,
                             properties: [String: ToolJSON], required: [String] = [],
                             readOnly: Bool, destructive: Bool = false, openWorld: Bool = false) -> ToolJSON {
        GoogleToolSchema.tool(name, title, description, properties: properties, required: required,
                              readOnly: readOnly, destructive: destructive, openWorld: openWorld)
    }
}
