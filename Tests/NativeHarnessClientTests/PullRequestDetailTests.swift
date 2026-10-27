import Foundation
import XCTest
@testable import NativeHarnessClient

/// The rail's pull request: `gh pr view --json` read into each
/// check, the merge state and reviews; the commands Yardlet would run; that no write runs without the
/// person, a merge not without their confirmation; and auto-fix, which sends nothing unless the
/// person turned it on for that task. All through a fake `gh`; nothing starts a process.
@MainActor
final class PullRequestDetailTests: XCTestCase {
    nonisolated static let url = URL(string: "https://github.com/example-org/yardlet/pull/341")!
    static let folder = URL(filePath: "/tmp/pr-detail-qa", directoryHint: .isDirectory)

    /// The shape `gh pr view <url> --json …` gives (gh 2.86, checked read-only against a real pull
    /// request): a failed job, a re-run of it cancelled earlier, one still running, a pass, a skip and a
    /// commit status.
    nonisolated static func viewJSON(head: String = "265cce6ecf84184ae968aa03ac34727f26b48773", state: String = "OPEN",
                         mergeState: String = "BLOCKED", mergeable: String = "MERGEABLE", lintStatus: String = "IN_PROGRESS",
                         lintConclusion: String = "", autoMerge: String = "null", testConclusion: String = "FAILURE") -> String {
        """
        {"autoMergeRequest":\(autoMerge),"baseRefName":"main","headRefName":"feat/session-rail","headRefOid":"\(head)",
         "isDraft":false,"latestReviews":[{"author":{"login":"reviewer"},"authorAssociation":"MEMBER","body":"",
         "submittedAt":"2026-10-16T08:10:00Z","includesCreatedEdit":false,"reactionGroups":[],"state":"CHANGES_REQUESTED",
         "commit":{"oid":"\(head)"}},{"author":{"login":"bot"},"state":"COMMENTED","submittedAt":"2026-10-16T08:11:00Z"}],
         "mergeStateStatus":"\(mergeState)","mergeable":"\(mergeable)","number":341,"reviewDecision":"CHANGES_REQUESTED",
         "state":"\(state)","title":"Add the session rail","url":"\(url.absoluteString)",
         "statusCheckRollup":[
          {"__typename":"CheckRun","completedAt":"2026-10-16T07:55:00Z","conclusion":"CANCELLED",
           "detailsUrl":"https://github.com/example-org/yardlet/actions/runs/38870360000/job/1","name":"test",
           "startedAt":"2026-10-16T07:50:00Z","status":"COMPLETED","workflowName":"CI"},
          {"__typename":"CheckRun","completedAt":"2026-10-16T08:04:59Z","conclusion":"\(testConclusion)",
           "detailsUrl":"https://github.com/example-org/yardlet/actions/runs/38870363420/job/116872751090","name":"test",
           "startedAt":"2026-10-16T07:56:14Z","status":"COMPLETED","workflowName":"CI"},
          {"__typename":"CheckRun","completedAt":"0001-01-01T00:00:00Z","conclusion":"\(lintConclusion)",
           "detailsUrl":"https://github.com/example-org/yardlet/actions/runs/38870363421/job/116872751091","name":"lint",
           "startedAt":"2026-10-16T07:56:14Z","status":"\(lintStatus)","workflowName":"CI"},
          {"__typename":"CheckRun","completedAt":"2026-10-16T08:00:00Z","conclusion":"SUCCESS",
           "detailsUrl":"https://github.com/example-org/yardlet/actions/runs/38870363420/job/116872751092","name":"build",
           "startedAt":"2026-10-16T07:56:14Z","status":"COMPLETED","workflowName":"CI"},
          {"__typename":"CheckRun","completedAt":"2026-10-16T07:56:20Z","conclusion":"SKIPPED",
           "detailsUrl":"https://github.com/example-org/yardlet/actions/runs/38870363422/job/3","name":"deploy-preview",
           "startedAt":"2026-10-16T07:56:20Z","status":"COMPLETED","workflowName":"Preview"},
          {"__typename":"StatusContext","context":"vercel","state":"SUCCESS","targetUrl":"https://vercel.com/o/r/1",
           "startedAt":"2026-10-16T07:57:00Z"}
         ]}
        """
    }

