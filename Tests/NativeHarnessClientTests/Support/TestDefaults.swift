import Foundation

/// A preferences suite of one test's own, for `UserDefaults(suiteName:)`, that leaves nothing on
/// the Mac. A suite named `Label.<UUID>` is a plist in ~/Library/Preferences, and cfprefsd keeps
/// that file after `removePersistentDomain(forName:)`, writing it back as an empty dictionary, so
/// every run left thousands behind. A suite named by an absolute path is the same `UserDefaults`
/// kept in that file instead: these live in a folder of this test process's own, which goes when
/// the process exits.
func testDefaultsSuite(_ label: String) -> String {
    TestDefaultsFolder.url.appending(path: "\(label).\(UUID().uuidString)").path(percentEncoded: false)
}

private enum TestDefaultsFolder {
    static let url: URL = {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "yardlet-test-defaults-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        atexit { try? FileManager.default.removeItem(at: TestDefaultsFolder.url) }
        return url
    }()
}
