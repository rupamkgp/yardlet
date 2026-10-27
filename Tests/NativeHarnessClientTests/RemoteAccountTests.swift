import CryptoKit
import Foundation
import XCTest
@testable import NativeHarnessClient
@testable import YardletRemote

/// The Mac's side of the relay's accounts (docs/REMOTE_PROTOCOL.md §14.4, §12.1): signing in with PKCE
/// in the browser sheet, putting this Mac on the account with a signature the relay can check, taking
/// link requests only while signed in, and signing out. The relay is a stub on `relay.example.test`.
@MainActor
final class RemoteAccountTests: XCTestCase {
    override func setUp() {
        super.setUp()
        StubRelay.reset()
        URLProtocol.registerClass(StubRelay.self)
    }

    override func tearDown() {
        URLProtocol.unregisterClass(StubRelay.self)
        super.tearDown()
    }

    func testTheMacSignsInPutsItselfOnTheAccountAndTakesLinkRequests() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("RemoteAccountTests")))
        defaults.set("wss://relay.example.test", forKey: RemoteControlService.relayURLKey)
        let identity = RemoteIdentity.generate()
        let token = RemoteMemorySecret()
        var sheet: URL?
        let service = RemoteControlService(
            bridge: FakeBridge(), deviceStore: RemoteDeviceStore(fileURL: nil), audit: nil,
            identityStore: RemoteMemoryIdentityStore(identity), accountToken: token,
            webSignIn: { url, scheme in
                sheet = url
                XCTAssertEqual(scheme, "yardlet-remote")
                let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                StubRelay.challenge = items.first { $0.name == "code_challenge" }?.value
                let state = items.first { $0.name == "state" }?.value ?? ""
                return URL(string: "yardlet-remote://auth?code=C1&state=\(state)")!
            },
            defaults: defaults, environment: [:], interfaces: { [] }, resolveName: { _ in nil }, listens: false,
            macName: "MacBook Pro", appVersion: "test")
        await service.start()
        service.setEnabled(true)
        StubRelay.providers = []
        await service.refreshAccount()
        XCTAssertFalse(service.showsAccount, "A relay without sign-in providers has no account row")
        StubRelay.providers = ["github"]
        await service.refreshAccount()
        XCTAssertEqual(service.accountProviders, ["github"])
        XCTAssertTrue(service.showsAccount)
        XCTAssertNil(service.account)

        await service.signIn(with: "github")
        XCTAssertEqual(sheet?.path(), "/v1/auth/github/start")
        XCTAssertEqual(service.account?.name, "octocat")
        XCTAssertEqual(token.load(), "ACC.secret")
        let registered = try XCTUnwrap(StubRelay.registered)
        XCTAssertEqual(registered.room, identity.room)
        XCTAssertTrue(registered.signatureValid, "The relay can check the Mac holds the room's key")
        XCTAssertEqual(registered.name, "MacBook Pro")

        // Signed in: a phone of the account may ask to link.
        let asking = try await PipePhone.connect(server: service.server, macStatic: identity.noise, phoneKey: .generate(),
                                                 hello: RemoteHandshakeHello(name: "Pixel 10", link: true),
                                                 targetKey: identity.noise.publicKey, expectsReply: true)
        XCTAssertEqual(asking.reply.pending, true)
        await service.answerLink(approve: false)

        await service.signOut()
        XCTAssertNil(service.account)
        XCTAssertNil(token.load())
        XCTAssertEqual(StubRelay.calls.suffix(2), ["DELETE /v1/account/macs/\(identity.room)", "POST /v1/auth/logout"])
        let refused = try await PipePhone.connect(server: service.server, macStatic: identity.noise, phoneKey: .generate(),
                                                  hello: RemoteHandshakeHello(name: "Pixel 11", link: true),
                                                  targetKey: identity.noise.publicKey, expectsReply: true)
        XCTAssertEqual(refused.reply.error?.code, .linkUnavailable)
    }
}

/// The relay's account endpoints on `relay.example.test`, as the tests need them.
final class StubRelay: URLProtocol {
    struct Registration {
        var room: String
        var name: String
        var signatureValid: Bool
    }

    nonisolated(unsafe) static var challenge: String?
    nonisolated(unsafe) static var registered: Registration?
    nonisolated(unsafe) static var calls: [String] = []
    nonisolated(unsafe) static var providers = ["github"]

    static func reset() {
        challenge = nil
        registered = nil
        calls = []
        providers = ["github"]
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "relay.example.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let method = request.httpMethod ?? "GET"
        Self.calls.append("\(method) \(url.path())")
        let body = request.httpBody ?? request.httpBodyStream.map(Self.read) ?? Data()
        let json = (try? JSONSerialization.jsonObject(with: body) as? [String: String]) ?? [:]
        let authorized = request.value(forHTTPHeaderField: "Authorization") == "Bearer ACC.secret"
        var status = 200
        var answer: Any = ["ok": true]
        switch (method, url.path()) {
        case ("GET", "/v1/auth/providers"):
            answer = ["providers": Self.providers]
        case ("POST", "/v1/auth/token"):
            let verifier = json["codeVerifier"] ?? ""
            let challenge = RemoteEncoding.base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
            if json["code"] == "C1", challenge == Self.challenge {
                answer = ["token": "ACC.secret", "account": ["id": "ACC", "provider": "github", "name": "octocat"]]
            } else {
                status = 401
                answer = ["error": "unauthorized"]
            }
        case ("GET", "/v1/account") where authorized:
            answer = ["id": "ACC", "provider": "github", "name": "octocat", "macs": []]
        case ("PUT", let path) where authorized && path.hasPrefix("/v1/account/macs/"):
            let room = String(path.dropFirst("/v1/account/macs/".count))
            let relayKey = RemoteEncoding.data(base64url: json["relayKey"] ?? "") ?? Data()
            let signature = RemoteEncoding.data(base64url: json["sig"] ?? "") ?? Data()
            let message = Data("yardlet-account-mac/1\nACC\n\(room)\n\(json["macKey"] ?? "")\n\(json["name"] ?? "")".utf8)
            let valid = (try? Curve25519.Signing.PublicKey(rawRepresentation: relayKey).isValidSignature(signature, for: message)) ?? false
            Self.registered = Registration(room: room, name: json["name"] ?? "",
                                           signatureValid: valid && RemoteIdentity.room(for: relayKey) == room)
        case ("DELETE", _), ("POST", "/v1/auth/logout"):
            status = authorized ? 204 : 401
        default:
            status = 401
            answer = ["error": "unauthorized"]
        }
        let data = status == 204 ? Data() : (try? JSONSerialization.data(withJSONObject: answer)) ?? Data()
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
