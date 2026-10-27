import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import YardletAgentTools

/// GitHub's device flow with Yardlet's own GitHub OAuth app, as the `gh` CLI signs in
/// (docs.github.com/en/apps/oauth-apps/building-oauth-apps/authorizing-oauth-apps#device-flow).
/// GitHub's MCP server has no dynamic client registration, so without an app of the host's own a
/// person pastes a personal access token; with this one they sign in. The device flow needs only
/// the app's client ID, which is public, so the app carries no secret (docs/CONNECTORS.md, "GitHub 로그인").
///
/// The token is an OAuth app user token: it does not expire and has no refresh token, so the
/// stored credential keeps the access token alone. GitHub ends it when the person revokes the app
/// or leaves it unused for a year; then the server refuses it and the connector asks for a new
/// sign-in.
enum GitHubDeviceSignIn {
    struct Endpoints: Equatable, Sendable {
        var deviceCode: URL
        var token: URL

        static let live = Endpoints(
            deviceCode: URL(string: "https://github.com/login/device/code")!,
            token: URL(string: "https://github.com/login/oauth/access_token")!
        )
    }

    /// The scopes a personal access token for GitHub's MCP server usually has: repositories,
    /// organization membership, and Actions workflows. The server offers the tools these allow.
    static let scope = "repo read:org workflow"

    /// The client ID a build carries, from `YardletGitHubOAuthClientID` in Info.plist.
    static let clientIDKey = "YardletGitHubOAuthClientID"

    static func clientID(from info: [String: Any]?) -> String? {
        let value = (info?[clientIDKey] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    struct DeviceCode: Equatable, Sendable {
        let deviceCode: String
        /// What the person types on GitHub's page, such as `WDJB-MJHT`.
        let userCode: String
        let verificationURI: URL
        let expiresIn: Int
        /// Seconds between token requests; GitHub raises it with `slow_down`.
        let interval: Int
    }

    enum Failure: Error, Equatable, LocalizedError {
        /// The person pressed Cancel on GitHub's page.
        case denied
        /// The code ran out (15 minutes) before the person entered it.
        case expired
        /// The app does not have device flow turned on in its GitHub settings.
        case deviceFlowDisabled
        case refused(String)

        var errorDescription: String? {
            switch self {
            case .denied: L10n.string("GitHub sign-in was cancelled.")
            case .expired: L10n.string("The GitHub code expired before it was entered. Connect again.")
            case .deviceFlowDisabled: L10n.string("Yardlet's GitHub app does not allow device sign-in.")
            case .refused(let detail): L10n.format("GitHub did not sign in: %@", detail)
            }
        }
    }

    static func requestCode(clientID: String, scope: String = scope, endpoints: Endpoints,
                            http: any ConnectorHTTPTransport) async throws -> DeviceCode {
        let body = try await post(endpoints.deviceCode, [("client_id", clientID), ("scope", scope)], http: http)
        if let error = body["error"]?.stringValue { throw failure(error, body) }
        guard let deviceCode = body["device_code"]?.stringValue,
              let userCode = body["user_code"]?.stringValue,
              let address = body["verification_uri"]?.stringValue, let verificationURI = URL(string: address)
        else {
            throw Failure.refused(L10n.string("GitHub's answer had no code."))
        }
        return DeviceCode(deviceCode: deviceCode, userCode: userCode, verificationURI: verificationURI,
                          expiresIn: int(body["expires_in"]) ?? 900, interval: max(int(body["interval"]) ?? 5, 1))
    }

    /// Asks for the token every `interval` seconds until the person approves, cancels, or the
    /// code expires. `sleep` waits between requests (tests pass one that does not).
    static func waitForToken(
        clientID: String,
        code: DeviceCode,
        endpoints: Endpoints,
        http: any ConnectorHTTPTransport,
        sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        now: @Sendable () -> Date = { Date() }
    ) async throws -> ConnectorCredential {
        let deadline = now().addingTimeInterval(TimeInterval(code.expiresIn))
        var interval = code.interval
        while true {
            try await sleep(.seconds(interval))
            try Task.checkCancellation()
            guard now() < deadline else { throw Failure.expired }
            let body = try await post(endpoints.token, [
                ("client_id", clientID),
                ("device_code", code.deviceCode),
                ("grant_type", "urn:ietf:params:oauth:grant-type:device_code")
            ], http: http)
            if let token = body["access_token"]?.stringValue, !token.isEmpty {
                return ConnectorCredential(kind: .oauth, accessToken: token, scope: body["scope"]?.stringValue,
                                           clientID: clientID, tokenEndpoint: endpoints.token,
                                           tokenEndpointAuthMethod: "none")
            }
            switch body["error"]?.stringValue {
            case "authorization_pending":
                continue
            case "slow_down":
                interval = int(body["interval"]) ?? interval + 5
            case let error?:
                throw failure(error, body)
            case nil:
                throw Failure.refused(L10n.string("GitHub's answer had no token."))
            }
        }
    }

    private static func int(_ value: ToolJSON?) -> Int? {
        switch value {
        case .integer(let number)?: Int(number)
        case .number(let number)?: Int(number)
        default: nil
        }
    }

    private static func failure(_ error: String, _ body: ToolJSON) -> Failure {
        switch error {
        case "access_denied": .denied
        case "expired_token": .expired
        case "device_flow_disabled": .deviceFlowDisabled
        default: .refused(body["error_description"]?.stringValue ?? error)
        }
    }

    /// GitHub answers these endpoints with JSON when asked to, and with HTTP 200 even for the
    /// errors the flow expects (`authorization_pending`).
    private static func post(_ url: URL, _ fields: [(String, String)], http: any ConnectorHTTPTransport) async throws -> ToolJSON {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(fields.map { "\(ConnectorOAuth.formEncode($0.0))=\(ConnectorOAuth.formEncode($0.1))" }
            .joined(separator: "&").utf8)
        let (data, response) = try await http.send(request)
        guard let body = try? JSONDecoder().decode(ToolJSON.self, from: data), case .object = body else {
            throw Failure.refused(L10n.format("HTTP %lld", Int64(response.statusCode)))
        }
        return body
    }
}
