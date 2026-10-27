import Foundation
import XCTest
@testable import NativeHarnessClient

final class HarnessProtocolTests: XCTestCase {
    func testDistributedV1SchemaIsValidAndDeclaresEveryFrameKind() throws {
        let repositoryURL = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let schemaURL = repositoryURL.appending(
            path: "SDK/YardletHarnessProtocolV1/yardlet-harness-protocol-v1.schema.json"
        )
        let data = try Data(contentsOf: schemaURL)
        let schema = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let definitions = try XCTUnwrap(schema["$defs"] as? [String: Any])

        XCTAssertEqual(schema["$schema"] as? String, "https://json-schema.org/draft/2020-12/schema")
        XCTAssertNotNil(definitions["hello"])
        XCTAssertNotNil(definitions["ready"])
        XCTAssertNotNil(definitions["requestFrame"])
        XCTAssertNotNil(definitions["responseFrame"])
        XCTAssertNotNil(definitions["eventFrame"])
    }

    func testNegotiationSelectsHighestExplicitlySharedVersion() throws {
        let v11 = HarnessProtocolVersion(major: 1, minor: 1)
        let manifest = makeManifest(protocolVersions: [.v1, v11])

        let selected = try HarnessProtocolNegotiator.negotiate(
            hostVersions: [.v1, v11],
            adapter: manifest
        )

        XCTAssertEqual(selected, v11)
    }

    func testNegotiationRejectsAnIncompatibleAdapter() {
        let manifest = makeManifest(
            protocolVersions: [HarnessProtocolVersion(major: 2, minor: 0)]
        )

        XCTAssertThrowsError(try HarnessProtocolNegotiator.negotiate(adapter: manifest)) { error in
            XCTAssertEqual(
                error as? HarnessProtocolNegotiationError,
                .incompatibleVersions(host: [.v1], adapter: manifest.protocolVersions)
            )
        }
    }

    func testManifestRequiresThePortableLifecycleBaseline() {
        let manifest = HarnessAdapterManifest(
            adapterID: "com.yardlet.fixture",
            harness: HarnessKind(rawValue: "fixture"),
            displayName: "Fixture",
            protocolVersions: [.v1],
            capabilities: [.runtimeDiscovery, .sessionCreate, .turnSend, .streaming]
        )

        XCTAssertThrowsError(try HarnessAdapterManifestValidator.validate(manifest)) { error in
            XCTAssertEqual(
                error as? HarnessAdapterManifestViolation,
                .missingRequiredCapability(.sessionClose)
            )
        }
    }

    func testExistingCapabilitiesProjectIntoProtocolCapabilities() {
        let capabilities = HarnessCapabilities(
            canResume: true,
            canInterrupt: true,
            hasStructuredPermissions: true,
            hasStructuredActivities: true,
            hasPlans: false,
            acceptsImages: true,
            hasSubagents: false
        )

        let projected = Set(capabilities.protocolCapabilities())

        XCTAssertTrue(projected.isSuperset(of: HarnessAdapterManifestValidator.requiredCapabilities))
        XCTAssertTrue(projected.contains(.sessionResume))
        XCTAssertTrue(projected.contains(.turnInterrupt))
        XCTAssertTrue(projected.contains(.structuredPermissions))
        XCTAssertTrue(projected.contains(.structuredActivities))
        XCTAssertTrue(projected.contains(.images))
        XCTAssertFalse(projected.contains(.plans))
        XCTAssertFalse(projected.contains(.subagents))
    }

