import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import YardletAgentTools

/// ES256 with a P-256 private key in PEM, as App Store Connect wants its tokens signed. The
/// platform layer provides it (`MacES256Signer`, CryptoKit on macOS).
protocol ES256Signing: Sendable {
    /// Whether the text is a P-256 private key in PEM (PKCS #8, as a `.p8` file holds it).
    func isPrivateKey(_ pem: String) -> Bool
    /// The signature of `message`: R and S, 32 bytes each.
    func sign(_ message: Data, withPrivateKey pem: String) throws -> Data
}

/// An App Store Connect API key (developer.apple.com, "Creating API Keys for App Store Connect
/// API"): a team key, with its issuer ID, or an individual key, which has none. Its private key
/// signs every token; it lives in the secure store and in this value only while one is made.
struct AppStoreConnectKey: Sendable {
    enum Problem: Error, Equatable, LocalizedError {
        case unreadablePrivateKey
        case invalidKeyID
        case invalidIssuerID
        /// This build cannot sign tokens.
        case noSigner

        var errorDescription: String? {
            switch self {
            case .unreadablePrivateKey:
                L10n.string("That file isn't an App Store Connect private key. Choose the .p8 file App Store Connect gave you.")
            case .invalidKeyID:
                L10n.string("A key ID is 10 letters and digits, such as 2X9R4HXF34.")
            case .invalidIssuerID:
                L10n.string("An issuer ID looks like 57246542-96fe-1a63-e053-0824d011072a.")
            case .noSigner:
                L10n.string("This build of Yardlet can't sign App Store Connect tokens.")
            }
        }
    }

    let id: String
    /// A team key's issuer ID; nil for an individual key.
    let issuer: String?
    private let pem: String
    private let signer: any ES256Signing

    /// - Parameter pem: the `.p8` file's text (PKCS #8, `-----BEGIN PRIVATE KEY-----`).
    init(id: String, issuer: String?, pem: String, signer: (any ES256Signing)?) throws {
        let keyID = id.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard Self.isKeyID(keyID) else { throw Problem.invalidKeyID }
        let issuer = issuer?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let issuer, !issuer.isEmpty, UUID(uuidString: issuer) == nil { throw Problem.invalidIssuerID }
        guard let signer else { throw Problem.noSigner }
        guard signer.isPrivateKey(pem) else { throw Problem.unreadablePrivateKey }
        self.id = keyID
        self.issuer = issuer?.isEmpty == false ? issuer : nil
        self.pem = pem
        self.signer = signer
    }

    init(_ credential: ConnectorCredential, signer: (any ES256Signing)?) throws {
        guard credential.kind == .signingKey, let id = credential.keyID, let pem = credential.privateKey else {
            throw Problem.unreadablePrivateKey
        }
        try self.init(id: id, issuer: credential.issuerID, pem: pem, signer: signer)
    }

    var credential: ConnectorCredential {
        .signingKey(id: id, issuer: issuer, privateKey: pem)
    }

    var isTeamKey: Bool { issuer != nil }

    /// Ten letters and digits (`2X9R4HXF34`).
    static func isKeyID(_ text: String) -> Bool {
        text.count == 10 && text.allSatisfy { $0.isASCII && ($0.isUppercase || $0.isNumber) }
    }

    /// The key ID in the name App Store Connect gives the file (`AuthKey_2X9R4HXF34.p8`).
    static func keyID(fromFileName name: String) -> String? {
        let base = (name as NSString).deletingPathExtension
        guard base.hasPrefix("AuthKey_") else { return nil }
        let id = String(base.dropFirst("AuthKey_".count)).uppercased()
        return isKeyID(id) ? id : nil
    }

