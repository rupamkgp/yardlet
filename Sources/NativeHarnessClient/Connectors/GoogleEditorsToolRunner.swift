import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import YardletAgentTools

/// Runs one of the Drive connector's Docs, Sheets, and Slides tools (`GoogleEditorsToolCatalog`)
/// against the Docs API v1, Sheets API v4, or Slides API v1, and answers with compact JSON text.
/// A document, range, or deck larger than a tool returns comes in parts, each answer saying where
/// the next begins. Writes pass the APIs' own batchUpdate requests through, which Google checks and
/// applies all or none. Arguments are checked before any request; Google's errors are thrown to
/// the connector center, which words them.
struct GoogleEditorsToolRunner {
    let docs: GoogleREST
    let sheets: GoogleREST
    let slides: GoogleREST
    /// The Drive tools, for comment threads, which Drive keeps for every file.
    let drive: GoogleDriveToolRunner
    /// Fetches a slide thumbnail Google rendered. Its address is signed for the account, so no
    /// token goes with it.
    let http: any ConnectorHTTPTransport

    /// The most text a tool returns, and the most bytes of a thumbnail.
    var maximumCharacters = 100_000
    var maximumImage = 5 * 1_048_576

    typealias Problem = GoogleToolArguments.Problem
    private typealias Arguments = GoogleToolArguments
    private typealias Catalog = GoogleEditorsToolCatalog

    init(endpoints: GoogleOAuth.Endpoints, session: GoogleAPISession, drive: GoogleDriveToolRunner,
         http: any ConnectorHTTPTransport) {
        docs = GoogleREST(base: endpoints.docsAPI, session: session)
        sheets = GoogleREST(base: endpoints.sheetsAPI, session: session)
        slides = GoogleREST(base: endpoints.slidesAPI, session: session)
        self.drive = drive
        self.http = http
    }

    func call(_ name: String, _ arguments: ToolJSON) async throws -> AgentToolResult {
        let arguments = arguments.objectValue ?? [:]
        do {
            let result: ToolJSON
            switch name {
            case Catalog.readDoc: result = try await readDoc(arguments)
            case Catalog.updateDoc: result = try await batchUpdate(docs, "documents", "documentId", arguments, writeControl: true)
            case Catalog.getSpreadsheet: result = try await getSpreadsheet(arguments)
            case Catalog.getValues: result = try await getValues(arguments)
            case Catalog.updateValues: result = try await updateValues(arguments, "values", input: "RAW")
            case Catalog.updateFormulas: result = try await updateValues(arguments, "formulas", input: "USER_ENTERED")
            case Catalog.insertDimension: result = try await insertDimension(arguments)
            case Catalog.updateSpreadsheet:
                result = try await batchUpdate(sheets, "spreadsheets", "spreadsheetId", arguments, writeControl: false)
            case Catalog.readPresentation: result = try await readPresentation(arguments)
            case Catalog.readSlidePage: result = try await readSlidePage(arguments)
            case Catalog.readSlidePageThumbnail: return try await thumbnail(arguments)
            case Catalog.updatePresentation:
                result = try await batchUpdate(slides, "presentations", "presentationId", arguments, writeControl: true)
            default: return .error("Unknown tool: \(name)")
            }
            return .text(Arguments.text(result))
        } catch let problem as Problem {
            return .error(problem.localizedDescription)
        } catch GoogleREST.Failure.invalidID(let id) {
            return .error("Not an ID Google Drive takes: \(id)")
        }
    }

    // MARK: Docs

