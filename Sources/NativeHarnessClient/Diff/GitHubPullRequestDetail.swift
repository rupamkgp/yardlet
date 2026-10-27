import Foundation

/// A pull request's full status, as the session rail's Changes card shows it: its
/// title and branches, whether it can merge, each check, its reviews and auto-merge.
/// Read with the person's own `gh` (`gh pr view <url> --json …`); Yardlet asks GitHub nothing else.
struct PullRequestDetail: Equatable, Sendable {
    /// One check of the head commit: a GitHub Actions job or another app's check run, or a commit
    /// status.
    struct Check: Identifiable, Equatable, Sendable {
        /// How the check sums into the checks' state, as `gh pr checks` buckets them. A cancelled
        /// check fails; a skipped or neutral one passes.
        enum Bucket: String, Equatable, Sendable, CaseIterable {
            case failing
            case pending
            case passing
            case skipped
        }

        let id: String
        let name: String
        let workflow: String?
        let bucket: Bucket
        /// GitHub's word for it: `FAILURE`, `IN_PROGRESS`, `SUCCESS`, ….
        let state: String
        let link: URL?
        let startedAt: Date?
        let completedAt: Date?

        /// The Actions run behind the check, from its link (`…/actions/runs/<id>/job/<job>`), which
        /// `gh run view` and `gh run rerun` take. Nil for a check another app reports.
        var runID: String? { link.flatMap(Self.runID(in:)) }

        var duration: TimeInterval? {
            guard let startedAt, let completedAt, completedAt >= startedAt else { return nil }
            return completedAt.timeIntervalSince(startedAt)
        }

        static func runID(in url: URL) -> String? {
            let parts = url.path(percentEncoded: false).split(separator: "/").map(String.init)
            guard let index = parts.firstIndex(of: "runs"), index > 0, parts[index - 1] == "actions",
                  parts.indices.contains(index + 1) else { return nil }
            let id = parts[index + 1]
            return !id.isEmpty && id.allSatisfy(\.isNumber) ? id : nil
        }
    }

    struct Review: Equatable, Sendable {
        enum Decision: String, Equatable, Sendable {
            case approved = "APPROVED"
            case changesRequested = "CHANGES_REQUESTED"
            case commented = "COMMENTED"
            case dismissed = "DISMISSED"
            case pending = "PENDING"
        }

        let author: String
        let decision: Decision
        let submittedAt: Date?
    }

    /// GitHub's `mergeStateStatus`.
    enum MergeState: String, Equatable, Sendable {
        case clean = "CLEAN"
        case blocked = "BLOCKED"
        case behind = "BEHIND"
        case dirty = "DIRTY"
        case unstable = "UNSTABLE"
        case draft = "DRAFT"
        case hasHooks = "HAS_HOOKS"
        case unknown = "UNKNOWN"
    }

    enum MergeMethod: String, Equatable, Sendable, CaseIterable {
        case squash = "SQUASH"
        case merge = "MERGE"
        case rebase = "REBASE"

        /// The flag `gh pr merge` takes for it.
        var flag: String {
            switch self {
            case .squash: "--squash"
            case .merge: "--merge"
            case .rebase: "--rebase"
            }
        }

        var title: String {
            switch self {
            case .squash: L10n.string("Squash and merge")
            case .merge: L10n.string("Create a merge commit")
            case .rebase: L10n.string("Rebase and merge")
            }
        }
    }

    let number: Int
    let url: URL
    let title: String
    let state: TaskPullRequest.State
    let headBranch: String?
    let baseBranch: String?
    /// The head commit, which a merge names so a newer push is never merged unseen.
    let headSHA: String?
    /// `MERGEABLE`, `CONFLICTING` or `UNKNOWN`.
    let mergeable: String?
    let mergeState: MergeState
    let review: TaskPullRequest.Review?
    let reviews: [Review]
    /// Auto-merge's method, while it is on.
    let autoMerge: MergeMethod?
    /// Failing first, then running, then passing and skipped, each by name.
    let checks: [Check]

