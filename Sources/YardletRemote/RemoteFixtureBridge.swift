import Foundation

/// Fixture projects, tasks and conversations behind the remote protocol, for building the phone
/// client without a Mac running real tasks (`yardlet-remote-fixture`, docs/REMOTE_PROTOCOL.md §9).
/// Its tasks act out what real ones do: an approval that runs a command and streams an answer once
/// allowed, an answer streaming word by word that `stopTurn` interrupts, a long finished history
/// whose earliest turns the "provider" hands over only when asked, a question only the Mac answers,
/// a reply to any message sent to an idle task, and a message sent to a running task queued until
/// its turn ends. For v2 phones (§15) the question and a plan review are answerable, lines open into
/// output and diffs, a suggested task can be started, and tasks can be pinned, archived and started.
/// Nothing is read from or written to the Mac.
public actor RemoteFixtureBridge: RemoteBridge {
    public enum ID {
        public static let approval = "0F1E0001-0000-4000-8000-000000000001"
        public static let streaming = "0F1E0002-0000-4000-8000-000000000002"
        public static let history = "0F1E0003-0000-4000-8000-000000000003"
        public static let idle = "0F1E0004-0000-4000-8000-000000000004"
        public static let question = "0F1E0005-0000-4000-8000-000000000005"
        public static let chat = "0F1E0006-0000-4000-8000-000000000006"
        public static let child = "0F1E0007-0000-4000-8000-000000000007"
        public static let failed = "0F1E0008-0000-4000-8000-000000000008"
        public static let plan = "0F1E0009-0000-4000-8000-000000000009"
        static let yardlet = "0F1E00A1-0000-4000-8000-0000000000A1"
        static let website = "0F1E00A2-0000-4000-8000-0000000000A2"
    }

    private struct Entry {
        var task: RemoteTask
        var turns: [RemoteTurn]
        /// Turns the "provider" still holds before `turns`, handed over by `loadEarlierConversation`.
        var held: [RemoteTurn] = []
        var pendingRequest: (id: String, kind: RemotePendingRequest)?
        /// Messages sent while the turn ran, taken when it ends.
        var queue: [RemoteItem] = []
    }

    private var order: [String] = []
    private var tasks: [String: Entry] = [:]
    private let projects: [RemoteProject]
    private var handler: (@Sendable (RemoteBridgeChange) -> Void)?
    private var scripts: [String: Task<Void, Never>] = [:]
    /// What starts again later: a new request, the next release build.
    private var timers: [String: Task<Void, Never>] = [:]
    private var counter = 0
    /// How much faster than real time the scripts run (tests run them fast).
    private let speed: Double

    public init(speed: Double = 1) {
        self.speed = max(0.01, speed)
        projects = [
            RemoteProject(id: ID.yardlet, name: "Yardlet", kind: .project, canCreateTask: true),
            RemoteProject(id: ID.website, name: "Website", kind: .project, canCreateTask: true),
            RemoteProject(id: "chats", name: "Chats", kind: .chats, canCreateTask: true)
        ]
        let now = Date()
        func at(_ minutesAgo: Double) -> Int64 { RemoteJSON.milliseconds(now.addingTimeInterval(-minutesAgo * 60)) }
        var historyTurns = (1...30).map { Self.historyTurn($0, now: now) }
        let held = Array(historyTurns.prefix(10))
        historyTurns.removeFirst(10)
        var entries = [
            Entry(task: Self.task(ID.approval, "Approve the index migration", .claude, ID.yardlet, at(1)),
                  turns: Self.approvalTurns(now: now), pendingRequest: ("toolu_fixture_1", .approval)),
            Entry(task: Self.task(ID.streaming, "Build the release bundle", .codex, ID.yardlet, at(2)), turns: []),
            Entry(task: Self.task(ID.history, "Summarize the crash reports", .codex, ID.website, at(6), unread: true),
                  turns: historyTurns, held: held),
            Entry(task: Self.task(ID.idle, "Fix the footer links", .claude, ID.website, at(12)),
                  turns: [Self.finishedTurn("footer-1", prompt: "Find the footer links that 404", answer: Self.footerAnswer,
                                            now: now, suggestion: true)]),
            Entry(task: Self.task(ID.plan, "Plan the cache rewrite", .claude, ID.yardlet, at(4)),
                  turns: Self.planReviewTurns(now: now), pendingRequest: ("toolu_fixture_plan", .approval)),
            Entry(task: Self.task(ID.question, "Pick the release name", .claude, ID.yardlet, at(3)),
                  turns: Self.questionTurns(now: now), pendingRequest: ("toolu_fixture_question", .input)),
            Entry(task: Self.task(ID.chat, "Plan the weekend trip", .claude, "chats", at(30)), turns: [Self.planTurn(now: now)]),
            Entry(task: Self.task(ID.child, "Check the footer on mobile", .claude, ID.website, at(14), parent: ID.idle),
                  turns: [Self.finishedTurn("child-1", prompt: "Check the footer at 375 pt",
                                            answer: "The footer wraps cleanly at 375 pt.", now: now)]),
            Entry(task: Self.task(ID.failed, "Regenerate the screenshots", .claude, ID.website, at(20), unread: true),
                  turns: [Self.failedTurn(now: now)])
        ]
        entries = entries.map(Self.withState)
        order = entries.map(\.task.id)
        tasks = Dictionary(uniqueKeysWithValues: entries.map { ($0.task.id, $0) })
    }

    // MARK: - Bridge

    public func setChangeHandler(_ handler: @escaping @Sendable (RemoteBridgeChange) -> Void) {
        self.handler = handler
        if scripts[ID.streaming] == nil, timers[ID.streaming] == nil { later(ID.streaming, after: 0) { await $0.streamRelease() } }
    }

    public func snapshot() -> RemoteSnapshot {
        var listed = order.compactMap { tasks[$0] }.sorted { $0.task.lastActivityAt > $1.task.lastActivityAt }
        var requests: [String: String] = [:]
        var summaries: [String: String] = [:]
        for index in listed.indices {
            let entry = listed[index]
            guard let request = entry.pendingRequest else { continue }
            requests[entry.task.id] = request.id
            let item = entry.turns.last?.items.last { $0.requestId == request.id }
            let summary = item?.requestKind == "question"
                ? RemoteSummary.line([item?.questions?.first])
                : RemoteSummary.line([item?.title, item?.detail ?? item?.command])
            summaries[entry.task.id] = summary
            listed[index].task.pendingSummary = summary
            listed[index].task.pendingKind = item?.requestKind
        }
        return RemoteSnapshot(projects: projects, tasks: listed.map(\.task), newestRequestIDs: requests,
                              requestSummaries: summaries,
                              newTask: RemoteNewTask(harness: "claude-code", harnessName: "Claude Code"))
    }

    /// The task's turns, and the messages queued behind its running turn at the end of the last one.
    public func conversation(of taskID: String) -> RemoteConversation? {
        guard let entry = tasks[taskID] else { return nil }
        var turns = entry.turns
        if !entry.queue.isEmpty, let last = turns.indices.last {
            turns[last].items += entry.queue.map { queued in
                var item = queued
                item.turnId = turns[last].id
                return item
            }
        }
        return RemoteConversation(turns: turns, hasEarlier: !entry.held.isEmpty)
    }

    public func prepareConversation(of taskID: String) {}

    public func loadEarlierConversation(of taskID: String) async {
        guard tasks[taskID]?.held.isEmpty == false else { return }
        try? await Task.sleep(for: .seconds(0.8 / speed))
        guard var entry = tasks[taskID] else { return }
        entry.turns = entry.held + entry.turns
        entry.held = []
        tasks[taskID] = entry
        changed(taskID)
    }

    public func setWatchedTasks(_ taskIDs: Set<String>) {}

    public func perform(_ command: RemoteCommand) async -> RemoteError? {
        switch command {
        case let .sendMessage(taskID, text):
            guard tasks[taskID] != nil else { return RemoteError(.notFound) }
            send(text, to: taskID)
            return nil
        case let .answerApproval(taskID, requestID, answer):
            guard let entry = tasks[taskID] else { return RemoteError(.notFound) }
            guard let item = entry.turns.last?.items.last(where: {
                $0.kind == .approval && $0.requestId == requestID && $0.status == "pending"
            }) else { return RemoteError(.requestNotFound) }
            guard item.options?.contains(answer.rawValue) == true else { return RemoteError(.notAllowed) }
            answerApproval(taskID, item: item, allow: answer == .allowOnce)
            return nil
        case let .stopTurn(taskID):
            guard let entry = tasks[taskID] else { return RemoteError(.notFound) }
            guard entry.task.running else { return RemoteError(.notRunning) }
            stop(taskID)
            return nil
        case let .markRead(taskID):
            guard tasks[taskID] != nil else { return RemoteError(.notFound) }
            tasks[taskID]?.task.unread = false
            refreshState(taskID)
            changed(taskID)
            return nil
        case let .answerQuestion(taskID, requestID, answers):
            guard let item = pendingItem(taskID, requestID) else {
                return tasks[taskID] == nil ? RemoteError(.notFound) : RemoteError(.requestNotFound)
            }
            guard item.options?.contains(RemoteProtocol.answerOption) == true, let steps = item.questionSteps,
                  let words = Self.answerText(answers, to: steps) else { return RemoteError(.notAllowed) }
            resolve(taskID, item: item, status: "answered", reply: "Going with **\(words)**. I'll use it in the release notes and the tag.")
            return nil
        case let .reviewPlan(taskID, requestID, decision, reason):
            guard let item = pendingItem(taskID, requestID) else {
                return tasks[taskID] == nil ? RemoteError(.notFound) : RemoteError(.requestNotFound)
            }
            guard item.requestKind == "planReview" else { return RemoteError(.notAllowed) }
            resolve(taskID, item: item, status: decision == .approve ? "allowed" : "denied",
                    reply: decision == .approve ? "Plan approved. Starting with the read path."
                        : "I'll rework the plan\(reason.map { ": \($0)" } ?? ".")")
            return nil
        case let .actOnSuggestion(taskID, suggestionID, action):
            guard let entry = tasks[taskID] else { return RemoteError(.notFound) }
            guard var item = entry.turns.flatMap(\.items).first(where: { $0.suggestionId == suggestionID }),
                  item.options?.contains(action.rawValue) == true else { return RemoteError(.notAllowed) }
            item.options = nil
            switch action {
            case .dismiss:
                item.suggestionState = "dismissed"
                replaceItem(item, in: taskID)
            case .here:
                item.suggestionState = "sentHere"
                replaceItem(item, in: taskID)
                send("Do this task here: “\(item.title ?? "")”", to: taskID)
            case .start:
                let started = startTask(title: item.title ?? "Suggested task", text: item.detail ?? "", project: entry.task.projectId,
                                        parent: taskID)
                item.suggestionState = "started"
                item.startedTaskId = started
                replaceItem(item, in: taskID)
            }
            return nil
        case let .setPinned(taskID, pinned):
            guard tasks[taskID] != nil else { return RemoteError(.notFound) }
            tasks[taskID]?.task.pinned = pinned
            changed(taskID)
            return nil
        case let .archiveTask(taskID):
            guard let entry = tasks[taskID] else { return RemoteError(.notFound) }
            guard !entry.task.running else { return RemoteError(.busy, "The task is running") }
            tasks[taskID] = nil
            order.removeAll { $0 == taskID }
            handler?(.tasks)
            handler?(.conversation(taskID))
            return nil
        }
    }

    public func createTask(projectID: String, text: String) async -> Result<String, RemoteError> {
        guard projects.contains(where: { $0.id == projectID }) else { return .failure(RemoteError(.notFound)) }
        let title = String((text.split(separator: "\n").first.map(String.init) ?? "New task").prefix(60))
        return .success(startTask(title: title, text: text, project: projectID, parent: nil))
    }

    public func itemDetail(taskID: String, itemID: String) async -> Result<RemoteItemDetail, RemoteError> {
        guard let entry = tasks[taskID], let item = entry.turns.flatMap(\.items).first(where: { $0.id == itemID }) else {
            return .failure(RemoteError(.notFound))
        }
        switch item.activity {
        case "fileChange"?:
            let file = item.title?.split(separator: " ").last.map(String.init) ?? "File.swift"
            return .success(RemoteItemDetail(diffs: [RemoteDiff(path: "Sources/\(file)", patch: Self.samplePatch,
                                                                additions: item.additions, deletions: item.deletions)]))
        case "command"?:
            return .success(RemoteItemDetail(output: Self.sampleOutput(for: item.title ?? "")))
        default:
            return .failure(RemoteError(.unavailable))
        }
    }

    /// A new task in a project, replying like any idle task.
    private func startTask(title: String, text: String, project: String?, parent: String?) -> String {
        counter += 1
        let id = String(format: "0F1E1%03d-0000-4000-8000-%012d", counter % 1000, counter)
        let entry = Entry(task: Self.task(id, title, .claude, project ?? "chats", RemoteJSON.milliseconds(Date()), parent: parent),
                          turns: [])
        tasks[id] = Self.withState(entry)
        order.insert(id, at: 0)
        startReply(to: text, in: id)
        return id
    }

    private func pendingItem(_ taskID: String, _ requestID: String) -> RemoteItem? {
        tasks[taskID]?.turns.last?.items.last { $0.kind == .approval && $0.requestId == requestID && $0.status == "pending" }
    }

    /// The words a question form's answers come to, or nil when they do not answer its steps.
    static func answerText(_ answers: [RemoteQuestionAnswer], to steps: [RemoteQuestionStep]) -> String? {
        var words: [String] = []
        for step in steps {
            guard let answer = answers.first(where: { $0.questionId == step.id }) else { return nil }
            if answer.skipped == true {
                guard step.skippable else { return nil }
                continue
            }
            let picked = answer.options ?? []
            guard picked.allSatisfy({ label in step.options.contains { $0.label == label } }),
                  step.multiple || picked.count <= 1 else { return nil }
            let own = answer.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard own.isEmpty || step.custom else { return nil }
            let value = (picked + (own.isEmpty ? [] : [own])).joined(separator: ", ")
            guard !value.isEmpty else { return nil }
            words.append(value)
        }
        return words.joined(separator: "; ")
    }

    /// A question or plan review answered: it joins the work and a short answer finishes the turn.
    private func resolve(_ taskID: String, item: RemoteItem, status: String, reply: String) {
        var answered = item
        answered.status = status
        answered.options = nil
        answered.moreOnMac = nil
        answered.inWork = true
        replaceItem(answered, in: taskID)
        tasks[taskID]?.pendingRequest = nil
        refreshState(taskID)
        changed(taskID)
        let turnID = item.turnId
        scripts[taskID]?.cancel()
        scripts[taskID] = Task {
            await self.stream(reply, id: "i:\(turnID)-answer-\(item.requestId ?? "")", turnID: turnID, in: taskID)
            guard !Task.isCancelled else { return }
            self.finishTurn(taskID, turnID: turnID, status: "completed")
        }
    }

    // MARK: - Scripts

    /// A message to a running task waits in its queue, as Claude Code holds a follow-up, and is taken
    /// when the turn ends; to an idle task it starts a turn that replies.
    private func send(_ text: String, to taskID: String) {
        guard let entry = tasks[taskID] else { return }
        counter += 1
        if entry.task.running {
            var queued = RemoteItem(id: "queued:\(counter)", turnId: "", kind: .user)
            queued.text = text
            queued.queued = true
            tasks[taskID]?.queue.append(queued)
            touch(taskID)
            return
        }
        startReply(to: text, in: taskID)
    }

    private func startReply(to text: String, in taskID: String) {
        counter += 1
        let turnID = "reply-\(counter)"
        tasks[taskID]?.turns.append(RemoteTurn(id: turnID, items: [Self.user(turnID, text), Self.turnItem(turnID, running: true)]))
        tasks[taskID]?.task.running = true
        touch(taskID)
        scripts[taskID]?.cancel()
        scripts[taskID] = Task { await self.reply(to: text, in: taskID, turnID: turnID) }
    }

    private func reply(to text: String, in taskID: String, turnID: String) async {
        await pause(1)
        guard !Task.isCancelled else { return }
        appendItem(Self.activity(turnID, "read", "Read Footer.tsx", "completed"), to: taskID)
        await pause(0.8)
        guard !Task.isCancelled else { return }
        var edit = Self.activity(turnID, "edit", "Edited Footer.tsx", "running")
        edit.activity = "fileChange"
        appendItem(edit, to: taskID)
        await pause(1)
        guard !Task.isCancelled else { return }
        edit.status = "completed"
        edit.additions = 3
        edit.deletions = 1
        replaceItem(edit, in: taskID)
        let answer = "Done. I fixed the footer for “\(String(text.prefix(80)))”:\n\n- Updated **Footer.tsx** so the links point at `/docs`.\n- Checked the other pages; nothing else needed a change."
        await stream(answer, id: "i:\(turnID)-answer", turnID: turnID, in: taskID)
        guard !Task.isCancelled else { return }
        finishTurn(taskID, turnID: turnID, status: "completed")
    }

    private func answerApproval(_ taskID: String, item: RemoteItem, allow: Bool) {
        var answered = item
        answered.status = allow ? "allowed" : "denied"
        answered.options = nil
        answered.moreOnMac = nil
        answered.inWork = true
        replaceItem(answered, in: taskID)
        tasks[taskID]?.pendingRequest = nil
        refreshState(taskID)
        changed(taskID)
        let turnID = item.turnId
        scripts[taskID]?.cancel()
        scripts[taskID] = Task {
            if allow {
                var command = Self.activity(turnID, "run-\(item.requestId ?? "")", "Ran swift test --filter Migration", "running")
                command.activity = "command"
                command.approved = true
                self.appendItem(command, to: taskID)
                await self.pause(1.5)
                guard !Task.isCancelled else { return }
                command.status = "completed"
                command.exitCode = 0
                self.replaceItem(command, in: taskID)
                await self.stream("All **12** migration tests pass. The index now uses the new schema, and old rows are read through the compatibility view.",
                                  id: "i:\(turnID)-answer-\(item.requestId ?? "")", turnID: turnID, in: taskID)
            } else {
                await self.stream("Okay, I won't run the tests. The migration is written but not verified; run `swift test --filter Migration` when you're ready.",
                                  id: "i:\(turnID)-answer-\(item.requestId ?? "")", turnID: turnID, in: taskID)
            }
            guard !Task.isCancelled else { return }
            self.finishTurn(taskID, turnID: turnID, status: "completed")
        }
    }

    /// A new request in the approval or question task, as after the person asked again on the Mac.
    private func askAgain(_ taskID: String) {
        guard tasks[taskID]?.task.running == false else { return }
        counter += 1
        let turnID = "again-\(counter)"
        if taskID == ID.plan {
            let requestID = "toolu_fixture_plan_\(counter)"
            tasks[taskID]?.turns.append(RemoteTurn(id: turnID, items: [
                Self.user(turnID, "Plan the cache rewrite again"),
                Self.turnItem(turnID, running: true, waiting: true),
                Self.planReview(turnID, requestID: requestID)
            ]))
            tasks[taskID]?.pendingRequest = (requestID, .approval)
        } else if taskID == ID.question {
            let requestID = "toolu_fixture_question_\(counter)"
            tasks[taskID]?.turns.append(RemoteTurn(id: turnID, items: [
                Self.user(turnID, "Pick a name for the 1.0 release, again"),
                Self.turnItem(turnID, running: true, waiting: true),
                Self.question(turnID, requestID: requestID)
            ]))
            tasks[taskID]?.pendingRequest = (requestID, .input)
        } else {
            let requestID = "toolu_fixture_\(counter)"
            var edit = Self.activity(turnID, "edit-\(counter)", "Edited SessionRepository.swift", "completed")
            edit.activity = "fileChange"
            edit.additions = 4
            edit.deletions = 2
            tasks[taskID]?.turns.append(RemoteTurn(id: turnID, items: [
                Self.user(turnID, "Run the migration tests again"),
                Self.turnItem(turnID, running: true, waiting: true),
                edit,
                Self.approval(turnID, requestID: requestID)
            ]))
            tasks[taskID]?.pendingRequest = (requestID, .approval)
        }
        tasks[taskID]?.task.running = true
        touch(taskID)
    }

    private func streamRelease() async {
        guard tasks[ID.streaming]?.task.running == false else { return }
        counter += 1
        let turnID = "release-\(counter)"
        tasks[ID.streaming]?.turns.append(RemoteTurn(id: turnID, items: [
            Self.user(turnID, counter > 1 ? "Build the release bundle again" : "Build the release bundle and summarize what changed"),
            Self.turnItem(turnID, running: true)
        ]))
        tasks[ID.streaming]?.task.running = true
        touch(ID.streaming)
        scripts[ID.streaming] = Task {
            var command = Self.activity(turnID, "build-\(turnID)", "Running swift build -c release", "running")
            command.activity = "command"
            self.appendItem(command, to: ID.streaming)
            await self.stream(Self.releaseNotes, id: "i:\(turnID)-answer", turnID: turnID, in: ID.streaming, wordDelay: 0.12)
            guard !Task.isCancelled else { return }
            command.title = "Ran swift build -c release"
            command.status = "completed"
            command.exitCode = 0
            self.replaceItem(command, in: ID.streaming)
            self.finishTurn(ID.streaming, turnID: turnID, status: "completed")
        }
    }

    /// The stop button: the running script ends, what ran stops, a waiting request expires, and the
    /// turn ends interrupted.
    private func stop(_ taskID: String) {
        scripts[taskID]?.cancel()
        scripts[taskID] = nil
        guard var turn = tasks[taskID]?.turns.last else { return }
        for index in turn.items.indices {
            if turn.items[index].streaming == true { turn.items[index].streaming = nil }
            if turn.items[index].kind == .activity, turn.items[index].status == "running" { turn.items[index].status = "stopped" }
            if turn.items[index].kind == .approval, turn.items[index].status == "pending" {
                turn.items[index].status = "expired"
                turn.items[index].options = nil
                turn.items[index].moreOnMac = nil
                turn.items[index].inWork = true
            }
        }
        let lastIndex = (tasks[taskID]?.turns.count ?? 1) - 1
        tasks[taskID]?.turns[lastIndex] = turn
        tasks[taskID]?.pendingRequest = nil
        finishTurn(taskID, turnID: turn.id, status: "interrupted")
    }

    /// Writes `text` into an answer a few words at a time.
    private func stream(_ text: String, id: String, turnID: String, in taskID: String, wordDelay: Double = 0.06) async {
        var item = RemoteItem(id: id, turnId: turnID, kind: .assistant)
        item.role = "answer"
        item.text = ""
        item.streaming = true
        appendItem(item, to: taskID)
        let words = text.split(separator: " ", omittingEmptySubsequences: false)
        for (index, word) in words.enumerated() {
            await pause(wordDelay)
            guard !Task.isCancelled else { return }
            item.text = (item.text ?? "") + (index == 0 ? "" : " ") + word
            replaceItem(item, in: taskID)
        }
        item.streaming = nil
        replaceItem(item, in: taskID)
    }

    /// Ends the turn. A message queued behind it is taken next; otherwise the approval, question and
    /// release tasks start over 30 seconds later, so each can be tried again.
    private func finishTurn(_ taskID: String, turnID: String, status: String) {
        guard var entry = tasks[taskID], let index = entry.turns.firstIndex(where: { $0.id == turnID }),
              let header = entry.turns[index].items.firstIndex(where: { $0.kind == .turn }) else { return }
        var item = entry.turns[index].items[header]
        item.status = status
        item.progress = nil
        let completedAt = RemoteJSON.milliseconds(Date())
        item.completedAt = completedAt
        item.durationMs = item.startedAt.map { completedAt - $0 }
        item.foldsWork = entry.turns[index].items.contains { $0.inWork == true }
        item.workCount = entry.turns[index].items.filter { $0.inWork == true }.count
        entry.turns[index].items[header] = item
        entry.task.running = false
        entry.task.unread = true
        tasks[taskID] = entry
        touch(taskID)
        scripts[taskID] = nil
        if let next = tasks[taskID]?.queue.first {
            tasks[taskID]?.queue.removeFirst()
            startReply(to: next.text ?? "", in: taskID)
            return
        }
        switch taskID {
        case ID.approval, ID.question, ID.plan: later(taskID, after: 30) { await $0.askAgain(taskID) }
        case ID.streaming: later(taskID, after: 30) { await $0.streamRelease() }
        default: break
        }
    }

    private func later(_ taskID: String, after seconds: Double, _ action: @escaping @Sendable (RemoteFixtureBridge) async -> Void) {
        timers[taskID]?.cancel()
        timers[taskID] = Task {
            await self.pause(seconds)
            guard !Task.isCancelled else { return }
            self.clearTimer(taskID)
            await action(self)
        }
    }

    private func clearTimer(_ taskID: String) {
        timers[taskID] = nil
    }

    private func appendItem(_ item: RemoteItem, to taskID: String) {
        guard var turn = tasks[taskID]?.turns.last, turn.id == item.turnId else { return }
        if let header = turn.items.firstIndex(where: { $0.kind == .turn }) {
            turn.items[header].progress = nil
        }
        turn.items.append(item)
        let lastIndex = (tasks[taskID]?.turns.count ?? 1) - 1
        tasks[taskID]?.turns[lastIndex] = turn
        touch(taskID)
    }

    private func replaceItem(_ item: RemoteItem, in taskID: String) {
        guard let turns = tasks[taskID]?.turns,
              let turn = turns.firstIndex(where: { $0.id == item.turnId }),
              let index = turns[turn].items.firstIndex(where: { $0.id == item.id }) else { return }
        tasks[taskID]?.turns[turn].items[index] = item
        touch(taskID)
    }

    private func touch(_ taskID: String) {
        tasks[taskID]?.task.lastActivityAt = RemoteJSON.milliseconds(Date())
        refreshState(taskID)
        changed(taskID)
    }

    private func refreshState(_ taskID: String) {
        guard let entry = tasks[taskID] else { return }
        tasks[taskID] = Self.withState(entry)
    }

    /// The task's attention, mark and request as the Mac's sidebar would read them. A turn waiting
    /// on a request is still running, so the stop button applies, as on the Mac.
    private static func withState(_ entry: Entry) -> Entry {
        var entry = entry
        let failed = entry.turns.last?.items.contains { $0.kind == .error } == true
        if let request = entry.pendingRequest {
            entry.task.running = true
            entry.task.attention = .waiting
            entry.task.pendingRequest = request.kind
            entry.task.indicator = request.kind == .input ? .needsInput : .awaitingApproval
        } else if entry.task.running {
            entry.task.attention = .active
            entry.task.pendingRequest = nil
            entry.task.indicator = .running
        } else {
            entry.task.attention = entry.task.unread ? .unread : .idle
            entry.task.pendingRequest = nil
            entry.task.indicator = failed ? .failed : entry.task.unread ? .unread : nil
        }
        return entry
    }

    private func changed(_ taskID: String) {
        handler?(.tasks)
        handler?(.conversation(taskID))
    }

    private func pause(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds / speed))
    }

    // MARK: - Fixture content

    private enum Harness {
        case claude
        case codex
    }

    private static func task(_ id: String, _ title: String, _ harness: Harness, _ project: String, _ at: Int64,
                             unread: Bool = false, parent: String? = nil) -> RemoteTask {
        RemoteTask(id: id, title: title, harness: harness == .claude ? "claude-code" : "codex",
                   harnessName: harness == .claude ? "Claude Code" : "Codex", projectId: project,
                   attention: .idle, unread: unread, lastActivityAt: at, parentTaskId: parent)
    }

    private static func user(_ turnID: String, _ text: String) -> RemoteItem {
        var item = RemoteItem(id: "i:\(turnID)-user", turnId: turnID, kind: .user)
        item.text = text
        return item
    }

    private static func turnItem(_ turnID: String, running: Bool, waiting: Bool = false, durationMs: Int64? = nil,
                                 now: Date = Date()) -> RemoteItem {
        var item = RemoteItem(id: "turn:\(turnID)", turnId: turnID, kind: .turn)
        item.status = running ? "running" : "completed"
        item.startedAt = RemoteJSON.milliseconds(now) - (durationMs ?? 0)
        if running {
            item.progress = waiting ? nil : "thinking"
        } else {
            item.completedAt = RemoteJSON.milliseconds(now)
            item.durationMs = durationMs
        }
        item.foldsWork = !running
        return item
    }

    private static func activity(_ turnID: String, _ key: String, _ title: String, _ status: String) -> RemoteItem {
        var item = RemoteItem(id: "i:\(turnID)-\(key)", turnId: turnID, kind: .activity)
        item.inWork = true
        item.activity = "tool"
        item.title = title
        item.status = status
        if title.hasPrefix("Edited") || title.hasPrefix("Ran") || title.hasPrefix("Running") { item.hasDetail = true }
        return item
    }

    private static func answer(_ turnID: String, _ text: String) -> RemoteItem {
        var item = RemoteItem(id: "i:\(turnID)-answer", turnId: turnID, kind: .assistant)
        item.role = "answer"
        item.text = text
        return item
    }

    private static func approval(_ turnID: String, requestID: String) -> RemoteItem {
        var item = RemoteItem(id: "req:\(requestID)", turnId: turnID, kind: .approval)
        item.requestId = requestID
        item.requestKind = "approval"
        item.status = "pending"
        item.title = "Bash"
        item.command = "swift test --filter Migration"
        item.detail = "Run the migration tests"
        item.options = [RemoteApprovalAnswer.allowOnce.rawValue, RemoteApprovalAnswer.deny.rawValue]
        item.moreOnMac = true
        return item
    }

    private static func finishedTurn(_ turnID: String, prompt: String, answer text: String, now: Date,
                                     suggestion: Bool = false) -> RemoteTurn {
        var header = turnItem(turnID, running: false, durationMs: 48_000, now: now.addingTimeInterval(-600))
        header.workCount = 2
        var items = [
            user(turnID, prompt), header,
            activity(turnID, "search", "Searched href=\"/doc\"", "completed"),
            activity(turnID, "read", "Read Footer.tsx", "completed"),
            answer(turnID, text)
        ]
        if suggestion {
            var chip = RemoteItem(id: "i:\(turnID)-suggestion", turnId: turnID, kind: .activity)
            chip.activity = "taskSuggestion"
            chip.title = "Add a link checker to CI"
            chip.detail = "Run a link check on every pull request so footer links cannot break again."
            chip.status = "completed"
            chip.suggestionId = "task_fixture1"
            chip.suggestionState = "open"
            chip.options = [RemoteSuggestionAction.start.rawValue, RemoteSuggestionAction.here.rawValue,
                            RemoteSuggestionAction.dismiss.rawValue]
            items.append(chip)
        }
        return RemoteTurn(id: turnID, items: items)
    }

    private static func planReviewTurns(now: Date) -> [RemoteTurn] {
        let turnID = "cache-1"
        let header = turnItem(turnID, running: true, waiting: true, now: now.addingTimeInterval(-60))
        return [RemoteTurn(id: turnID, items: [user(turnID, "Plan how to replace the session cache"), header,
                                               activity(turnID, "read", "Read SessionStore.swift", "completed"),
                                               planReview(turnID, requestID: "toolu_fixture_plan")])]
    }

    private static func planReview(_ turnID: String, requestID: String) -> RemoteItem {
        var item = RemoteItem(id: "req:\(requestID)", turnId: turnID, kind: .approval)
        item.requestId = requestID
        item.requestKind = "planReview"
        item.status = "pending"
        item.title = "Plan"
        item.text = """
        ## Replace the session cache

        1. Move reads behind `SessionStore.read`.
        2. Write through to SQLite and drop the JSON mirror.
        3. Migrate on first launch and keep a backup of the old file.
        """
        item.options = [RemoteProtocol.keepPlanningOption, RemoteProtocol.approvePlanOption]
        return item
    }

    private static let samplePatch = """
    @@ -12,7 +12,9 @@ struct SessionRepository {
         func load() throws -> [Session] {
    -        let data = try Data(contentsOf: legacyURL)
    -        return try decoder.decode([Session].self, from: data)
    +        guard let rows = try index.rows() else { return [] }
    +        return rows.map(Session.init(row:))
         }
    +
    +    private let index: SessionIndex
     }
    """

    private static func sampleOutput(for title: String) -> String {
        if title.contains("swift test") {
            return "Building for debugging...\nTest Suite 'MigrationTests' started.\n" +
                (1...12).map { "Test Case 'MigrationTests.test\($0)' passed (0.0\($0 % 10) seconds)." }.joined(separator: "\n") +
                "\nExecuted 12 tests, with 0 failures (0 unexpected) in 0.31 seconds"
        }
        return "Compiling Yardlet (412 sources)\nLinking Yardlet\nBuild complete! (128.4s)"
    }

    private static func approvalTurns(now: Date) -> [RemoteTurn] {
        let first = finishedTurn("migration-0", prompt: "Explain how the session index is stored",
                                 answer: "The index is one SQLite file, `session-index.sqlite3`, with one row per task.", now: now)
        let turnID = "migration-1"
        let header = turnItem(turnID, running: true, waiting: true, now: now.addingTimeInterval(-40))
        var edit = activity(turnID, "edit", "Edited SessionRepository.swift", "completed")
        edit.activity = "fileChange"
        edit.additions = 42
        edit.deletions = 7
        var note = RemoteItem(id: "i:\(turnID)-note", turnId: turnID, kind: .assistant)
        note.role = "commentary"
        note.inWork = true
        note.text = "Now I'll run the migration tests."
        return [first, RemoteTurn(id: turnID, items: [
            user(turnID, "Migrate the index to the new schema and run the migration tests"),
            header,
            activity(turnID, "read", "Read SessionRepository.swift", "completed"),
            edit, note,
            approval(turnID, requestID: "toolu_fixture_1")
        ])]
    }

    private static func questionTurns(now: Date) -> [RemoteTurn] {
        let turnID = "name-1"
        let header = turnItem(turnID, running: true, waiting: true, now: now.addingTimeInterval(-20))
        return [RemoteTurn(id: turnID, items: [user(turnID, "Pick a name for the 1.0 release"), header,
                                               question(turnID, requestID: "toolu_fixture_question")])]
    }

    private static func question(_ turnID: String, requestID: String) -> RemoteItem {
        var question = RemoteItem(id: "req:\(requestID)", turnId: turnID, kind: .approval)
        question.requestId = requestID
        question.requestKind = "question"
        question.status = "pending"
        question.title = "Question"
        question.questions = ["Which name should the release use?"]
        question.questionSteps = [
            RemoteQuestionStep(id: "Which name should the release use?", header: "Name", text: "Which name should the release use?",
                               options: [.init(label: "Juniper", description: "Short and easy to say"),
                                         .init(label: "Larch", description: "Keeps the tree names"),
                                         .init(label: "Hornbeam")],
                               custom: true)
        ]
        question.options = [RemoteProtocol.answerOption]
        return question
    }

    private static func planTurn(now: Date) -> RemoteTurn {
        let turnID = "trip-1"
        var plan = RemoteItem(id: "plan:\(turnID)", turnId: turnID, kind: .plan)
        plan.inWork = true
        plan.explanation = "Book the cabin first; it sells out."
        plan.steps = [
            RemotePlanStep(text: "Book the cabin", status: "completed"),
            RemotePlanStep(text: "Pack the hiking gear", status: "inProgress"),
            RemotePlanStep(text: "Check the trail conditions", status: "pending")
        ]
        var header = turnItem(turnID, running: false, durationMs: 12_000, now: now.addingTimeInterval(-1800))
        header.workCount = 1
        return RemoteTurn(id: turnID, items: [user(turnID, "Plan a weekend trip to the mountains"), header, plan,
                                              answer(turnID, "Here's the plan. The cabin is booked for Saturday.")])
    }

    private static func failedTurn(now: Date) -> RemoteTurn {
        let turnID = "shots-1"
        var header = turnItem(turnID, running: false, durationMs: 9_000, now: now.addingTimeInterval(-1200))
        header.status = "failed"
        header.foldsWork = false
        var error = RemoteItem(id: "outcome:\(turnID)", turnId: turnID, kind: .error)
        error.errorKind = "error"
        error.title = "The screenshot script failed"
        error.message = "scripts/screenshots.sh exited with code 1: Simulator not found."
        error.recoverable = true
        return RemoteTurn(id: turnID, items: [user(turnID, "Regenerate the App Store screenshots"), header, error])
    }

    private static func historyTurn(_ number: Int, now: Date) -> RemoteTurn {
        let turnID = "crash-\(number)"
        var header = turnItem(turnID, running: false, durationMs: Int64(20_000 + number * 1_000),
                              now: now.addingTimeInterval(Double(number - 31) * 900))
        header.workCount = 1
        var command = activity(turnID, "grep", "Searched crash-\(number).ips for EXC_BAD_ACCESS", "completed")
        command.activity = "command"
        command.exitCode = 0
        return RemoteTurn(id: turnID, items: [
            user(turnID, "Summarize crash report \(number)"), header, command,
            answer(turnID, "Crash \(number): a nil dereference in `TaskSidebar.row(for:)` while a task was being archived.")
        ])
    }

    private static let footerAnswer = """
    Two footer links 404:

    | Link | Points at | Should be |
    |---|---|---|
    | Docs | `/doc` | `/docs` |
    | Blog | `/blog/` | `/blog` |
    """

    private static let releaseNotes = """
    ## Release 1.0

    The release bundle is building. What changed since 0.9:

    - **Remote control:** a phone on your tailnet can follow tasks, answer approvals and stop turns.
    - **Menu bar:** running, unread and pinned tasks, with the sidebar's state dots.
    - **Diff comments:** comments on diff lines travel with the next message.

    Signing and notarization run after the build; I'll report when the bundle is ready.
    """
}