    func testJSONLWireFramesRoundTripWithoutLosingExtensionsOrRawEvents() throws {
        let codec = HarnessProtocolJSONLCodec()
        let manifest = makeManifest()
        let sessionID = UUID()
        let session = HarnessProtocolSessionDescriptor(
            localSessionID: sessionID,
            providerSessionID: "provider-fixture",
            workspacePath: "/tmp/yardlet-yhp-fixture"
        )
        let frames: [HarnessProtocolFrame] = [
            .hello(manifest),
            .ready(.v1),
            .request(
                version: .v1,
                HarnessProtocolRequest(
                    id: "request-1",
                    method: .sessionSend,
                    params: .object([
                        "text": .string("hello"),
                        "fixture.testing.trace": .string("kept")
                    ])
                )
            ),
            .response(
                version: .v1,
                HarnessProtocolResponse(id: "request-1", result: .object(["accepted": .bool(true)]))
            ),
            .event(
                version: .v1,
                HarnessProtocolEventEnvelope(
                    localSessionID: sessionID,
                    timestamp: Date(timeIntervalSince1970: 1_700_000_000),
                    sequence: 0,
                    payload: .sessionStarted(session),
                    rawProviderEvent: Data(#"{"provider":"fixture"}"#.utf8)
                )
            )
        ]

        for frame in frames {
            let encoded = try codec.encodeLine(frame)
            XCTAssertEqual(encoded.last, 0x0A)
            XCTAssertEqual(try codec.decodeLine(encoded), frame)
        }
    }

    func testConformanceKitAcceptsACompleteOrderedLifecycle() async throws {
        let adapter = ConformingHarnessAdapter()
        let runtime = try await adapter.probeRuntime()
        let localSessionID = UUID()
        let handle = try await adapter.createSession(
            CreateHarnessSessionRequest(
                localSessionID: localSessionID,
                workspaceURL: URL(fileURLWithPath: "/tmp/yardlet-yhp-fixture"),
                initialPrompt: nil
            )
        )
        try await adapter.send("hello", to: handle)

        var events: [HarnessEventEnvelope] = []
        for await event in await adapter.events(for: handle) {
            events.append(event)
        }

        let report = try HarnessAdapterConformanceKit.validate(
            manifest: adapter.protocolManifest,
            session: handle,
            events: events
        )

        XCTAssertEqual(runtime.harness, adapter.kind)
        XCTAssertEqual(report.negotiatedVersion, .v1)
        XCTAssertEqual(report.acceptedEventCount, 7)
        XCTAssertEqual(events.map(\.sequence), Array(0..<7))
        await adapter.close(handle)
    }

    func testEventContractRejectsSequenceGapsAndDuplicateStarts() throws {
        let sessionID = UUID()
        let handle = HarnessSessionHandle(
            harness: HarnessKind(rawValue: "fixture"),
            localSessionID: sessionID,
            providerSessionID: "provider-fixture",
            workspaceURL: URL(fileURLWithPath: "/tmp/yardlet-yhp-fixture")
        )
        var validator = HarnessEventContractValidator(session: handle)
        try validator.accept(event(sequence: 0, payload: .sessionStarted(handle), sessionID: sessionID))

        XCTAssertThrowsError(
            try validator.accept(
                event(sequence: 2, payload: .assistantDelta("gap"), sessionID: sessionID)
            )
        ) { error in
            XCTAssertEqual(
                error as? HarnessEventContractViolation,
                .sequenceGap(expected: 1, actual: 2)
            )
        }

        XCTAssertThrowsError(
            try validator.accept(event(sequence: 1, payload: .sessionStarted(handle), sessionID: sessionID))
        ) { error in
            XCTAssertEqual(error as? HarnessEventContractViolation, .duplicateSessionStart)
        }
    }

    func testConformanceKitRejectsAnEmptyEventStream() {
        let sessionID = UUID()
        let handle = HarnessSessionHandle(
            harness: HarnessKind(rawValue: "fixture"),
            localSessionID: sessionID,
            providerSessionID: "provider-fixture",
            workspaceURL: URL(fileURLWithPath: "/tmp/yardlet-yhp-fixture")
        )

        XCTAssertThrowsError(
            try HarnessAdapterConformanceKit.validate(
                manifest: makeManifest(),
                session: handle,
                events: []
            )
        ) { error in
            XCTAssertEqual(error as? HarnessEventContractViolation, .missingSessionStart)
        }
    }

    private func makeManifest(
        protocolVersions: [HarnessProtocolVersion] = [.v1]
    ) -> HarnessAdapterManifest {
        HarnessAdapterManifest(
            adapterID: "com.yardlet.fixture",
            harness: HarnessKind(rawValue: "fixture"),
            displayName: "Fixture",
            protocolVersions: protocolVersions,
            capabilities: Array(HarnessAdapterManifestValidator.requiredCapabilities),
            extensionNamespaces: ["fixture.testing"]
        )
    }

    private func event(
        sequence: UInt64,
        payload: HarnessEventPayload,
        sessionID: UUID
    ) -> HarnessEventEnvelope {
        HarnessEventEnvelope(
            localSessionID: sessionID,
            sequence: sequence,
            payload: payload
        )
    }
}

private actor ConformingHarnessAdapter: VersionedHarnessAdapter {
    nonisolated let kind = HarnessKind(rawValue: "fixture")
    nonisolated let protocolManifest = HarnessAdapterManifest(
        adapterID: "com.yardlet.fixture",
        harness: HarnessKind(rawValue: "fixture"),
        displayName: "Fixture",
        protocolVersions: [.v1],
        capabilities: [
            .runtimeDiscovery,
            .sessionCreate,
            .sessionClose,
            .turnSend,
            .streaming,
            .turnInterrupt,
            .structuredActivities
        ],
        extensionNamespaces: ["fixture.testing"]
    )

    private var handles: [UUID: HarnessSessionHandle] = [:]
    private var histories: [UUID: [HarnessEventEnvelope]] = [:]
    private var sequences: [UUID: UInt64] = [:]

    func probeRuntime() async throws -> HarnessRuntimeDescriptor {
        HarnessRuntimeDescriptor(
            harness: kind,
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            version: "fixture-1.0",
            capabilities: HarnessCapabilities(
                canResume: false,
                canInterrupt: true,
                hasStructuredPermissions: false,
                hasStructuredActivities: true,
                hasPlans: false,
                acceptsImages: false,
                hasSubagents: false
            ),
            fingerprint: "fixture"
        )
    }

    func createSession(_ request: CreateHarnessSessionRequest) async throws -> HarnessSessionHandle {
        let handle = HarnessSessionHandle(
            harness: kind,
            localSessionID: request.localSessionID,
            providerSessionID: "provider-\(request.localSessionID.uuidString)",
            workspaceURL: request.workspaceURL
        )
        handles[request.localSessionID] = handle
        emit(.sessionStarted(handle), for: handle.localSessionID)
        emit(.sessionStatusChanged(.ready), for: handle.localSessionID)
        return handle
    }

    func resumeSession(
        providerSessionID: String,
        localSessionID: UUID,
        workspaceURL: URL
    ) async throws -> HarnessSessionHandle {
        throw HarnessAdapterError.capabilityUnavailable("Fixture resume is unavailable")
    }

    func send(_ prompt: String, to session: HarnessSessionHandle) async throws {
        try requireSession(session)
        emit(.sessionStatusChanged(.running), for: session.localSessionID)
        emit(.assistantDelta(prompt), for: session.localSessionID)
        emit(.assistantMessageCompleted(prompt), for: session.localSessionID)
        emit(.turnCompleted, for: session.localSessionID)
        emit(.sessionStatusChanged(.ready), for: session.localSessionID)
    }

    func interrupt(_ session: HarnessSessionHandle) async throws {
        try requireSession(session)
        emit(.sessionStatusChanged(.ready), for: session.localSessionID)
    }

    func respond(
        to permissionRequestID: String,
        decision: PermissionDecision,
        in session: HarnessSessionHandle
    ) async throws {
        throw HarnessAdapterError.capabilityUnavailable("Fixture permissions are unavailable")
    }

    func events(for session: HarnessSessionHandle) async -> AsyncStream<HarnessEventEnvelope> {
        let history = histories[session.localSessionID] ?? []
        return AsyncStream { continuation in
            for event in history {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }

    func close(_ session: HarnessSessionHandle) async {
        handles.removeValue(forKey: session.localSessionID)
        histories.removeValue(forKey: session.localSessionID)
        sequences.removeValue(forKey: session.localSessionID)
    }

    private func requireSession(_ session: HarnessSessionHandle) throws {
        guard handles[session.localSessionID] == session else {
            throw HarnessAdapterError.invalidProviderEvent("Fixture session is not attached")
        }
    }

    private func emit(_ payload: HarnessEventPayload, for sessionID: UUID) {
        let sequence = sequences[sessionID] ?? 0
        sequences[sessionID] = sequence + 1
        histories[sessionID, default: []].append(
            HarnessEventEnvelope(
                localSessionID: sessionID,
                sequence: sequence,
                payload: payload
            )
        )
    }
}
