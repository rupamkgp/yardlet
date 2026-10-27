import Foundation
import XCTest
@testable import NativeHarnessClient

@MainActor
final class AccountCenterLoadingTests: XCTestCase {
    func testCardsPublishIndependentlyBeforeSlowestProbeCompletes() async throws {
        let gate = AccountSnapshotGate(blockedHarness: .codex)
        let store = ProviderConnectionStore(defaultLoader: { descriptor, executableURL in
            await gate.load(descriptor: descriptor, executableURL: executableURL)
        })
        let suiteName = testDefaultsSuite("AccountCenterLoadingTests")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let selections = RuntimeSelectionStore(
            defaults: defaults,
            discoversRuntimes: false,
            loadsPersistedSelections: false
        )

        let refresh = Task { await store.check(savedOf: [], policy: .refresh, runtimeSelections: selections) }
        let deadline = ContinuousClock.now + .seconds(2)
        while store.defaultSnapshots[.openCode] == nil,
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertNotNil(store.defaultSnapshots[.openCode])
        XCTAssertFalse(store.isCheckingDefault(.openCode))
        XCTAssertTrue(store.isCheckingDefault(.codex))
        XCTAssertTrue(store.isChecking(anyOf: HarnessCatalog.builtIns.map(\.id)))

        await gate.release()
        await refresh.value

        XCTAssertFalse(store.isChecking(anyOf: HarnessCatalog.builtIns.map(\.id)))
        XCTAssertNotNil(store.defaultSnapshots[.codex])
    }
}

private actor AccountSnapshotGate {
    private let blockedHarness: HarnessKind
    private var isBlocked = true
    private var continuations: [CheckedContinuation<Void, Never>] = []

    init(blockedHarness: HarnessKind) {
        self.blockedHarness = blockedHarness
    }

    func load(
        descriptor: HarnessDescriptor,
        executableURL: URL?
    ) async -> HarnessAccountSnapshot {
        if descriptor.id == blockedHarness, isBlocked {
            await withCheckedContinuation { continuation in
                continuations.append(continuation)
            }
        }
        return .unavailable(for: descriptor)
    }

    func release() {
        isBlocked = false
        let values = continuations
        continuations.removeAll()
        values.forEach { $0.resume() }
    }
}
