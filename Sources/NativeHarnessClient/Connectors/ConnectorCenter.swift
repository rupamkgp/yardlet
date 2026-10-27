import Foundation
import Observation
import YardletAgentTools

/// The platform half of a sign-in: a loopback listener for the redirect and the user's browser.
protocol OAuthUserAgent: Sendable {
    /// Listens on a loopback address for one redirect: on `port`, for a client whose redirect URI
    /// the user registered, otherwise on any free port.
    func startLoopback(port: UInt16?) async throws -> any OAuthLoopbackReceiving
    /// Opens the sign-in page in the user's browser.
    func open(_ url: URL) async -> Bool
}

protocol OAuthLoopbackReceiving: Sendable {
    var redirectURI: URL { get }
    /// The first request to the redirect path, with its query. Ends with `CancellationError`
    /// when the waiting task is cancelled.
    func callback() async throws -> URL
    func stop()
}

/// Which connectors the user turned off in which task: task ID → connector IDs.
typealias ConnectorTaskChoices = [UUID: Set<UUID>]

@MainActor
protocol ConnectorRepository {
    func load() -> [ConnectorRecord]
    func save(_ records: [ConnectorRecord])
    func loadTaskChoices() -> ConnectorTaskChoices
    func saveTaskChoices(_ choices: ConnectorTaskChoices)
    /// The client ID of the Google OAuth app the person saved, which is not a secret (RFC 6749
    /// §2.2): Settings shows it without a keychain read. The app's secret is in the secure store.
    func loadGoogleAppClientID() -> String?
    func saveGoogleAppClientID(_ clientID: String?)
}

@MainActor
final class InMemoryConnectorRepository: ConnectorRepository {
    var records: [ConnectorRecord]
    var taskChoices: ConnectorTaskChoices
    var googleAppClientID: String?

    init(records: [ConnectorRecord] = [], taskChoices: ConnectorTaskChoices = [:], googleAppClientID: String? = nil) {
        self.records = records
        self.taskChoices = taskChoices
        self.googleAppClientID = googleAppClientID
    }

    func load() -> [ConnectorRecord] { records }
    func save(_ records: [ConnectorRecord]) { self.records = records }
    func loadTaskChoices() -> ConnectorTaskChoices { taskChoices }
    func saveTaskChoices(_ choices: ConnectorTaskChoices) { taskChoices = choices }
    func loadGoogleAppClientID() -> String? { googleAppClientID }
    func saveGoogleAppClientID(_ clientID: String?) { googleAppClientID = clientID }
}

/// `~/.yardlet/connectors.json`: names, addresses, status, each server's tool list, the
/// connectors turned off per task, and the Google OAuth app's client ID. Secrets are never
/// written here.
struct FileConnectorRepository: ConnectorRepository {
    private struct Snapshot: Codable {
        var version = 1
        var connectors: [ConnectorRecord]
        /// Task ID → connector IDs turned off in that task. Absent in files from before.
        var offInTasks: [String: [String]]?
        /// The Google OAuth app's client ID (not a secret). Absent in files from before.
        var googleOAuthClientID: String?
    }

    let fileURL: URL

    static func live(homeURL: URL = FileManager.default.homeDirectoryForCurrentUser) -> FileConnectorRepository {
        FileConnectorRepository(fileURL: homeURL
            .appending(path: YardletProduct.storageDirectoryName, directoryHint: .isDirectory)
            .appending(path: "connectors.json"))
    }

    private func snapshot() -> Snapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder.connectors.decode(Snapshot.self, from: data)
    }

    func load() -> [ConnectorRecord] {
        snapshot()?.connectors ?? []
    }

    func save(_ records: [ConnectorRecord]) {
        var current = snapshot() ?? Snapshot(connectors: [])
        current.connectors = records
        write(current)
    }

    func loadTaskChoices() -> ConnectorTaskChoices {
        var choices: ConnectorTaskChoices = [:]
        for (task, connectors) in snapshot()?.offInTasks ?? [:] {
            guard let taskID = UUID(uuidString: task) else { continue }
            let ids = Set(connectors.compactMap(UUID.init(uuidString:)))
            if !ids.isEmpty { choices[taskID] = ids }
        }
        return choices
    }

    func saveTaskChoices(_ choices: ConnectorTaskChoices) {
        var current = snapshot() ?? Snapshot(connectors: [])
        let kept = choices.filter { !$0.value.isEmpty }
        current.offInTasks = kept.isEmpty ? nil : Dictionary(uniqueKeysWithValues: kept.map { task, connectors in
            (task.uuidString, connectors.map(\.uuidString).sorted())
        })
        write(current)
    }

    func loadGoogleAppClientID() -> String? {
        snapshot()?.googleOAuthClientID
    }

    func saveGoogleAppClientID(_ clientID: String?) {
        var current = snapshot() ?? Snapshot(connectors: [])
        current.googleOAuthClientID = clientID
        write(current)
    }

    private func write(_ snapshot: Snapshot) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(snapshot) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}

private extension JSONDecoder {
    static var connectors: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// The connectors the user added, their sign-ins, and the tools they give harness sessions
/// through the Yardlet MCP server (docs/CONNECTORS.md).
@MainActor
@Observable
final class ConnectorCenter: ConnectorToolProviding {
    struct Environment {
        var repository: any ConnectorRepository
        var credentials: any ConnectorCredentialStoring
        var http: any ConnectorHTTPTransport
        /// Nil where this build cannot sign in (tests without a browser).
        var userAgent: (any OAuthUserAgent)?
        var sha256: @Sendable (Data) -> Data
        var clientVersion: String
        var now: @Sendable () -> Date = { Date() }
        var signInTimeout: Duration = .seconds(300)
        /// A cached tool list older than this is read again in the background when a session asks.
        var toolListMaximumAge: TimeInterval = 12 * 60 * 60
        /// Where harnesses keep their own MCP servers, for the read-only list and the import
        /// suggestions; the app adds saved accounts (`NativeMCPHome.all`).
        var nativeHomes: @MainActor () -> [NativeMCPHome] = { [] }
        /// Google's sign-in and API addresses, for the services Yardlet serves itself.
        var google: GoogleOAuth.Endpoints = .live
        /// The Google OAuth app this build carries; nil when it carries none.
        var googleBuiltInApp: GoogleOAuth.BuiltInApp?
        /// The client ID of Yardlet's own GitHub OAuth app, for GitHub's device sign-in; nil when
        /// the build carries none, and GitHub then takes a pasted token.
        var gitHubClientID: String?
        var gitHub: GitHubDeviceSignIn.Endpoints = .live
        /// Puts GitHub's code on the clipboard, so the person pastes it on GitHub's page.
        var copyToClipboard: @MainActor (String) -> Void = { _ in }
        /// Waits between GitHub token requests (tests pass one that does not).
        var gitHubPollSleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
        /// Waits before trying a token refresh the server could not answer again (tests pass one
        /// that does not).
        var refreshRetrySleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
        /// The zone Google Calendar reads a time without an offset in: the Mac's.
        var timeZone: @Sendable () -> TimeZone = { .current }
    }