    /// The document's body as paragraphs, tables, and breaks with their UTF-16 indexes, from
    /// `startIndex` until the answer would pass `maximumCharacters`.
    private func readDoc(_ arguments: [String: ToolJSON]) async throws -> ToolJSON {
        let (id, plain) = try Self.fileID(arguments, "documentId")
        let document = try await docs.get(["documents", id], [URLQueryItem(name: "includeTabsContent", value: "true")])
        let tabs = Self.flattened(document["tabs"]?.arrayValue ?? [])
        let tab: ToolJSON?
        if let wanted = Arguments.string(arguments, "tabId") {
            guard let found = tabs.first(where: { $0["tabProperties"]?["tabId"]?.stringValue == wanted }) else {
                throw Problem.invalid("The document has no tab \(wanted).")
            }
            tab = found
        } else {
            tab = tabs.first
        }
        let body = (tab?["documentTab"]?["body"] ?? document["body"])?["content"]?.arrayValue ?? []
        let from = Arguments.integer(arguments["startIndex"]) ?? 0
        var content: [ToolJSON] = []
        var used = 0
        var next: Int?
        for element in body where Self.int(element["endIndex"]) > from {
            let budget = maximumCharacters - used
            if !content.isEmpty, budget <= 0 { next = max(Self.int(element["startIndex"]), from); break }
            guard let (item, rest) = Self.docElement(element, from: from, budget: budget, first: content.isEmpty) else { continue }
            let size = Arguments.text(item).count + 1
            if !content.isEmpty, size > budget, rest == nil {
                next = max(Self.int(element["startIndex"]), from)
                break
            }
            content.append(item)
            used += size
            if let rest { next = rest; break }
        }
        var result: [String: ToolJSON] = [
            "documentId": .string(plain), "title": document["title"] ?? .null,
            "endIndex": .integer(Int64(body.last.map { Self.int($0["endIndex"]) } ?? 0)),
            "content": .array(content)
        ]
        if let revision = document["revisionId"] { result["revisionId"] = revision }
        if let next { result["nextStartIndex"] = .integer(Int64(next)) }
        if tabs.count > 1 {
            result["tabId"] = tab?["tabProperties"]?["tabId"] ?? .null
            result["tabs"] = .array(tabs.map {
                .object(Arguments.pick($0["tabProperties"], ["tabId", "title", "parentTabId"]))
            })
        }
        if from == 0, Arguments.bool(arguments["commentsIncluded"]) == true {
            result["commentThreads"] = try await drive.comments(id)
        }
        return .object(result)
    }

    /// Every tab, child tabs after their parent, as the document lists them.
    private static func flattened(_ tabs: [ToolJSON]) -> [ToolJSON] {
        tabs.flatMap { [$0] + flattened($0["childTabs"]?.arrayValue ?? []) }
    }

    /// One element of a body. A table starts at the first row that ends after `from` and stops
    /// before the row that would pass `budget`, which is where the next part begins; a paragraph
    /// longer than a whole answer is cut. Nil for the section break every body opens with.
    private static func docElement(_ element: ToolJSON, from: Int, budget: Int, first: Bool) -> (ToolJSON, Int?)? {
        let start = int(element["startIndex"]), end = int(element["endIndex"])
        var item: [String: ToolJSON] = ["startIndex": .integer(Int64(start)), "endIndex": .integer(Int64(end))]
        if let paragraph = element["paragraph"] {
            item["kind"] = .string("paragraph")
            let (text, links) = paragraphText(paragraph)
            if text.count > budget, first {
                item["text"] = .string(String(text.prefix(max(budget, 1_000))))
                item["textCut"] = .bool(true)
            } else {
                item["text"] = .string(text)
            }
            if let style = paragraph["paragraphStyle"]?["namedStyleType"]?.stringValue, style != "NORMAL_TEXT" {
                item["style"] = .string(style)
            }
            if let bullet = paragraph["bullet"] {
                item["bullet"] = .object(["listId": bullet["listId"] ?? .null,
                                          "nestingLevel": .integer(Int64(int(bullet["nestingLevel"])))])
            }
            if !links.isEmpty { item["links"] = .array(links) }
            return (.object(item), nil)
        }
        if let table = element["table"] {
            item["kind"] = .string("table")
            item["rows"] = table["rows"] ?? .null
            item["columns"] = table["columns"] ?? .null
            var rows: [ToolJSON] = []
            var used = 0
            var next: Int?
            let all = table["tableRows"]?.arrayValue ?? []
            let firstRow = all.firstIndex { int($0["endIndex"]) > from } ?? all.count
            for row in all[firstRow...] {
                let cells: ToolJSON = .array((row["tableCells"]?.arrayValue ?? []).map { cell in
                    let content = cell["content"]?.arrayValue ?? []
                    return .object([
                        "startIndex": .integer(Int64(content.first.map { int($0["startIndex"]) } ?? int(cell["startIndex"]))),
                        "endIndex": .integer(Int64(content.last.map { int($0["endIndex"]) } ?? int(cell["endIndex"]))),
                        "text": .string(bodyText(content))
                    ])
                })
                let size = GoogleToolArguments.text(cells).count + 1
                if !rows.isEmpty, used + size > budget { next = int(row["startIndex"]); break }
                rows.append(cells)
                used += size
            }
            if firstRow > 0 { item["firstRow"] = .integer(Int64(firstRow)) }
            item["cells"] = .array(rows)
            return (.object(item), next)
        }
        if let contents = element["tableOfContents"] {
            item["kind"] = .string("tableOfContents")
            item["text"] = .string(bodyText(contents["content"]?.arrayValue ?? []))
            return (.object(item), nil)
        }
        if element["sectionBreak"] != nil {
            guard start > 0 else { return nil }
            item["kind"] = .string("sectionBreak")
            return (.object(item), nil)
        }
        return nil
    }