    nonisolated static func output(_ text: String, status: Int32 = 0, error: String = "") -> GitHubCLIOutput {
        GitHubCLIOutput(status: status, output: Data(text.utf8), errorText: error)
    }

    // MARK: - Parsing

    func testViewOutputReadsChecksFailingFirstReviewsAndTheMergeState() throws {
        let detail = try XCTUnwrap(GitHubPullRequestDetailParser.parse(Data(Self.viewJSON().utf8)))
        XCTAssertEqual(detail.number, 341)
        XCTAssertEqual(detail.title, "Add the session rail")
        XCTAssertEqual(detail.state, .open)
        XCTAssertEqual(detail.headBranch, "feat/session-rail")
        XCTAssertEqual(detail.baseBranch, "main")
        XCTAssertEqual(detail.headSHA, "265cce6ecf84184ae968aa03ac34727f26b48773")
        XCTAssertEqual(detail.checks.map(\.name), ["test", "lint", "build", "vercel", "deploy-preview"])
        XCTAssertEqual(detail.checks.map(\.bucket), [.failing, .pending, .passing, .passing, .skipped])
        // The re-run that started last stands for "test".
        XCTAssertEqual(detail.checks[0].state, "FAILURE")
        XCTAssertEqual(detail.checks[0].runID, "38870363420")
        XCTAssertEqual(detail.checks[0].duration ?? 0, 525, accuracy: 0.5)
        XCTAssertNil(detail.checks[1].completedAt, "the zero date is no date")
        XCTAssertNil(detail.checks[3].runID, "a commit status has no Actions run")
        XCTAssertEqual(detail.checksState, .failing)
        XCTAssertEqual(detail.checksSummaryText, [L10n.format("%lld failed", 1), L10n.format("%lld in progress", 1),
                                                  L10n.format("%lld passed", 2), L10n.format("%lld skipped", 1)]
            .joined(separator: ", "))
        XCTAssertEqual(detail.mergeState, .blocked)
        XCTAssertEqual(detail.mergeStateText, L10n.string("Waiting for required checks or reviews"))
        XCTAssertEqual(detail.review, .changesRequested)
        XCTAssertEqual(detail.reviews.map(\.author), ["reviewer", "bot"])
        XCTAssertEqual(detail.reviews.map(\.decision), [.changesRequested, .commented])
        XCTAssertNil(detail.autoMerge)
        // The badge and sidebar row read the same sum.
        XCTAssertEqual(detail.summary.checks, .failing)
        XCTAssertEqual(detail.summary.review, .changesRequested)
    }

