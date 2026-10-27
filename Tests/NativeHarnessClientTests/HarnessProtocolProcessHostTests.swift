import Darwin
import Foundation
import XCTest
@testable import NativeHarnessClient

final class HarnessProtocolProcessHostTests: XCTestCase {
    func testIndependentlyInstalledSamplePassesExternalConformanceRunner() async throws {
        let installation = try installSampleAdapter()
        defer { try? FileManager.default.removeItem(at: installation.directory) }

        let report = try await HarnessProtocolExternalConformanceRunner().run(
            configuration: installation.configuration
        )

        XCTAssertEqual(report.adapterID, "dev.yardlet.sample.echo")
        XCTAssertEqual(report.negotiatedVersion, .v1)
        XCTAssertEqual(report.createdSessionEventCount, 7)
        XCTAssertEqual(report.resumedSessionEventCount, 5)
        XCTAssertEqual(report.preservedExtensionValue, .string("conformance"))
        XCTAssertFalse(isProcessAlive(report.processID))
    }

    func testDistributedConformanceCLIPassesInstalledSample() throws {
        let installation = try installSampleAdapter()
        defer { try? FileManager.default.removeItem(at: installation.directory) }
        let runnerURL = repositoryURL
            .appending(path: "SDK/YardletHarnessProtocolV1/bin/yardlet-harness-conformance")
        let process = Process()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = URL(filePath: "/usr/bin/python3")
        process.arguments = [
            runnerURL.path(percentEncoded: false),
            installation.configuration.executableURL.path(percentEncoded: false)
        ]
        process.currentDirectoryURL = installation.directory
        process.standardOutput = output
        process.standardError = error

        try process.run()
        process.waitUntilExit()

        let stdout = output.fileHandleForReading.readDataToEndOfFile()
        let stderr = error.fileHandleForReading.readDataToEndOfFile()
        XCTAssertEqual(
            process.terminationStatus,
            0,
            String(decoding: stderr, as: UTF8.self)
        )
        let report = try XCTUnwrap(
            JSONSerialization.jsonObject(with: stdout) as? [String: Any]
        )
        XCTAssertEqual(report["adapterID"] as? String, "dev.yardlet.sample.echo")
        XCTAssertEqual(report["createdSessionEvents"] as? Int, 7)
        XCTAssertEqual(report["resumedSessionEvents"] as? Int, 5)
        XCTAssertEqual(report["extensionRoundTrip"] as? Bool, true)
    }

    func testInstalledSampleMalformedSequenceFailsClosedAndLeavesNoProcess() async throws {
        let installation = try installSampleAdapter(
            environmentOverrides: ["YARDLET_SAMPLE_MALFORMED": "sequence-gap"]
        )
        defer { try? FileManager.default.removeItem(at: installation.directory) }
        let host = HarnessProtocolProcessHost(
            handshakeTimeout: 1,
            requestTimeout: .seconds(1)
        )
        let processSession = try await host.start(installation.configuration)
        let localSessionID = UUID()
        let request = try HarnessProtocolRequest(
            id: "malformed-create",
            method: .sessionCreate,
            typedParams: HarnessProtocolCreateSessionParams(
                localSessionID: localSessionID,
                config: HarnessProtocolSessionConfig(
                    workspacePath: installation.directory.path(percentEncoded: false),
                    modelID: nil,
                    modeID: nil,
                    featureValues: [:],
                    extensionValues: [:]
                ),
                initialPrompt: []
            )
        )

        do {
            _ = try await host.request(request)
            XCTFail("The host must reject a sequence gap")
        } catch {
            XCTAssertEqual(
                error as? HarnessProtocolProcessHostError,
                .protocolViolation(
                    .invalidEvent(.sequenceMustStartAtZero(actual: 1))
                )
            )
        }

        await host.stop()
        XCTAssertFalse(isProcessAlive(processSession.processID))
    }