    /// A paragraph's text, with U+FFFC for each index an image, footnote mark, or other object
    /// holds, so the text's UTF-16 length is its length in the document; and its web links.
    private static func paragraphText(_ paragraph: ToolJSON) -> (String, [ToolJSON]) {
        var text = ""
        var links: [ToolJSON] = []
        for part in paragraph["elements"]?.arrayValue ?? [] {
            let start = int(part["startIndex"]), end = int(part["endIndex"])
            if let run = part["textRun"]?["content"]?.stringValue {
                text += run
                if let url = part["textRun"]?["textStyle"]?["link"]?["url"] {
                    links.append(.object(["startIndex": .integer(Int64(start)), "endIndex": .integer(Int64(end)), "url": url]))
                }
            } else {
                text += String(repeating: "\u{FFFC}", count: max(end - start, 0))
            }
        }
        return (text, links)
    }

    /// The text of a cell or a table of contents: its paragraphs, and a table inside it cell by cell.
    private static func bodyText(_ content: [ToolJSON]) -> String {
        content.map { element in
            if let paragraph = element["paragraph"] { return paragraphText(paragraph).0 }
            if let rows = element["table"]?["tableRows"]?.arrayValue {
                return rows.map { row in
                    (row["tableCells"]?.arrayValue ?? []).map { bodyText($0["content"]?.arrayValue ?? []) }
                        .map { $0.trimmingCharacters(in: .newlines) }.joined(separator: "\t")
                }.joined(separator: "\n") + "\n"
            }
            return ""
        }.joined()
    }

    // MARK: Sheets

    static let spreadsheetFields = "spreadsheetId,spreadsheetUrl,properties(title,locale,timeZone),"
        + "sheets(properties(sheetId,title,index,sheetType,hidden,"
        + "gridProperties(rowCount,columnCount,frozenRowCount,frozenColumnCount))),namedRanges(namedRangeId,name,range)"

    private func getSpreadsheet(_ arguments: [String: ToolJSON]) async throws -> ToolJSON {
        let (id, plain) = try Self.fileID(arguments, "spreadsheetId")
        var query = try Arguments.strings(arguments, "ranges").map { URLQueryItem(name: "ranges", value: $0) }
        let fields = try Arguments.strings(arguments, "fields")
        let grid = Arguments.bool(arguments["includeGridData"]) == true
        var result: [String: ToolJSON]
        if fields.isEmpty, !grid {
            query.append(URLQueryItem(name: "fields", value: Self.spreadsheetFields))
            result = Self.spreadsheet(try await sheets.get(["spreadsheets", id], query))
        } else {
            if grid { query.append(URLQueryItem(name: "includeGridData", value: "true")) }
            if !fields.isEmpty { query.append(URLQueryItem(name: "fields", value: fields.joined(separator: ","))) }
            result = try await sheets.get(["spreadsheets", id], query).objectValue ?? [:]
            result["spreadsheetId"] = .string(plain)
        }
        if Arguments.bool(arguments["commentsIncluded"]) == true { result["commentThreads"] = try await drive.comments(id) }
        return try fitting(.object(result))
    }

