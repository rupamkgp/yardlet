import Foundation

/// The pull request a task made, as Yardlet shows it beside the task: which one (number, link,
/// repository) and, when GitHub's CLI could say, its state, its checks and its review.
///
/// A Claude Code task names its pull request in its own transcript (`TaskPullRequestLink`); any
/// task can also be matched by its folder's current branch. Without `gh`, or signed out of it,
/// only what the transcript names is known, and `state`, `checks` and `review` stay nil.
struct TaskPullRequest: Equatable, Sendable {
    enum State: String, Equatable, Sendable, CaseIterable {
        case open
        case draft
        case merged
        case closed
    }

    enum Checks: String, Equatable, Sendable, CaseIterable {
        case passing
        case failing
        case pending
    }

    enum Review: String, Equatable, Sendable, CaseIterable {
        case changesRequested
        case approved
    }

    /// How Yardlet found it: the task's transcript named it, or its folder's branch has it.
    enum Source: Equatable, Sendable {
        case transcriptLink
        case branch(String)
    }

    let number: Int
    let url: URL
    /// `owner/name`.
    let repository: String?
    var source: Source
    /// Nil when GitHub was not asked or could not answer.
    var state: State?
    /// Nil when the pull request has no checks, or its state is unknown.
    var checks: Checks?
    /// Nil when no review decided anything yet, or its state is unknown.
    var review: Review?

    init(number: Int, url: URL, repository: String?, source: Source = .transcriptLink,
         state: State? = nil, checks: Checks? = nil, review: Review? = nil) {
        self.number = number
        self.url = url
        self.repository = repository ?? Self.repository(in: url)
        self.source = source
        self.state = state
        self.checks = checks
        self.review = review
    }

    init(link: TaskPullRequestLink) {
        self.init(number: link.number, url: link.url, repository: link.repository)
    }

    /// Whether GitHub answered for it: false when only the transcript's link is known.
    var hasState: Bool { state != nil }

    /// A merged pull request no longer changes; there is nothing to ask GitHub again.
    var isSettled: Bool { state == .merged }

    /// The same pull request, which a link or a branch may name again.
    func isSamePullRequest(as other: TaskPullRequest) -> Bool {
        number == other.number && Self.canonical(url) == Self.canonical(other.url)
    }

    /// `owner/name` from `https://github.com/owner/name/pull/123`.
    static func repository(in url: URL) -> String? {
        let parts = url.path(percentEncoded: false).split(separator: "/").map(String.init)
        guard parts.count >= 4, parts[2] == "pull" else { return nil }
        return parts[0] + "/" + parts[1]
    }