    func testExternalAdapterNegotiatesRespondsStreamsAndLeavesNoProcess() async throws {
        let manifest = makeManifest()
        let sessionID = UUID()
        let response = HarnessProtocolResponse(
            id: "request-1",
            result: .object(["available": .bool(true)])
        )
        let event = HarnessProtocolEventEnvelope(
            localSessionID: sessionID,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            sequence: 0,
            payload: .sessionStarted(
                HarnessProtocolSessionDescriptor(
                    localSessionID: sessionID,
                    providerSessionID: "provider-fixture",
                    workspacePath: FileManager.default.temporaryDirectory.path
                )
            )
        )
        let script = """
        printf '%s\\n' "$1"
        IFS= read -r ready || exit 11
        IFS= read -r request || exit 12
        printf '%s\\n' "$2"
        printf '%s\\n' "$3"
        IFS= read -r ignored
        """
        let host = HarnessProtocolProcessHost(
            handshakeTimeout: 1,
            requestTimeout: .seconds(1)
        )
        let stream = await host.events()
        var iterator = stream.makeAsyncIterator()
        let session = try await host.start(
            fixtureConfiguration(
                script: script,
                lines: [
                    try line(.hello(manifest)),
                    try line(.response(version: .v1, response)),
                    try line(.event(version: .v1, event))
                ]
            )
        )

        XCTAssertEqual(session.manifest, manifest)
        XCTAssertEqual(session.version, .v1)
        XCTAssertTrue(isProcessAlive(session.processID))

        let request = try HarnessProtocolRequest(
            id: "request-1",
            method: .runtimeProbe,
            typedParams: HarnessProtocolEmptyParams()
        )
        let result = try await host.request(request)
        XCTAssertEqual(result, .object(["available": .bool(true)]))
        let receivedEvent = await iterator.next()
        XCTAssertEqual(receivedEvent, event)

        await host.stop()

        XCTAssertFalse(isProcessAlive(session.processID))
        let diagnostics = await host.diagnostics()
        XCTAssertEqual(diagnostics.phase, .closed)
        XCTAssertEqual(diagnostics.processID, session.processID)
    }

    func testHandshakeTimeoutTerminatesSilentAdapter() async throws {
        let host = HarnessProtocolProcessHost(handshakeTimeout: 0.05)

        do {
            _ = try await host.start(
                fixtureConfiguration(script: "sleep 30", lines: [])
            )
            XCTFail("Expected handshake timeout")
        } catch {
            XCTAssertEqual(
                error as? HarnessProtocolProcessHostError,
                .protocolViolation(.handshakeTimedOut)
            )
        }

        let diagnostics = await host.diagnostics()
        XCTAssertEqual(diagnostics.phase, .failed(.handshakeTimedOut))
        XCTAssertNotNil(diagnostics.processID)
        if let processID = diagnostics.processID {
            XCTAssertFalse(isProcessAlive(processID))
        }
    }

    func testCancelledHandshakeTerminatesAdapter() async throws {
        let host = HarnessProtocolProcessHost(handshakeTimeout: 30)
        let configuration = fixtureConfiguration(script: "sleep 30", lines: [])
        let startTask = Task { try await host.start(configuration) }

        try await Task.sleep(for: .milliseconds(20))
        startTask.cancel()

        do {
            _ = try await startTask.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertEqual(error as? HarnessProtocolProcessHostError, .cancelled)
        }
        let diagnostics = await host.diagnostics()
        XCTAssertEqual(diagnostics.terminalError, .cancelled)
        if let processID = diagnostics.processID {
            XCTAssertFalse(isProcessAlive(processID))
        }
    }

    func testAdapterExitDuringHandshakeFailsAndPreservesExitCode() async {
        let host = HarnessProtocolProcessHost(handshakeTimeout: 1)

        do {
            _ = try await host.start(
                fixtureConfiguration(script: "exit 7", lines: [])
            )
            XCTFail("Expected adapter exit")
        } catch {
            XCTAssertEqual(
                error as? HarnessProtocolProcessHostError,
                .protocolViolation(.adapterExitedBeforeHandshake(code: 7))
            )
        }
    }