    var failedChecks: [Check] { checks.filter { $0.bucket == .failing } }

    func count(_ bucket: Check.Bucket) -> Int { checks.filter { $0.bucket == bucket }.count }

    /// The checks summed as the badge sums them.
    var checksState: TaskPullRequest.Checks? {
        guard !checks.isEmpty else { return nil }
        if count(.failing) > 0 { return .failing }
        if count(.pending) > 0 { return .pending }
        return .passing
    }

    var hasConflicts: Bool { mergeState == .dirty || mergeable == "CONFLICTING" }

    var isOpen: Bool { state == .open || state == .draft }

    /// What the badge and the sidebar row show for the same pull request.
    var summary: TaskPullRequest {
        TaskPullRequest(number: number, url: url, repository: nil, state: state, checks: checksState, review: review)
    }

    /// "1 failed, 2 in progress, 5 passed, 1 skipped" — the Claude app's checks line (`47HDImpBnt`),
    /// naming only what is there.
    var checksSummaryText: String? {
        guard !checks.isEmpty else { return nil }
        var parts: [String] = []
        if count(.failing) > 0 { parts.append(L10n.format("%lld failed", Int64(count(.failing)))) }
        if count(.pending) > 0 { parts.append(L10n.format("%lld in progress", Int64(count(.pending)))) }
        if count(.passing) > 0 { parts.append(L10n.format("%lld passed", Int64(count(.passing)))) }
        if count(.skipped) > 0 { parts.append(L10n.format("%lld skipped", Int64(count(.skipped)))) }
        return parts.joined(separator: ", ")
    }

    /// `mergeStateStatus` in plain words.
    var mergeStateText: String? {
        guard isOpen else { return nil }
        if hasConflicts { return L10n.string("Merge conflicts") }
        switch mergeState {
        case .clean, .hasHooks: return L10n.string("Ready to merge")
        case .blocked: return L10n.string("Waiting for required checks or reviews")
        case .behind: return L10n.string("Behind the base branch")
        case .dirty: return L10n.string("Merge conflicts")
        case .unstable: return L10n.string("Checks that aren't required failed")
        case .draft: return L10n.string("Draft")
        case .unknown: return nil
        }
    }
}

/// The repository's merge settings, which decide the merge menu's choices.
struct PullRequestMergeMethods: Equatable, Sendable {
    var squash: Bool
    var merge: Bool
    var rebase: Bool

    static let all = PullRequestMergeMethods(squash: true, merge: true, rebase: true)

    var allowed: [PullRequestDetail.MergeMethod] {
        [squash ? .squash : nil, merge ? .merge : nil, rebase ? .rebase : nil].compactMap { $0 }
    }

    /// `gh repo view --json squashMergeAllowed,mergeCommitAllowed,rebaseMergeAllowed`.
    static let fields = "squashMergeAllowed,mergeCommitAllowed,rebaseMergeAllowed"

    static func parse(_ data: Data) -> PullRequestMergeMethods? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return PullRequestMergeMethods(squash: object["squashMergeAllowed"] as? Bool ?? false,
                                       merge: object["mergeCommitAllowed"] as? Bool ?? false,
                                       rebase: object["rebaseMergeAllowed"] as? Bool ?? false)
    }
}

/// `gh pr view <url> --json …` read into a `PullRequestDetail`.
enum GitHubPullRequestDetailParser {
    static let fields = [
        "number", "url", "title", "state", "isDraft", "headRefName", "baseRefName", "headRefOid", "mergeable",
        "mergeStateStatus", "reviewDecision", "latestReviews", "autoMergeRequest", "statusCheckRollup"
    ].joined(separator: ",")

