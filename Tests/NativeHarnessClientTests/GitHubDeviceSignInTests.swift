import Foundation
import XCTest
@testable import NativeHarnessClient
@testable import YardletAgentTools

/// GitHub's device sign-in with Yardlet's own GitHub OAuth app (docs/CONNECTORS.md, "GitHub sign-in"): the code
/// request, polling through `authorization_pending` and `slow_down`, the refusals, and a GitHub
/// connector that signs in this way instead of taking a pasted token. GitHub and the MCP server
/// are local fakes: no request leaves the machine.
@MainActor
final class GitHubDeviceSignInTests: XCTestCase {
    static let endpoints = GitHubDeviceSignIn.Endpoints(
        deviceCode: URL(string: "https://github.test/login/device/code")!,
        token: URL(string: "https://github.test/login/oauth/access_token")!)
    static let clientID = "Ov23liTestClient"

    func testTheClientIDComesFromTheInfoDictionary() {
        XCTAssertEqual(GitHubDeviceSignIn.clientID(from: ["YardletGitHubOAuthClientID": " Ov23liX \n"]), "Ov23liX")
        XCTAssertNil(GitHubDeviceSignIn.clientID(from: ["YardletGitHubOAuthClientID": ""]))
        XCTAssertNil(GitHubDeviceSignIn.clientID(from: nil))
    }

    func testTheShippedInfoPlistCarriesYardletsGitHubApp() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Packaging/Info.plist")
        let info = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: Any])
        XCTAssertEqual(GitHubDeviceSignIn.clientID(from: info), "Ov23liSikdZLShjUFzbR")
    }

    func testTheCodeRequestAndPollingUntilTheTokenComes() async throws {
        let github = FakeGitHub(pendingPolls: 2, slowDownOnce: true)
        let code = try await GitHubDeviceSignIn.requestCode(clientID: Self.clientID, endpoints: Self.endpoints, http: github)
        XCTAssertEqual(code.userCode, "WDJB-MJHT")
        XCTAssertEqual(code.verificationURI.absoluteString, "https://github.test/login/device")
        XCTAssertEqual(code.interval, 5)
        let request = try XCTUnwrap(github.requests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(FakeConnectorServer.form(request), ["client_id": Self.clientID, "scope": "repo read:org workflow"])

        let waits = Waits()
        let credential = try await GitHubDeviceSignIn.waitForToken(
            clientID: Self.clientID, code: code, endpoints: Self.endpoints, http: github, sleep: { await waits.add($0) })
        XCTAssertEqual(credential.kind, .oauth)
        XCTAssertEqual(credential.accessToken, FakeGitHub.token)
        XCTAssertNil(credential.refreshToken, "An OAuth app user token does not expire")
        XCTAssertNil(credential.clientSecret, "The device flow needs no secret")
        XCTAssertEqual(credential.clientID, Self.clientID)
        XCTAssertEqual(credential.scope, "repo,read:org,workflow")
        let polls = github.requests.filter { $0.url?.path() == "/login/oauth/access_token" }
        XCTAssertEqual(polls.count, 4, "Two pending, one slow_down, then the token")
        XCTAssertEqual(FakeConnectorServer.form(try XCTUnwrap(polls.first))["grant_type"],
                       "urn:ietf:params:oauth:grant-type:device_code")
        let seconds = await waits.seconds
        XCTAssertEqual(seconds, [5, 5, 5, 10], "slow_down raises the interval to what GitHub says")
    }

    func testRefusalsEndTheSignIn() async throws {
        for (error, expected) in [("access_denied", GitHubDeviceSignIn.Failure.denied),
                                  ("expired_token", .expired),
                                  ("device_flow_disabled", .deviceFlowDisabled)] {
            let github = FakeGitHub(pendingPolls: 0, finalError: error)
            let code = try await GitHubDeviceSignIn.requestCode(clientID: Self.clientID, endpoints: Self.endpoints, http: github)
            do {
                _ = try await GitHubDeviceSignIn.waitForToken(clientID: Self.clientID, code: code, endpoints: Self.endpoints,
                                                              http: github, sleep: { _ in })
                XCTFail("\(error) should end the sign-in")
            } catch let failure as GitHubDeviceSignIn.Failure {
                XCTAssertEqual(failure, expected)
            }
        }
        // A code that runs out on Yardlet's side stops polling.
        let github = FakeGitHub(pendingPolls: 1_000)
        let code = try await GitHubDeviceSignIn.requestCode(clientID: Self.clientID, endpoints: Self.endpoints, http: github)
        let clock = Clock()
        do {
            _ = try await GitHubDeviceSignIn.waitForToken(clientID: Self.clientID, code: code, endpoints: Self.endpoints,
                                                          http: github, sleep: { clock.advance($0) }, now: { clock.now })
            XCTFail("An expired code should end the sign-in")
        } catch let failure as GitHubDeviceSignIn.Failure {
            XCTAssertEqual(failure, .expired)
        }
    }

    /// The GitHub connector signs in on GitHub's device page: the code goes to the clipboard and
    /// beside the connector, the browser opens the device page, and the token GitHub issues reaches
    /// the MCP server as a bearer token.
    func testTheGitHubConnectorSignsInWithYardletsApp() async throws {
        let server = FakeConnectorServer()
        let github = FakeGitHub(pendingPolls: 1, mcp: server)
        let agent = FakeUserAgent()
        let credentials = InMemoryConnectorCredentialStore()
        var copied: [String] = []
        var environment = ConnectorCenter.Environment(
            repository: InMemoryConnectorRepository(), credentials: credentials, http: github, userAgent: agent,
            sha256: MacOAuthUserAgent.sha256, clientVersion: "9.9")
        environment.gitHubClientID = Self.clientID
        environment.gitHub = Self.endpoints
        environment.gitHubPollSleep = { _ in }
        environment.copyToClipboard = { copied.append($0) }
        let center = ConnectorCenter(environment: environment)
        XCTAssertTrue(center.canSignInToGitHub)
        let preset = try XCTUnwrap(ConnectorPreset.preset(id: "github"))
        XCTAssertEqual(ConnectorSetupGuide.Kind.of(preset, gitHubSignIn: true), .oneClick)
        XCTAssertEqual(ConnectorSetupGuide.Kind.of(preset), .key)

        let record = try await center.add(name: "GitHub", serverURL: FakeConnectorServer.mcpURL, preset: preset)
        XCTAssertTrue(center.signsInOnGitHub(record))
        center.connect(record.id)
        await center.waitForConnection(record.id)

        XCTAssertNil(center.failures[record.id])
        XCTAssertEqual(center.record(record.id)?.status, .connected)
        XCTAssertEqual(center.record(record.id)?.authorization, .oauth)
        XCTAssertEqual(copied, ["WDJB-MJHT"])
        XCTAssertEqual(agent.opened.map(\.absoluteString), ["https://github.test/login/device"])
        XCTAssertTrue(center.deviceCodes.isEmpty, "The code goes once the sign-in ends")
        XCTAssertEqual(try credentials.load(record.id)?.accessToken, FakeGitHub.token)
        let list = try XCTUnwrap(server.requests.last { FakeConnectorServer.rpcMethod($0) == "tools/list" })
        XCTAssertEqual(list.value(forHTTPHeaderField: "Authorization"), "Bearer \(FakeGitHub.token)")
        XCTAssertFalse(server.requests.contains { $0.url?.path() == "/register" }, "No dynamic registration")
    }

    /// Without Yardlet's app in the build, GitHub still asks for a token first, as before.
    func testWithoutTheAppGitHubTakesAToken() async throws {
        let center = ConnectorCenter(environment: ConnectorCenter.Environment(
            repository: InMemoryConnectorRepository(), credentials: InMemoryConnectorCredentialStore(),
            http: FakeConnectorServer(), userAgent: FakeUserAgent(), sha256: MacOAuthUserAgent.sha256, clientVersion: "9.9"))
        XCTAssertFalse(center.canSignInToGitHub)
        let record = try await center.add(name: "GitHub", serverURL: FakeConnectorServer.mcpURL,
                                          preset: try XCTUnwrap(ConnectorPreset.preset(id: "github")))
        XCTAssertFalse(center.signsInOnGitHub(record))
        center.connect(record.id)
        await center.waitForConnection(record.id)
        XCTAssertEqual(center.failures[record.id], ConnectorOAuthError.noDynamicRegistration.errorDescription)
    }
}

