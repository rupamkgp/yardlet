import Foundation
import YardletAgentTools

/// Yardlet's own Google Analytics 4 server: read-only tools for each Google account that turns it
/// on, named and shaped as Google's own Analytics MCP server names them
/// (github.com/googleanalytics/google-analytics-mcp: `get_account_summaries`,
/// `get_property_details`, `list_google_ads_links`, `get_custom_dimensions_and_metrics`,
/// `run_report`, `run_realtime_report`), over the public Analytics Admin and Data APIs (v1beta).
/// That server runs locally with Python and Application Default Credentials; Yardlet calls the same
/// APIs with the account's one Google sign-in instead. Each reaches a harness under the account's
/// slug (`analytics_run_report`).
///
/// One scope reads everything here, `analytics.readonly`, with the account's address to name an
/// account that has none of Gmail, Calendar, and Drive. Nothing writes, so nothing asks.
enum GoogleAnalyticsToolCatalog {
    static let getAccountSummaries = "get_account_summaries"
    static let getPropertyDetails = "get_property_details"
    static let listGoogleAdsLinks = "list_google_ads_links"
    static let getCustomDimensionsAndMetrics = "get_custom_dimensions_and_metrics"
    static let runReport = "run_report"
    static let runRealtimeReport = "run_realtime_report"

    static let readScope = "https://www.googleapis.com/auth/analytics.readonly"
    static let scopes = [readScope, GoogleOAuth.emailScope]

    private typealias Schema = ConnectorToolSchema

    private static let propertyID = Schema.string("The property's ID (123456789) or name (properties/123456789).")

    private static func objects(_ description: String) -> ToolJSON {
        .object(["type": .string("array"), "items": .object(["type": .string("object")]), "description": .string(description)])
    }

    private static let reportFields: [String: ToolJSON] = [
        "property_id": propertyID,
        "dimensions": Schema.stringArray("Dimension names, such as date, sessionSource, or pagePath."),
        "metrics": Schema.stringArray("Metric names, such as sessions, totalUsers, or conversions."),
        "dimension_filter": .object(["type": .string("object"),
                                     "description": .string("A Data API FilterExpression on dimensions, as the API takes it.")]),
        "metric_filter": .object(["type": .string("object"),
                                  "description": .string("A Data API FilterExpression on metrics, as the API takes it.")]),
        "order_bys": objects("Data API OrderBy objects, as the API takes them."),
        "limit": Schema.integer("Rows to return, 1 to 10,000. Defaults to 1,000.", 1...10_000),
        "return_property_quota": Schema.boolean("Include the property's remaining quota.")
    ]

    static let tools: [ToolJSON] = [
        Schema.tool(getAccountSummaries, "Get account summaries",
                    "Lists the Analytics accounts and properties the Google account can read, with their IDs and names.",
                    properties: [:], readOnly: true),
        Schema.tool(getPropertyDetails, "Get property details",
                    "Reads a property's settings: name, time zone, currency, industry, and when it was made.",
                    properties: ["property_id": propertyID], required: ["property_id"], readOnly: true),
        Schema.tool(listGoogleAdsLinks, "List Google Ads links",
                    "Lists the Google Ads accounts linked to a property.",
                    properties: ["property_id": propertyID], required: ["property_id"], readOnly: true),
        Schema.tool(getCustomDimensionsAndMetrics, "Get custom dimensions and metrics",
                    "Lists a property's custom dimensions and metrics, with the API names reports use.",
                    properties: ["property_id": propertyID], required: ["property_id"], readOnly: true),
        Schema.tool(runReport, "Run report",
                    "Runs a Data API report on a property: metrics by dimensions over date ranges, filtered and ordered.",
                    properties: reportFields.merging([
                        "date_ranges": objects("Date ranges, each {start_date, end_date, name}: YYYY-MM-DD, today, yesterday, or NdaysAgo."),
                        "offset": Schema.integer("Rows to skip, for the next page.", 0...10_000_000),
                        "currency_code": Schema.string("ISO 4217 currency for money metrics, such as KRW.")
                    ]) { $1 }, required: ["property_id", "date_ranges", "metrics"], readOnly: true),
        Schema.tool(runRealtimeReport, "Run realtime report",
                    "Runs a realtime report on a property: activity from the last 30 minutes.",
                    properties: reportFields, required: ["property_id", "metrics"], readOnly: true)
    ]
}
