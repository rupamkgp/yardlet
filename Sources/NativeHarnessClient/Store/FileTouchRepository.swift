import Foundation

/// Each task's file touches (`FileTouches`), one JSON file per task in Yardlet's own folder:
/// `~/.yardlet/file-activity/<task UUID>.json`. Nothing else reads them, and the folder can go at any
/// time: a Claude Code task's touches are read again from its transcript, another task's start over
/// with what Yardlet reads of it next. A deleted task's file goes with it.
struct FileTouchRepository: Sendable {
    let directoryURL: URL

    init(directoryURL: URL) {
        self.directoryURL = directoryURL.standardizedFileURL
    }

    func load(for taskID: UUID) -> FileTouches? {
        guard let data = try? Data(contentsOf: fileURL(for: taskID)) else { return nil }
        return try? JSONDecoder().decode(FileTouches.self, from: data)
    }

    func save(_ touches: FileTouches, for taskID: UUID) {
        guard let data = try? JSONEncoder().encode(touches) else { return }
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            try data.write(to: fileURL(for: taskID), options: .atomic)
        } catch {
            // The touches are read again from the transcript, or from what Yardlet reads next.
        }
    }

    func remove(for taskID: UUID) {
        let url = fileURL(for: taskID)
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private func fileURL(for taskID: UUID) -> URL {
        directoryURL.appending(path: "\(taskID.uuidString).json")
    }
}
