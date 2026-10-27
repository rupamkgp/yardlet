import Foundation
import XCTest
@testable import NativeHarnessClient

final class HarnessProtocolEventTests: XCTestCase {
    func testRichCanonicalTimelinePassesConformanceAndWireRoundTrip() throws {
        let manifest = makeManifest(
            extraCapabilities: [
                .reasoning,
                .structuredActivities,
                .structuredPermissions,
                .plans,
                .usage,
                .subagents
            ],
            extensionNamespaces: ["fixture.testing"]
        )
        let sessionID = UUID()
        let events = makeRichTimeline(sessionID: sessionID)

        let report = try HarnessProtocolConformanceKit.validate(
            manifest: manifest,
            localSessionID: sessionID,
            events: events
        )

        XCTAssertEqual(report.negotiatedVersion, .v1)
        XCTAssertEqual(report.acceptedEventCount, events.count)
        XCTAssertEqual(events.map(\.sequence), Array(0..<UInt64(events.count)))

        let codec = HarnessProtocolJSONLCodec()
        for event in events {
            let frame = HarnessProtocolFrame.event(version: .v1, event)
            XCTAssertEqual(try codec.decodeLine(codec.encodeLine(frame)), frame)
        }
        XCTAssertNotNil(events.first?.rawProviderEvent)
    }

    func testHostRejectsEventWhoseCapabilityWasNotAdvertised() throws {
        let now = Date(timeIntervalSince1970: 3_000)
        let manifest = makeManifest()
        let sessionID = UUID()
        var connection = HarnessProtocolHostConnection(now: now)
        _ = try connection.accept(.hello(manifest), at: now)
        let start = event(
            sessionID: sessionID,
            sequence: 0,
            payload: .sessionStarted(
                HarnessProtocolSessionDescriptor(
                    localSessionID: sessionID,
                    providerSessionID: "provider-fixture",
                    workspacePath: "/tmp/yardlet-yhp-event"
                )
            )
        )
        _ = try connection.accept(.event(version: .v1, start), at: now)

        let plan = event(
            sessionID: sessionID,
            sequence: 1,
            payload: .planUpdated(
                turnID: "turn-1",
                plan: HarnessProtocolPlan(
                    explanation: nil,
                    items: [
                        HarnessProtocolPlanItem(id: "step-1", text: "Implement", status: .pending)
                    ]
                )
            )
        )
        let violation = HarnessProtocolEventContractViolation.missingCapability(
            event: .planUpdated,
            capability: .plans
        )

        XCTAssertThrowsError(
            try connection.accept(.event(version: .v1, plan), at: now)
        ) { error in
            XCTAssertEqual(error as? HarnessProtocolHostError, .invalidEvent(violation))
        }
        XCTAssertEqual(connection.phase, .failed(.invalidEvent(violation)))
    }

    func testHostTracksSequenceIndependentlyForConcurrentSessions() throws {
        let now = Date(timeIntervalSince1970: 3_000)
        let manifest = makeManifest()
        var connection = HarnessProtocolHostConnection(now: now)
        _ = try connection.accept(.hello(manifest), at: now)
        let firstID = UUID()
        let secondID = UUID()

        for sessionID in [firstID, secondID] {
            let start = event(
                sessionID: sessionID,
                sequence: 0,
                payload: .sessionStarted(
                    HarnessProtocolSessionDescriptor(
                        localSessionID: sessionID,
                        providerSessionID: "provider-\(sessionID.uuidString)",
                        workspacePath: "/tmp/yardlet-yhp-event"
                    )
                )
            )
            XCTAssertEqual(
                try connection.accept(.event(version: .v1, start), at: now),
                .acceptedEvent(start)
            )
        }

        let firstReady = event(
            sessionID: firstID,
            sequence: 1,
            payload: .sessionStatusChanged(.ready)
        )
        XCTAssertEqual(
            try connection.accept(.event(version: .v1, firstReady), at: now),
            .acceptedEvent(firstReady)
        )
    }

    func testUndeclaredExtensionEventFailsClosed() throws {
        let manifest = makeManifest(extensionNamespaces: ["fixture.testing"])
        let sessionID = UUID()
        let start = event(
            sessionID: sessionID,
            sequence: 0,
            payload: .sessionStarted(
                HarnessProtocolSessionDescriptor(
                    localSessionID: sessionID,
                    providerSessionID: "provider-fixture",
                    workspacePath: "/tmp/yardlet-yhp-event"
                )
            )
        )
        let custom = event(
            sessionID: sessionID,
            sequence: 1,
            payload: .extensionEvent(
                HarnessProtocolExtensionEvent(
                    namespace: "other.testing",
                    name: "custom",
                    payload: .object([:])
                )
            )
        )
        var validator = HarnessProtocolEventContractValidator(
            localSessionID: sessionID,
            manifest: manifest
        )
        try validator.accept(start)

        XCTAssertThrowsError(try validator.accept(custom)) { error in
            XCTAssertEqual(
                error as? HarnessProtocolEventContractViolation,
                .undeclaredExtensionNamespace("other.testing")
            )
        }
    }

