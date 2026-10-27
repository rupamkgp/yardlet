import Foundation
import XCTest
@testable import NativeHarnessClient

final class TranscriptRepositoryTests: XCTestCase {
    func testFileRepositoryRoundTripsAndRemovesBoundedSnapshot() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: "YardletTranscriptRepositoryTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let repository = FileTranscriptRepository(directoryURL: rootURL)
        let sessionID = UUID()
        let entries = [
            TranscriptEntry(content: .user(text: "question")),
            TranscriptEntry(content: .assistant(text: "answer", isStreaming: false))
        ]

        repository.save(entries, for: sessionID)
        XCTAssertEqual(repository.load(for: sessionID), entries)

        repository.remove(for: sessionID)
        XCTAssertTrue(repository.load(for: sessionID).isEmpty)
    }

    func testMigratingRepositoryMovesLegacySnapshotAfterVerifiedPrimaryWrite() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: "YardletTranscriptMigrationTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: testDefaultsSuite("NativeHarnessClientTests"))
        )
        let sessionID = UUID()
        let legacy = UserDefaultsTranscriptRepository(defaults: defaults, keyPrefix: "legacy.")
        let primary = FileTranscriptRepository(directoryURL: rootURL)
        let repository = MigratingTranscriptRepository(primary: primary, legacy: legacy)
        let entries = [TranscriptEntry(content: .user(text: "migrate me"))]
        legacy.save(entries, for: sessionID)

        XCTAssertEqual(repository.load(for: sessionID), entries)
        XCTAssertEqual(primary.load(for: sessionID), entries)
        XCTAssertTrue(legacy.load(for: sessionID).isEmpty)
    }

    /// The snapshot queue saves a streaming task many times; no save may write to UserDefaults,
    /// whose change notification waits for the main thread (the 2026-10-22 hang).
    func testSavingAndRemovingWithoutALegacySnapshotDoNotWriteUserDefaults() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: "YardletTranscriptNoDefaultsTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("NativeHarnessClientTests")))
        let repository = MigratingTranscriptRepository(
            primary: FileTranscriptRepository(directoryURL: rootURL),
            legacy: UserDefaultsTranscriptRepository(defaults: defaults, keyPrefix: "legacy."))
        var changes = 0
        let observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: defaults, queue: nil) { _ in changes += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        let sessionID = UUID()
        for index in 0..<5 {
            repository.save([TranscriptEntry(content: .user(text: "turn \(index)"))], for: sessionID)
        }
        repository.remove(for: sessionID)
        XCTAssertEqual(changes, 0)
        XCTAssertTrue(repository.load(for: sessionID).isEmpty)
    }

    /// The 2026-10-22 hang the other way round: a legacy snapshot is still moved, on the snapshot
    /// queue, when a task's snapshot is first read, and the main thread waits for that read
    /// (`TranscriptSnapshotWriter.load`). The UserDefaults write that removes the legacy copy must
    /// not wait for the main thread: the menu bar item observing those defaults is told on the
    /// writing thread. Before, its main-queue observer held the write until the main thread ran it,
    /// which it never did while it waited.
    @MainActor
    func testMovingALegacySnapshotOnTheSnapshotQueueDoesNotWaitForTheWaitingMainThread() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: "YardletTranscriptMainWaitTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let suite = testDefaultsSuite("NativeHarnessClientTests")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(false, forKey: MenuBarPreference.key)
        let item = MenuBarStatusItem(controller: MenuBarMenuController(content: { .empty }, actions: .init()),
                                     defaults: defaults)
        defer { withExtendedLifetime(item) {} }
        let legacy = UserDefaultsTranscriptRepository(defaults: defaults, keyPrefix: "legacy.")
        let sessionID = UUID()
        let entries = [TranscriptEntry(content: .user(text: "moved while the main thread waits"))]
        legacy.save(entries, for: sessionID)
        let repository = SendableRepository(base: MigratingTranscriptRepository(
            primary: FileTranscriptRepository(directoryURL: rootURL), legacy: legacy))

        // The main thread waits for the queue as `queue.sync` would, but gives up after a while
        // instead of hanging the test when the write waits for it.
        let read = DispatchSemaphore(value: 0)
        DispatchQueue(label: "TranscriptRepositoryTests.snapshots").async {
            _ = repository.base.load(for: sessionID)
            read.signal()
        }
        let finished = read.wait(timeout: .now() + 2) == .success
        if !finished { RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }
        XCTAssertTrue(finished, "Removing the legacy copy waited for the main thread")
        XCTAssertTrue(legacy.load(for: sessionID).isEmpty)
        XCTAssertEqual(FileTranscriptRepository(directoryURL: rootURL).load(for: sessionID), entries)
    }
}

private struct SendableRepository: @unchecked Sendable {
    let base: MigratingTranscriptRepository
}
