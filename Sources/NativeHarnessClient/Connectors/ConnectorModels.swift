import Foundation
import YardletAgentTools

/// A service the user connected in Yardlet: a remote MCP server (Streamable HTTP) that Yardlet
/// signs in to once and offers to every harness through the Yardlet MCP server
/// (docs/CONNECTORS.md). The record carries no secret; the credential lives in the platform's
/// secure store under the record's ID.
struct ConnectorRecord: Codable, Equatable, Identifiable, Sendable {
    enum Authorization: String, Codable, Sendable {
        /// Not decided yet: the first connection finds out what the server asks for.
        case unknown
        /// OAuth 2.1 with the server's authorization server (MCP authorization).
        case oauth
        /// An access token the user pasted, sent as a bearer token.
        case token
        /// The server answers without credentials.
        case none
    }

    enum Status: String, Codable, Sendable {
        /// Added but never connected, or disconnected by the user.
        case notConnected
        /// Signed in with a tool list; its tools reach new sessions.
        case connected
        /// The server refused the credential and a refresh did not help.
        case signInRequired
    }

    var id: UUID
    var name: String
    /// Prefix of this connector's tool names, unique among connectors.
    var slug: String
    var serverURL: URL
    var authorization: Authorization
    var status: Status
    /// The server's tools as its `tools/list` gave them, kept so a new session lists them without
    /// waiting for the network.
    var tools: [ToolJSON]
    var toolsUpdatedAt: Date?
    /// The directory entry it was added from (`ConnectorPreset.id`), for its icon and help.
    var presetID: String?
    /// An OAuth client the user registered with the service, for a server without dynamic client
    /// registration (Slack, Google). Its secret, if any, is in the secure store with the token.
    var oauthClientID: String?
    /// The scope to ask for at sign-in instead of the one the server advertises.
    var scope: String?
    /// Further authorization request parameters (Google's `access_type=offline`).
    var authorizationParameters: [String: String]?
    /// The query parameter the access token goes in, for a server that takes its key in the
    /// address (Browserbase); nil sends it as a bearer token.
    var tokenQueryParameter: String?
    /// The server Yardlet runs itself for this connector instead of a remote MCP server (Gmail
    /// through Google's public REST API); nil for a remote server. Absent in files from before.
    var localService: LocalConnectorService?
    /// The account the connector is signed in to, once known (a Gmail address). Several
    /// connectors of one local service are told apart by it.
    var account: String?
    /// For a Google service: the secure-store item of the Google account's one sign-in, which that
    /// account's Gmail, Calendar, and Drive share. Nil when it is this record's own ID: the first
    /// service of an account, and every Gmail account added before Calendar and Drive.
    var googleAccountID: UUID?
    /// The icons the server gave for itself when Yardlet last connected (`serverInfo.icons`), for
    /// its picture. Absent in files from before and for a server that gives none.
    var serverIcons: [MCPServerIcon]?

    init(
        id: UUID = UUID(),
        name: String,
        slug: String,
        serverURL: URL,
        authorization: Authorization = .unknown,
        status: Status = .notConnected,
        tools: [ToolJSON] = [],
        toolsUpdatedAt: Date? = nil,
        presetID: String? = nil,
        oauthClientID: String? = nil,
        scope: String? = nil,
        authorizationParameters: [String: String]? = nil,
        tokenQueryParameter: String? = nil,
        localService: LocalConnectorService? = nil,
        account: String? = nil,
        googleAccountID: UUID? = nil,
        serverIcons: [MCPServerIcon]? = nil
    ) {
        self.id = id
        self.name = name
        self.slug = slug
        self.serverURL = serverURL
        self.authorization = authorization
        self.status = status
        self.tools = tools
        self.toolsUpdatedAt = toolsUpdatedAt
        self.presetID = presetID
        self.oauthClientID = oauthClientID
        self.scope = scope
        self.authorizationParameters = authorizationParameters
        self.tokenQueryParameter = tokenQueryParameter
        self.localService = localService
        self.account = account
        self.googleAccountID = googleAccountID
        self.serverIcons = serverIcons
    }