    private static func canonical(_ url: URL) -> String {
        url.absoluteString.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

/// The record Claude Code writes to a session's transcript when the session opens or finds a pull
/// request: `{"type":"pr-link","sessionId":…,"prNumber":…,"prUrl":…,"prRepository":…,"timestamp":…}`.
/// It writes the record again as the session goes on, so the newest one is near the file's end.
struct TaskPullRequestLink: Equatable, Sendable {
    let number: Int
    let url: URL
    let repository: String?

    /// The bytes every such record holds, as a JSON token (a string value holding them is escaped).
    static let marker = Data(#""pr-link""#.utf8)

    /// The record on one transcript line, nil for any other line.
    init?(line: some DataProtocol) {
        let data = Data(line)
        guard data.range(of: Self.marker) != nil,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "pr-link" else { return nil }
        let number: Int
        if let value = object["prNumber"] as? Int {
            number = value
        } else if let text = object["prNumber"] as? String, let value = Int(text) {
            number = value
        } else {
            return nil
        }
        guard number > 0, let text = object["prUrl"] as? String, let url = URL(string: text),
              url.scheme == "https" || url.scheme == "http", url.host() != nil else { return nil }
        self.number = number
        self.url = url
        let repository = (object["prRepository"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.repository = repository.flatMap { $0.isEmpty ? nil : $0 } ?? TaskPullRequest.repository(in: url)
    }

    init(number: Int, url: URL, repository: String?) {
        self.number = number
        self.url = url
        self.repository = repository
    }

    /// The newest record among the lines of `data` — the last one in it.
    static func latest(in data: Data) -> TaskPullRequestLink? {
        var searchEnd = data.endIndex
        while searchEnd > data.startIndex,
              let found = data.range(of: marker, options: .backwards, in: data.startIndex..<searchEnd) {
            let lineStart = data[data.startIndex..<found.lowerBound].lastIndex(of: 10).map { $0 + 1 } ?? data.startIndex
            let lineEnd = data[found.upperBound..<data.endIndex].firstIndex(of: 10) ?? data.endIndex
            if let link = TaskPullRequestLink(line: data[lineStart..<lineEnd]) { return link }
            searchEnd = lineStart
        }
        return nil
    }
}

/// What a scan of one transcript found and how far it read. The next scan of the same file reads
/// only what was appended since; a replaced or shortened file is scanned again from its end.
struct ClaudePullRequestLinkScan: Equatable, Sendable {
    struct FileIdentity: Equatable, Sendable {
        let device: Int64
        let inode: UInt64
    }

    let file: FileIdentity
    /// Just past the last whole line read: where the next scan starts.
    let scannedThrough: Int64
    /// The newest record up to `scannedThrough`.
    let link: TaskPullRequestLink?
    /// Where under the config's `projects` folder the transcript was found, so the next scan of
    /// the same file need not look through every project folder again. In memory only.
    var path: [String]? = nil
}

/// Finds a transcript's newest `pr-link` record without reading the whole file each time.
///
/// The first scan reads back from the file's end a chunk at a time and stops at the first record
/// it meets, which is the newest. Claude Code writes the record again as a session goes on: in all
/// 123 of this Mac's transcripts that had one (2026-10-15), the newest was within 33 KiB of the end.
/// So the first scan goes back at most `maximumFirstScanBytes` and takes a transcript without one
/// there to have none. Later scans read forward from where the last one stopped, so only appended
/// lines are read.
enum ClaudePullRequestLinkScanner {
    static let chunkBytes = 1 << 20
    /// How far back the first scan of a transcript goes before taking it to have no link.
    static let maximumFirstScanBytes: Int64 = 8 << 20

    /// - Parameters:
    ///   - size: the file's size now.
    ///   - previous: the last scan of a file, used when it was this file and it has not shrunk.
    ///   - read: the bytes at an offset, at most `count` of them.
    static func scan(
        file: ClaudePullRequestLinkScan.FileIdentity,
        size: Int64,
        previous: ClaudePullRequestLinkScan?,
        maximumFirstScanBytes: Int64 = maximumFirstScanBytes,
        read: (_ offset: Int64, _ count: Int) throws -> Data
    ) throws -> ClaudePullRequestLinkScan {
        if let previous, previous.file == file, previous.scannedThrough <= size {
            return try scanForward(previous, size: size, read: read)
        }
        return try scanBackward(file: file, size: size, floor: max(0, size - maximumFirstScanBytes), read: read)
    }

    /// The lines appended after `previous`: a newer record replaces the one it found.
    private static func scanForward(
        _ previous: ClaudePullRequestLinkScan, size: Int64,
        read: (Int64, Int) throws -> Data
    ) throws -> ClaudePullRequestLinkScan {
        var position = previous.scannedThrough
        var link = previous.link
        var scannedThrough = previous.scannedThrough
        var carry = Data()
        while position < size {
            let count = Int(min(Int64(chunkBytes), size - position))
            let bytes = try read(position, count)
            guard !bytes.isEmpty else { break }
            position += Int64(bytes.count)
            carry.append(bytes)
            // Only whole lines: a line still being written is read again next time.
            guard let lastNewline = carry.lastIndex(of: 10) else { continue }
            let whole = carry[carry.startIndex...lastNewline]
            if let found = TaskPullRequestLink.latest(in: Data(whole)) { link = found }
            scannedThrough += Int64(whole.count)
            carry = Data(carry[(lastNewline + 1)...])
        }
        return ClaudePullRequestLinkScan(file: previous.file, scannedThrough: scannedThrough, link: link)
    }

    /// Back from the end of the file's last whole line to `floor`, stopping at the first record.
    private static func scanBackward(
        file: ClaudePullRequestLinkScan.FileIdentity, size: Int64, floor: Int64,
        read: (Int64, Int) throws -> Data
    ) throws -> ClaudePullRequestLinkScan {
        var position = size
        // Bytes from `position` up to the end of the region still to search; the region's end is
        // always a line's end.
        var pending = Data()
        var regionEnd: Int64?
        while position > floor {
            let start = max(floor, position - Int64(chunkBytes))
            let bytes = try read(start, Int(position - start))
            guard bytes.count == Int(position - start) else { break }
            pending = bytes + pending
            position = start
            if regionEnd == nil {
                // The file's last whole line ends at its last newline; anything after is being written.
                guard let lastNewline = pending.lastIndex(of: 10) else { continue }
                regionEnd = position + Int64(lastNewline - pending.startIndex) + 1
                pending = Data(pending[...lastNewline])
            }
            // Lines before the first newline may begin before `position`: keep them for the next chunk.
            let completeFrom: Data.Index
            if position == 0 {
                completeFrom = pending.startIndex
            } else if let newline = pending.firstIndex(of: 10) {
                completeFrom = newline + 1
            } else {
                continue
            }
            if let link = TaskPullRequestLink.latest(in: Data(pending[completeFrom...])) {
                return ClaudePullRequestLinkScan(file: file, scannedThrough: regionEnd ?? size, link: link)
            }
            pending = Data(pending[..<completeFrom])
        }
        return ClaudePullRequestLinkScan(file: file, scannedThrough: regionEnd ?? 0, link: nil)
    }
}

/// `gh pr view --json number,url,state,isDraft,reviewDecision,statusCheckRollup` read into a
/// `TaskPullRequest`.
enum GitHubPullRequestStatus {
    static let fields = "number,url,state,isDraft,reviewDecision,statusCheckRollup"

    /// Nil when the output is not a pull request.
    static func parse(_ data: Data, source: TaskPullRequest.Source) -> TaskPullRequest? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let number = object["number"] as? Int, number > 0,
              let text = object["url"] as? String, let url = URL(string: text) else { return nil }
        let state: TaskPullRequest.State?
        switch (object["state"] as? String)?.uppercased() {
        case "OPEN": state = (object["isDraft"] as? Bool) == true ? .draft : .open
        case "MERGED": state = .merged
        case "CLOSED": state = .closed
        default: state = nil
        }
        let review: TaskPullRequest.Review? = switch (object["reviewDecision"] as? String)?.uppercased() {
        case "CHANGES_REQUESTED": .changesRequested
        case "APPROVED": .approved
        default: nil
        }
        return TaskPullRequest(number: number, url: url, repository: nil, source: source, state: state,
                               checks: checks(object["statusCheckRollup"] as? [[String: Any]] ?? []),
                               review: review)
    }

    /// The checks' sum, as `gh pr checks` sums them: any failure fails them, then anything not
    /// finished keeps them pending; skipped and neutral checks count as passing. Nil without checks.
    static func checks(_ rollup: [[String: Any]]) -> TaskPullRequest.Checks? {
        var sawFailure = false
        var sawPending = false
        var sawAny = false
        for check in rollup {
            let value: String
            if check["__typename"] as? String == "StatusContext" || (check["status"] == nil && check["state"] != nil) {
                value = (check["state"] as? String ?? "").uppercased()
            } else {
                let status = (check["status"] as? String ?? "").uppercased()
                value = status == "COMPLETED" ? (check["conclusion"] as? String ?? "").uppercased() : status
            }
            sawAny = true
            switch value {
            case "SUCCESS", "NEUTRAL", "SKIPPED":
                break
            case "FAILURE", "ERROR", "CANCELLED", "TIMED_OUT", "ACTION_REQUIRED", "STARTUP_FAILURE":
                sawFailure = true
            default:
                // EXPECTED, PENDING, QUEUED, IN_PROGRESS, WAITING, REQUESTED, STALE, or a new one.
                sawPending = true
            }
        }
        guard sawAny else { return nil }
        return sawFailure ? .failing : sawPending ? .pending : .passing
    }
}