private actor Waits {
    var seconds: [Int64] = []
    func add(_ duration: Duration) { seconds.append(duration.components.seconds) }
}

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { lock.withLock { value } }
    func advance(_ duration: Duration) { lock.withLock { value += TimeInterval(duration.components.seconds) } }
}

/// GitHub's device endpoints, answering as github.com does (JSON, HTTP 200 for the pending
/// states), and everything else passed to the MCP server stand-in.
private final class FakeGitHub: ConnectorHTTPTransport, @unchecked Sendable {
    static let token = "gho_device-token"
    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    private var polls = 0
    private let pendingPolls: Int
    private var slowDown: Bool
    private let finalError: String?
    private let mcp: FakeConnectorServer?

    init(pendingPolls: Int, slowDownOnce: Bool = false, finalError: String? = nil, mcp: FakeConnectorServer? = nil) {
        self.pendingPolls = pendingPolls
        self.slowDown = slowDownOnce
        self.finalError = finalError
        self.mcp = mcp
    }

    var requests: [URLRequest] { lock.withLock { recorded } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        guard url.host() == "github.test" else {
            guard let mcp else { throw URLError(.cannotFindHost) }
            return try await mcp.send(request)
        }
        lock.withLock { recorded.append(request) }
        let body: [String: ToolJSON]
        switch url.path() {
        case "/login/device/code":
            body = ["device_code": .string("device-1"), "user_code": .string("WDJB-MJHT"),
                    "verification_uri": .string("https://github.test/login/device"), "expires_in": .integer(900),
                    "interval": .integer(5)]
        case "/login/oauth/access_token":
            body = lock.withLock { () -> [String: ToolJSON] in
                polls += 1
                if polls <= pendingPolls { return ["error": .string("authorization_pending")] }
                if slowDown {
                    slowDown = false
                    return ["error": .string("slow_down"), "interval": .integer(10)]
                }
                if let finalError { return ["error": .string(finalError)] }
                mcp?.validTokens.insert(Self.token)
                return ["access_token": .string(Self.token), "token_type": .string("bearer"),
                        "scope": .string("repo,read:org,workflow")]
            }
        default:
            body = ["error": .string("not_found")]
        }
        return (try JSONEncoder().encode(ToolJSON.object(body)),
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!)
    }
}