    /// The secure-store item this connector's sign-in is under: its Google account's for a Google
    /// service, its own otherwise.
    var credentialID: UUID { googleAccountID ?? id }

    /// The directory entry. A local service's entry belongs only to a record of that service: a
    /// remote server once added under the same ID stays a plain remote server.
    var preset: ConnectorPreset? {
        guard let preset = presetID.flatMap(ConnectorPreset.preset(id:)) else { return nil }
        return (preset.signIn == .googleAccount) == (localService != nil) ? preset : nil
    }

    /// The tools it offers: a local service's own catalog, which comes with the app, or the
    /// remote server's list as it last gave it.
    var offeredTools: [ToolJSON] { localService?.tools ?? tools }

    /// "Gmail · person@example.com" where an account tells several apart; the name alone otherwise.
    var displayName: String { account.map { "\(name) · \($0)" } ?? name }

    /// Signs in with a client the user registered rather than one Yardlet registers itself.
    var usesRegisteredClient: Bool { oauthClientID?.isEmpty == false }

    /// A directory service that needs the user's own OAuth client (Slack, Google) or a token
    /// (GitHub, Browserbase) and has neither yet. Connecting would otherwise reach a server that
    /// lists tools to anyone and only refuses calls.
    var needsSetupBeforeConnecting: Bool {
        guard let preset, !usesRegisteredClient, authorization != .token else { return false }
        return preset.needsRegisteredClient || preset.usesToken
    }
}

/// A service whose MCP server Yardlet runs itself, inside the app, calling the service's public
/// API with the person's own sign-in. Its tools reach harnesses through the Yardlet MCP server
/// like any connector's (docs/CONNECTORS.md, "Google"). All three are Google's, signed in with the
/// one Google OAuth app the person registered: one sign-in per Google account carries the scopes of
/// the services turned on for it.
enum LocalConnectorService: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Gmail through the Gmail REST API.
    case gmail
    /// Google Calendar through the Calendar API v3.
    case googleCalendar = "google-calendar"
    /// Google Drive through the Drive API v3.
    case googleDrive = "google-drive"

    var id: String { rawValue }

    /// The directory entry (`ConnectorPreset.id`), which is the raw value.
    var presetID: String { rawValue }

    var name: String {
        switch self {
        case .gmail: "Gmail"
        case .googleCalendar: "Google Calendar"
        case .googleDrive: "Google Drive"
        }
    }

    /// The first account's tool prefix (`calendar_list_events`); a later account's adds its address.
    var slugBase: String {
        switch self {
        case .gmail: "gmail"
        case .googleCalendar: "calendar"
        case .googleDrive: "drive"
        }
    }

    /// The Google scopes its tools need, all asked for in the account's one sign-in.
    var scopes: [String] {
        switch self {
        case .gmail: [GmailToolCatalog.scope]
        case .googleCalendar: GoogleCalendarToolCatalog.scopes
        case .googleDrive: GoogleDriveToolCatalog.scopes
        }
    }

    var tools: [ToolJSON] {
        switch self {
        case .gmail: GmailToolCatalog.tools
        case .googleCalendar: GoogleCalendarToolCatalog.tools
        case .googleDrive: GoogleDriveToolCatalog.tools
        }
    }

    /// Tools each harness asks the person about before every call: sending and changing labels,
    /// writing events, creating and changing files.
    var approvalRequiredTools: Set<String> {
        switch self {
        case .gmail: GmailToolCatalog.approvalRequired
        case .googleCalendar: GoogleCalendarToolCatalog.approvalRequired
        case .googleDrive: GoogleDriveToolCatalog.approvalRequired
        }
    }

    /// The Google API that must be turned on in the person's Cloud project.
    var apiID: String {
        switch self {
        case .gmail: "gmail.googleapis.com"
        case .googleCalendar: "calendar-json.googleapis.com"
        case .googleDrive: "drive.googleapis.com"
        }
    }

    init?(presetID: String) {
        self.init(rawValue: presetID)
    }
}

