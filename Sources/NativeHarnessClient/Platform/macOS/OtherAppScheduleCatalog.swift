import Foundation

/// Finds the schedules the Claude app and the Codex app keep on this Mac, read only:
/// - Claude app: `~/Library/Application Support/Claude/claude-code-sessions/<a>/<b>/scheduled-tasks.json`,
///   each task's prompt in the `SKILL.md` its `filePath` names (under `~/.claude/scheduled-tasks/<id>/`).
/// - Codex app: `~/.codex/automations/<id>/automation.toml` (`.run-jitter-salt` and other files are
///   not read).
/// Nothing is written to either app's files, and no app is asked anything.
enum OtherAppScheduleCatalog {
    struct Listing: Equatable {
        var claude: [ImportableSchedule] = []
        var codex: [ImportableSchedule] = []
        /// The Claude app's session IDs (`local_…`) to their Claude Code session IDs, for the sessions
        /// the listed Claude schedules report to.
        var claudeAppSessions: [String: String] = [:]
        var all: [ImportableSchedule] { claude + codex }
    }

    static func read(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                     claudeRoot: URL = ClaudeDesktopSessionCatalog.defaultRoot()) -> Listing {
        var listing = Listing(
            claude: claudeSchedules(root: claudeRoot, home: home),
            codex: codexSchedules(automations: home.appending(path: ".codex/automations", directoryHint: .isDirectory)))
        let wanted = Set(listing.claude.compactMap { item -> String? in
            if case let .claudeAppSession(id) = item.link { return id }
            return nil
        })
        if !wanted.isEmpty {
            for session in ClaudeDesktopSessionCatalog.sessions(in: claudeRoot) {
                guard let id = session.desktopSessionID, wanted.contains(id), listing.claudeAppSessions[id] == nil else { continue }
                listing.claudeAppSessions[id] = session.cliSessionID
            }
        }
        return listing
    }

    static func claudeSchedules(root: URL, home: URL) -> [ImportableSchedule] {
        var seen = Set<String>()
        var found: [ImportableSchedule] = []
        for account in folders(in: root) {
            for organization in folders(in: account) {
                let file = organization.appending(path: "scheduled-tasks.json")
                guard isSmallRegularFile(file, limit: OtherAppScheduleImport.maximumFileBytes),
                      let data = try? Data(contentsOf: file) else { continue }
                let schedules = OtherAppScheduleImport.claudeSchedules(from: data) { filePath, id in
                    promptFile(filePath, id: id, home: home)
                }
                for schedule in schedules where seen.insert(schedule.origin.sourceID).inserted {
                    found.append(schedule)
                }
            }
        }
        return found
    }

    /// The task's `SKILL.md`: the path the app recorded when it is that file, else where the app keeps it.
    private static func promptFile(_ filePath: String?, id: String, home: URL) -> String? {
        var candidates: [URL] = []
        if let filePath, filePath.hasPrefix("/"), filePath.hasSuffix("/SKILL.md") {
            candidates.append(URL(filePath: filePath))
        }
        if !id.contains("/"), id != "..", id != "." {
            candidates.append(home.appending(path: ".claude/scheduled-tasks/\(id)/SKILL.md"))
        }
        for file in candidates where isSmallRegularFile(file, limit: OtherAppScheduleImport.maximumPromptBytes) {
            if let text = try? String(contentsOf: file, encoding: .utf8) { return text }
        }
        return nil
    }

    static func codexSchedules(automations: URL) -> [ImportableSchedule] {
        folders(in: automations).compactMap { folder in
            let file = folder.appending(path: "automation.toml")
            guard isSmallRegularFile(file, limit: OtherAppScheduleImport.maximumFileBytes),
                  let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
            return OtherAppScheduleImport.codexSchedule(fromTOML: text)
        }
    }

    private static let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]

    private static func folders(in folder: URL) -> [URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])) ?? []
        return entries.filter { url in
            guard let values = try? url.resourceValues(forKeys: keys) else { return false }
            return values.isDirectory == true && values.isSymbolicLink != true
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func isSmallRegularFile(_ url: URL, limit: Int) -> Bool {
        guard let values = try? url.resourceValues(forKeys: keys) else { return false }
        return values.isRegularFile == true && values.isSymbolicLink != true && (values.fileSize ?? 0) <= limit
    }
}

extension AppModel {
    /// Reads both apps' schedules off the main thread and finds each one's Yardlet task.
    func scheduleImportListing() async -> ScheduleImportListing {
        let root = claudeDesktopSessionsRoot
        let found = await Task.detached(priority: .userInitiated) { OtherAppScheduleCatalog.read(claudeRoot: root) }.value
        return scheduleImportListing(found)
    }

    func scheduleImportListing(_ found: OtherAppScheduleCatalog.Listing) -> ScheduleImportListing {
        var listing = ScheduleImportListing(claude: found.claude, codex: found.codex)
        for item in found.all {
            if scheduledTasks.isImported(item.origin) { listing.imported.insert(item.id) }
            switch item.link {
            case .none:
                continue
            case let .codexThread(thread):
                if let task = store.sessions.first(where: { $0.harness == .codex && $0.providerSessionID == thread }) {
                    listing.linkedTasks[item.id] = task.id
                }
            case let .claudeAppSession(desktopID):
                if let cli = found.claudeAppSessions[desktopID],
                   let task = store.sessions.first(where: {
                       $0.harness == .claudeCode && $0.providerSessionID?.lowercased() == cli.lowercased()
                   }) {
                    listing.linkedTasks[item.id] = task.id
                }
            }
        }
        return listing
    }

    /// Adds the chosen schedules. Returns how many came in (one already here is not added twice).
    @discardableResult
    func importSchedules(_ chosen: [ImportableSchedule], linkedTasks: [String: UUID]) -> Int {
        let schedules = chosen.compactMap { item in
            OtherAppScheduleImport.schedule(
                from: item, linkedTask: linkedTasks[item.id],
                projectID: item.workspacePath.flatMap {
                    projects.project(containingRoot: URL(filePath: $0, directoryHint: .isDirectory))?.id
                })
        }
        return scheduledTasks.add(imported: schedules).count
    }
}
