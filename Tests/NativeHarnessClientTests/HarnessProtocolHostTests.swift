import Foundation
import XCTest
@testable import NativeHarnessClient

final class HarnessProtocolHostTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000)

    func testHelloNegotiatesAndReturnsReady() throws {
        let manifest = makeManifest(extraCapabilities: [.turnInterrupt])
        var connection = HarnessProtocolHostConnection(now: now)

        let action = try connection.accept(.hello(manifest), at: now)

        XCTAssertEqual(action, .send(.ready(.v1)))
        XCTAssertEqual(connection.phase, .active(manifest: manifest, version: .v1))
    }

    func testRequestResponseAndEventFramesFailBeforeNegotiation() {
        let request = HarnessProtocolRequest(
            id: "request-1",
            method: .runtimeProbe,
            params: .object([:])
        )
        let response = HarnessProtocolResponse(id: "request-1", result: .object([:]))
        let sessionID = UUID()
        let session = HarnessProtocolSessionDescriptor(
            localSessionID: sessionID,
            providerSessionID: "provider-fixture",
            workspacePath: "/tmp/yardlet-yhp-host"
        )
        let event = HarnessProtocolEventEnvelope(
            localSessionID: sessionID,
            sequence: 0,
            payload: .sessionStarted(session)
        )
        let cases: [(HarnessProtocolFrame, String)] = [
            (.request(version: .v1, request), "request"),
            (.response(version: .v1, response), "response"),
            (.event(version: .v1, event), "event")
        ]

        for (frame, kind) in cases {
            var connection = HarnessProtocolHostConnection(now: now)
            let expected = HarnessProtocolHostError.frameBeforeNegotiation(kind)

            XCTAssertThrowsError(try connection.accept(frame, at: now)) { error in
                XCTAssertEqual(error as? HarnessProtocolHostError, expected)
            }
            XCTAssertEqual(connection.phase, .failed(expected))
        }
    }

    func testDuplicateHelloFailsTheConnection() throws {
        let manifest = makeManifest()
        var connection = HarnessProtocolHostConnection(now: now)
        _ = try connection.accept(.hello(manifest), at: now)

        XCTAssertThrowsError(try connection.accept(.hello(manifest), at: now)) { error in
            XCTAssertEqual(error as? HarnessProtocolHostError, .duplicateHello)
        }
        XCTAssertEqual(connection.phase, .failed(.duplicateHello))
    }

    func testWrongVersionFrameFailsBeforeDispatch() throws {
        let manifest = makeManifest()
        var connection = HarnessProtocolHostConnection(now: now)
        _ = try connection.accept(.hello(manifest), at: now)
        let wrongVersion = HarnessProtocolVersion(major: 1, minor: 1)
        let request = HarnessProtocolRequest(
            id: "request-1",
            method: .sessionSend,
            params: .object([:])
        )
        let expected = HarnessProtocolHostError.wrongVersion(
            expected: .v1,
            actual: wrongVersion
        )

        XCTAssertThrowsError(
            try connection.accept(.request(version: wrongVersion, request), at: now)
        ) { error in
            XCTAssertEqual(error as? HarnessProtocolHostError, expected)
        }
        XCTAssertEqual(connection.phase, .failed(expected))
    }

    func testStandardMethodRequiresItsAdvertisedCapability() throws {
        let manifest = makeManifest()
        var connection = HarnessProtocolHostConnection(now: now)
        _ = try connection.accept(.hello(manifest), at: now)
        let request = HarnessProtocolRequest(
            id: "request-1",
            method: .sessionInterrupt,
            params: .object([:])
        )
        let admission = HarnessProtocolMethodAdmissionError.missingCapability(
            method: .sessionInterrupt,
            requiresAnyOf: [.turnInterrupt]
        )
        let expected = HarnessProtocolHostError.methodNotAdmitted(admission)

        XCTAssertThrowsError(
            try connection.accept(.request(version: .v1, request), at: now)
        ) { error in
            XCTAssertEqual(error as? HarnessProtocolHostError, expected)
        }
        XCTAssertEqual(connection.phase, .failed(expected))
    }

    func testCatalogNeedsEitherModelOrModeCapability() throws {
        let manifest = makeManifest(extraCapabilities: [.modeCatalog])
        var connection = HarnessProtocolHostConnection(now: now)
        _ = try connection.accept(.hello(manifest), at: now)
        let request = try HarnessProtocolRequest(
            id: "request-1",
            method: .catalogRead,
            typedParams: HarnessProtocolCatalogRequest(
                workspacePath: "/tmp/yardlet-yhp-host",
                refresh: false
            )
        )

        XCTAssertEqual(
            try connection.accept(.request(version: .v1, request), at: now),
            .acceptedRequest(request)
        )
    }

    func testExtensionMethodMustBelongToADeclaredNamespace() throws {
        let allowed = HarnessProtocolMethodID(rawValue: "fixture.testing.inspect")
        let denied = HarnessProtocolMethodID(rawValue: "other.testing.inspect")
        let manifest = makeManifest(extensionNamespaces: ["fixture.testing"])

        var allowedConnection = HarnessProtocolHostConnection(now: now)
        _ = try allowedConnection.accept(.hello(manifest), at: now)
        let allowedRequest = HarnessProtocolRequest(
            id: "request-1",
            method: allowed,
            params: .object([:])
        )
        XCTAssertEqual(
            try allowedConnection.accept(.request(version: .v1, allowedRequest), at: now),
            .acceptedRequest(allowedRequest)
        )

        var deniedConnection = HarnessProtocolHostConnection(now: now)
        _ = try deniedConnection.accept(.hello(manifest), at: now)
        let deniedRequest = HarnessProtocolRequest(
            id: "request-2",
            method: denied,
            params: .object([:])
        )
        let admission = HarnessProtocolMethodAdmissionError.undeclaredExtensionMethod(denied)
        XCTAssertThrowsError(
            try deniedConnection.accept(.request(version: .v1, deniedRequest), at: now)
        ) { error in
            XCTAssertEqual(
                error as? HarnessProtocolHostError,
                .methodNotAdmitted(admission)
            )
        }
    }

    func testHandshakeTimeoutFailsClosed() {
        var connection = HarnessProtocolHostConnection(handshakeTimeout: 5, now: now)

        XCTAssertThrowsError(
            try connection.checkHandshakeDeadline(at: now.addingTimeInterval(5))
        ) { error in
            XCTAssertEqual(error as? HarnessProtocolHostError, .handshakeTimedOut)
        }
        XCTAssertEqual(connection.phase, .failed(.handshakeTimedOut))
    }

    func testAdapterExitDuringHandshakeFailsClosed() {
        var connection = HarnessProtocolHostConnection(now: now)
        let expected = HarnessProtocolHostError.adapterExitedBeforeHandshake(code: 9)

        XCTAssertThrowsError(try connection.adapterExited(code: 9)) { error in
            XCTAssertEqual(error as? HarnessProtocolHostError, expected)
        }
        XCTAssertEqual(connection.phase, .failed(expected))
    }

    func testInvalidAndIncompatibleManifestsFailBeforeReady() {
        var missingVersionConnection = HarnessProtocolHostConnection(now: now)
        let missingVersion = makeManifest(protocolVersions: [])
        XCTAssertThrowsError(
            try missingVersionConnection.accept(.hello(missingVersion), at: now)
        ) { error in
            XCTAssertEqual(
                error as? HarnessProtocolHostError,
                .invalidManifest(.missingProtocolVersions)
            )
        }

        var incompatibleConnection = HarnessProtocolHostConnection(now: now)
        let v2 = HarnessProtocolVersion(major: 2, minor: 0)
        let incompatible = makeManifest(protocolVersions: [v2])
        XCTAssertThrowsError(
            try incompatibleConnection.accept(.hello(incompatible), at: now)
        ) { error in
            XCTAssertEqual(
                error as? HarnessProtocolHostError,
                .negotiationFailed(
                    .incompatibleVersions(host: [.v1], adapter: [v2])
                )
            )
        }
    }

    private func makeManifest(
        protocolVersions: [HarnessProtocolVersion] = [.v1],
        extraCapabilities: [HarnessCapabilityID] = [],
        extensionNamespaces: [String] = []
    ) -> HarnessAdapterManifest {
        HarnessAdapterManifest(
            adapterID: "com.yardlet.fixture",
            harness: HarnessKind(rawValue: "fixture"),
            displayName: "Fixture",
            protocolVersions: protocolVersions,
            capabilities: Array(HarnessAdapterManifestValidator.requiredCapabilities)
                + extraCapabilities,
            extensionNamespaces: extensionNamespaces
        )
    }
}