    /// A spreadsheet as `get_spreadsheet` gives it by default: its sheets in a line each.
    private static func spreadsheet(_ answer: ToolJSON) -> [String: ToolJSON] {
        var result = GoogleToolArguments.pick(answer, ["spreadsheetId", "spreadsheetUrl", "namedRanges"])
        result.merge(GoogleToolArguments.pick(answer["properties"], ["title", "locale", "timeZone"])) { first, _ in first }
        result["sheets"] = .array((answer["sheets"]?.arrayValue ?? []).map { sheet in
            let properties = sheet["properties"]
            var line = GoogleToolArguments.pick(properties, ["sheetId", "title", "index", "hidden"])
            if let type = properties?["sheetType"]?.stringValue, type != "GRID" { line["sheetType"] = .string(type) }
            line.merge(GoogleToolArguments.pick(properties?["gridProperties"],
                                                ["rowCount", "columnCount", "frozenRowCount", "frozenColumnCount"])) { first, _ in first }
            return .object(line)
        })
        return result
    }

    /// A range's rows until the answer would pass `maximumCharacters`; `nextRange` covers the rest.
    private func getValues(_ arguments: [String: ToolJSON]) async throws -> ToolJSON {
        let (id, plain) = try Self.fileID(arguments, "spreadsheetId")
        let range = try Arguments.required(arguments, "range")
        let render = Arguments.string(arguments, "valueRenderOption") ?? "FORMATTED_VALUE"
        guard ["FORMATTED_VALUE", "UNFORMATTED_VALUE", "FORMULA"].contains(render) else {
            throw Problem.invalid("valueRenderOption is FORMATTED_VALUE, UNFORMATTED_VALUE, or FORMULA.")
        }
        let answer = try await sheets.get(["spreadsheets", id, "values", try GoogleREST.segment(range)], [
            URLQueryItem(name: "majorDimension", value: "ROWS"), URLQueryItem(name: "valueRenderOption", value: render)
        ])
        let all = answer["values"]?.arrayValue ?? []
        var kept: [ToolJSON] = []
        var used = 0
        for row in all {
            let size = Arguments.text(row).count + 1
            if !kept.isEmpty, used + size > maximumCharacters { break }
            kept.append(row)
            used += size
        }
        var result: [String: ToolJSON] = ["spreadsheetId": .string(plain), "range": answer["range"] ?? .string(range),
                                          "values": .array(kept)]
        if kept.count < all.count {
            result["rowsReturned"] = .integer(Int64(kept.count))
            if let next = answer["range"]?.stringValue.flatMap({ A1Range($0)?.rows(after: kept.count) }) {
                result["nextRange"] = .string(next)
            }
        }
        return .object(result)
    }

    /// `update_values` writes values as they are (`RAW`); `update_formulas` as typed (`USER_ENTERED`).
    private func updateValues(_ arguments: [String: ToolJSON], _ key: String, input: String) async throws -> ToolJSON {
        let (id, plain) = try Self.fileID(arguments, "spreadsheetId")
        let range = try Arguments.required(arguments, "range")
        guard let rows = arguments[key]?.arrayValue, !rows.isEmpty else { throw Problem.missing(key) }
        for row in rows {
            guard let cells = row.arrayValue, cells.allSatisfy(Self.isCell) else {
                throw Problem.invalid("\(key) takes rows (arrays) of strings, numbers, booleans, or null.")
            }
        }
        let answer = try await sheets.put(["spreadsheets", id, "values", try GoogleREST.segment(range)],
                                          .object(["range": .string(range), "majorDimension": .string("ROWS"),
                                                   "values": .array(rows)]),
                                          [URLQueryItem(name: "valueInputOption", value: input)])
        var result = Arguments.pick(answer, ["updatedRange", "updatedRows", "updatedColumns", "updatedCells"])
        result["spreadsheetId"] = .string(plain)
        return .object(result)
    }

    private static func isCell(_ value: ToolJSON) -> Bool {
        switch value {
        case .string, .integer, .number, .bool, .null: true
        case .array, .object: false
        }
    }

