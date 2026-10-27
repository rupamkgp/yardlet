import Foundation
import YardletAgentTools

/// Runs one Google Analytics tool call against the Analytics Admin and Data APIs (v1beta) and
/// answers with compact JSON text. Report rows come back as lists of values under their headers.
/// Arguments are checked before any request; Google's errors and a sign-in that ended are thrown to
/// the connector center.
struct GoogleAnalyticsToolRunner {
    let admin: GoogleREST
    let data: GoogleREST

    typealias Problem = ConnectorToolArguments.Problem
    private typealias Arguments = ConnectorToolArguments
    private typealias Catalog = GoogleAnalyticsToolCatalog

    /// An answer is cut here, as Drive's are.
    static let answerLimit = 100_000

    func call(_ name: String, _ arguments: ToolJSON) async throws -> AgentToolResult {
        let arguments = arguments.objectValue ?? [:]
        do {
            let result: ToolJSON
            switch name {
            case Catalog.getAccountSummaries: result = try await summaries()
            case Catalog.getPropertyDetails: result = try await admin.get([try property(arguments)])
            case Catalog.listGoogleAdsLinks: result = try await admin.get([try property(arguments), "googleAdsLinks"])
            case Catalog.getCustomDimensionsAndMetrics: result = try await custom(arguments)
            case Catalog.runReport: result = try await report(arguments, realtime: false)
            case Catalog.runRealtimeReport: result = try await report(arguments, realtime: true)
            default: return .error("Unknown tool: \(name)")
            }
            let text = Arguments.text(result)
            guard text.count <= Self.answerLimit else {
                return .error("The answer is \(text.count) characters, over the \(Self.answerLimit) a tool returns. "
                    + "Ask for fewer rows (limit), dimensions, or a shorter date range.")
            }
            return .text(text)
        } catch let problem as Problem {
            return .error(problem.localizedDescription)
        } catch GoogleREST.Failure.invalidID(let id) {
            return .error("Not a property Google Analytics takes: \(id)")
        }
    }

    /// `properties/123`, from 123 or properties/123.
    private func property(_ arguments: [String: ToolJSON]) throws -> String {
        let value = try Arguments.required(arguments, "property_id")
        let number = value.hasPrefix("properties/") ? String(value.dropFirst("properties/".count)) : value
        guard !number.isEmpty, number.allSatisfy(\.isNumber) else {
            throw Problem.invalid("property_id is a number such as 123456789, or properties/123456789.")
        }
        return "properties/\(number)"
    }

    private func summaries() async throws -> ToolJSON {
        var accounts: [ToolJSON] = []
        var token: String?
        repeat {
            var query = [URLQueryItem(name: "pageSize", value: "200")]
            if let token { query.append(URLQueryItem(name: "pageToken", value: token)) }
            let page = try await admin.get(["accountSummaries"], query)
            accounts += page["accountSummaries"]?.arrayValue ?? []
            token = page["nextPageToken"]?.stringValue
        } while token?.isEmpty == false && accounts.count < 2_000
        return .object(["accountSummaries": .array(accounts)])
    }

    private func custom(_ arguments: [String: ToolJSON]) async throws -> ToolJSON {
        let metadata = try await data.get([try property(arguments) + "/metadata"])
        func customOnly(_ key: String) -> ToolJSON {
            .array((metadata[key]?.arrayValue ?? []).filter { $0["customDefinition"] == .bool(true) }.map {
                .object(Arguments.pick($0, ["apiName", "uiName", "description", "type", "category"]))
            })
        }
        return .object(["dimensions": customOnly("dimensions"), "metrics": customOnly("metrics")])
    }

    private func report(_ arguments: [String: ToolJSON], realtime: Bool) async throws -> ToolJSON {
        let property = try property(arguments)
        let metrics = try Arguments.strings(arguments, "metrics")
        guard !metrics.isEmpty else { throw Problem.missing("metrics") }
        var body: [String: ToolJSON] = [
            "metrics": .array(metrics.map { .object(["name": .string($0)]) }),
            "limit": .integer(Int64(Arguments.pageSize(arguments, "limit", range: 1...10_000, fallback: 1_000)))
        ]
        let dimensions = try Arguments.strings(arguments, "dimensions")
        if !dimensions.isEmpty { body["dimensions"] = .array(dimensions.map { .object(["name": .string($0)]) }) }
        for (argument, field) in [("dimension_filter", "dimensionFilter"), ("metric_filter", "metricFilter")] {
            if let filter = arguments[argument], filter != .null {
                guard filter.objectValue != nil else { throw Problem.invalid("\(argument) is a FilterExpression object.") }
                body[field] = filter
            }
        }
        if let orders = arguments["order_bys"], orders != .null {
            guard orders.arrayValue != nil else { throw Problem.invalid("order_bys is a list of OrderBy objects.") }
            body["orderBys"] = orders
        }
        if Arguments.bool(arguments["return_property_quota"]) == true { body["returnPropertyQuota"] = .bool(true) }
        if !realtime {
            guard let ranges = arguments["date_ranges"]?.arrayValue, !ranges.isEmpty else { throw Problem.missing("date_ranges") }
            body["dateRanges"] = .array(try ranges.map { range in
                guard let start = range["start_date"]?.stringValue ?? range["startDate"]?.stringValue,
                      let end = range["end_date"]?.stringValue ?? range["endDate"]?.stringValue else {
                    throw Problem.invalid("Each date range has start_date and end_date.")
                }
                var fields: [String: ToolJSON] = ["startDate": .string(start), "endDate": .string(end)]
                if let name = range["name"]?.stringValue { fields["name"] = .string(name) }
                return .object(fields)
            })
            if let offset = Arguments.integer(arguments["offset"]), offset > 0 { body["offset"] = .integer(Int64(offset)) }
            if let currency = Arguments.string(arguments, "currency_code") { body["currencyCode"] = .string(currency) }
        }
        let answer = try await data.post([property + (realtime ? ":runRealtimeReport" : ":runReport")], .object(body))
        return Self.rows(answer)
    }

    /// The report as headers and rows of plain values, with its totals, row count, and quota.
    static func rows(_ answer: ToolJSON) -> ToolJSON {
        let dimensions = (answer["dimensionHeaders"]?.arrayValue ?? []).compactMap { $0["name"] }
        let metrics = (answer["metricHeaders"]?.arrayValue ?? []).compactMap { $0["name"] }
        func values(_ row: ToolJSON, _ key: String) -> [ToolJSON] {
            (row[key]?.arrayValue ?? []).map { $0["value"] ?? .null }
        }
        var result: [String: ToolJSON] = [
            "headers": .array(dimensions + metrics),
            "rows": .array((answer["rows"]?.arrayValue ?? []).map { .array(values($0, "dimensionValues") + values($0, "metricValues")) }),
            "rowCount": answer["rowCount"] ?? .integer(0)
        ]
        if let totals = answer["totals"]?.arrayValue, !totals.isEmpty {
            result["totals"] = .array(totals.map { .array(values($0, "dimensionValues") + values($0, "metricValues")) })
        }
        for key in ["metadata", "propertyQuota"] { if let value = answer[key] { result[key] = value } }
        return .object(result)
    }
}
