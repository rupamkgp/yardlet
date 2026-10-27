import Foundation
import XCTest
@testable import NativeHarnessClient

/// Which folder holds each task's browser profile, and which folders go: removing the wrong one signs a
/// person out of a running task without a sign, and a folder Chromium cannot open as a profile keeps its
/// sign-ins only in memory (docs/BROWSER_SESSION_ISOLATION.md).
@MainActor
final class BrowserTaskProfilesTests: XCTestCase {
    private var folder: URL!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "BrowserTaskProfilesTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = "yardlet.browser-profiles.tests"
        defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
        defaults.removePersistentDomain(forName: "yardlet.browser-profiles.tests")
    }

    private func makeFolder(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func testATaskStartsFromItsParentTakesTheDraftsProfileAndKeepsOnlyKeptFolders() throws {
        let profiles = BrowserTaskProfiles(root: folder, defaults: defaults)
        let parent = UUID(), child = UUID(), started = UUID(), archived = UUID()
        profiles.parentOf = { $0 == child ? parent : nil }
        // Chromium opens a profile on disk only in a direct child of its root cache.
        XCTAssertEqual(profiles.folder(for: parent.uuidString).deletingLastPathComponent().standardizedFileURL,
                       folder.standardizedFileURL)

        // A new task with no parent profile starts from the default profile.
        XCTAssertEqual(profiles.profile(for: parent), BrowserTabProfile(key: parent.uuidString, seedFrom: nil))
        try makeFolder(profiles.folder(for: parent.uuidString))
        XCTAssertEqual(profiles.profile(for: child)?.seedFrom, parent.uuidString, "a child task starts signed in as its parent")
        try makeFolder(profiles.folder(for: child.uuidString))
        XCTAssertNil(profiles.profile(for: child)?.seedFrom, "an existing profile is not seeded again")

        // The new-task screen's tabs go to the task it starts, with their profile; the screen gets a new one.
        let draftKey = profiles.key(for: TaskWorkspaceStore.draftID)
        try makeFolder(profiles.folder(for: draftKey))
        profiles.tabsMoved(from: TaskWorkspaceStore.draftID, to: started)
        XCTAssertEqual(profiles.key(for: started), draftKey)
        XCTAssertNotEqual(profiles.key(for: TaskWorkspaceStore.draftID), draftKey)
        XCTAssertEqual(BrowserTaskProfiles(root: folder, defaults: defaults).key(for: started), draftKey,
                       "the alias outlives the app")

        // The root cache also holds the default profile and Chromium's own folders; they stay.
        try makeFolder(profiles.folder(for: archived.uuidString))
        let chromium = ["Default", archived.uuidString, "Profile 1", "Safe Browsing"].map { folder.appending(path: $0) }
        for url in chromium { try makeFolder(url) }
        // Chromium lists the profiles it opened in Local State and keeps a removed one there.
        let gone = "Task-" + archived.uuidString, stays = "Task-" + parent.uuidString
        let entry: [String: Any] = ["name": "Person"], groups: [Any] = []
        let localState: [String: Any] = [
            "profile": ["info_cache": ["Default": entry, gone: entry, stays: entry], "profiles_order": ["Default", gone, stays]],
            "variations_google_groups": [gone: groups, stays: groups], "browser": ["enabled_labs_experiments": groups]
        ]
        try JSONSerialization.data(withJSONObject: localState).write(to: folder.appending(path: "Local State"))
        let removed = profiles.removeFolders(keeping: [parent, child, started])
        XCTAssertEqual(removed, [archived.uuidString])
        for kept in [parent.uuidString, child.uuidString, draftKey] {
            XCTAssertTrue(profiles.folderExists(kept), kept)
        }
        for url in chromium {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path(percentEncoded: false)), url.lastPathComponent)
        }
        let after = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: folder.appending(path: "Local State"))) as? [String: Any])
        let profileState = after["profile"] as? [String: Any]
        XCTAssertEqual((profileState?["info_cache"] as? [String: Any]).map { Set($0.keys) }, ["Default", stays])
        XCTAssertEqual(profileState?["profiles_order"] as? [String], ["Default", stays])
        XCTAssertEqual((after["variations_google_groups"] as? [String: Any]).map { Set($0.keys) }, [stays])
        XCTAssertNotNil(after["browser"], "the rest of Local State stays")

        profiles.storage = .shared
        XCTAssertNil(profiles.profile(for: parent), "shared storage opens every tab in the default profile")
    }
}