    private func insertDimension(_ arguments: [String: ToolJSON]) async throws -> ToolJSON {
        let (id, plain) = try Self.fileID(arguments, "spreadsheetId")
        guard let sheet = Arguments.integer(arguments["sheetId"]) else { throw Problem.missing("sheetId") }
        guard let dimension = Arguments.string(arguments, "dimension")?.uppercased(), ["ROWS", "COLUMNS"].contains(dimension) else {
            throw Problem.invalid("dimension is ROWS or COLUMNS.")
        }
        guard let start = Arguments.integer(arguments["startIndex"]), let end = Arguments.integer(arguments["endIndex"]),
              start >= 0, end > start else {
            throw Problem.invalid("startIndex and endIndex are 0-based, with endIndex past startIndex.")
        }
        let range: ToolJSON = .object(["sheetId": .integer(Int64(sheet)), "dimension": .string(dimension),
                                       "startIndex": .integer(Int64(start)), "endIndex": .integer(Int64(end))])
        var insert: [String: ToolJSON] = ["range": range]
        if let inherit = Arguments.bool(arguments["inheritFromBefore"]) { insert["inheritFromBefore"] = .bool(inherit) }
        _ = try await sheets.post(["spreadsheets", id + ":batchUpdate"],
                                  .object(["requests": .array([.object(["insertDimension": .object(insert)])])]))
        return .object(["spreadsheetId": .string(plain), "inserted": range])
    }

    // MARK: Slides

    static let presentationFields = "presentationId,title,revisionId,pageSize,slides,layouts(objectId,layoutProperties)"

    /// The slides from `startSlide` until the answer would pass `maximumCharacters`.
    private func readPresentation(_ arguments: [String: ToolJSON]) async throws -> ToolJSON {
        let (id, plain) = try Self.fileID(arguments, "presentationId")
        let fields = try Arguments.strings(arguments, "fields")
        let comments = Arguments.bool(arguments["commentsIncluded"]) == true
        if !fields.isEmpty {
            var raw = try await slides.get(["presentations", id], [URLQueryItem(name: "fields", value: fields.joined(separator: ","))])
                .objectValue ?? [:]
            raw["presentationId"] = .string(plain)
            if comments { raw["commentThreads"] = try await drive.comments(id) }
            return try fitting(.object(raw))
        }
        let deck = try await slides.get(["presentations", id], [URLQueryItem(name: "fields", value: Self.presentationFields)])
        var layouts: [String: ToolJSON] = [:]
        for layout in deck["layouts"]?.arrayValue ?? [] {
            if let id = layout["objectId"]?.stringValue,
               let name = layout["layoutProperties"]?["displayName"] ?? layout["layoutProperties"]?["name"] {
                layouts[id] = name
            }
        }
        let all = deck["slides"]?.arrayValue ?? []
        let from = min(max(Arguments.integer(arguments["startSlide"]) ?? 0, 0), all.count)
        var kept: [ToolJSON] = []
        var used = 0
        var next: Int?
        for (index, page) in all.enumerated().dropFirst(from) {
            var slide = Self.page(page, geometry: false)
            slide["index"] = .integer(Int64(index))
            if let layout = page["slideProperties"]?["layoutObjectId"]?.stringValue, let name = layouts[layout] {
                slide["layout"] = name
            }
            let size = Arguments.text(.object(slide)).count + 1
            if !kept.isEmpty, used + size > maximumCharacters { next = index; break }
            kept.append(.object(slide))
            used += size
        }
        var result: [String: ToolJSON] = ["presentationId": .string(plain), "title": deck["title"] ?? .null,
                                          "slideCount": .integer(Int64(all.count)), "slides": .array(kept)]
        result.merge(Arguments.pick(deck, ["revisionId", "pageSize"])) { first, _ in first }
        if let next { result["nextStartSlide"] = .integer(Int64(next)) }
        if from == 0, comments { result["commentThreads"] = try await drive.comments(id) }
        return .object(result)
    }

    private func readSlidePage(_ arguments: [String: ToolJSON]) async throws -> ToolJSON {
        let (id, plain) = try Self.fileID(arguments, "presentationId")
        let page = try GoogleREST.segment(try Arguments.required(arguments, "pageId"))
        let fields = try Arguments.strings(arguments, "fields")
        let query = fields.isEmpty ? [] : [URLQueryItem(name: "fields", value: fields.joined(separator: ","))]
        let answer = try await slides.get(["presentations", id, "pages", page], query)
        var result = fields.isEmpty ? Self.page(answer, geometry: true) : answer.objectValue ?? [:]
        result["presentationId"] = .string(plain)
        return try fitting(.object(result))
    }