    func testConflictsAutoMergeAndAMergedPullRequestReadAsTheyAre() throws {
        let conflicted = try XCTUnwrap(GitHubPullRequestDetailParser.parse(Data(Self.viewJSON(
            mergeState: "DIRTY", mergeable: "CONFLICTING",
            autoMerge: #"{"mergeMethod":"SQUASH","enabledAt":"2026-10-16T08:00:00Z"}"#).utf8)))
        XCTAssertTrue(conflicted.hasConflicts)
        XCTAssertEqual(conflicted.mergeStateText, L10n.string("Merge conflicts"))
        XCTAssertEqual(conflicted.autoMerge, .squash)
        let clean = try XCTUnwrap(GitHubPullRequestDetailParser.parse(Data(Self.viewJSON(mergeState: "CLEAN").utf8)))
        XCTAssertEqual(clean.mergeStateText, L10n.string("Ready to merge"))
        XCTAssertEqual(try XCTUnwrap(GitHubPullRequestDetailParser.parse(Data(Self.viewJSON(mergeState: "BEHIND").utf8)))
            .mergeStateText, L10n.string("Behind the base branch"))
        let merged = try XCTUnwrap(GitHubPullRequestDetailParser.parse(Data(Self.viewJSON(state: "MERGED").utf8)))
        XCTAssertFalse(merged.isOpen)
        XCTAssertNil(merged.mergeStateText)
        XCTAssertNil(GitHubPullRequestDetailParser.parse(Data("[]".utf8)))
        XCTAssertEqual(L10n.string("Ready to merge", languageCode: "ko"), "병합 준비 완료")
    }

    func testMergeMethodsCommandsAndLogTails() throws {
        let methods = try XCTUnwrap(PullRequestMergeMethods.parse(Data(
            #"{"mergeCommitAllowed":false,"rebaseMergeAllowed":true,"squashMergeAllowed":true}"#.utf8)))
        XCTAssertEqual(methods.allowed, [.squash, .rebase])

        let head = "abc123"
        XCTAssertEqual(PullRequestMergeRequest(url: Self.url, kind: .merge(.squash), headSHA: head).arguments,
                       ["pr", "merge", Self.url.absoluteString, "--squash", "--match-head-commit", head])
        XCTAssertEqual(PullRequestMergeRequest(url: Self.url, kind: .enableAuto(.rebase), headSHA: head).arguments,
                       ["pr", "merge", Self.url.absoluteString, "--auto", "--rebase", "--match-head-commit", head])
        XCTAssertEqual(PullRequestMergeRequest(url: Self.url, kind: .disableAuto, headSHA: head).arguments,
                       ["pr", "merge", Self.url.absoluteString, "--disable-auto"])

        let log = (1...500).map { "line \($0)" }.joined(separator: "\n") + "\n\n"
        let tail = GitHubPullRequestDetailClient.tail(log)
        XCTAssertEqual(tail.split(separator: "\n").count, 200)
        XCTAssertTrue(tail.hasPrefix("line 301"))
        XCTAssertTrue(tail.hasSuffix("line 500"))
        let wide = String(repeating: "x", count: 1_000)
        XCTAssertEqual(GitHubPullRequestDetailClient.tail(Array(repeating: wide, count: 100).joined(separator: "\n"),
                                                          bytes: 4_000).split(separator: "\n").count, 3)
        XCTAssertEqual(PullRequestDetail.Check.runID(in: URL(string: "https://github.com/o/r/actions/runs/123/job/4")!), "123")
        XCTAssertNil(PullRequestDetail.Check.runID(in: URL(string: "https://github.com/o/r/runs/123")!))
    }

    func testGhProblemsReadAsTheCardSaysThem() async {
        func answer(_ output: GitHubCLIOutput) async -> PullRequestCLIProblem? {
            let client = GitHubPullRequestDetailClient(cli: FakeGitHubCLI { _, _ in output })
            if case let .failure(problem) = await client.detail(of: Self.url, in: Self.folder) { return problem }
            return nil
        }
        let signedOut = await answer(Self.output("", status: 4, error: "To get started with GitHub CLI, please run:  gh auth login"))
        XCTAssertEqual(signedOut, .signedOut)
        let limited = await answer(Self.output("", status: 1, error: "API rate limit exceeded for user"))
        XCTAssertEqual(limited, .rateLimited)
        let other = await answer(Self.output("", status: 1, error: "no pull requests found\nmore"))
        XCTAssertEqual(other, .failed("no pull requests found"))
        let missing = await GitHubPullRequestDetailClient(cli: LocalGitHubCLI(executableURL: nil)).detail(of: Self.url, in: Self.folder)
        XCTAssertEqual(missing, .failure(.notInstalled))
        XCTAssertEqual(PullRequestCLIProblem.signedOut.message,
                       L10n.string("Sign in with gh to see checks and reviews."))
        XCTAssertEqual(L10n.string("Sign in with gh to see checks and reviews.", languageCode: "ko"),
                       "gh로 로그인하면 검사와 리뷰가 보입니다.")
    }

    // MARK: - The center

    private func center(_ answers: AnswerBox, cli: inout FakeGitHubCLI?) -> PullRequestDetailCenter {
        let fake = FakeGitHubCLI { arguments, _ in
            if arguments.starts(with: ["repo", "view"]) {
                return Self.output(#"{"mergeCommitAllowed":true,"rebaseMergeAllowed":true,"squashMergeAllowed":true}"#)
            }
            if arguments.starts(with: ["pr", "view"]) { return answers.value }
            return Self.output("")
        }
        cli = fake
        let center = PullRequestDetailCenter()
        // No loop: the tests drive every look.
        center.start(GitHubPullRequestDetailClient(cli: fake), looking: false)
        return center
    }

    func testWritesRunOnlyFromThePersonAndAMergeOnlyOnceConfirmed() async throws {
        let answers = AnswerBox(Self.output(Self.viewJSON(mergeState: "CLEAN")))
        var fake: FakeGitHubCLI?
        let center = center(answers, cli: &fake)
        let task = UUID()
        center.setState(.init(url: Self.url, folder: Self.folder), for: task)
        await center.refresh(task)
        let detail = try XCTUnwrap(center.state(for: task)?.detail)
        let reads = await fake!.calls.map(\.arguments)
        XCTAssertTrue(reads.allSatisfy { $0.starts(with: ["pr", "view"]) || $0.starts(with: ["repo", "view"]) }, "\(reads)")
        XCTAssertEqual(reads.first, ["pr", "view", Self.url.absoluteString, "--json", GitHubPullRequestDetailParser.fields])

        // Asking for a merge only asks the person.
        center.requestMerge(taskID: task, .merge(.squash))
        XCTAssertEqual(center.state(for: task)?.pendingMerge, .merge(.squash))
        let afterRequest = await fake!.calls.map(\.arguments)
        XCTAssertFalse(afterRequest.contains { $0.starts(with: ["pr", "merge"]) })
        // Cancelled, nothing ran.
        center.cancelMerge(taskID: task)
        await center.confirmMerge(taskID: task)
        let afterCancel = await fake!.calls.map(\.arguments)
        XCTAssertFalse(afterCancel.contains { $0.starts(with: ["pr", "merge"]) })
        // Confirmed, the merge names the head commit the person saw.
        center.requestMerge(taskID: task, .merge(.squash))
        await center.confirmMerge(taskID: task)
        let merges = await fake!.calls.map(\.arguments).filter { $0.starts(with: ["pr", "merge"]) }
        XCTAssertEqual(merges, [["pr", "merge", Self.url.absoluteString, "--squash", "--match-head-commit", detail.headSHA!]])

        // Re-running failed jobs runs each failed run once, then reads again.
        await center.rerunFailed(taskID: task, checks: detail.failedChecks)
        let reruns = await fake!.calls.map(\.arguments).filter { $0.starts(with: ["run", "rerun"]) }
        XCTAssertEqual(reruns, [["run", "rerun", "38870363420", "--failed"]])
    }

    func testAFailedLogOpensAndCloses() async throws {
        let answers = AnswerBox(Self.output(Self.viewJSON()))
        let fake = FakeGitHubCLI { arguments, _ in
            if arguments.starts(with: ["run", "view"]) { return Self.output("Run tests\nerror: expected 2, got 3\n") }
            if arguments.starts(with: ["repo", "view"]) { return Self.output("{}") }
            return answers.value
        }
        let center = PullRequestDetailCenter()
        center.start(GitHubPullRequestDetailClient(cli: fake), looking: false)
        let task = UUID()
        center.setState(.init(url: Self.url, folder: Self.folder), for: task)
        await center.refresh(task)
        let check = try XCTUnwrap(center.state(for: task)?.detail?.failedChecks.first)
        await center.loadLog(taskID: task, check: check)
        XCTAssertEqual(center.state(for: task)?.logs[check.id], .loaded("Run tests\nerror: expected 2, got 3"))
        let calls = await fake.calls.map(\.arguments)
        XCTAssertTrue(calls.contains(["run", "view", "38870363420", "--log-failed"]))
        // "Fix CI" carries the excerpt into the composer's draft.
        let draft = PullRequestAutoFixPolicy.draft(for: try XCTUnwrap(center.state(for: task)?.detail),
                                                   logs: [check.id: "error: expected 2, got 3"])
        XCTAssertTrue(draft.hasPrefix("Fix the failing CI checks on feat/session-rail (pull request #341): test."))
        XCTAssertTrue(draft.contains("```\nerror: expected 2, got 3\n```"))
        center.closeLog(taskID: task, check: check)
        XCTAssertNil(center.state(for: task)?.logs[check.id])
    }

    // MARK: - Auto-fix

    func testAutoFixDecidesNothingUnlessThePersonTurnedItOn() throws {
        let failing = try XCTUnwrap(GitHubPullRequestDetailParser.parse(Data(Self.viewJSON(lintStatus: "COMPLETED",
                                                                                          lintConclusion: "SUCCESS").utf8)))
        let running = try XCTUnwrap(GitHubPullRequestDetailParser.parse(Data(Self.viewJSON().utf8)))
        let passing = try XCTUnwrap(GitHubPullRequestDetailParser.parse(Data(Self.viewJSON(
            lintStatus: "COMPLETED", lintConclusion: "SUCCESS", testConclusion: "SUCCESS").utf8)))
        var on = PullRequestAutoFixRecord()
        on.choice = .on
        var off = PullRequestAutoFixRecord()
        off.choice = .off

        XCTAssertEqual(PullRequestAutoFixPolicy.decide(record: nil, detail: failing, taskIsIdle: true), .none)
        XCTAssertEqual(PullRequestAutoFixPolicy.decide(record: PullRequestAutoFixRecord(), detail: failing, taskIsIdle: true),
                       .none, "asked but not answered is off")
        XCTAssertEqual(PullRequestAutoFixPolicy.decide(record: off, detail: failing, taskIsIdle: true), .none)
        XCTAssertEqual(PullRequestAutoFixPolicy.decide(record: on, detail: passing, taskIsIdle: true), .none)
        XCTAssertEqual(PullRequestAutoFixPolicy.decide(record: on, detail: running, taskIsIdle: true), .none,
                       "a failure waits until no check is still running")
        guard case let .send(key, message) = PullRequestAutoFixPolicy.decide(record: on, detail: failing, taskIsIdle: true)
        else { return XCTFail("auto-fix on and a finished failure send") }
        XCTAssertEqual(key, "265cce6ecf84184ae968aa03ac34727f26b48773|CI/test")
        XCTAssertEqual(message, """
            Fix the failing CI checks on feat/session-rail (pull request #341): test.
            Read the failed logs with `gh run view 38870363420 --log-failed`, fix the cause, and push the fix to this branch.
            """)
        XCTAssertEqual(PullRequestAutoFixPolicy.decide(record: on, detail: failing, taskIsIdle: false), .wait(eventKey: key))
        // Once sent, the same failure never sends again; a new push's failure does.
        on.recordSent(key, at: Date())
        XCTAssertEqual(PullRequestAutoFixPolicy.decide(record: on, detail: failing, taskIsIdle: true), .none)
        let pushed = try XCTUnwrap(GitHubPullRequestDetailParser.parse(Data(Self.viewJSON(
            head: "f00d", lintStatus: "COMPLETED", lintConclusion: "SUCCESS").utf8)))
        guard case .send = PullRequestAutoFixPolicy.decide(record: on, detail: pushed, taskIsIdle: true) else {
            return XCTFail("a new head commit's failure is a new failure")
        }
        // Merged: nothing more.
        let merged = try XCTUnwrap(GitHubPullRequestDetailParser.parse(Data(Self.viewJSON(
            state: "MERGED", lintStatus: "COMPLETED", lintConclusion: "SUCCESS").utf8)))
        XCTAssertEqual(PullRequestAutoFixPolicy.decide(record: on, detail: merged, taskIsIdle: true), .none)
    }

    /// The question shows once per task while the setting asks (the default), and never with "Don't ask".
    func testTheQuestionShowsUntilTheTaskIsAnswered() throws {
        let open = try XCTUnwrap(GitHubPullRequestDetailParser.parse(Data(Self.viewJSON().utf8)))
        XCTAssertEqual(PullRequestAutoFixPrompt.current(in: UserDefaults(suiteName: testDefaultsSuite("PullRequestDetailTests"))!), .ask)
        XCTAssertTrue(PullRequestAutoFixPolicy.asks(record: nil, prompt: .ask, detail: open))
        XCTAssertFalse(PullRequestAutoFixPolicy.asks(record: nil, prompt: .never, detail: open))
        var answered = PullRequestAutoFixRecord()
        answered.choice = .off
        XCTAssertFalse(PullRequestAutoFixPolicy.asks(record: answered, prompt: .ask, detail: open))
        XCTAssertFalse(PullRequestAutoFixPolicy.asks(record: nil, prompt: .ask, detail: nil))
        XCTAssertEqual(L10n.string("autoFix.prompt.ask", languageCode: "ko"), "묻기")
        XCTAssertEqual(L10n.string("autoFix.prompt.never", languageCode: "ko"), "묻지 않음")
        XCTAssertEqual(L10n.string("Fix CI", languageCode: "ko"), "CI 고치기")
    }

    func testTheCenterSendsOneTurnPerNewFailureOnlyForATaskWithAutoFixOn() async throws {
        let answers = AnswerBox(Self.output(Self.viewJSON(lintStatus: "COMPLETED", lintConclusion: "SUCCESS")))
        var fake: FakeGitHubCLI?
        let center = center(answers, cli: &fake)
        var sent: [(UUID, String)] = []
        var idle = true
        center.isTaskIdle = { _ in idle }
        center.deliver = { id, message in
            sent.append((id, message))
            return true
        }
        let task = UUID()
        center.setState(.init(url: Self.url, folder: Self.folder), for: task)
        await center.refresh(task)
        XCTAssertTrue(sent.isEmpty, "a failure with auto-fix never chosen sends nothing")
        center.setAutoFix(false, taskID: task)
        await center.refresh(task)
        XCTAssertTrue(sent.isEmpty, "auto-fix off sends nothing")

        // On while the task works: it waits for the turn.
        idle = false
        center.setAutoFix(true, taskID: task)
        await center.evaluateAutoFix(task)
        XCTAssertTrue(sent.isEmpty)
        idle = true
        await center.evaluateAutoFix(task)
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.0, task)
        // Asked again with the same failure: nothing more.
        await center.refresh(task)
        await center.evaluateAutoFix(task)
        XCTAssertEqual(sent.count, 1)
        XCTAssertNotNil(center.autoFix.record(for: task)?.lastSentAt)
        // A new push fails: one more.
        answers.value = Self.output(Self.viewJSON(head: "f00d", lintStatus: "COMPLETED", lintConclusion: "SUCCESS"))
        await center.refresh(task)
        XCTAssertEqual(sent.count, 2)
        // Turned off: the next failure sends nothing.
        center.setAutoFix(false, taskID: task)
        answers.value = Self.output(Self.viewJSON(head: "beef", lintStatus: "COMPLETED", lintConclusion: "SUCCESS"))
        await center.refresh(task)
        XCTAssertEqual(sent.count, 2)
        // A delivery that did not go is tried again next time.
        center.setAutoFix(true, taskID: task)
        center.deliver = { _, _ in false }
        await center.evaluateAutoFix(task)
        XCTAssertFalse(center.autoFix.record(for: task)?.sentEvents.contains { $0.hasPrefix("beef|") } ?? true)
        // Nothing the center did was a write.
        let calls = await fake!.calls.map(\.arguments)
        XCTAssertFalse(calls.contains { $0.starts(with: ["pr", "merge"]) || $0.starts(with: ["run", "rerun"]) })
    }

    /// An auto-fix task off screen is looked at from its record: its pull request and folder.
    func testAnAutoFixTaskOffScreenIsLookedAtFromItsRecord() async throws {
        let answers = AnswerBox(Self.output(Self.viewJSON(lintStatus: "COMPLETED", lintConclusion: "SUCCESS")))
        var fake: FakeGitHubCLI?
        let center = center(answers, cli: &fake)
        var sent = 0
        center.isTaskIdle = { _ in true }
        center.deliver = { _, _ in
            sent += 1
            return true
        }
        let task = UUID()
        center.setState(.init(url: Self.url, folder: Self.folder), for: task)
        center.setAutoFix(true, taskID: task)
        center.setState(nil, for: task)
        XCTAssertTrue(center.isDue(task))
        await center.tick()
        XCTAssertEqual(sent, 1)
        let first = await fake!.calls.first?.directory
        XCTAssertEqual(first?.path(percentEncoded: false), Self.folder.path(percentEncoded: false))
        XCTAssertFalse(center.isDue(task), "asked just now")
        center.forget(task)
        XCTAssertNil(center.autoFix.record(for: task))
    }

    func testAutoFixRecordsAreKeptInYardletsDefaults() throws {
        let suite = testDefaultsSuite("PullRequestDetailTests")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let store = PullRequestAutoFixStore(defaults: defaults)
        let task = UUID()
        store.setChoice(.on, for: task, pullRequestURL: Self.url, folder: Self.folder)
        store.recordSent("a|b", at: Date(timeIntervalSince1970: 5), for: task)
        let reopened = PullRequestAutoFixStore(defaults: defaults)
        XCTAssertEqual(reopened.record(for: task)?.choice, .on)
        XCTAssertEqual(reopened.record(for: task)?.pullRequestURL, Self.url)
        XCTAssertEqual(reopened.record(for: task)?.sentEvents, ["a|b"])
        XCTAssertEqual(reopened.enabledTaskIDs, [task])
        reopened.forget(task)
        XCTAssertNil(defaults.data(forKey: PullRequestAutoFixStore.defaultsKey))
        var record = PullRequestAutoFixRecord()
        for index in 0..<30 { record.recordSent("e\(index)", at: Date()) }
        XCTAssertEqual(record.sentEvents.count, PullRequestAutoFixRecord.sentEventLimit)
        XCTAssertEqual(record.sentEvents.last, "e29")
    }

    /// `YARDLET_LIVE_GH_PR="<folder>|<pull request URL>"` reads one real pull request with the
    /// person's own `gh`, read only. Skipped otherwise.
    func testLiveReadOfOnePullRequest() async throws {
        guard let value = ProcessInfo.processInfo.environment["YARDLET_LIVE_GH_PR"] else {
            throw XCTSkip("Set YARDLET_LIVE_GH_PR to read one pull request with gh.")
        }
        let parts = value.split(separator: "|").map(String.init)
        let folder = URL(filePath: parts[0], directoryHint: .isDirectory)
        let url = try XCTUnwrap(URL(string: parts[1]))
        let client = GitHubPullRequestDetailClient(cli: LocalGitHubCLI())
        let detail = try (await client.detail(of: url, in: folder)).get()
        XCTAssertGreaterThan(detail.number, 0)
        XCTAssertFalse(detail.title.isEmpty)
        let methods = await client.mergeMethods(repository: TaskPullRequest.repository(in: url), in: folder)
        XCTAssertNotNil(methods)
    }
}
