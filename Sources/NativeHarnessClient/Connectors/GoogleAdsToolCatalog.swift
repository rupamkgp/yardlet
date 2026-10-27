import Foundation
import YardletAgentTools

/// Yardlet's own Google Ads server: read-only tools for each Google account that turns it on,
/// named as Google's own Google Ads MCP server names them (`list_accessible_customers`, `search`,
/// `get_resource_metadata`; developers.google.com/google-ads/api/docs/developer-toolkit/mcp-server),
/// over the public Google Ads API (v26). Each reaches a harness under the account's slug
/// (`google_ads_search`).
///
/// Google Ads has one scope, `adwords`, which can also change campaigns and budgets, and Google
/// lists it as restricted. Reading only is the code's to keep: the API is reached only through
/// listing customers and Google Ads Query Language searches, and a query that is not a `SELECT` is
/// refused before any request. Developer tokens ended on 2026-09-09, so none is sent.
enum GoogleAdsToolCatalog {
    static let listAccessibleCustomers = "list_accessible_customers"
    static let search = "search"
    static let getResourceMetadata = "get_resource_metadata"

    static let scope = "https://www.googleapis.com/auth/adwords"
    static let scopes = [scope, GoogleOAuth.emailScope]

    private typealias Schema = ConnectorToolSchema

    static let tools: [ToolJSON] = [
        Schema.tool(listAccessibleCustomers, "List accessible customers",
                    "Lists the Google Ads customer IDs the Google account can reach directly.",
                    properties: [:], readOnly: true),
        Schema.tool(search, "Search",
                    "Runs a Google Ads Query Language SELECT on one customer: campaigns, ad groups, keywords, costs, "
                        + "conversions, and the rest by date. Reads only.",
                    properties: [
                        "customer_id": Schema.string("The customer ID, digits only or with dashes."),
                        "query": Schema.string("A GAQL SELECT, such as SELECT campaign.name, metrics.cost_micros FROM campaign "
                            + "WHERE segments.date DURING LAST_7_DAYS."),
                        "login_customer_id": Schema.string("The manager account the access comes through, if any."),
                        "page_token": Schema.string("nextPageToken from the previous page.")
                    ], required: ["customer_id", "query"], readOnly: true),
        Schema.tool(getResourceMetadata, "Get resource metadata",
                    "Lists the fields of a GAQL resource (campaign, ad_group, metrics, segments) with whether each "
                        + "can be selected, filtered, and sorted.",
                    properties: ["resource": Schema.string("A resource or field prefix, such as campaign or metrics.")],
                    required: ["resource"], readOnly: true)
    ]
}
