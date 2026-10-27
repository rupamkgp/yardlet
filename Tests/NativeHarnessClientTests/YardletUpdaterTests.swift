import XCTest
@testable import NativeHarnessClient

/// Self-update: a staged build replaces the installed bundle only after the app has quit, keeps the
/// previous bundle, and changes nothing when the staged build cannot be verified.
final class YardletUpdaterTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "yardlet-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testOnlyAStagedBuildOfThisAppThatDiffersFromTheInstalledOneIsOffered() throws {
        let updates = root.appending(path: "Updates")
        let installed = try bundle(at: root.appending(path: "Installed/Yardlet.app"), marker: "installed")
        XCTAssertThrowsError(try YardletUpdater.pending(root: updates, bundleIdentifier: identifier, installedBundle: installed)) {
            XCTAssertEqual($0 as? YardletUpdater.Problem, .nothingStaged)
        }
        let staged = updates.appending(path: "Pending/Yardlet.app")
        try bundle(at: staged, marker: "other", identifier: "com.example.other")
        XCTAssertThrowsError(try YardletUpdater.pending(root: updates, bundleIdentifier: identifier, installedBundle: installed)) {
            XCTAssertEqual($0 as? YardletUpdater.Problem, .otherApp)
        }
        try FileManager.default.removeItem(at: staged)
        try FileManager.default.copyItem(at: installed, to: staged)
        XCTAssertThrowsError(try YardletUpdater.pending(root: updates, bundleIdentifier: identifier, installedBundle: installed)) {
            XCTAssertEqual($0 as? YardletUpdater.Problem, .alreadyInstalled)
        }
        try FileManager.default.removeItem(at: staged)
        try bundle(at: staged, marker: "new", executableSuffix: "new build")
        try Data(#"{"commit":"abc1234","dirty":true,"builtAt":"2026-10-06T13:00:00Z"}"#.utf8)
            .write(to: updates.appending(path: "Pending/manifest.json"))
        let candidate = try YardletUpdater.pending(root: updates, bundleIdentifier: identifier, installedBundle: installed)
        XCTAssertEqual(candidate.commit, "abc1234")
        XCTAssertTrue(candidate.hasUncommittedChanges)
        XCTAssertEqual(candidate.builtAt, Date(timeIntervalSince1970: 1_791_291_600))
        XCTAssertNoThrow(try YardletUpdater.verifySignature(of: candidate.bundleURL))
    }

    func testStagingScriptPublishesACompleteBuildWithItsManifest() throws {
        let built = try bundle(at: root.appending(path: "build/Yardlet.app"), marker: "built", executableSuffix: "built")
        let installed = try bundle(at: root.appending(path: "Installed/Yardlet.app"), marker: "installed")
        let updates = root.appending(path: "Updates")
        let script = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "scripts/stage-update.sh")
        let result = try run("/bin/zsh", [script.path, built.path],
                             environment: ["YARDLET_UPDATES_DIR": updates.path, "YARDLET_INSTALLED_APP": installed.path])
        XCTAssertEqual(result.status, 0, result.output)
        let candidate = try YardletUpdater.pending(root: updates, bundleIdentifier: identifier, installedBundle: installed)
        XCTAssertNotNil(candidate.commit)
        XCTAssertNotNil(candidate.builtAt)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: updates.path).filter { $0.hasPrefix(".incoming") }
        XCTAssertEqual(leftovers, [])
    }

    func testInstallerSwapsAfterTheAppQuitsAndKeepsThePreviousApp() throws {
        let updates = root.appending(path: "Updates")
        let target = try bundle(at: root.appending(path: "Applications/Yardlet.app"), marker: "old")
        try bundle(at: updates.appending(path: "Pending/Yardlet.app"), marker: "new", executableSuffix: "new")
        try Data("{}".utf8).write(to: updates.appending(path: "Pending/manifest.json"))
        let app = try Process.run(URL(filePath: "/bin/sleep"), arguments: ["1"])
        let installer = try YardletUpdater.launchInstaller(target: target, processID: app.processIdentifier,
            root: updates, relaunch: false)
        XCTAssertEqual(try marker(target), "old", "Nothing moves while the app is still running")
        XCTAssertNotEqual(getsid(installer), getsid(0), "The installer does not share the app's session")
        XCTAssertEqual(exitStatus(installer), 0)
        XCTAssertEqual(try marker(target), "new")
        XCTAssertEqual(try marker(updates.appending(path: "Previous/Yardlet.app")), "old")
        XCTAssertFalse(FileManager.default.fileExists(atPath: updates.appending(path: "Pending/Yardlet.app").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: updates.appending(path: "installed.json").path))
        XCTAssertNoThrow(try YardletUpdater.verifySignature(of: target))
    }

    func testATamperedStagedBuildChangesNothing() throws {
        let updates = root.appending(path: "Updates")
        let target = try bundle(at: root.appending(path: "Applications/Yardlet.app"), marker: "old")
        let staged = try bundle(at: updates.appending(path: "Pending/Yardlet.app"), marker: "new", executableSuffix: "new")
        try Data("changed after signing".utf8).write(to: staged.appending(path: "Contents/Resources/marker.txt"))
        XCTAssertThrowsError(try YardletUpdater.verifySignature(of: staged))
        let installer = try YardletUpdater.launchInstaller(target: target, processID: 999_999, root: updates, relaunch: false)
        XCTAssertNotEqual(exitStatus(installer), 0)
        XCTAssertEqual(try marker(target), "old")
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path))
        XCTAssertTrue(try String(contentsOf: updates.appending(path: "install.log"), encoding: .utf8)
            .contains("nothing changed"))
    }

    // MARK: - Fixtures

    private let identifier = "com.zzunkie.yardlet"

    /// A minimal ad-hoc signed app bundle whose resources carry a marker.
    @discardableResult
    private func bundle(at url: URL, marker: String, identifier: String = "com.zzunkie.yardlet",
                        executableSuffix: String = "") throws -> URL {
        let contents = url.appending(path: "Contents")
        try FileManager.default.createDirectory(at: contents.appending(path: "MacOS"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: contents.appending(path: "Resources"), withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleExecutable": "Yardlet",
                                   "CFBundlePackageType": "APPL", "CFBundleName": "Yardlet"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appending(path: "Info.plist"))
        let executable = contents.appending(path: "MacOS/Yardlet")
        try Data("#!/bin/sh\n# \(executableSuffix)\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try Data(marker.utf8).write(to: contents.appending(path: "Resources/marker.txt"))
        let signed = try run("/usr/bin/codesign", ["--force", "--sign", "-", url.path])
        XCTAssertEqual(signed.status, 0, signed.output)
        return url
    }

    private func exitStatus(_ pid: pid_t) -> Int32 {
        var status: Int32 = 0
        _ = waitpid(pid, &status, 0)
        return (status >> 8) & 0xff
    }

    private func marker(_ bundle: URL) throws -> String {
        try String(contentsOf: bundle.appending(path: "Contents/Resources/marker.txt"), encoding: .utf8)
    }

    private func run(_ path: String, _ arguments: [String], environment: [String: String] = [:]) throws -> (status: Int32, output: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(filePath: path)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
