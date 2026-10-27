import Foundation
import XCTest
@testable import NativeHarnessClient

final class HarnessDomainTests: XCTestCase {
    func testLegacyPermissionJSONDefaultsMissingActionsToEmpty() throws {
        let data = Data(
            #"{"id":"permission-1","title":"Run","detail":null,"command":"swift test"}"#.utf8
        )

        let permission = try JSONDecoder().decode(PermissionRequest.self, from: data)

        XCTAssertEqual(permission.id, "permission-1")
        XCTAssertTrue(permission.actions.isEmpty)
    }

    func testEventEnvelopeRoundTripsWithoutDiscardingRawProviderEvent() throws {
        let localSessionID = UUID()
        let rawEvent = Data(#"{"method":"turn/started"}"#.utf8)
        let envelope = HarnessEventEnvelope(
            localSessionID: localSessionID,
            timestamp: Date(timeIntervalSince1970: 123),
            sequence: 7,
            payload: .assistantDelta("hello"),
            rawProviderEvent: rawEvent
        )

        let encoded = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(HarnessEventEnvelope.self, from: encoded)

        XCTAssertEqual(decoded, envelope)
        XCTAssertEqual(decoded.rawProviderEvent, rawEvent)
    }

    func testCapabilitiesDoNotAssumeFeatureParity() {
        let capabilities = HarnessCapabilities(
            canResume: true,
            canInterrupt: true,
            hasStructuredPermissions: false,
            hasStructuredActivities: true,
            hasPlans: false,
            acceptsImages: false,
            hasSubagents: false
        )

        XCTAssertTrue(capabilities.canResume)
        XCTAssertFalse(capabilities.hasStructuredPermissions)
        XCTAssertFalse(capabilities.hasPlans)
    }
}