    /// Nil when the output is not a pull request.
    static func parse(_ data: Data) -> PullRequestDetail? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let summary = GitHubPullRequestStatus.parse(data, source: .transcriptLink),
              let state = summary.state else { return nil }
        let checks = Self.checks(object["statusCheckRollup"] as? [[String: Any]] ?? [])
        let reviews = (object["latestReviews"] as? [[String: Any]] ?? []).compactMap { review -> PullRequestDetail.Review? in
            guard let decision = (review["state"] as? String).flatMap(PullRequestDetail.Review.Decision.init(rawValue:))
            else { return nil }
            let author = (review["author"] as? [String: Any])?["login"] as? String ?? ""
            return PullRequestDetail.Review(author: author, decision: decision,
                                            submittedAt: date(review["submittedAt"]))
        }
        let autoMerge = ((object["autoMergeRequest"] as? [String: Any])?["mergeMethod"] as? String)
            .flatMap { PullRequestDetail.MergeMethod(rawValue: $0.uppercased()) }
            ?? ((object["autoMergeRequest"] as? [String: Any]) != nil ? .squash : nil)
        return PullRequestDetail(
            number: summary.number, url: summary.url,
            title: (object["title"] as? String) ?? "",
            state: state,
            headBranch: nonEmpty(object["headRefName"]),
            baseBranch: nonEmpty(object["baseRefName"]),
            headSHA: nonEmpty(object["headRefOid"]),
            mergeable: nonEmpty(object["mergeable"])?.uppercased(),
            mergeState: nonEmpty(object["mergeStateStatus"]).flatMap {
                PullRequestDetail.MergeState(rawValue: $0.uppercased())
            } ?? .unknown,
            review: summary.review,
            reviews: reviews,
            autoMerge: autoMerge,
            checks: checks)
    }

    /// Each check once — the latest run of a name in a workflow — failing first, then running,
    /// then passing and skipped, each by name.
    static func checks(_ rollup: [[String: Any]]) -> [PullRequestDetail.Check] {
        var latest: [String: PullRequestDetail.Check] = [:]
        var firstSeen: [String] = []
        for (index, entry) in rollup.enumerated() {
            let isStatus = entry["__typename"] as? String == "StatusContext"
                || (entry["status"] == nil && entry["state"] != nil)
            let name = (isStatus ? entry["context"] : entry["name"]) as? String ?? ""
            let workflow = nonEmpty(entry["workflowName"])
            let value: String
            if isStatus {
                value = (entry["state"] as? String ?? "").uppercased()
            } else {
                let status = (entry["status"] as? String ?? "").uppercased()
                value = status == "COMPLETED" ? (entry["conclusion"] as? String ?? "").uppercased() : status
            }
            let link = ((isStatus ? entry["targetUrl"] : entry["detailsUrl"]) as? String).flatMap(URL.init(string:))
            let key = "\(workflow ?? "")\u{1F}\(name)"
            let check = PullRequestDetail.Check(
                id: "\(key)\u{1F}\(index)", name: name.isEmpty ? (workflow ?? "") : name, workflow: workflow,
                bucket: bucket(value), state: value, link: link,
                startedAt: date(entry["startedAt"]), completedAt: date(entry["completedAt"]))
            if let previous = latest[key] {
                // A re-run reports the same name again; the one that started last stands.
                if (check.startedAt ?? .distantPast) >= (previous.startedAt ?? .distantPast) { latest[key] = check }
            } else {
                latest[key] = check
                firstSeen.append(key)
            }
        }
        let rank: [PullRequestDetail.Check.Bucket: Int] = [.failing: 0, .pending: 1, .passing: 2, .skipped: 3]
        return firstSeen.compactMap { latest[$0] }.sorted { left, right in
            if left.bucket != right.bucket { return rank[left.bucket]! < rank[right.bucket]! }
            return left.name.localizedStandardCompare(right.name) == .orderedAscending
        }
    }

    /// The same buckets as the badge's sum (`GitHubPullRequestStatus.checks`).
    static func bucket(_ value: String) -> PullRequestDetail.Check.Bucket {
        switch value {
        case "SUCCESS": .passing
        case "NEUTRAL", "SKIPPED": .skipped
        case "FAILURE", "ERROR", "CANCELLED", "TIMED_OUT", "ACTION_REQUIRED", "STARTUP_FAILURE": .failing
        default: .pending
        }
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        return text
    }

    private static func date(_ value: Any?) -> Date? {
        guard let text = value as? String, !text.hasPrefix("0001-") else { return nil }
        return ISO8601DateFormatter().date(from: text)
    }
}