    private func makeRichTimeline(sessionID: UUID) -> [HarnessProtocolEventEnvelope] {
        let usage = HarnessProtocolUsage(
            inputTokens: 100,
            cachedInputTokens: 80,
            outputTokens: 25,
            reasoningTokens: 10,
            totalCostUSD: 0.02,
            contextWindowTokens: 200_000,
            contextUsedTokens: 215,
            extensionValues: ["fixture.testing.usage": .string("measured")]
        )
        let permission = HarnessProtocolPermissionRequest(
            id: "permission-1",
            localSessionID: sessionID,
            turnID: "turn-1",
            kind: .question,
            name: "target",
            title: "Choose a target",
            description: nil,
            input: nil,
            suggestions: [],
            actions: [
                HarnessProtocolPermissionAction(
                    id: "allow",
                    label: "Allow",
                    behavior: .allow,
                    role: .primary,
                    intent: nil
                )
            ],
            extensionValues: ["fixture.testing.permission": .bool(true)]
        )
        let payloads: [HarnessProtocolEventPayload] = [
            .sessionStarted(
                HarnessProtocolSessionDescriptor(
                    localSessionID: sessionID,
                    providerSessionID: "provider-fixture",
                    workspacePath: "/tmp/yardlet-yhp-event"
                )
            ),
            .sessionStatusChanged(.ready),
            .turnStarted(HarnessProtocolTurnDescriptor(id: "turn-1", localSessionID: sessionID)),
            .assistantDelta(turnID: "turn-1", messageID: "message-1", text: "Hello"),
            .reasoningDelta(turnID: "turn-1", text: "Checking"),
            .toolCallUpdated(
                turnID: "turn-1",
                toolCall: HarnessProtocolToolCall(
                    id: "tool-1",
                    name: "read",
                    title: "Read file",
                    kind: "read",
                    status: .completed,
                    input: .object(["path": .string("README.md")]),
                    output: .object(["text": .string("contents")]),
                    extensionValues: ["fixture.testing.tool": .bool(true)]
                )
            ),
            .permissionRequested(permission),
            .planUpdated(
                turnID: "turn-1",
                plan: HarnessProtocolPlan(
                    explanation: "One bounded step",
                    items: [
                        HarnessProtocolPlanItem(
                            id: "step-1",
                            text: "Implement",
                            status: .inProgress
                        )
                    ]
                )
            ),
            .usageUpdated(turnID: "turn-1", usage: usage),
            .subagentUpdated(
                HarnessProtocolSubagent(
                    id: "child-1",
                    parentSessionID: sessionID,
                    providerSessionID: "provider-child",
                    title: "Review",
                    status: .running,
                    extensionValues: ["fixture.testing.child": .bool(true)]
                )
            ),
            .messageCompleted(
                turnID: "turn-1",
                message: HarnessProtocolMessage(
                    id: "message-1",
                    role: .assistant,
                    content: [.text("Hello")]
                )
            ),
            .permissionResolved(
                turnID: "turn-1",
                resolution: HarnessProtocolPermissionResolution(
                    requestID: "permission-1",
                    selectedActionID: "allow",
                    behavior: .allow
                )
            ),
            .turnCompleted(turnID: "turn-1", usage: usage),
            .sessionStatusChanged(.ready),
            .extensionEvent(
                HarnessProtocolExtensionEvent(
                    namespace: "fixture.testing",
                    name: "trace",
                    payload: .object(["value": .integer(1)])
                )
            )
        ]
        return payloads.enumerated().map { index, payload in
            HarnessProtocolEventEnvelope(
                localSessionID: sessionID,
                timestamp: Date(timeIntervalSince1970: TimeInterval(index)),
                sequence: UInt64(index),
                payload: payload,
                rawProviderEvent: index == 0 ? Data(#"{"native":true}"#.utf8) : nil
            )
        }
    }

    private func event(
        sessionID: UUID,
        sequence: UInt64,
        payload: HarnessProtocolEventPayload
    ) -> HarnessProtocolEventEnvelope {
        HarnessProtocolEventEnvelope(
            localSessionID: sessionID,
            sequence: sequence,
            payload: payload
        )
    }

    private func makeManifest(
        extraCapabilities: [HarnessCapabilityID] = [],
        extensionNamespaces: [String] = []
    ) -> HarnessAdapterManifest {
        HarnessAdapterManifest(
            adapterID: "com.yardlet.fixture",
            harness: HarnessKind(rawValue: "fixture"),
            displayName: "Fixture",
            protocolVersions: [.v1],
            capabilities: Array(HarnessAdapterManifestValidator.requiredCapabilities)
                + extraCapabilities,
            extensionNamespaces: extensionNamespaces
        )
    }
}