    /// One Google account and the services turned on for it, each a connector of its own that
    /// shares the account's one sign-in.
    struct GoogleAccount: Identifiable, Equatable {
        /// The secure-store item of the account's sign-in (`ConnectorRecord.credentialID`).
        var id: UUID
        /// Its address once Google has said whose it is.
        var address: String?
        /// Its services' connectors, in the directory's order.
        var services: [ConnectorRecord]

        func record(_ service: LocalConnectorService) -> ConnectorRecord? {
            services.first { $0.localService == service }
        }

        var enabled: Set<LocalConnectorService> { Set(services.compactMap(\.localService)) }
    }

    enum Activity: Equatable, Sendable {
        case connecting
        /// The sign-in page is open in the browser.
        case waitingForBrowser
    }

    private(set) var connectors: [ConnectorRecord] {
        didSet {
            environment.repository.save(connectors)
            ConnectorToolLabels.shared.update(connectors)
            onToolsChanged?()
        }
    }
    private(set) var activity: [UUID: Activity] = [:]
    /// The last failure per connector, until the next attempt.
    private(set) var failures: [UUID: String] = [:]
    /// Connectors the user turned off per task (the composer's connector list).
    private(set) var offInTasks: ConnectorTaskChoices {
        didSet {
            environment.repository.saveTaskChoices(offInTasks)
            onToolsChanged?()
        }
    }
    /// Called after anything a task's tool list is made from changes: a connector added,
    /// connected, signed out, signed in again or removed, its server's list read again, or a
    /// connector turned on or off for a task. The Yardlet MCP server's broker then tells running
    /// tasks whose list changed (`AgentToolBroker.toolsMayHaveChanged`).
    @ObservationIgnored var onToolsChanged: (@MainActor () -> Void)?
    /// What each harness has in its own configuration, read when Settings asks.
    private(set) var nativeInventory: [NativeMCPInventoryEntry] = []
    /// The client ID of the Google OAuth app the person saved for Gmail, Calendar, and Drive; nil
    /// until one is saved. Its secret is in the secure store.
    private(set) var googleAppClientID: String? {
        didSet { environment.repository.saveGoogleAppClientID(googleAppClientID) }
    }

    /// The Google OAuth app this build carries, used when the person saved none of their own.
    var googleBuiltInApp: GoogleOAuth.BuiltInApp? { environment.googleBuiltInApp }

    /// Whether a Google account can sign in: with the person's app, or else the built-in one.
    var canSignInWithGoogle: Bool { googleAppClientID != nil || googleBuiltInApp != nil }

    /// The code GitHub's device page asks for, per connector, while its sign-in waits for it.
    private(set) var deviceCodes: [UUID: String] = [:]

    /// GitHub signs in with Yardlet's own app instead of a pasted token.
    var canSignInToGitHub: Bool { environment.gitHubClientID != nil }

    /// A GitHub connector without a token or an OAuth client of the person's own signs in on
    /// GitHub's device page with Yardlet's app.
    func signsInOnGitHub(_ record: ConnectorRecord) -> Bool {
        record.presetID == "github" && canSignInToGitHub && !record.usesRegisteredClient && record.authorization != .token
    }

    @ObservationIgnored private var environment: Environment
    @ObservationIgnored private var sessions: [UUID: ConnectorSession] = [:]
    @ObservationIgnored private var googleSessions: [UUID: GoogleAPISession] = [:]
    @ObservationIgnored private var connectTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var toolRefreshes: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var pendingDeletion: Task<Void, Never>?

    init(environment: Environment) {
        self.environment = environment
        connectors = environment.repository.load()
        offInTasks = environment.repository.loadTaskChoices()
        googleAppClientID = environment.repository.loadGoogleAppClientID()
        ConnectorToolLabels.shared.update(connectors)
    }

    /// Replaces where harness homes come from, once the app knows its saved accounts.
    func setNativeHomes(_ homes: @escaping @MainActor () -> [NativeMCPHome]) {
        environment.nativeHomes = homes
    }

    func record(_ id: UUID) -> ConnectorRecord? {
        connectors.first { $0.id == id }
    }

    // MARK: Editing

    /// Adds a connector. With a token, the token is its credential; with a client, that client
    /// signs in instead of one Yardlet registers; without either, connecting finds out whether
    /// the server wants a sign-in. A preset brings its icon, scope, and sign-in details.
    @discardableResult
    func add(
        name: String,
        serverURL: URL,
        token: String? = nil,
        client: (id: String, secret: String?)? = nil,
        preset: ConnectorPreset? = nil
    ) async throws -> ConnectorRecord {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = trimmedName.isEmpty ? (preset?.name ?? serverURL.host() ?? "Connector") : trimmedName
        let matchingPreset = preset ?? ConnectorPreset.preset(for: serverURL)
            .flatMap { MCPServerAddress.canonical($0.serverURL) == MCPServerAddress.canonical(serverURL) ? $0 : nil }
        var record = ConnectorRecord(
            name: displayName,
            slug: ConnectorToolNaming.slug(for: displayName, taken: Set(connectors.map(\.slug))),
            serverURL: serverURL,
            presetID: matchingPreset?.id,
            scope: matchingPreset?.scope,
            authorizationParameters: matchingPreset.map { $0.authorizationParameters.isEmpty ? nil : $0.authorizationParameters } ?? nil,
            tokenQueryParameter: matchingPreset?.tokenQueryParameter
        )
        if matchingPreset?.signIn == ConnectorPreset.SignIn.none { record.authorization = .none }
        let id = record.id
        if let token = token?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            try await store { try $0.save(.token(token), for: id) }
            record.authorization = .token
        } else if let client, let clientID = Self.trimmed(client.id) {
            let secret = Self.trimmed(client.secret)
            try await store { try $0.save(.client(id: clientID, secret: secret), for: id) }
            record.oauthClientID = clientID
            record.authorization = .oauth
        }
        connectors.append(record)
        return record
    }

    /// Makes a pasted access token the connector's credential and connects with it, for a server
    /// that has no sign-in Yardlet can use.
    func useToken(_ token: String, for id: UUID) async throws {
        let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, record(id) != nil else { return }
        try await replaceCredential(.token(value), for: id)
        update(id) {
            $0.authorization = .token
            $0.oauthClientID = nil
        }
        connect(id)
    }

    /// Makes an OAuth client the user registered with the service the one this connector signs
    /// in with, then signs in.
    func useRegisteredClient(id clientID: String, secret: String?, for id: UUID) async throws {
        guard let clientID = Self.trimmed(clientID), record(id) != nil else { return }
        try await replaceCredential(.client(id: clientID, secret: Self.trimmed(secret)), for: id)
        update(id) {
            $0.authorization = .oauth
            $0.oauthClientID = clientID
        }
        connect(id)
    }

    // MARK: Google OAuth app and accounts

    /// Saves the Google OAuth app the person registered: both values in the secure store, the
    /// client ID also in `connectors.json` for Settings. A new app replaces the old; accounts
    /// already signed in keep the client they signed in with until they sign in again.
    func saveGoogleApp(clientID: String, secret: String?) async throws {
        guard let id = Self.trimmed(clientID) else { return }
        let credential = ConnectorCredential.client(id: id, secret: Self.trimmed(secret))
        try await store { try $0.save(credential, for: GoogleOAuth.appCredentialID) }
        googleAppClientID = id
    }