    /// A token for `lifetime` from `now` (at most 20 minutes; "Generating Tokens for API
    /// Requests"): ES256 over the header and payload, the signature as R and S.
    func token(now: Date, lifetime: TimeInterval = AppStoreConnectSession.tokenLifetime) throws -> String {
        let issued = Int64(now.timeIntervalSince1970)
        let header: ToolJSON = .object(["alg": .string("ES256"), "kid": .string(id), "typ": .string("JWT")])
        var payload: [String: ToolJSON] = [
            "aud": .string("appstoreconnect-v1"),
            "iat": .integer(issued),
            "exp": .integer(issued + Int64(min(lifetime, 20 * 60)))
        ]
        if let issuer { payload["iss"] = .string(issuer) } else { payload["sub"] = .string("user") }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let input = try Self.base64URL(encoder.encode(header)) + "." + Self.base64URL(encoder.encode(ToolJSON.object(payload)))
        return input + "." + Self.base64URL(try signer.sign(Data(input.utf8), withPrivateKey: pem))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// One App Store Connect key's access to the API: a token signed with the key from the secure
/// store, made again a minute before it ends and once more if Apple refuses it. Apple refusing a
/// fresh token too (the key revoked, or its IDs wrong) ends in `keyRefused`.
actor AppStoreConnectSession {
    enum Failure: Error, Equatable {
        case keyRefused
    }

    /// Fifteen minutes, within Apple's twenty, and a token is made again a minute before it ends.
    static let tokenLifetime: TimeInterval = 15 * 60

    private let id: UUID
    private let credentials: any ConnectorCredentialStoring
    private let http: any ConnectorHTTPTransport
    private let signer: (any ES256Signing)?
    private let now: @Sendable () -> Date
    private var key: AppStoreConnectKey?
    private var token: (value: String, expires: Date)?

    init(id: UUID, credentials: any ConnectorCredentialStoring, http: any ConnectorHTTPTransport,
         signer: (any ES256Signing)?, now: @escaping @Sendable () -> Date) {
        self.id = id
        self.credentials = credentials
        self.http = http
        self.signer = signer
        self.now = now
    }

    /// Sends a request with a token. `make` builds it afresh for a retry.
    func send(_ make: @Sendable () -> URLRequest) async throws -> (Data, HTTPURLResponse) {
        let first = try await http.send(authorized(make(), fresh: false))
        guard first.1.statusCode == 401 else { return first }
        let second = try await http.send(authorized(make(), fresh: true))
        if second.1.statusCode == 401 { throw Failure.keyRefused }
        return second
    }

    private func authorized(_ request: URLRequest, fresh: Bool) throws -> URLRequest {
        let date = now()
        if fresh || token.map({ $0.expires.timeIntervalSince(date) < 60 }) ?? true {
            if key == nil {
                guard let credential = try credentials.load(id) else { throw Failure.keyRefused }
                key = try AppStoreConnectKey(credential, signer: signer)
            }
            guard let key else { throw Failure.keyRefused }
            token = (try key.token(now: date), date.addingTimeInterval(Self.tokenLifetime))
        }
        var request = request
        if let token { request.setValue("Bearer \(token.value)", forHTTPHeaderField: "Authorization") }
        return request
    }
}

/// The App Store Connect API (JSON:API) for one key: JSON in and out. A failure carries Apple's own
/// error detail and the HTTP status, never a request or response body.
struct AppStoreConnectAPI: Sendable {
    static let liveBase = URL(string: "https://api.appstoreconnect.apple.com/")!

    let base: URL
    let session: AppStoreConnectSession

    enum Failure: Error, Equatable, LocalizedError {
        /// Apple answered with an error: its HTTP status and its errors' detail.
        case http(status: Int, message: String)
        case unreadableAnswer

        var errorDescription: String? {
            switch self {
            case .http(let status, let message): message.isEmpty ? "HTTP \(status)" : "\(message) (HTTP \(status))"
            case .unreadableAnswer: "App Store Connect's answer could not be read."
            }
        }

        var status: Int? {
            if case .http(let status, _) = self { status } else { nil }
        }
    }

    func get(_ path: [String], _ query: [URLQueryItem] = []) async throws -> ToolJSON {
        try await json("GET", path, query, body: nil)
    }

    func post(_ path: [String], _ body: ToolJSON) async throws -> ToolJSON {
        try await json("POST", path, [], body: body)
    }

    func patch(_ path: [String], _ body: ToolJSON) async throws -> ToolJSON {
        try await json("PATCH", path, [], body: body)
    }

    func delete(_ path: [String], _ body: ToolJSON? = nil) async throws {
        _ = try await json("DELETE", path, [], body: body)
    }

    private func json(_ method: String, _ path: [String], _ query: [URLQueryItem], body: ToolJSON?) async throws -> ToolJSON {
        let payload = try body.map { try JSONEncoder().encode($0) }
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        var prefix = components.percentEncodedPath
        if !prefix.hasSuffix("/") { prefix += "/" }
        components.percentEncodedPath = prefix + path.joined(separator: "/")
        if !query.isEmpty { components.queryItems = query }
        let url = components.url!
        let (data, response) = try await session.send {
            var request = URLRequest(url: url, timeoutInterval: 60)
            request.httpMethod = method
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if let payload {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = payload
            }
            return request
        }
        guard (200..<300).contains(response.statusCode) else {
            throw Failure.http(status: response.statusCode, message: Self.message(data))
        }
        if data.isEmpty { return .object([:]) }
        guard let json = try? JSONDecoder().decode(ToolJSON.self, from: data) else { throw Failure.unreadableAnswer }
        return json
    }

    /// Apple's `errors[].detail` (or `title`), joined.
    static func message(_ data: Data) -> String {
        let errors = (try? JSONDecoder().decode(ToolJSON.self, from: data))?["errors"]?.arrayValue ?? []
        return errors.compactMap { $0["detail"]?.stringValue ?? $0["title"]?.stringValue }.joined(separator: " ")
    }

    /// One path segment: an ID Apple gave, refused before the request when it could not be one.
    static func segment(_ id: String) throws -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        guard !id.isEmpty, id.count <= 200, id.unicodeScalars.allSatisfy(allowed.contains) else {
            throw GoogleToolArguments.Problem.invalid("Not an ID App Store Connect gives: \(id)")
        }
        return id
    }
}