/// Why `gh` could not answer, in the words the card shows.
enum PullRequestCLIProblem: Error, Equatable, Sendable {
    /// No `gh` where it is installed.
    case notInstalled
    /// `gh` is signed out (it exits 4 when a command needs a sign-in).
    case signedOut
    case rateLimited
    case timedOut
    /// Anything else `gh` said, first line.
    case failed(String)

    var message: String {
        switch self {
        case .notInstalled: L10n.string("Sign in with gh to see checks and reviews.")
        case .signedOut: L10n.string("Sign in with gh to see checks and reviews.")
        case .rateLimited: L10n.string("GitHub rate limit reached.")
        case .timedOut: L10n.string("GitHub didn't answer in time.")
        case let .failed(text): text
        }
    }

    static func from(_ output: GitHubCLIOutput) -> PullRequestCLIProblem {
        let text = output.errorText.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = text.lowercased()
        if output.status == 4 || lowered.contains("gh auth login") || lowered.contains("not logged in") {
            return .signedOut
        }
        if lowered.contains("rate limit") { return .rateLimited }
        let first = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return .failed(first.isEmpty ? L10n.format("gh exited with status %lld.", Int64(output.status)) : first)
    }

    static func from(_ error: Error) -> PullRequestCLIProblem {
        switch error as? GitHubCLIFailure {
        case .missing?: .notInstalled
        case .timedOut?: .timedOut
        case .couldNotStart?, nil: .failed(L10n.string("gh could not start."))
        }
    }
}

/// A merge, or turning auto-merge on or off, as `gh pr merge` takes it. Built only once the person
/// confirmed it (`PullRequestDetailCenter.confirmMerge`).
struct PullRequestMergeRequest: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// Merge now with the method.
        case merge(PullRequestDetail.MergeMethod)
        /// Merge with the method once the checks and reviews allow (`--auto`).
        case enableAuto(PullRequestDetail.MergeMethod)
        case disableAuto
    }

    let url: URL
    let kind: Kind
    /// The head commit the person saw; GitHub refuses the merge if the branch moved since.
    let headSHA: String?

    var arguments: [String] {
        var arguments = ["pr", "merge", url.absoluteString]
        switch kind {
        case let .merge(method):
            arguments.append(method.flag)
        case let .enableAuto(method):
            arguments += ["--auto", method.flag]
        case .disableAuto:
            return arguments + ["--disable-auto"]
        }
        if let headSHA { arguments += ["--match-head-commit", headSHA] }
        return arguments
    }
}

/// Asks GitHub, through the person's `gh`, for a pull request's full status, the failing steps'
/// log, and — only when the person pressed for it — re-runs failed jobs and merges.
struct GitHubPullRequestDetailClient: Sendable {
    let cli: any GitHubCLIRunning
    var timeout: Duration = .seconds(20)
    /// How much of a failed log the card keeps: the end, at most this many lines and bytes.
    static let logLineLimit = 200
    static let logByteLimit = 64 * 1024

    func detail(of url: URL, in folder: URL) async -> Result<PullRequestDetail, PullRequestCLIProblem> {
        switch await run(["pr", "view", url.absoluteString, "--json", GitHubPullRequestDetailParser.fields], in: folder) {
        case let .success(data):
            guard let detail = GitHubPullRequestDetailParser.parse(data) else {
                return .failure(.failed(L10n.string("gh gave an answer Yardlet can't read.")))
            }
            return .success(detail)
        case let .failure(problem):
            return .failure(problem)
        }
    }