    /// A slide, layout, or master: its kind, layout, elements, and speaker notes; with `geometry`,
    /// each element's size and position too.
    private static func page(_ page: ToolJSON, geometry: Bool) -> [String: ToolJSON] {
        var result = GoogleToolArguments.pick(page, ["objectId"])
        if let type = page["pageType"]?.stringValue, type != "SLIDE" { result["pageType"] = .string(type) }
        let properties = page["slideProperties"]
        if let layout = properties?["layoutObjectId"] { result["layoutId"] = layout }
        if properties?["isSkipped"] == .bool(true) { result["skipped"] = .bool(true) }
        if let name = page["layoutProperties"]?["displayName"] ?? page["layoutProperties"]?["name"] { result["name"] = name }
        result["elements"] = .array((page["pageElements"]?.arrayValue ?? []).map { element($0, geometry: geometry) })
        if let notes = properties?["notesPage"], let id = notes["notesProperties"]?["speakerNotesObjectId"]?.stringValue {
            let shape = notes["pageElements"]?.arrayValue?.first { $0["objectId"]?.stringValue == id }
            result["notesObjectId"] = .string(id)
            result["notes"] = .string(text(shape?["shape"]?["text"]))
        }
        return result
    }

    private static func element(_ element: ToolJSON, geometry: Bool) -> ToolJSON {
        var item = GoogleToolArguments.pick(element, ["objectId", "title"])
        if let shape = element["shape"] {
            item["kind"] = .string("shape")
            if let type = shape["shapeType"] { item["shapeType"] = type }
            if let placeholder = shape["placeholder"]?["type"] { item["placeholder"] = placeholder }
            if shape["text"] != nil { item["text"] = .string(text(shape["text"])) }
        } else if let table = element["table"] {
            item["kind"] = .string("table")
            item.merge(GoogleToolArguments.pick(table, ["rows", "columns"])) { first, _ in first }
            item["cells"] = .array((table["tableRows"]?.arrayValue ?? []).map { row in
                .array((row["tableCells"]?.arrayValue ?? []).map { .string(text($0["text"])) })
            })
        } else if let group = element["elementGroup"] {
            item["kind"] = .string("group")
            item["children"] = .array((group["children"]?.arrayValue ?? []).map { Self.element($0, geometry: geometry) })
        } else if let chart = element["sheetsChart"] {
            item["kind"] = .string("sheetsChart")
            item.merge(GoogleToolArguments.pick(chart, ["spreadsheetId", "chartId"])) { first, _ in first }
        } else if let art = element["wordArt"] {
            item["kind"] = .string("wordArt")
            if let rendered = art["renderedText"] { item["text"] = rendered }
        } else {
            let kinds = ["image", "video", "line", "speakerSpotlight"]
            item["kind"] = .string(kinds.first { element[$0] != nil } ?? "other")
        }
        if geometry { item.merge(GoogleToolArguments.pick(element, ["size", "transform"])) { first, _ in first } }
        return .object(item)
    }

    /// A shape's or cell's text as its runs and auto text (slide numbers) hold it.
    private static func text(_ content: ToolJSON?) -> String {
        (content?["textElements"]?.arrayValue ?? []).compactMap {
            $0["textRun"]?["content"]?.stringValue ?? $0["autoText"]?["content"]?.stringValue
        }.joined()
    }

    /// The thumbnail's size and the PNG itself, which the model can look at.
    private func thumbnail(_ arguments: [String: ToolJSON]) async throws -> AgentToolResult {
        let (id, plain) = try Self.fileID(arguments, "presentationId")
        let pageID = try Arguments.required(arguments, "pageId")
        let size = arguments["thumbnailProperties"]?["thumbnailSize"]?.stringValue?.uppercased() ?? "MEDIUM"
        guard ["SMALL", "MEDIUM", "LARGE"].contains(size) else { throw Problem.invalid("thumbnailSize is SMALL, MEDIUM, or LARGE.") }
        let answer = try await slides.get(["presentations", id, "pages", try GoogleREST.segment(pageID), "thumbnail"], [
            URLQueryItem(name: "thumbnailProperties.mimeType", value: "PNG"),
            URLQueryItem(name: "thumbnailProperties.thumbnailSize", value: size)
        ])
        var result: [String: ToolJSON] = ["presentationId": .string(plain), "pageId": .string(pageID)]
        result.merge(Arguments.pick(answer, ["width", "height", "contentUrl"])) { first, _ in first }
        var content: [AgentToolContent] = [.text(Arguments.text(.object(result)))]
        if let address = answer["contentUrl"]?.stringValue, let url = URL(string: address), url.scheme == "https",
           let (data, response) = try? await http.send(URLRequest(url: url, timeoutInterval: 60)),
           (200..<300).contains(response.statusCode), !data.isEmpty, data.count <= maximumImage {
            content.append(.image(data: data.base64EncodedString(), mimeType: "image/png"))
        }
        return AgentToolResult(content: content)
    }

