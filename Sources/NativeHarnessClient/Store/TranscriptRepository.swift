import Foundation

/// A bounded, app-owned reading snapshot. Provider state remains authoritative after a task is
/// resumed; this repository only lets a detached task show its last observed conversation.
protocol TranscriptRepository {
    func load(for sessionID: UUID) -> [TranscriptEntry]
    func save(_ entries: [TranscriptEntry], for sessionID: UUID)
    func remove(for sessionID: UUID)
}

struct UserDefaultsTranscriptRepository: TranscriptRepository {
    let defaults: UserDefaults
    let keyPrefix: String

    init(
        defaults: UserDefaults = .yardlet,
        keyPrefix: String = "NativeHarnessClient.transcript."
    ) {
        self.defaults = defaults
        self.keyPrefix = keyPrefix
    }

    func load(for sessionID: UUID) -> [TranscriptEntry] {
        guard let data = defaults.data(forKey: keyPrefix + sessionID.uuidString) else { return [] }
        return (try? JSONDecoder().decode([TranscriptEntry].self, from: data)) ?? []
    }

    func save(_ entries: [TranscriptEntry], for sessionID: UUID) {
        let bounded = Array(entries.suffix(500))
        guard !bounded.isEmpty,
              let data = try? JSONEncoder().encode(bounded) else {
            remove(for: sessionID)
            return
        }
        defaults.set(data, forKey: keyPrefix + sessionID.uuidString)
    }

    /// Writes only when there is something to remove. A UserDefaults write posts
    /// `didChangeNotification`, which waits for its main-queue observers; posted from the snapshot
    /// queue while the main thread waits on that queue, it hung the app (2026-10-22).
    func remove(for sessionID: UUID) {
        let key = keyPrefix + sessionID.uuidString
        guard defaults.object(forKey: key) != nil else { return }
        defaults.removeObject(forKey: key)
    }
}

struct FileTranscriptRepository: TranscriptRepository {
    let directoryURL: URL
    private let fileManager: FileManager

    init(directoryURL: URL, fileManager: FileManager = .default) {
        self.directoryURL = directoryURL.standardizedFileURL
        self.fileManager = fileManager
    }

    func load(for sessionID: UUID) -> [TranscriptEntry] {
        guard let data = try? Data(contentsOf: fileURL(for: sessionID)) else { return [] }
        return (try? JSONDecoder().decode([TranscriptEntry].self, from: data)) ?? []
    }

    func save(_ entries: [TranscriptEntry], for sessionID: UUID) {
        let bounded = Array(entries.suffix(500))
        guard !bounded.isEmpty,
              let data = try? JSONEncoder().encode(bounded) else {
            remove(for: sessionID)
            return
        }
        do {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL(for: sessionID), options: .atomic)
        } catch {
            // The provider remains authoritative; an unavailable reading cache must not break a
            // task's live lifecycle.
        }
    }

    func remove(for sessionID: UUID) {
        let url = fileURL(for: sessionID)
        guard fileManager.fileExists(atPath: url.path(percentEncoded: false)) else { return }
        try? fileManager.removeItem(at: url)
    }

    private func fileURL(for sessionID: UUID) -> URL {
        directoryURL.appending(path: "\(sessionID.uuidString).json")
    }
}

/// Moves the brief UserDefaults-backed development snapshot into the product storage directory
/// without making migration success part of task restoration. Only loading migrates: a save
/// writes the file alone, so the snapshot queue does not touch UserDefaults or read back what it
/// just wrote on every save of a streaming task.
struct MigratingTranscriptRepository: TranscriptRepository {
    let primary: any TranscriptRepository
    let legacy: any TranscriptRepository

    func load(for sessionID: UUID) -> [TranscriptEntry] {
        let current = primary.load(for: sessionID)
        guard current.isEmpty else { return current }
        let previous = legacy.load(for: sessionID)
        guard !previous.isEmpty else { return [] }
        primary.save(previous, for: sessionID)
        if !primary.load(for: sessionID).isEmpty {
            legacy.remove(for: sessionID)
        }
        return previous
    }

    func save(_ entries: [TranscriptEntry], for sessionID: UUID) {
        primary.save(entries, for: sessionID)
    }

    func remove(for sessionID: UUID) {
        primary.remove(for: sessionID)
        legacy.remove(for: sessionID)
    }
}