    /// Forgets the saved Google OAuth app. Signed-in accounts keep working until a sign-in is
    /// needed again, which then uses the built-in app or, without one, asks for an app.
    func removeGoogleApp() async throws {
        try await store { try $0.delete(GoogleOAuth.appCredentialID) }
        googleAppClientID = nil
    }

    /// The Gmail accounts, in the order they were added.
    var gmailAccounts: [ConnectorRecord] {
        connectors.filter { $0.localService == .gmail }
    }

    /// The Google accounts, in the order they were added, each with its services.
    var googleAccounts: [GoogleAccount] {
        var order: [UUID] = []
        var groups: [UUID: [ConnectorRecord]] = [:]
        for record in connectors where record.localService != nil {
            if groups[record.credentialID] == nil { order.append(record.credentialID) }
            groups[record.credentialID, default: []].append(record)
        }
        let rank = Dictionary(uniqueKeysWithValues: LocalConnectorService.allCases.enumerated().map { ($1, $0) })
        return order.map { id in
            let records = (groups[id] ?? []).sorted { rank[$0.localService!]! < rank[$1.localService!]! }
            return GoogleAccount(id: id, address: records.compactMap(\.account).first, services: records)
        }
    }

    private func googleRecords(_ accountID: UUID) -> [ConnectorRecord] {
        connectors.filter { $0.localService != nil && $0.credentialID == accountID }
    }

    /// Adds a Gmail account and signs it in (`addGoogleAccount` with Gmail alone).
    @discardableResult
    func addGmailAccount() -> ConnectorRecord? {
        addGoogleAccount(services: [.gmail])?.services.first
    }

    /// Adds a Google account with the services the person chose and signs it in once: the browser
    /// opens Google's account chooser and asks for those services' scopes together. The account's
    /// address names its connectors once Google says whose account it is.
    @discardableResult
    func addGoogleAccount(services: Set<LocalConnectorService>) -> GoogleAccount? {
        let chosen = LocalConnectorService.allCases.filter(services.contains)
        guard !chosen.isEmpty else { return nil }
        var accountID: UUID?
        for service in chosen {
            // The first service's own ID is the account's sign-in item, as a Gmail account's always was.
            let record = makeGoogleRecord(service, address: nil, accountID: accountID)
            accountID = accountID ?? record.id
            connectors.append(record)
        }
        guard let accountID else { return nil }
        connect(accountID)
        return googleAccounts.first { $0.id == accountID }
    }

    /// Turns a service on or off for a Google account. On adds its connector, connected at once
    /// when the account's sign-in already holds its scopes, or after one more Google consent for
    /// them otherwise (incremental authorization). Off removes the connector; the sign-in stays
    /// for the account's other services and goes with the last.
    func setGoogleService(_ service: LocalConnectorService, on: Bool, account accountID: UUID) async {
        guard let account = googleAccounts.first(where: { $0.id == accountID }) else { return }
        guard on else {
            if let record = account.record(service) { remove(record.id) }
            return
        }
        guard account.record(service) == nil else { return }
        let record = makeGoogleRecord(service, address: account.address, accountID: accountID)
        connectors.append(record)
        let stored = try? await store { try $0.load(accountID) }
        if let stored, stored.kind == .oauth, stored.refreshToken != nil,
           GoogleOAuth.grantedServices(stored.scope, of: [service]).contains(service), account.address != nil {
            update(record.id) {
                $0.status = .connected
                $0.toolsUpdatedAt = environment.now()
            }
        } else {
            connect(record.id)
        }
    }

    /// Signs a Google account out of Yardlet: all its services' connectors and its sign-in.
    func removeGoogleAccount(_ accountID: UUID) {
        for record in googleRecords(accountID) { remove(record.id) }
    }

    /// A new connector for one service of a Google account. Its tools are named after the service
    /// (`calendar_…`), or after the service and the account (`calendar_work_…`) when another
    /// account has that name already.
    private func makeGoogleRecord(_ service: LocalConnectorService, address: String?, accountID: UUID?) -> ConnectorRecord {
        let taken = Set(connectors.map(\.slug))
        let base = if let address, taken.contains(service.slugBase) {
            "\(service.slugBase) \(address.split(separator: "@").first.map(String.init) ?? address)"
        } else {
            service.slugBase
        }
        return ConnectorRecord(
            name: service.name,
            slug: ConnectorToolNaming.slug(for: base, taken: taken),
            serverURL: environment.google.base(for: service),
            authorization: .oauth,
            presetID: service.presetID,
            scope: service.scopes.joined(separator: " "),
            localService: service,
            account: address,
            googleAccountID: accountID
        )
    }

    private func replaceCredential(_ credential: ConnectorCredential, for id: UUID) async throws {
        cancelConnect(id)
        await connectTasks[id]?.value
        await pendingDeletion?.value
        try await store { try $0.save(credential, for: id) }
        sessions[id] = nil
    }

    /// Connects in the background: reads the tool list, signing in first when the server asks
    /// or when the connector signs in with a registered client, or always with `signingInAgain`.
    /// A Google service connects its whole account, whose services share one sign-in.
    func connect(_ id: UUID, signingInAgain: Bool = false) {
        guard let record = record(id) else { return }
        let key = taskKey(id)
        guard connectTasks[key] == nil else { return }
        connectTasks[key] = Task { [weak self] in
            if record.localService != nil {
                await self?.performGoogleConnect(account: key, signingInAgain: signingInAgain)
            } else {
                await self?.performConnect(id, signingInAgain: signingInAgain)
            }
        }
    }

    /// The connection a connector's work runs under: its Google account's for a Google service.
    private func taskKey(_ id: UUID) -> UUID {
        guard let record = record(id), record.localService != nil else { return id }
        return record.credentialID
    }

    /// Signs in again even while the stored OAuth sign-in works. That sign-in stays until the new
    /// one is saved, so a sign-in the person cancels, or one that fails, leaves the connection and
    /// its tools as they were. A pasted token is kept, since only the user can replace it. A
    /// Google service signs its account in again, for all the account's services.
    func reconnect(_ id: UUID) {
        guard let record = record(id) else { return }
        guard record.authorization == .oauth else { return connect(id) }
        cancelConnect(id)
        connect(id, signingInAgain: true)
    }

    /// Waits for a connection started by `connect`; for callers that need the outcome.
    func waitForConnection(_ id: UUID) async {
        await connectTasks[taskKey(id)]?.value
    }

    func cancelConnect(_ id: UUID) {
        connectTasks[taskKey(id)]?.cancel()
    }

    /// Forgets the token. The connector and a client the user registered stay, and its tools
    /// leave new sessions. A Google service's sign-in is its account's, so the account's other
    /// services go with it.
    func disconnect(_ id: UUID) {
        let key = taskKey(id)
        cancelConnect(id)
        forgetCredential(key, keepingClient: true)
        sessions[id] = nil
        googleSessions[key] = nil
        let affected = record(id)?.localService == nil ? [id] : googleRecords(key).map(\.id)
        for other in affected {
            failures[other] = nil
            update(other) { $0.status = .notConnected }
        }
    }

