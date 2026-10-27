#if DEBUG
import Foundation

/// DEBUG-only playback of the showcase's latest turn, for recording (`--ui-fixture=showcase
/// --ui-fixture-playback`): the request is typed into the composer and sent, the commentary
/// streams, the exploring commands run and fold, the file changes and the tests land, the answer
/// streams and the turn completes. It then holds and starts over, about 17 seconds a round; the
/// last frame of a round is the still scene, and each round starts from the same frame, so a
/// recording of one round loops without a seam.
///
/// Every frame is an App Server notification through `CodexTaskReducer`, as a real turn arrives.
/// At the start of each round it posts the distributed notification `loopNotification` with the
/// round's length in seconds (`seconds`), which scripts/showcase/record-window.swift waits for.
@MainActor
final class ShowcasePlayback {
    static let loopNotification = Notification.Name("Yardlet.showcase.loopStarted")
    /// How long one round lasts, from the reset to the next.
    static let roundSeconds = 17.0

    private static var current: ShowcasePlayback?

    private let model: AppModel
    private let sessionID = ShowcaseFixture.darkModeTaskID
    private let workspacePath: String
    private let reducer = CodexTaskReducer()
    private var state = CodexTaskState.empty
    private var sequence: UInt64 = 1_000
    private var roundStart = ContinuousClock.now

    private init(model: AppModel) {
        self.model = model
        workspacePath = ShowcaseFixture.projects(root: ShowcaseFixture.root()).web.path(percentEncoded: false)
    }

    static func start(model: AppModel) {
        guard current == nil else { return }
        let playback = ShowcasePlayback(model: model)
        current = playback
        Task { @MainActor in
            // Let the window lay out and the rail read Git before the first round.
            try? await Task.sleep(for: .seconds(2))
            while true { await playback.playRound() }
        }
    }

    // MARK: A round

    private func playRound() async {
        roundStart = .now
        reset()
        DistributedNotificationCenter.default().postNotificationName(
            Self.loopNotification, object: nil, userInfo: ["seconds": Self.roundSeconds], deliverImmediately: true)

        // The request, typed.
        await wait(until: 0.9)
        let draft = model.composerDrafts.tasks.draft(for: sessionID)
        let request = ShowcaseFixture.latestRequest
        for (index, _) in request.enumerated() where index.isMultiple(of: 2) || index == request.count - 1 {
            draft.text = String(request.prefix(index + 1))
            try? await Task.sleep(for: .milliseconds(36))
        }
        draft.text = request
        await wait(until: 3.4)

        // Sent: the turn starts with it.
        draft.text = ""
        let sent = 3.6
        await wait(until: sent)
        // Its running time counts from 3 seconds, so it ends at the 14 the still shows.
        notify("turn/started", ["turn": .object([
            "id": .string(ShowcaseFixture.latestTurnID), "status": .string("inProgress"),
            "startedAt": .integer(Int64(Date().addingTimeInterval(-3).timeIntervalSince1970)), "items": .array([])
        ])])
        complete(ShowcaseFixture.userMessage("user-dark-mode", request))
        notify("turn/plan/updated", ["plan": ShowcaseFixture.plan(done: 0)])
        await setStatus(.running)

        let items = ShowcaseFixture.latestTurnItems(workspacePath: workspacePath)
        func item(_ id: String) -> JSONValue { items.first { $0["id"]?.stringValue == id }! }

        await stream(item("note-dark-mode-1"), from: sent + 0.5, over: 0.9)
        await run(item("cmd-dark-mode-1"), from: sent + 1.6, for: 0.35)
        await run(item("cmd-dark-mode-2"), from: sent + 2.1, for: 0.25)
        await run(item("cmd-dark-mode-3"), from: sent + 2.5, for: 0.25)
        notify("turn/plan/updated", ["plan": ShowcaseFixture.plan(done: 1)])
        await stream(item("note-dark-mode-2"), from: sent + 3.0, over: 1.3)

        // The patch is written, then lands.
        await wait(until: sent + 4.5)
        started(ShowcaseFixture.fileChange("patch-dark-mode", workspacePath: workspacePath, status: "inProgress"))
        notify("turn/plan/updated", ["plan": ShowcaseFixture.plan(done: 2)])
        await wait(until: sent + 5.4)
        complete(item("patch-dark-mode"))
        notify("turn/diff/updated", ["diff": .string(ShowcaseFixture.latestTurnDiff)])
        notify("turn/plan/updated", ["plan": ShowcaseFixture.plan(done: 3)])

        // The tests print as they run.
        await wait(until: sent + 5.7)
        let tests = item("cmd-dark-mode-4")
        started(running(tests))
        for line in ShowcaseFixture.testOutput.split(separator: "\n", omittingEmptySubsequences: false) {
            notify("item/commandExecution/outputDelta", ["itemId": .string("cmd-dark-mode-4"), "delta": .string(line + "\n")])
            try? await Task.sleep(for: .milliseconds(90))
        }
        complete(tests)
        await run(item("cmd-dark-mode-5"), from: sent + 7.3, for: 0.45)
        notify("turn/plan/updated", ["plan": ShowcaseFixture.plan(done: 4)])

        await stream(item("answer-dark-mode"), from: sent + 8.0, over: 2.6)
        await wait(until: sent + 10.8)
        notify("turn/completed", ["turn": .object([
            "id": .string(ShowcaseFixture.latestTurnID), "status": .string("completed"),
            "durationMs": .integer(Int64(ShowcaseFixture.latestTurnDurationMs))
        ])])
        await setStatus(.completed)

        await wait(until: Self.roundSeconds)
    }