    func testAdapterCrashFailsPendingRequestAndLeavesNoProcess() async throws {
        let manifest = makeManifest()
        let script = """
        printf '%s\\n' "$1"
        IFS= read -r ready || exit 11
        IFS= read -r request || exit 12
        printf 'fixture crashed\\n' >&2
        exit 23
        """
        let host = HarnessProtocolProcessHost(
            handshakeTimeout: 1,
            requestTimeout: .seconds(2)
        )
        let session = try await host.start(
            fixtureConfiguration(script: script, lines: [try line(.hello(manifest))])
        )
        let request = try HarnessProtocolRequest(
            id: "request-crash",
            method: .runtimeProbe,
            typedParams: HarnessProtocolEmptyParams()
        )

        do {
            _ = try await host.request(request)
            XCTFail("Expected process exit")
        } catch let error as HarnessProtocolProcessHostError {
            guard case let .processExited(code, _) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(code, 23)
        }

        XCTAssertFalse(isProcessAlive(session.processID))
    }

    func testRequestTimeoutIsBoundedAndStopCleansUpAdapter() async throws {
        let manifest = makeManifest()
        let script = """
        printf '%s\\n' "$1"
        IFS= read -r ready || exit 11
        IFS= read -r request || exit 12
        sleep 30
        """
        let host = HarnessProtocolProcessHost(
            handshakeTimeout: 1,
            requestTimeout: .milliseconds(50)
        )
        let session = try await host.start(
            fixtureConfiguration(script: script, lines: [try line(.hello(manifest))])
        )
        let request = try HarnessProtocolRequest(
            id: "request-timeout",
            method: .runtimeProbe,
            typedParams: HarnessProtocolEmptyParams()
        )

        do {
            _ = try await host.request(request)
            XCTFail("Expected request timeout")
        } catch {
            XCTAssertEqual(
                error as? HarnessProtocolProcessHostError,
                .requestTimedOut("request-timeout")
            )
        }
        do {
            _ = try await host.request(request)
            XCTFail("A transmitted request ID must not be reused after timeout")
        } catch {
            XCTAssertEqual(
                error as? HarnessProtocolProcessHostError,
                .duplicateRequestID("request-timeout")
            )
        }
        XCTAssertTrue(isProcessAlive(session.processID))

        await host.stop()
        XCTAssertFalse(isProcessAlive(session.processID))
    }

    func testCancelledRequestReleasesWaiterWithoutKillingAdapter() async throws {
        let manifest = makeManifest()
        let script = """
        printf '%s\\n' "$1"
        IFS= read -r ready || exit 11
        IFS= read -r request || exit 12
        sleep 30
        """
        let host = HarnessProtocolProcessHost(
            handshakeTimeout: 1,
            requestTimeout: .seconds(30)
        )
        let session = try await host.start(
            fixtureConfiguration(script: script, lines: [try line(.hello(manifest))])
        )
        let request = try HarnessProtocolRequest(
            id: "request-cancel",
            method: .runtimeProbe,
            typedParams: HarnessProtocolEmptyParams()
        )
        let requestTask = Task { try await host.request(request) }

        try await Task.sleep(for: .milliseconds(20))
        requestTask.cancel()

        do {
            _ = try await requestTask.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertEqual(error as? HarnessProtocolProcessHostError, .cancelled)
        }
        XCTAssertTrue(isProcessAlive(session.processID))

        await host.stop()
        XCTAssertFalse(isProcessAlive(session.processID))
    }

    func testAdapterCannotSendHostDirectedRequest() async throws {
        let manifest = makeManifest()
        let inboundRequest = try HarnessProtocolRequest(
            id: "adapter-request",
            method: .runtimeProbe,
            typedParams: HarnessProtocolEmptyParams()
        )
        let script = """
        printf '%s\\n' "$1"
        IFS= read -r ready || exit 11
        printf '%s\\n' "$2"
        IFS= read -r ignored
        """
        let host = HarnessProtocolProcessHost(handshakeTimeout: 1)
        let session = try await host.start(
            fixtureConfiguration(
                script: script,
                lines: [
                    try line(.hello(manifest)),
                    try line(.request(version: .v1, inboundRequest))
                ]
            )
        )

        try await waitUntilProcessExits(session.processID)

        let diagnostics = await host.diagnostics()
        XCTAssertEqual(diagnostics.terminalError, .unexpectedInboundFrame("request"))
        XCTAssertFalse(isProcessAlive(session.processID))
    }

