import Foundation
import YardletAgentTools

/// Runs one Google Ads tool call against the Google Ads API and answers with compact JSON text.
/// Only `customers:listAccessibleCustomers`, `googleAds:search`, and `googleAdsFields:search` are
/// called, with a GAQL `SELECT` checked before the request, so nothing here can change an account.
/// Google's errors and a sign-in that ended are thrown to the connector center.
struct GoogleAdsToolRunner {
    let base: URL
    let session: OAuthAPISession

    typealias Problem = ConnectorToolArguments.Problem
    private typealias Arguments = ConnectorToolArguments
    private typealias Catalog = GoogleAdsToolCatalog

    static let answerLimit = 100_000

    func call(_ name: String, _ arguments: ToolJSON) async throws -> AgentToolResult {
        let arguments = arguments.objectValue ?? [:]
        do {
            let result: ToolJSON
            switch name {
            case Catalog.listAccessibleCustomers:
                result = try await GoogleREST(base: base, session: session).get(["customers:listAccessibleCustomers"])
            case Catalog.search: result = try await search(arguments)
            case Catalog.getResourceMetadata: result = try await metadata(arguments)
            default: return .error("Unknown tool: \(name)")
            }
            let text = Arguments.text(result)
            guard text.count <= Self.answerLimit else {
                return .error("The answer is \(text.count) characters, over the \(Self.answerLimit) a tool returns. "
                    + "Select fewer fields, add LIMIT, or narrow the date range.")
            }
            return .text(text)
        } catch let problem as Problem {
            return .error(problem.localizedDescription)
        }
    }

    /// A customer ID's digits: 123-456-7890 is 1234567890.
    static func customerID(_ text: String, name: String) throws -> String {
        let digits = text.filter { $0 != "-" && $0 != " " }
        guard !digits.isEmpty, digits.count <= 12, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            throw Problem.invalid("\(name) is a Google Ads customer ID such as 123-456-7890.")
        }
        return digits
    }

    /// A GAQL query that only reads: it starts with SELECT. GAQL has no other statement, but a
    /// request that is not one goes nowhere.
    static func readingQuery(_ text: String) throws -> String {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.range(of: #"^select\s"#, options: [.regularExpression, .caseInsensitive]) != nil else {
            throw Problem.invalid("query is a Google Ads Query Language SELECT.")
        }
        return query
    }

    private func search(_ arguments: [String: ToolJSON]) async throws -> ToolJSON {
        let customer = try Self.customerID(try Arguments.required(arguments, "customer_id"), name: "customer_id")
        var body: [String: ToolJSON] = ["query": .string(try Self.readingQuery(try Arguments.required(arguments, "query")))]
        if let token = Arguments.string(arguments, "page_token") { body["pageToken"] = .string(token) }
        var api = GoogleREST(base: base, session: session)
        if let login = Arguments.string(arguments, "login_customer_id") {
            api.headers["login-customer-id"] = try Self.customerID(login, name: "login_customer_id")
        }
        let answer = try await api.post(["customers", customer, "googleAds:search"], .object(body))
        var result = Arguments.pick(answer, ["results", "fieldMask", "nextPageToken", "totalResultsCount"])
        if result["results"] == nil { result["results"] = .array([]) }
        return .object(result)
    }

    private func metadata(_ arguments: [String: ToolJSON]) async throws -> ToolJSON {
        let resource = try Arguments.required(arguments, "resource")
        guard resource.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == ".") }) else {
            throw Problem.invalid("resource is a name such as campaign or metrics.")
        }
        let query = "SELECT name, category, data_type, selectable, filterable, sortable, is_repeated "
            + "WHERE name LIKE '\(resource).%'"
        let answer = try await GoogleREST(base: base, session: session).post(["googleAdsFields:search"],
                                                                             .object(["query": .string(query)]))
        return .object(["fields": .array((answer["results"]?.arrayValue ?? []).map {
            .object(Arguments.pick($0, ["name", "category", "dataType", "selectable", "filterable", "sortable", "isRepeated"]))
        })])
    }
}
