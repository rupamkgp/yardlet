import Foundation
import XCTest
@testable import NativeHarnessClient

/// Both YHP wrappers hand their launch settings to the adapter they wrap through the one
/// `WrappedAdapterLaunchFacets`, and skip a facet the wrapped adapter lacks.
final class WrappedAdapterLaunchFacetsTests: XCTestCase {
    func testBothWrappersHandTheLaunchSettingsToTheWrappedAdapter() async throws {
        let claude = LaunchRecordingAdapter(kind: .claudeCode)
        let codex = LaunchRecordingAdapter(kind: .codex)
        let wrappers: [(LaunchRecordingAdapter, any HarnessAdapter)] = [
            (claude, YHPProviderCompatibilityAdapter(adapter: claude, manifest: HarnessProtocolCompatibilityManifest.claude())),
            (codex, YHPCodexCompatibilityAdapter(adapter: codex, manifest: HarnessProtocolCompatibilityManifest.codex()))
        ]
        let server = AgentToolServerLaunch(command: "/tmp/yardlet-mcp", environment: ["YARDLET_TASK": "fixture"])
        for (wrapped, wrapper) in wrappers {
            let id = UUID()
            try await XCTUnwrap(wrapper as? any HarnessLaunchOptionConfiguring).setLaunchOptions(["model": "fixture"], for: id)
            try await XCTUnwrap(wrapper as? any HarnessWorkspaceRootsConfiguring)
                .setAdditionalWorkspaceRoots([URL(filePath: "/tmp/extra")], for: id)
            try await XCTUnwrap(wrapper as? any HarnessAgentToolConfiguring).setAgentToolServer(server, for: id)
            let sources = try await XCTUnwrap(wrapper as? any HarnessInstructionSourceReporting).instructionSources(for: id)
            XCTAssertEqual(sources, ["/tmp/AGENTS.md"], "\(wrapped.kind)")
            let options = await wrapped.launchOptions[id]
            let roots = await wrapped.roots[id]
            let servers = await wrapped.servers[id]
            XCTAssertEqual(options, ["model": "fixture"], "\(wrapped.kind)")
            XCTAssertEqual(roots, [URL(filePath: "/tmp/extra")], "\(wrapped.kind)")
            XCTAssertEqual(servers, .some(server), "\(wrapped.kind)")
        }
    }

    func testAFacetTheWrappedAdapterLacksIsSkipped() async {
        let facets = WrappedAdapterLaunchFacets(wrapping: BareAdapter())
        let id = UUID()
        await facets.setLaunchOptions(["model": "fixture"], for: id)
        await facets.setAdditionalWorkspaceRoots([URL(filePath: "/tmp/extra")], for: id)
        await facets.setAgentToolServer(nil, for: id)
        let sources = await facets.instructionSources(for: id)
        XCTAssertNil(sources)
    }
}

private actor LaunchRecordingAdapter: HarnessAdapter, HarnessLaunchOptionConfiguring, HarnessWorkspaceRootsConfiguring,
    HarnessInstructionSourceReporting, HarnessAgentToolConfiguring {
    nonisolated let kind: HarnessKind
    private(set) var launchOptions: [UUID: [String: String]] = [:]
    private(set) var roots: [UUID: [URL]] = [:]
    private(set) var servers: [UUID: AgentToolServerLaunch?] = [:]

    init(kind: HarnessKind) { self.kind = kind }

    func setLaunchOptions(_ options: [String: String], for localSessionID: UUID) { launchOptions[localSessionID] = options }
    func setAdditionalWorkspaceRoots(_ roots: [URL], for localSessionID: UUID) { self.roots[localSessionID] = roots }
    func setAgentToolServer(_ server: AgentToolServerLaunch?, for localSessionID: UUID) { servers[localSessionID] = .some(server) }
    func instructionSources(for localSessionID: UUID) -> [String]? { ["/tmp/AGENTS.md"] }

    func probeRuntime() async throws -> HarnessRuntimeDescriptor { throw HarnessAdapterError.capabilityUnavailable("fixture") }
    func createSession(_ request: CreateHarnessSessionRequest) async throws -> HarnessSessionHandle {
        throw HarnessAdapterError.capabilityUnavailable("fixture")
    }
    func resumeSession(providerSessionID: String, localSessionID: UUID, workspaceURL: URL) async throws -> HarnessSessionHandle {
        throw HarnessAdapterError.capabilityUnavailable("fixture")
    }
    func send(_ prompt: String, to session: HarnessSessionHandle) async throws {}
    func interrupt(_ session: HarnessSessionHandle) async throws {}
    func respond(to permissionRequestID: String, decision: PermissionDecision, in session: HarnessSessionHandle) async throws {}
    func events(for session: HarnessSessionHandle) async -> AsyncStream<HarnessEventEnvelope> { AsyncStream { $0.finish() } }
    func close(_ session: HarnessSessionHandle) async {}
}

private actor BareAdapter: HarnessAdapter {
    nonisolated let kind = HarnessKind.claudeCode
    func probeRuntime() async throws -> HarnessRuntimeDescriptor { throw HarnessAdapterError.capabilityUnavailable("fixture") }
    func createSession(_ request: CreateHarnessSessionRequest) async throws -> HarnessSessionHandle {
        throw HarnessAdapterError.capabilityUnavailable("fixture")
    }
    func resumeSession(providerSessionID: String, localSessionID: UUID, workspaceURL: URL) async throws -> HarnessSessionHandle {
        throw HarnessAdapterError.capabilityUnavailable("fixture")
    }
    func send(_ prompt: String, to session: HarnessSessionHandle) async throws {}
    func interrupt(_ session: HarnessSessionHandle) async throws {}
    func respond(to permissionRequestID: String, decision: PermissionDecision, in session: HarnessSessionHandle) async throws {}
    func events(for session: HarnessSessionHandle) async -> AsyncStream<HarnessEventEnvelope> { AsyncStream { $0.finish() } }
    func close(_ session: HarnessSessionHandle) async {}
}