    func mergeMethods(repository: String?, in folder: URL) async -> PullRequestMergeMethods? {
        let selector = repository.map { [$0] } ?? []
        guard case let .success(data) = await run(["repo", "view"] + selector + ["--json", PullRequestMergeMethods.fields],
                                                  in: folder) else { return nil }
        return PullRequestMergeMethods.parse(data)
    }

    /// The failed steps' log of an Actions run, its last lines (`gh run view <id> --log-failed`).
    func failedLog(runID: String, in folder: URL) async -> Result<String, PullRequestCLIProblem> {
        switch await run(["run", "view", runID, "--log-failed"], in: folder) {
        case let .success(data): .success(Self.tail(String(decoding: data, as: UTF8.self)))
        case let .failure(problem): .failure(problem)
        }
    }

    /// `gh run rerun <id> --failed`. Only from the person's press.
    func rerunFailedJobs(runID: String, in folder: URL) async -> Result<Void, PullRequestCLIProblem> {
        await run(["run", "rerun", runID, "--failed"], in: folder).map { _ in () }
    }

    /// `gh pr merge …`. Only once the person confirmed it.
    func merge(_ request: PullRequestMergeRequest, in folder: URL) async -> Result<Void, PullRequestCLIProblem> {
        await run(request.arguments, in: folder).map { _ in () }
    }

    /// The end of a log: at most `logLineLimit` lines and `logByteLimit` bytes, whole lines.
    static func tail(_ text: String, lines lineLimit: Int = logLineLimit, bytes byteLimit: Int = logByteLimit) -> String {
        var lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        while lines.last?.isEmpty == true { lines.removeLast() }
        var kept: [Substring] = []
        var bytes = 0
        for line in lines.reversed() {
            let size = line.utf8.count + 1
            guard kept.count < lineLimit, bytes + size <= byteLimit else { break }
            kept.append(line)
            bytes += size
        }
        return kept.reversed().joined(separator: "\n")
    }

    private func run(_ arguments: [String], in folder: URL) async -> Result<Data, PullRequestCLIProblem> {
        do {
            let output = try await cli.run(arguments, in: folder, timeout: timeout)
            guard output.status == 0 else { return .failure(.from(output)) }
            return .success(output.output)
        } catch {
            return .failure(.from(error))
        }
    }
}

/// The GitHub page of a remote's repository: `https://github.com/o/r` from `https://github.com/o/r.git`,
/// `git@github.com:o/r.git` or `ssh://git@github.com/o/r`.
enum GitHubRemote {
    static func webURL(fromRemote remote: String) -> URL? {
        var text = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasSuffix(".git") { text.removeLast(4) }
        let host: String
        let path: String
        if let scheme = text.range(of: "://") {
            let rest = text[scheme.upperBound...]
            guard let slash = rest.firstIndex(of: "/") else { return nil }
            let authority = rest[..<slash]
            host = String(authority.split(separator: "@").last?.split(separator: ":").first ?? authority)
            path = String(rest[rest.index(after: slash)...])
        } else if let colon = text.firstIndex(of: ":") {
            let authority = text[..<colon]
            host = String(authority.split(separator: "@").last ?? authority)
            path = String(text[text.index(after: colon)...])
        } else {
            return nil
        }
        let parts = path.split(separator: "/")
        guard host.lowercased().contains("github"), parts.count == 2 else { return nil }
        return URL(string: "https://\(host)/\(parts[0])/\(parts[1])")
    }

    /// The branch's page on GitHub.
    static func branchURL(repository: URL, branch: String) -> URL? {
        guard let encoded = branch.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        return URL(string: repository.absoluteString + "/tree/" + encoded)
    }
}
