import Foundation
import YardletAgentTools

/// The Slack app Yardlet asks the person to create, as an app manifest
/// (docs.slack.dev/reference/app-manifest) and the link that opens Slack's "create an app from a
/// manifest" flow with it filled in (docs.slack.dev/app-manifests/configuring-apps-with-app-manifests:
/// `https://api.slack.com/apps?new_app=1&manifest_json=<URL-encoded JSON>`). The person picks a
/// workspace, presses Create, and copies the client ID; nothing else is typed on Slack's side.
///
/// - The user scopes are the 30 Slack's MCP server advertises (`scopes_supported` at
///   `mcp.slack.com/.well-known/oauth-authorization-server`, read 2026-10-19), the same list as its
///   guide (docs.slack.dev/ai/mcp-server). No bot scopes: a desktop redirect may not ask for them.
/// - `settings.is_mcp_enabled` turns on MCP for the app, which Slack's MCP server requires of an
///   internal app (an app created in a workspace and not distributed is internal).
/// - `oauth_config.pkce_enabled`: Slack's OAuth guide says a redirect URL must use HTTPS, and
///   its PKCE guide says a `localhost` redirect counts as a desktop redirect only for an app that
///   opted into PKCE. Yardlet's redirect is the loopback `http://127.0.0.1:47823/callback`, so the
///   app uses PKCE, and a PKCE app sends no client secret (docs.slack.dev/authentication/using-pkce):
///   the client ID is all the person copies. Slack ends a PKCE app's refresh tokens after 30 days.
enum SlackAppManifest {
    static let appName = "Yardlet"

    static let userScopes = [
        "canvases:read", "canvases:write",
        "channels:history", "channels:read", "channels:write",
        "chat:write",
        "emoji:read",
        "files:read", "files:write",
        "groups:history", "groups:read", "groups:write",
        "im:history", "im:read", "im:write",
        "lists:read", "lists:write",
        "mpim:history", "mpim:read", "mpim:write",
        "reactions:read", "reactions:write",
        "search:read.files", "search:read.im", "search:read.mpim", "search:read.private", "search:read.public",
        "search:read.users",
        "users:read", "users:read.email"
    ]

    static var redirectURL: String { ConnectorOAuth.registeredClientRedirectURI.absoluteString }

    static var manifest: ToolJSON {
        .object([
            "display_information": .object([
                "name": .string(appName),
                "description": .string("Slack for the coding agents Yardlet runs, through Slack's MCP server."),
                "background_color": .string("#1f2933")
            ]),
            "oauth_config": .object([
                "redirect_urls": .array([.string(redirectURL)]),
                "scopes": .object(["user": .array(userScopes.map(ToolJSON.string))]),
                "pkce_enabled": .bool(true)
            ]),
            "settings": .object([
                "is_mcp_enabled": .bool(true),
                "org_deploy_enabled": .bool(false),
                "socket_mode_enabled": .bool(false)
            ])
        ])
    }

    /// The manifest as compact JSON with its keys in order, as the link carries it.
    static var json: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(manifest)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    /// The manifest laid out for reading and pasting into Slack's own manifest editor.
    static var prettyJSON: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted]
        return (try? encoder.encode(manifest)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    /// Slack's create-from-manifest page with Yardlet's manifest filled in. Everything outside
    /// RFC 3986's unreserved characters is percent-encoded, so the JSON's `&`, `=`, `+`, `#`, `:`,
    /// and `/` reach Slack as the manifest's own.
    static var createURL: URL {
        let unreserved = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let encoded = json.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
        return URL(string: "https://api.slack.com/apps?new_app=1&manifest_json=\(encoded)")!
    }

    /// Slack's list of the person's apps, where the new app's Basic Information page is.
    static let appsURL = URL(string: "https://api.slack.com/apps")!
}