/// What Yardlet keeps in the secure store for one connector.
struct ConnectorCredential: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case oauth
        case token
        /// Only the OAuth client the user registered (`ConnectorRecord.oauthClientID`), kept for the
        /// next sign-in; no token yet.
        case client
    }

    var kind: Kind
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date?
    var scope: String?
    /// The OAuth client Yardlet registered with the authorization server, needed to refresh.
    var clientID: String?
    var clientSecret: String?
    var tokenEndpoint: URL?
    /// `none`, `client_secret_post`, or `client_secret_basic`.
    var tokenEndpointAuthMethod: String?
    /// RFC 8707 resource indicator sent with every token request.
    var resource: String?

    static func token(_ value: String) -> ConnectorCredential {
        ConnectorCredential(kind: .token, accessToken: value)
    }

    static func client(id: String, secret: String?) -> ConnectorCredential {
        ConnectorCredential(kind: .client, accessToken: "", clientID: id, clientSecret: secret)
    }

    /// What goes to the server: nothing for a client kept before its first sign-in.
    var presentedToken: String? {
        kind == .client || accessToken.isEmpty ? nil : accessToken
    }

    /// The registered client alone, as a disconnect keeps it for the next sign-in.
    var clientOnly: ConnectorCredential? {
        guard let clientID, !clientID.isEmpty else { return nil }
        return .client(id: clientID, secret: clientSecret)
    }

    /// True when the access token is past, or within a minute of, its expiry.
    func needsRefresh(at now: Date) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSince(now) < 60
    }
}

/// The connector's secret, in the platform's secure store (the Keychain on macOS).
protocol ConnectorCredentialStoring: Sendable {
    func load(_ id: UUID) throws -> ConnectorCredential?
    func save(_ credential: ConnectorCredential, for id: UUID) throws
    func delete(_ id: UUID) throws
}

final class InMemoryConnectorCredentialStore: ConnectorCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var credentials: [UUID: ConnectorCredential] = [:]

    init(_ credentials: [UUID: ConnectorCredential] = [:]) {
        self.credentials = credentials
    }

    func load(_ id: UUID) throws -> ConnectorCredential? {
        lock.withLock { credentials[id] }
    }

    func save(_ credential: ConnectorCredential, for id: UUID) throws {
        lock.withLock { credentials[id] = credential }
    }

    func delete(_ id: UUID) throws {
        _ = lock.withLock { credentials.removeValue(forKey: id) }
    }
}

/// Names under which a connector's tools reach a harness. Claude Code and Codex call a tool
/// `mcp__yardlet__<name>` and the model APIs allow 64 characters of `[A-Za-z0-9_-]`, so a name
/// is the connector's slug, an underscore, and the server's tool name, cleaned and kept to 50.
enum ConnectorToolNaming {
    static let maximumLength = 50
    static let maximumSlugLength = 20

    /// A lowercase ASCII prefix from the connector's name. `browser` is the browser tools'.
    static func slug(for name: String, taken: Set<String>) -> String {
        var base = String(name.lowercased().unicodeScalars.map { scalar -> Character in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar)) ? Character(scalar) : "_"
        })
        base = base.split(separator: "_").joined(separator: "_")
        if base.count > maximumSlugLength { base = String(base.prefix(maximumSlugLength)) }
        base = base.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        if base.isEmpty { base = "connector" }
        let reserved = String(AgentToolCatalog.browserToolPrefix.dropLast())
        var candidate = base
        var suffix = 2
        while candidate == reserved || taken.contains(candidate) {
            candidate = "\(base)\(suffix)"
            suffix += 1
        }
        return candidate
    }

    static func name(slug: String, tool: String) -> String {
        let cleaned = String(tool.unicodeScalars.map { scalar -> Character in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "-")
                ? Character(scalar) : "_"
        })
        let full = "\(slug)_\(cleaned)"
        guard full.count > maximumLength else { return full }
        // Keep names distinct when two long names share a beginning.
        let hash = String(format: "%08x", fnv1a(tool))
        return "\(full.prefix(maximumLength - hash.count - 1))_\(hash)"
    }

    /// FNV-1a: stable across runs and platforms, unlike `Hasher`.
    private static func fnv1a(_ text: String) -> UInt32 {
        text.utf8.reduce(UInt32(2_166_136_261)) { ($0 ^ UInt32($1)) &* 16_777_619 }
    }
}