    // MARK: Writing

    /// A batchUpdate: the requests as the API takes them, all applied or none, and its replies
    /// (a new sheet's or slide's ID).
    private func batchUpdate(_ api: GoogleREST, _ collection: String, _ key: String, _ arguments: [String: ToolJSON],
                             writeControl: Bool) async throws -> ToolJSON {
        let (id, plain) = try Self.fileID(arguments, key)
        guard let requests = arguments["requests"]?.arrayValue, !requests.isEmpty else { throw Problem.missing("requests") }
        guard requests.allSatisfy({ $0.objectValue?.isEmpty == false }) else {
            throw Problem.invalid("requests takes request objects, such as {\"insertText\": {…}}.")
        }
        var body: [String: ToolJSON] = ["requests": .array(requests)]
        if writeControl, let control = arguments["writeControl"], control.objectValue != nil { body["writeControl"] = control }
        let answer = try await api.post([collection, id + ":batchUpdate"], .object(body))
        var result = Arguments.pick(answer, ["replies", "writeControl"])
        result[key] = .string(plain)
        return try fitting(.object(result))
    }

    // MARK: Pieces

    /// The file's ID as a path segment and as given. A link (`…/document/d/<id>/edit`) gives its ID.
    private static func fileID(_ arguments: [String: ToolJSON], _ key: String) throws -> (String, String) {
        var value = try GoogleToolArguments.required(arguments, key)
        if let range = value.range(of: "/d/") {
            value = String(value[range.upperBound...].prefix { $0 != "/" && $0 != "?" && $0 != "#" })
        }
        return (try GoogleREST.segment(value), value)
    }

    private static func int(_ value: ToolJSON?) -> Int { GoogleToolArguments.integer(value) ?? 0 }

    /// An answer that fits a tool's limit, or what to ask for instead.
    private func fitting(_ json: ToolJSON) throws -> ToolJSON {
        let count = Arguments.text(json).count
        guard count <= maximumCharacters else {
            throw Problem.invalid("The answer is \(count) characters, more than the \(maximumCharacters) a tool returns. "
                + "Ask for fewer fields or a smaller range.")
        }
        return json
    }
}

/// An A1 range as the Sheets API gives it back (`Sheet1!A1:D50`, `'Q3 plan'!B2:F`), enough to say
/// where the rows after the first few begin.
struct A1Range: Equatable {
    var sheet: String?
    var startColumn: String
    var startRow: Int
    var endColumn: String
    var endRow: Int?

    init?(_ text: String) {
        var cells = Substring(text)
        if let bang = text.lastIndex(of: "!") {
            sheet = String(text[..<bang])
            cells = text[text.index(after: bang)...]
        }
        let parts = cells.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let start = Self.cell(parts[0]), let end = Self.cell(parts[1]),
              let row = start.row, !start.column.isEmpty, !end.column.isEmpty else { return nil }
        startColumn = start.column
        startRow = row
        endColumn = end.column
        endRow = end.row
    }

    /// The same columns from `count` rows further down; nil when nothing is left.
    func rows(after count: Int) -> String? {
        let row = startRow + count
        if let endRow, row > endRow { return nil }
        let cells = "\(startColumn)\(row):\(endColumn)\(endRow.map(String.init) ?? "")"
        return sheet.map { "\($0)!\(cells)" } ?? cells
    }

    private static func cell(_ text: Substring) -> (column: String, row: Int?)? {
        let column = text.prefix { $0.isLetter && $0.isASCII }
        let digits = text.dropFirst(column.count)
        guard digits.allSatisfy(\.isNumber) else { return nil }
        return (column.uppercased(), digits.isEmpty ? nil : Int(digits))
    }
}