    /// The thread before the latest turn, an empty composer, and a finished task.
    private func reset() {
        state = ShowcaseFixture.darkModeState(workspacePath: workspacePath, includesLatestTurn: false)
        sequence = 1_000
        model.composerDrafts.tasks.draft(for: sessionID).text = ""
        model.showVisualFixtureCodexState(state, for: sessionID)
        Task { await setStatus(.completed) }
    }

    // MARK: Frames

    private func wait(until seconds: Double) async {
        let deadline = roundStart + .milliseconds(Int(seconds * 1_000))
        if deadline > .now { try? await Task.sleep(until: deadline, clock: .continuous) }
    }

    private func notify(_ method: String, _ params: [String: JSONValue]) {
        sequence += 1
        var params = params
        params["threadId"] = .string(ShowcaseFixture.codexThreadID)
        if params["turnId"] == nil, !method.hasPrefix("turn/started"), !method.hasPrefix("turn/completed") {
            params["turnId"] = .string(ShowcaseFixture.latestTurnID)
        }
        _ = reducer.applyNotification(method: method, params: .object(params), sequence: sequence, to: &state)
        model.showVisualFixtureCodexState(state, for: sessionID)
    }

    private func started(_ item: JSONValue) { notify("item/started", ["item": item]) }
    private func complete(_ item: JSONValue) { notify("item/completed", ["item": item]) }

    private func running(_ item: JSONValue) -> JSONValue {
        guard case var .object(fields) = item else { return item }
        fields["status"] = .string("inProgress")
        fields["aggregatedOutput"] = .null
        fields["exitCode"] = nil
        fields["durationMs"] = nil
        return .object(fields)
    }

    /// A command that starts at `start` and finishes `duration` later.
    private func run(_ item: JSONValue, from start: Double, for duration: Double) async {
        await wait(until: start)
        started(running(item))
        await wait(until: start + duration)
        complete(item)
    }

    /// A message that starts empty at `start` and arrives word by word over `duration`.
    private func stream(_ item: JSONValue, from start: Double, over duration: Double) async {
        guard let id = item["id"]?.stringValue, let text = item["text"]?.stringValue,
              case var .object(empty) = item else { return }
        await wait(until: start)
        empty["text"] = .string("")
        started(.object(empty))
        var pieces: [String] = []
        var piece = ""
        for character in text {
            piece.append(character)
            if character == " " || character == "\n" { pieces.append(piece); piece = "" }
        }
        if !piece.isEmpty { pieces.append(piece) }
        let chunk = max(1, pieces.count / max(1, Int(duration / 0.05)))
        for index in stride(from: 0, to: pieces.count, by: chunk) {
            notify("item/agentMessage/delta", ["itemId": .string(id),
                                               "delta": .string(pieces[index..<min(index + chunk, pieces.count)].joined())])
            await wait(until: start + duration * Double(index + chunk) / Double(pieces.count))
        }
        complete(item)
    }

    private func setStatus(_ status: SessionStatus) async {
        try? await model.store.updateSession(id: sessionID, status: status,
                                             completionState: status == .completed ? .completed : SessionCompletionState.none,
                                             updatesRecency: false)
    }
}
#endif