    func remove(_ id: UUID) {
        let key = taskKey(id)
        // A Google service's sign-in stays while another service of its account uses it.
        let shared = record(id)?.localService != nil
            && connectors.contains { $0.id != id && $0.localService != nil && $0.credentialID == key }
        if !shared {
            cancelConnect(id)
            forgetCredential(key, keepingClient: false)
            googleSessions[key] = nil
        }
        toolRefreshes.removeValue(forKey: id)?.cancel()
        sessions[id] = nil
        failures[id] = nil
        activity[id] = nil
        connectors.removeAll { $0.id == id }
        let pruned = offInTasks.compactMapValues { set -> Set<UUID>? in
            let rest = set.subtracting([id])
            return rest.isEmpty ? nil : rest
        }
        if pruned != offInTasks { offInTasks = pruned }
    }

    private func performConnect(_ id: UUID, signingInAgain: Bool) async {
        defer {
            connectTasks[id] = nil
            activity[id] = nil
            deviceCodes[id] = nil
        }
        // A disconnect just before must not leave its old credential for this connection to find.
        await pendingDeletion?.value
        guard let record = record(id) else { return }
        guard !record.needsSetupBeforeConnecting || signsInOnGitHub(record) else {
            failures[id] = ConnectorOAuthError.noDynamicRegistration.errorDescription
            return
        }
        failures[id] = nil
        activity[id] = .connecting
        let session = session(for: record)
        do {
            var tools: [ToolJSON] = []
            let stored = try await store { try $0.load(id) }
            if signingInAgain {
                // Asked without the stored token, the server says where to sign in as it does
                // the first time; the stored token serves the tools until the new one is saved.
                try await signInAndUse(record, challenge: await challengeWithoutToken(record), session: session)
                tools = try await session.listTools()
            } else if record.usesRegisteredClient, stored?.kind != .oauth {
                // A server can list its tools to anyone and refuse only calls (Google's), so a
                // connector with a registered client signs in before it counts as connected.
                try await signInAndUse(record, challenge: nil, session: session)
                tools = try await session.listTools()
            } else {
                do {
                    tools = try await session.listTools()
                    if record.authorization == .unknown, stored == nil {
                        update(id) { $0.authorization = .none }
                    }
                } catch ConnectorSession.Failure.signInRequired(let challenge) {
                    guard record.authorization != .token else { throw ConnectorSession.Failure.signInRequired(challenge) }
                    try await signInAndUse(record, challenge: challenge, session: session)
                    tools = try await session.listTools()
                }
            }
            let icons = await session.serverIcons()
            update(id) {
                $0.status = .connected
                $0.tools = tools
                $0.toolsUpdatedAt = environment.now()
                $0.serverIcons = icons.isEmpty ? nil : icons
            }
        } catch let error where Self.isCancellation(error) {
            return
        } catch {
            if Task.isCancelled { return }
            failures[id] = message(for: error, connector: record)
            if case ConnectorSession.Failure.signInRequired = error, self.record(id)?.status == .connected {
                update(id) { $0.status = .signInRequired }
            }
        }
    }

    /// The server's challenge to a request that carries no token, or nil when it sent none.
    private func challengeWithoutToken(_ record: ConnectorRecord) async -> BearerChallenge? {
        let client = MCPHTTPClient(endpoint: record.serverURL, transport: environment.http,
                                   clientVersion: environment.clientVersion)
        do {
            _ = try await client.listTools()
        } catch MCPHTTPError.unauthorized(let challenge) {
            return challenge
        } catch {}
        return nil
    }

    private func signInAndUse(_ record: ConnectorRecord, challenge: BearerChallenge?, session: ConnectorSession) async throws {
        let credential = try await signIn(record, challenge: challenge)
        let id = record.id
        try await store { try $0.save(credential, for: id) }
        await session.use(credential)
        update(id) { $0.authorization = .oauth }
    }

    private func signIn(_ record: ConnectorRecord, challenge: BearerChallenge?) async throws -> ConnectorCredential {
        guard let userAgent = environment.userAgent else { throw ConnectorOAuthError.cannotOpenBrowser }
        if signsInOnGitHub(record), let clientID = environment.gitHubClientID {
            return try await signInOnGitHub(record, clientID: clientID, userAgent: userAgent)
        }
        let http = environment.http
        var plan = try await ConnectorOAuth.discover(serverURL: record.serverURL, challenge: challenge, http: http)
        if let scope = record.scope, !scope.isEmpty { plan.scope = scope }
        let id = record.id
        let registered: OAuthClient? = if record.usesRegisteredClient {
            try await store { try $0.load(id) }.flatMap { credential in
                credential.clientID.map {
                    ConnectorOAuth.registeredClient(id: $0, secret: credential.clientSecret, server: plan.server)
                }
            } ?? ConnectorOAuth.registeredClient(id: record.oauthClientID ?? "", secret: nil, server: plan.server)
        } else {
            nil
        }
        let loopback = try await userAgent.startLoopback(port: registered == nil ? nil : ConnectorOAuth.registeredClientRedirectPort)
        defer { loopback.stop() }
        let client: OAuthClient = if let registered {
            registered
        } else {
            try await ConnectorOAuth.register(with: plan.server, redirectURI: loopback.redirectURI, http: http)
        }
        let verifier = ConnectorOAuth.randomToken()
        let state = ConnectorOAuth.randomToken()
        let url = ConnectorOAuth.authorizationURL(
            plan: plan,
            client: client,
            redirectURI: loopback.redirectURI,
            state: state,
            codeChallenge: ConnectorOAuth.codeChallenge(for: verifier, sha256: environment.sha256),
            extraParameters: record.authorizationParameters ?? [:]
        )
        activity[record.id] = .waitingForBrowser
        guard await userAgent.open(url) else { throw ConnectorOAuthError.cannotOpenBrowser }
        let callback = try await Self.withTimeout(environment.signInTimeout) { try await loopback.callback() }
        activity[record.id] = .connecting
        let code = try ConnectorOAuth.code(fromCallback: callback, expectedState: state)
        return try await ConnectorOAuth.exchange(
            code: code, verifier: verifier, plan: plan, client: client,
            redirectURI: loopback.redirectURI, http: http, now: environment.now()
        )
    }

    /// GitHub's device flow: Yardlet asks GitHub for a code, puts it on the clipboard and beside
    /// the connector, and opens GitHub's device page; the person pastes it and authorizes, while
    /// Yardlet asks for the token until then (`GitHubDeviceSignIn`).
    private func signInOnGitHub(_ record: ConnectorRecord, clientID: String,
                                userAgent: any OAuthUserAgent) async throws -> ConnectorCredential {
        let http = environment.http
        let endpoints = environment.gitHub
        let code = try await GitHubDeviceSignIn.requestCode(clientID: clientID, endpoints: endpoints, http: http)
        deviceCodes[record.id] = code.userCode
        defer { deviceCodes[record.id] = nil }
        environment.copyToClipboard(code.userCode)
        activity[record.id] = .waitingForBrowser
        guard await userAgent.open(code.verificationURI) else { throw ConnectorOAuthError.cannotOpenBrowser }
        let now = environment.now
        let credential = try await GitHubDeviceSignIn.waitForToken(
            clientID: clientID, code: code, endpoints: endpoints, http: http,
            sleep: environment.gitHubPollSleep, now: now)
        activity[record.id] = .connecting
        return credential
    }