    func testOversizedJSONLineFailsClosed() async {
        let script = "printf '%*s\\n' 512 '' | tr ' ' x; IFS= read -r ignored"
        let host = HarnessProtocolProcessHost(
            handshakeTimeout: 1,
            maximumLineBytes: 128
        )

        do {
            _ = try await host.start(fixtureConfiguration(script: script, lines: []))
            XCTFail("Expected line-size failure")
        } catch {
            XCTAssertEqual(
                error as? HarnessProtocolProcessHostError,
                .lineTooLarge(limit: 128)
            )
        }
    }

    func testStopTerminatesAdapterDescendants() async throws {
        let manifest = makeManifest()
        let script = """
        printf '%s\\n' "$1"
        IFS= read -r ready || exit 11
        sleep 30 &
        wait
        """
        let host = HarnessProtocolProcessHost(handshakeTimeout: 1)
        let session = try await host.start(
            fixtureConfiguration(script: script, lines: [try line(.hello(manifest))])
        )
        var descendants: [Int32] = []
        try await waitUntil {
            descendants = NativeProcessTree.descendantProcessIDs(of: session.processID)
            return !descendants.isEmpty
        }
        XCTAssertFalse(descendants.isEmpty)

        await host.stop()

        XCTAssertFalse(isProcessAlive(session.processID))
        for processID in descendants {
            XCTAssertFalse(isProcessAlive(processID))
        }
    }

    private func makeManifest() -> HarnessAdapterManifest {
        HarnessAdapterManifest(
            adapterID: "com.yardlet.external-fixture",
            harness: HarnessKind(rawValue: "external-fixture"),
            displayName: "External Fixture",
            protocolVersions: [.v1],
            capabilities: Array(HarnessAdapterManifestValidator.requiredCapabilities)
        )
    }

    private func fixtureConfiguration(
        script: String,
        lines: [String]
    ) -> HarnessProtocolAdapterLaunchConfiguration {
        HarnessProtocolAdapterLaunchConfiguration(
            executableURL: URL(filePath: "/bin/sh"),
            arguments: ["-c", script, "fixture"] + lines,
            workspaceURL: FileManager.default.temporaryDirectory
        )
    }

    private func installSampleAdapter(
        environmentOverrides: [String: String] = [:]
    ) throws -> (
        directory: URL,
        configuration: HarnessProtocolAdapterLaunchConfiguration
    ) {
        let sourceURL = repositoryURL
            .appending(path: "Examples/YardletSampleAdapter/yardlet_sample_adapter.py")
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "yardlet-sample-install-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let installedURL = directory.appending(path: "yardlet-sample-adapter")
        try FileManager.default.copyItem(at: sourceURL, to: installedURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: installedURL.path(percentEncoded: false)
        )
        return (
            directory,
            HarnessProtocolAdapterLaunchConfiguration(
                executableURL: installedURL,
                workspaceURL: directory,
                environmentOverrides: environmentOverrides
            )
        )
    }

    private var repositoryURL: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func line(_ frame: HarnessProtocolFrame) throws -> String {
        var data = try HarnessProtocolJSONLCodec().encodeLine(frame)
        data.removeLast()
        return String(decoding: data, as: UTF8.self)
    }

    private func isProcessAlive(_ processID: Int32) -> Bool {
        Darwin.kill(processID, 0) == 0 || errno == EPERM
    }

    private func waitUntilProcessExits(_ processID: Int32) async throws {
        try await waitUntil { !isProcessAlive(processID) }
    }
}
