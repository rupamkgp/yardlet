import Foundation
import XCTest
@testable import NativeHarnessClient

/// The Google OAuth app a build carries (docs/CONNECTORS.md, "Google"): read from the bundle's
/// Info.plist, used to sign in when the person saved no app of their own, and set aside by one they
/// save. Google is a local fake here: no request leaves the machine and no real account signs in.
@MainActor
final class GoogleBuiltInAppTests: XCTestCase {
    private static let otherClientID = "999-builtin.apps.googleusercontent.com"

    private func makeCenter(
        builtIn: GoogleOAuth.BuiltInApp?,
        google: FakeGoogle = FakeGoogle(),
        agent: FakeUserAgent = FakeUserAgent(),
        credentials: InMemoryConnectorCredentialStore = InMemoryConnectorCredentialStore()
    ) -> ConnectorCenter {
        var environment = ConnectorCenter.Environment(
            repository: InMemoryConnectorRepository(), credentials: credentials, http: google, userAgent: agent,
            sha256: MacOAuthUserAgent.sha256, clientVersion: "9.9")
        environment.google = FakeGoogle.endpoints
        environment.googleBuiltInApp = builtIn
        return ConnectorCenter(environment: environment)
    }

    func testTheBuiltInAppComesFromTheInfoDictionary() {
        XCTAssertEqual(GoogleOAuth.BuiltInApp.from(info: [
            "YardletGoogleOAuthClientID": " \(FakeGoogle.clientID) ",
            "YardletGoogleOAuthClientSecret": "\(FakeGoogle.clientSecret)\n"
        ]), GoogleOAuth.BuiltInApp(clientID: FakeGoogle.clientID, clientSecret: FakeGoogle.clientSecret))
        XCTAssertEqual(GoogleOAuth.BuiltInApp.from(info: ["YardletGoogleOAuthClientID": FakeGoogle.clientID]),
                       GoogleOAuth.BuiltInApp(clientID: FakeGoogle.clientID, clientSecret: nil))
        XCTAssertNil(GoogleOAuth.BuiltInApp.from(info: ["YardletGoogleOAuthClientSecret": FakeGoogle.clientSecret]))
        XCTAssertNil(GoogleOAuth.BuiltInApp.from(info: ["YardletGoogleOAuthClientID": "  "]))
        XCTAssertNil(GoogleOAuth.BuiltInApp.from(info: nil))
    }

    /// With no app of the person's own, an account signs in with the built-in one, and its sign-in
    /// keeps that client for later refreshes.
    func testAnAccountSignsInWithTheBuiltInApp() async throws {
        let google = FakeGoogle()
        let agent = FakeUserAgent()
        let credentials = InMemoryConnectorCredentialStore()
        let center = makeCenter(builtIn: .init(clientID: FakeGoogle.clientID, clientSecret: FakeGoogle.clientSecret),
                                google: google, agent: agent, credentials: credentials)
        XCTAssertNil(center.googleAppClientID)
        XCTAssertTrue(center.canSignInWithGoogle)

        let record = try XCTUnwrap(center.addGmailAccount())
        await center.waitForConnection(record.id)
        XCTAssertNil(center.failures[record.id])
        XCTAssertEqual(center.record(record.id)?.status, .connected)

        let opened = try XCTUnwrap(agent.opened.first)
        let query = URLComponents(url: opened, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(query.first { $0.name == "client_id" }?.value, FakeGoogle.clientID)
        let form = FakeConnectorServer.form(try XCTUnwrap(google.requests.first { $0.url?.path() == "/token" }))
        XCTAssertEqual(form["client_secret"], FakeGoogle.clientSecret)
        XCTAssertEqual(try credentials.load(record.id)?.clientID, FakeGoogle.clientID)
        XCTAssertNil(try credentials.load(GoogleOAuth.appCredentialID), "Nothing is saved as the person's own app")
    }

    /// An app the person saves signs in instead of the built-in one; removing it brings the built-in
    /// one back.
    func testAnAppOfYourOwnTakesPrecedence() async throws {
        let agent = FakeUserAgent()
        let center = makeCenter(builtIn: .init(clientID: Self.otherClientID, clientSecret: "GOCSPX-builtin"), agent: agent)
        try await center.saveGoogleApp(clientID: FakeGoogle.clientID, secret: FakeGoogle.clientSecret)

        let record = try XCTUnwrap(center.addGmailAccount())
        await center.waitForConnection(record.id)
        XCTAssertNil(center.failures[record.id], "The fake Google takes only the person's app")
        let query = URLComponents(url: try XCTUnwrap(agent.opened.first), resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(query.first { $0.name == "client_id" }?.value, FakeGoogle.clientID)

        try await center.removeGoogleApp()
        XCTAssertNil(center.googleAppClientID)
        XCTAssertTrue(center.canSignInWithGoogle)
    }

    func testWithoutEitherAppNoAccountCanSignIn() {
        XCTAssertFalse(makeCenter(builtIn: nil).canSignInWithGoogle)
    }

    /// The setup page's assistant: with the built-in app, signing in is the only step.
    func testTheAssistantWithTheBuiltInAppIsOnlyTheSignIn() {
        let builtIn = ConnectorSetupAssistant.google(opened: [], appSaved: false, connectedAccounts: 0, builtIn: true)
        XCTAssertEqual(builtIn.steps.map(\.id), [.googleSignIn])
        XCTAssertEqual(builtIn.current, .googleSignIn)
        XCTAssertTrue(ConnectorSetupAssistant.google(opened: [], appSaved: false, connectedAccounts: 1, builtIn: true).isComplete)
        XCTAssertEqual(ConnectorSetupAssistant.google(opened: [], appSaved: false, connectedAccounts: 0).steps.count, 7)
    }
}