    private static func withTimeout<T: Sendable>(
        _ timeout: Duration,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw ConnectorOAuthError.timedOut
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    // MARK: Google accounts (Yardlet's own servers)

    /// Signs the account in when it has no lasting sign-in or lacks a turned-on service's scopes,
    /// or always with `signingInAgain`, asking Google for every service of the account at once,
    /// then asks Google whose account it is. A sign-in Google no longer accepts leaves its
    /// services needing sign-in ("Reconnect").
    private func performGoogleConnect(account accountID: UUID, signingInAgain: Bool) async {
        defer {
            connectTasks[accountID] = nil
            for record in googleRecords(accountID) { activity[record.id] = nil }
        }
        // A disconnect just before must not leave its old credential for this connection to find.
        await pendingDeletion?.value
        let records = googleRecords(accountID)
        guard let first = records.first else { return }
        let address = records.compactMap(\.account).first
        let services = records.compactMap(\.localService)
        for record in records {
            failures[record.id] = nil
            activity[record.id] = .connecting
        }
        let session = googleSession(accountID)
        do {
            var credential = try await store { try $0.load(accountID) }
            var signedIn: ConnectorCredential?
            if signingInAgain || credential?.kind != .oauth || credential?.refreshToken == nil
                || GoogleOAuth.grantedServices(credential?.scope, of: services).count < Set(services).count {
                signedIn = try await signInWithGoogle(account: accountID, address: address, services: services)
                credential = signedIn
            }
            let granted = GoogleOAuth.grantedServices(credential?.scope, of: services)
            guard !granted.isEmpty else { throw GoogleSignInError.scopeNotGranted(services) }
            // A new sign-in is read on a session of its own and replaces the stored one only once
            // it is the account's: until then the earlier sign-in serves the account's tools, and
            // one as another account leaves it as it was.
            var reading = session
            if let signedIn {
                reading = GoogleAPISession(id: accountID, credentials: InMemoryConnectorCredentialStore(),
                                           http: environment.http, now: environment.now)
                await reading.use(signedIn)
            }
            let identity = try await googleAddress(session: reading, granted: granted)
            if let address, address.lowercased() != identity.lowercased() {
                let text = L10n.format("Google signed in %@, not %@. Reconnect and choose %@.", identity, address, address)
                for record in googleRecords(accountID) { failures[record.id] = text }
                return
            }
            if let signedIn {
                try await store { try $0.save(signedIn, for: accountID) }
                await session.use(signedIn)
            }
            try await settleGoogleAccount(accountID, address: identity, scope: credential?.scope)
        } catch let error where Self.isCancellation(error) {
            // A first sign-in the person cancelled, in Yardlet or on Google's page, leaves no
            // account behind.
            if address == nil {
                for record in googleRecords(accountID) where record.account == nil { remove(record.id) }
            }
            return
        } catch GoogleAPISession.Failure.signInRequired {
            if Task.isCancelled { return }
            for record in googleRecords(accountID) { update(record.id) { $0.status = .signInRequired } }
        } catch {
            if Task.isCancelled { return }
            let text = message(for: error, connector: first)
            for record in googleRecords(accountID) { failures[record.id] = text }
        }
    }

    /// Whose account a sign-in is, from a service it can read: Gmail's profile, the primary
    /// calendar's ID, or Drive's user.
    private func googleAddress(session: GoogleAPISession, granted: Set<LocalConnectorService>) async throws -> String {
        let address: String?
        if granted.contains(.gmail) {
            address = try await GmailAPI(base: environment.google.gmailAPI, session: session).profile()["emailAddress"]?.stringValue
        } else if granted.contains(.googleCalendar) {
            address = try await GoogleREST(base: environment.google.calendarAPI, session: session)
                .get(["users", "me", "calendarList", "primary"])["id"]?.stringValue
        } else {
            address = try await GoogleREST(base: environment.google.driveAPI, session: session)
                .get(["about"], [URLQueryItem(name: "fields", value: "user(emailAddress)")])["user"]?["emailAddress"]?.stringValue
        }
        guard let address, !address.isEmpty else { throw GoogleREST.Failure.unreadableAnswer }
        return address
    }

    /// Names a new account by its address, or hands its services and sign-in to the account that
    /// already has that address. Each service is connected when the sign-in holds its scopes, and
    /// says so otherwise.
    private func settleGoogleAccount(_ accountID: UUID, address: String, scope: String?) async throws {
        let records = googleRecords(accountID)
        var target = accountID
        if records.allSatisfy({ $0.account == nil }),
           let existing = googleAccounts.first(where: { $0.id != accountID && $0.address?.lowercased() == address.lowercased() }) {
            // The same account signed in twice: one account, with the newer sign-in, which holds what
            // was granted before as well (`include_granted_scopes`).
            if let credential = try await store({ try $0.load(accountID) }) {
                try await store { try $0.save(credential, for: existing.id) }
            }
            try await store { try $0.delete(accountID) }
            googleSessions[accountID] = nil
            googleSessions[existing.id] = nil
            for record in records {
                if let service = record.localService, existing.record(service) != nil {
                    connectors.removeAll { $0.id == record.id }
                } else {
                    update(record.id) { $0.googleAccountID = existing.id }
                }
            }
            target = existing.id
        }
        let granted = GoogleOAuth.grantedServices(scope, of: googleRecords(target).compactMap(\.localService))
        for record in googleRecords(target) {
            guard let service = record.localService else { continue }
            let firstSignIn = record.account == nil
            update(record.id) {
                $0.account = $0.account ?? address
                $0.status = granted.contains(service) ? .connected : .signInRequired
                if granted.contains(service) { $0.toolsUpdatedAt = environment.now() }
            }
            failures[record.id] = granted.contains(service) ? nil : GoogleSignInError.scopeNotGranted([service]).errorDescription
            // A second account's tools are named after it (`gmail_work_…`), the first keeps `gmail_…`.
            if firstSignIn, record.slug != service.slugBase {
                let local = address.split(separator: "@").first.map(String.init) ?? address
                let taken = Set(connectors.filter { $0.id != record.id }.map(\.slug))
                let slug = ConnectorToolNaming.slug(for: "\(service.slugBase) \(local)", taken: taken)
                update(record.id) { $0.slug = slug }
            }
        }
    }

    private func signInWithGoogle(account accountID: UUID, address: String?,
                                  services: [LocalConnectorService]) async throws -> ConnectorCredential {
        guard let userAgent = environment.userAgent else { throw ConnectorOAuthError.cannotOpenBrowser }
        let saved = try await store { try $0.load(GoogleOAuth.appCredentialID) }
        let app: (id: String, secret: String?)
        if let id = saved?.clientID, !id.isEmpty {
            app = (id, saved?.clientSecret)
        } else if let builtIn = environment.googleBuiltInApp {
            app = (builtIn.clientID, builtIn.clientSecret)
        } else {
            throw GoogleSignInError.noApp
        }
        let plan = GoogleOAuth.plan(scope: GoogleOAuth.scope(for: services), endpoints: environment.google)
        let client = ConnectorOAuth.registeredClient(id: app.id, secret: app.secret, server: plan.server)
        let loopback = try await userAgent.startLoopback(port: ConnectorOAuth.registeredClientRedirectPort)
        defer { loopback.stop() }
        let verifier = ConnectorOAuth.randomToken()
        let state = ConnectorOAuth.randomToken()
        let url = ConnectorOAuth.authorizationURL(
            plan: plan,
            client: client,
            redirectURI: loopback.redirectURI,
            state: state,
            codeChallenge: ConnectorOAuth.codeChallenge(for: verifier, sha256: environment.sha256),
            extraParameters: GoogleOAuth.authorizationParameters(account: address)
        )
        for record in googleRecords(accountID) { activity[record.id] = .waitingForBrowser }
        guard await userAgent.open(url) else { throw ConnectorOAuthError.cannotOpenBrowser }
        let callback = try await Self.withTimeout(environment.signInTimeout) { try await loopback.callback() }
        for record in googleRecords(accountID) { activity[record.id] = .connecting }
        let code = try ConnectorOAuth.code(fromCallback: callback, expectedState: state)
        let credential = try await ConnectorOAuth.exchange(
            code: code, verifier: verifier, plan: plan, client: client,
            redirectURI: loopback.redirectURI, http: environment.http, now: environment.now()
        )
        guard credential.refreshToken?.isEmpty == false else { throw GoogleSignInError.noRefreshToken }
        guard !GoogleOAuth.grantedServices(credential.scope, of: services).isEmpty else {
            throw GoogleSignInError.scopeNotGranted(services)
        }
        return credential
    }

    /// The account's one session, so its services refresh its token one at a time.
    private func googleSession(_ accountID: UUID) -> GoogleAPISession {
        if let session = googleSessions[accountID] { return session }
        let session = GoogleAPISession(id: accountID, credentials: environment.credentials, http: environment.http,
                                       now: environment.now)
        googleSessions[accountID] = session
        return session
    }

    private func callGoogleTool(_ record: ConnectorRecord, tool: String, arguments: ToolJSON) async -> AgentToolResult {
        let session = googleSession(record.credentialID)
        let google = environment.google
        do {
            switch record.localService {
            case .gmail?:
                return try await GmailToolRunner(api: GmailAPI(base: google.gmailAPI, session: session)).call(tool, arguments)
            case .googleCalendar?:
                return try await GoogleCalendarToolRunner(api: GoogleREST(base: google.calendarAPI, session: session),
                                                          timeZone: environment.timeZone(), now: environment.now)
                    .call(tool, arguments)
            case .googleDrive?:
                return try await GoogleDriveToolRunner(api: GoogleREST(base: google.driveAPI, session: session),
                                                       uploadBase: google.driveUpload)
                    .call(tool, arguments)
            case nil:
                return .error("Unknown tool: \(tool)")
            }
        } catch GoogleAPISession.Failure.signInRequired {
            for other in googleRecords(record.credentialID) { update(other.id) { $0.status = .signInRequired } }
            return .error("\(record.displayName) needs the user to sign in again: Yardlet Settings → Connectors → "
                + "\(record.name) → Reconnect.")
        } catch let failure as GmailAPI.Failure {
            return .error("\(record.name): \(failure.localizedDescription)")
        } catch let failure as GoogleREST.Failure {
            return .error("\(record.name): \(failure.localizedDescription)")
        } catch {
            return .error("Could not reach \(record.name): \(error.localizedDescription)")
        }
    }

    // MARK: Per task

    /// Whether a connector reaches a task, and if not, why. The scope is what Yardlet knew of
    /// the task's harness when it injected the server; nil (as for a task not started yet) only
    /// applies the user's choice.
    func state(of record: ConnectorRecord, inTask taskID: UUID?, scope: ConnectorTaskScope?) -> ConnectorTaskState {
        if let scope, !scope.carriesConnectors { return .unsupportedHarness }
        if let scope {
            let address = MCPServerAddress.canonical(record.serverURL)
            if scope.nativeServerURLs.contains(address), !scope.yardletServedURLs.contains(address) { return .harnessHasIt }
        }
        if let taskID, offInTasks[taskID]?.contains(record.id) == true { return .off }
        return .on
    }

    func isOn(_ connectorID: UUID, inTask taskID: UUID) -> Bool {
        offInTasks[taskID]?.contains(connectorID) != true
    }

    /// Turns a connector on or off for one task. A call to its tools follows at once; the task's
    /// tool list follows after its turn, in a harness that lists again when told (Claude Code),
    /// and otherwise when the task next starts or resumes.
    func setConnector(_ connectorID: UUID, on: Bool, inTask taskID: UUID) {
        var set = offInTasks[taskID] ?? []
        if on { set.remove(connectorID) } else { set.insert(connectorID) }
        offInTasks[taskID] = set.isEmpty ? nil : set
    }

    /// The scope a task gets: the remote servers its harness loads itself, read from that
    /// harness's files for the task's account and folder.
    static func scope(for session: SessionRecord, locations: HarnessModelSettingsLocations = .live()) -> ConnectorTaskScope {
        let folder = locations.folder(for: session.harness, connection: session.connection, scope: session.environmentScope)
        let servers = NativeMCPInventory.loadedRemoteServerEntries(
            harness: session.harness, configFolder: folder, workspaceURL: session.workspaceURL,
            originWorkspaceURL: session.originWorkspaceURL)
        return ConnectorTaskScope(harness: session.harness, nativeServerURLs: Set(servers.map(\.address)),
                                  nativeServers: servers)
    }

    /// The scope with Yardlet's connectors standing in for the harness's own servers at the same
    /// address, where the harness can leave a server out of one process (Claude Code) and the
    /// connector is connected now. One sign-in, Yardlet's, then serves every account and folder:
    /// Claude Code keeps MCP sign-ins per config directory, so each account would need its own and
    /// one without it holds the server back in the others (docs/CONNECTORS.md, "하네스 자체 서버"). A connector
    /// that is not connected, or needs a new sign-in, leaves the harness's server in place; a
    /// change applies from the task's next start.
    func withYardletStandIns(_ scope: ConnectorTaskScope) -> ConnectorTaskScope {
        guard ConnectorTaskScope.canLeaveOutNativeServers(scope.harness), scope.carriesConnectors else { return scope }
        var scope = scope
        scope.yardletServedURLs = Set(connectors.filter { $0.status == .connected && $0.localService == nil }
            .map { MCPServerAddress.canonical($0.serverURL) }).intersection(scope.nativeServerURLs)
        return scope
    }

    // MARK: Harness configurations

    /// Reads every harness home's servers off the main thread and publishes them.
    func loadNativeInventory() async {
        let homes = environment.nativeHomes()
        nativeInventory = await Task.detached { NativeMCPInventory.read(homes) }.value
    }

    var importSuggestions: [ConnectorImportSuggestion] {
        ConnectorImportSuggestion.suggestions(from: nativeInventory, connected: connectors)
    }

    // MARK: Tools for harness sessions

    var offersTools: Bool {
        connectors.contains { $0.status == .connected }
    }

    /// A connector that worked and now needs a new sign-in keeps its tools in the list, each call
    /// saying so: signing in again then needs no new list, so a running task's calls work at once
    /// in every harness, including one that reads the list only when it starts (Codex). One that
    /// never connected (a Google service whose scope was left unchecked) offers none.
    func connectorTools(for context: ConnectorToolContext) async -> [ToolJSON] {
        var names = Set<String>()
        var tools: [ToolJSON] = []
        for record in connectors where record.status == .connected
            || (record.status == .signInRequired && record.toolsUpdatedAt != nil) {
            guard state(of: record, inTask: context.taskID, scope: context.scope) == .on else { continue }
            if record.localService == nil, record.status == .connected { refreshToolsIfStale(record) }
            for tool in record.offeredTools {
                guard let exposed = Self.exposedTool(tool, of: record),
                      let name = exposed["name"]?.stringValue, names.insert(name).inserted
                else { continue }
                tools.append(exposed)
            }
        }
        return tools
    }

    func callConnectorTool(named name: String, arguments: ToolJSON, for context: ConnectorToolContext) async -> AgentToolResult? {
        guard let (record, toolName) = owner(ofTool: name) else { return nil }
        switch state(of: record, inTask: context.taskID, scope: context.scope) {
        case .on:
            break
        case .off:
            return .error("\(record.name) is turned off for this task in Yardlet. The user can turn it on in the "
                + "composer's + → Connectors.")
        case .harnessHasIt:
            return .error("This task's harness has its own \(record.name) server; use that one's tools.")
        case .unsupportedHarness:
            return .error("Yardlet's connectors are not offered to this harness.")
        }
        switch record.status {
        case .connected:
            break
        case .signInRequired:
            return .error("\(record.displayName) needs the user to sign in again: Yardlet Settings → Connectors → "
                + "\(record.name). Once they have, the same tool works again.")
        case .notConnected:
            return .error("\(record.displayName) is not connected in Yardlet. The user can connect it in Yardlet "
                + "Settings → Connectors; the same tool works again once they have.")
        }
        if record.localService != nil { return await callGoogleTool(record, tool: toolName, arguments: arguments) }
        do {
            let result = try await session(for: record).callTool(name: toolName, arguments: arguments)
            return Self.toolResult(result)
        } catch ConnectorSession.Failure.signInRequired {
            update(record.id) { $0.status = .signInRequired }
            failures[record.id] = L10n.string("The server asked for a new sign-in.")
            return .error("\(record.name) needs the user to sign in again: Yardlet Settings → Connectors → \(record.name).")
        } catch ConnectorSession.Failure.refreshUnavailable(let detail) {
            // The sign-in stands: the connector stays connected and the next call tries again.
            return .error("Could not renew \(record.name)'s sign-in just now (\(detail)). The connection stays; "
                + "try the call again shortly.")
        } catch MCPHTTPError.rpc(_, let message) {
            return .error("\(record.name): \(message)")
        } catch {
            return .error("Could not reach \(record.name): \(error.localizedDescription)")
        }
    }


    /// The connector and server tool name behind one of Yardlet's names.
    private func owner(ofTool name: String) -> (ConnectorRecord, String)? {
        for record in connectors where name.hasPrefix(record.slug + "_") {
            for tool in record.offeredTools {
                guard let original = tool["name"]?.stringValue else { continue }
                if ConnectorToolNaming.name(slug: record.slug, tool: original) == name { return (record, original) }
            }
        }
        return nil
    }

    /// The server's tool under Yardlet's name, its description led by the connector's name (and
    /// account, where it has one) so the model knows which account it acts in.
    static func exposedTool(_ tool: ToolJSON, of record: ConnectorRecord) -> ToolJSON? {
        guard var fields = tool.objectValue, let name = fields["name"]?.stringValue else { return nil }
        fields["name"] = .string(ConnectorToolNaming.name(slug: record.slug, tool: name))
        let title = fields["title"]?.stringValue ?? fields["annotations"]?["title"]?.stringValue ?? name
        fields["title"] = .string("\(record.displayName): \(title)")
        fields["description"] = .string("[\(record.displayName)] \(fields["description"]?.stringValue ?? title)")
        if fields["inputSchema"]?.objectValue == nil {
            fields["inputSchema"] = .object(["type": .string("object")])
        }
        return .object(fields)
    }

    static func toolResult(_ result: ToolJSON) -> AgentToolResult {
        AgentToolResult(
            content: (result["content"]?.arrayValue ?? []).map { .json($0) },
            isError: result["isError"] == .bool(true),
            structuredContent: result["structuredContent"]
        )
    }

    private func refreshToolsIfStale(_ record: ConnectorRecord) {
        let age = record.toolsUpdatedAt.map { environment.now().timeIntervalSince($0) } ?? .infinity
        guard age > environment.toolListMaximumAge, toolRefreshes[record.id] == nil, connectTasks[record.id] == nil else { return }
        let session = session(for: record)
        toolRefreshes[record.id] = Task { [weak self] in
            let tools = try? await session.listTools()
            let icons = await session.serverIcons()
            guard let self else { return }
            self.toolRefreshes[record.id] = nil
            guard let tools else { return }
            self.update(record.id) {
                $0.tools = tools
                $0.toolsUpdatedAt = self.environment.now()
                $0.serverIcons = icons.isEmpty ? nil : icons
            }
        }
    }

    // MARK: Helpers

    /// The person stopped the sign-in: Yardlet's Cancel, or Cancel on the service's page.
    private static func isCancellation(_ error: Error) -> Bool {
        switch error {
        case is CancellationError, ConnectorOAuthError.declined, GitHubDeviceSignIn.Failure.denied: true
        default: false
        }
    }

    /// Runs a secure-store operation off the main actor: the keychain can wait on a system prompt.
    private func store<T: Sendable>(_ operation: @escaping @Sendable (any ConnectorCredentialStoring) throws -> T) async throws -> T {
        let credentials = environment.credentials
        return try await Task.detached { try operation(credentials) }.value
    }

    /// Deletes in the background; a stale item is harmless, since a new sign-in replaces it. With
    /// `keepingClient`, a client the user registered stays for the next sign-in.
    private func forgetCredential(_ id: UUID, keepingClient: Bool) {
        let credentials = environment.credentials
        let keeps = keepingClient && record(id)?.usesRegisteredClient == true
        pendingDeletion = Task.detached { [previous = pendingDeletion] in
            await previous?.value
            if keeps, let client = (try? credentials.load(id))??.clientOnly {
                try? credentials.save(client, for: id)
            } else {
                try? credentials.delete(id)
            }
        }
    }

    /// Waits for background deletions, for callers that read the store right after.
    func waitForPendingDeletions() async {
        await pendingDeletion?.value
    }

    private func session(for record: ConnectorRecord) -> ConnectorSession {
        if let session = sessions[record.id], session.endpoint == record.serverURL { return session }
        let session = ConnectorSession(
            id: record.id,
            endpoint: record.serverURL,
            tokenQueryParameter: record.tokenQueryParameter,
            credentials: environment.credentials,
            http: environment.http,
            clientVersion: environment.clientVersion,
            now: environment.now,
            sleep: environment.refreshRetrySleep
        )
        sessions[record.id] = session
        return session
    }

    private func update(_ id: UUID, _ change: (inout ConnectorRecord) -> Void) {
        guard let index = connectors.firstIndex(where: { $0.id == id }) else { return }
        var record = connectors[index]
        change(&record)
        if record != connectors[index] { connectors[index] = record }
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    private func message(for error: Error, connector record: ConnectorRecord) -> String {
        switch error {
        case ConnectorSession.Failure.signInRequired:
            record.authorization == .token
                ? L10n.string("The server did not accept the access token.")
                : L10n.string("The server asked for a new sign-in.")
        case ConnectorSession.Failure.refreshUnavailable(let detail):
            L10n.format("The sign-in could not be renewed just now: %@", detail)
        case let error as LocalizedError:
            error.errorDescription ?? String(describing: error)
        default:
            error.localizedDescription
        }
    }
}

/// One connector's MCP client and credential. It adds the bearer token (or the query token a
/// server asks for), refreshes an OAuth token that is about to expire or that the server
/// refused, and retries once after a refresh. Only one refresh runs at a time, since a server
/// may rotate the refresh token.
///
/// A refresh first reads the secure store again: another copy of Yardlet signed in to the same
/// item may have refreshed already, and on a server that rotates refresh tokens the one this
/// session holds is then spent. A refusal (`invalid_grant`, a client the server no longer knows)
/// reads the store once more for the same reason before it counts. A refresh the server could not
/// answer for now (offline, timed out, 5xx, 429) is tried again a little later and, if it still
/// fails, fails only that call: the sign-in stands and the next call refreshes again.
actor ConnectorSession {
    enum Failure: Error {
        case signInRequired(BearerChallenge?)
        /// The token could not be renewed for now; the sign-in itself was not refused.
        case refreshUnavailable(String)
    }

    private enum Refresh: Sendable {
        /// A newer token is in use.
        case refreshed
        /// The server refused the grant, or there is nothing to refresh with.
        case refused
        case unavailable(String)

        var isRefreshed: Bool {
            if case .refreshed = self { true } else { false }
        }
    }

    /// Waits between attempts at a refresh the server could not answer: three tries in all.
    static let refreshRetryDelays: [Duration] = [.seconds(1), .seconds(2)]

    nonisolated let endpoint: URL
    private let id: UUID
    private let tokenQueryParameter: String?
    private let client: MCPHTTPClient
    private let credentials: any ConnectorCredentialStoring
    private let http: any ConnectorHTTPTransport
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (Duration) async throws -> Void
    private var credential: ConnectorCredential?
    private var loaded = false
    private var refreshing: Task<Refresh, Never>?

    init(
        id: UUID,
        endpoint: URL,
        tokenQueryParameter: String? = nil,
        credentials: any ConnectorCredentialStoring,
        http: any ConnectorHTTPTransport,
        clientVersion: String,
        now: @escaping @Sendable () -> Date,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.id = id
        self.endpoint = endpoint
        self.tokenQueryParameter = tokenQueryParameter
        self.credentials = credentials
        self.http = http
        self.now = now
        self.sleep = sleep
        client = MCPHTTPClient(endpoint: endpoint, transport: http, clientVersion: clientVersion)
    }

    func use(_ credential: ConnectorCredential?) async {
        self.credential = credential
        loaded = true
        await client.reset()
        await present(credential)
    }

    private func present(_ credential: ConnectorCredential?) async {
        if let tokenQueryParameter {
            await client.setQueryToken(name: tokenQueryParameter, value: credential?.presentedToken)
        } else {
            await client.setBearer(credential?.presentedToken)
        }
    }

    func listTools() async throws -> [ToolJSON] {
        try await authorized { try await $0.listTools() }
    }

    /// The icons the server gave for itself when the session began.
    func serverIcons() async -> [MCPServerIcon] {
        await client.serverIcons
    }

    func callTool(name: String, arguments: ToolJSON) async throws -> ToolJSON {
        try await authorized { try await $0.callTool(name: name, arguments: arguments) }
    }

    private func authorized<T: Sendable>(_ operation: @Sendable (MCPHTTPClient) async throws -> T) async throws -> T {
        if !loaded {
            credential = try? credentials.load(id)
            loaded = true
            await present(credential)
        }
        // A token about to expire is renewed first. If that fails the call still goes out: the
        // token may have a minute left, and a refusal of it then needs no second token request.
        var early: Refresh?
        if let current = credential, current.kind == .oauth, current.needsRefresh(at: now()) {
            early = await refresh(from: current.accessToken)
        }
        let tokenUsed = credential?.accessToken
        do {
            return try await operation(client)
        } catch MCPHTTPError.unauthorized(let challenge) {
            let outcome: Refresh
            if let early, !early.isRefreshed { outcome = early } else { outcome = await refresh(from: tokenUsed) }
            switch outcome {
            case .refreshed: break
            case .refused: throw Failure.signInRequired(challenge)
            case .unavailable(let detail): throw Failure.refreshUnavailable(detail)
            }
            do {
                return try await operation(client)
            } catch MCPHTTPError.unauthorized(let challenge) {
                throw Failure.signInRequired(challenge)
            }
        }
    }

    /// Refreshes unless another call already replaced `staleToken`, joining a refresh already
    /// under way.
    private func refresh(from staleToken: String?) async -> Refresh {
        if let current = credential?.accessToken, current != staleToken { return .refreshed }
        if let refreshing { return await refreshing.value }
        let task = Task { await renew() }
        refreshing = task
        let outcome = await task.value
        refreshing = nil
        return outcome
    }

    private func renew() async -> Refresh {
        if await adoptStoredReplacement(), let current = credential, !current.needsRefresh(at: now()) {
            return .refreshed
        }
        var failure = ""
        for attempt in 0...Self.refreshRetryDelays.count {
            guard let current = credential, current.kind == .oauth, current.refreshToken != nil else { return .refused }
            do {
                let refreshed = try await ConnectorOAuth.refresh(current, http: http, now: now())
                // Saved over what it was made from, or where the store cannot be read: a sign-in
                // or a refresh that landed in the store meanwhile is newer, and a removed
                // connector stays removed.
                switch Result(catching: { try credentials.load(id) }) {
                case .success(let stored?) where stored.refreshToken != current.refreshToken: break
                case .success(nil): break
                default: try? credentials.save(refreshed, for: id)
                }
                credential = refreshed
                await present(refreshed)
                return .refreshed
            } catch let error where Self.isRefusal(error) {
                // Another copy of Yardlet may have spent the refresh token a moment ago; its
                // tokens are in the store, or will be once its answer arrives.
                if await adoptStoredReplacement() { return .refreshed }
                try? await sleep(Self.refreshRetryDelays[0])
                return await adoptStoredReplacement() ? .refreshed : .refused
            } catch {
                failure = Self.describe(error)
                if attempt < Self.refreshRetryDelays.count {
                    try? await sleep(Self.refreshRetryDelays[attempt])
                }
            }
        }
        return .unavailable(failure)
    }

    /// Takes the stored credential when it is not the one this session holds and expires no
    /// earlier: another process refreshed or signed in again. True when it did.
    private func adoptStoredReplacement() async -> Bool {
        guard let stored = try? credentials.load(id), stored.kind == .oauth, !stored.accessToken.isEmpty,
              stored.accessToken != credential?.accessToken || stored.refreshToken != credential?.refreshToken
        else { return false }
        if let storedExpiry = stored.expiresAt, let heldExpiry = credential?.expiresAt, storedExpiry < heldExpiry {
            return false
        }
        credential = stored
        await present(stored)
        return true
    }

    /// Whether only a new sign-in helps: the server refused the grant or the client, or the
    /// credential lacks what a refresh needs. A network failure or a server's own trouble is not.
    private static func isRefusal(_ error: Error) -> Bool {
        switch error {
        case ConnectorOAuthError.invalidGrant, ConnectorOAuthError.tokenRequestFailed: true
        default: false
        }
    }

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
