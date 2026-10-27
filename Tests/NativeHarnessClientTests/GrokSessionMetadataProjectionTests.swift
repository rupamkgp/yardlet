import Foundation
import XCTest
@testable import NativeHarnessClient

final class GrokSessionMetadataProjectionTests: XCTestCase {
    func testReadsDetachedModelReasoningUsageAndLiveContext() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "yardlet-grok-metadata-\(UUID().uuidString)", directoryHint: .isDirectory)
        let sessionID = "provider-session"
        let session = root
            .appending(path: "workspace", directoryHint: .isDirectory)
            .appending(path: sessionID, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try writeJSON([
            "current_model_id": "grok-4.6-build",
            "reasoning_effort": "high"
        ], to: session.appending(path: "summary.json"))
        try writeJSON([
            "contextTokensUsed": 10_445,
            "contextWindowTokens": 500_000
        ], to: session.appending(path: "signals.json"))
        let update = """
        {"method":"session/update","params":{"update":{"sessionUpdate":"agent_message_chunk"}}}
        {"method":"_x.ai/session/update","params":{"update":{"sessionUpdate":"turn_completed","usage":{"inputTokens":20618,"outputTokens":64,"cachedReadTokens":6400,"reasoningTokens":50,"costUsdTicks":54434000}}}}
        """
        try update.write(to: session.appending(path: "updates.jsonl"), atomically: true, encoding: .utf8)

        let snapshot = try XCTUnwrap(GrokSessionMetadataProjection.snapshot(
            providerSessionID: sessionID,
            grokSessionsRoot: root
        ))
        XCTAssertEqual(snapshot.modelID, "grok-4.6-build")
        XCTAssertEqual(snapshot.reasoningEffort, "high")
        XCTAssertEqual(snapshot.usage?.inputTokens, 20_618)
        XCTAssertEqual(snapshot.usage?.cachedInputTokens, 6_400)
        XCTAssertEqual(snapshot.usage?.contextUsedTokens, 10_445)
        XCTAssertEqual(snapshot.usage?.contextWindowTokens, 500_000)
        XCTAssertEqual(snapshot.usage?.totalCostUSD ?? -1, 0.0054434, accuracy: 0.0000001)
        XCTAssertEqual(snapshot.detachedCapabilityState?.selectors.map(\.id), [
            "model", "reasoning_effort"
        ])
        XCTAssertEqual(
            snapshot.detachedCapabilityState?.selectors.map { $0.choices.first?.name },
            ["Grok 4.6 Build", "High Effort"]
        )
    }

    func testRejectsAmbiguousProviderSessionDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "yardlet-grok-ambiguous-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        for workspace in ["one", "two"] {
            let session = root
                .appending(path: workspace, directoryHint: .isDirectory)
                .appending(path: "same-session", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
            try writeJSON(["current_model_id": "grok"], to: session.appending(path: "summary.json"))
        }
        XCTAssertNil(GrokSessionMetadataProjection.snapshot(
            providerSessionID: "same-session",
            grokSessionsRoot: root
        ))
    }

    private func writeJSON(_ object: [String: Any], to url: URL) throws {
        try JSONSerialization.data(withJSONObject: object).write(to: url)
    }
}
