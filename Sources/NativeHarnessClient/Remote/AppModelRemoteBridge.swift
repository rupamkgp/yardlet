import Foundation
import Observation
import YardletRemote

/// The phone remote's view of the app model: it reads the sidebar's tasks and a task's conversation
/// the way the window does, and carries out a phone's command through the same model calls the
/// window's controls make — the composer's send, the request card's answer, the stop button and
/// opening a task's read state. It runs on the main actor; the server calls it from its own.
///
/// Reads are cached until Observation says what they read changed, then the server is told
/// (`RemoteBridgeChange`) and reads again when it needs to, so a task streaming in the background
/// costs nothing until a phone follows it.
@MainActor
final class AppModelRemoteBridge: RemoteBridge {
    private weak var model: AppModel?
    private var changeHandler: (@Sendable (RemoteBridgeChange) -> Void)?
    private var cachedSnapshot: RemoteSnapshot?
    private var cachedConversations: [UUID: RemoteConversation] = [:]
    private var projectionCaches: [UUID: ConversationProjectionCache] = [:]
    private var turnMemos: [UUID: [String: (turn: ConversationTurn, remote: RemoteTurn)]] = [:]
    private var watched: Set<UUID> = []

    init(model: AppModel) {
        self.model = model
    }

    func setChangeHandler(_ handler: @escaping @Sendable (RemoteBridgeChange) -> Void) {
        changeHandler = handler
    }

    // MARK: - Reading

    func snapshot() -> RemoteSnapshot {
        if let cachedSnapshot { return cachedSnapshot }
        guard let model else { return .empty }
        let snapshot = withObservationTracking {
            Self.snapshot(of: model)
        } onChange: { [weak self] in
            Task { @MainActor in self?.tasksChanged() }
        }
        cachedSnapshot = snapshot
        return snapshot
    }

    static func snapshot(of model: AppModel) -> RemoteSnapshot {
        let sessions = model.store.sessions
        var snapshot = RemoteTaskProjection.snapshot(
            groups: model.projects.visibleGroups(sessions: sessions),
            chats: model.projects.chats(sessions: sessions),
            pinnedIDs: model.pinnedSidebarSessionIDs,
            details: model.taskAttentionDetails,
            shellBusy: model.shellBusySessionIDs,
            newestRequestID: { model.newestPendingApproval(in: $0)?.id },
            requestSummary: { requestSummary(of: $0, in: model) }
        )
        snapshot.newTask = newTaskHarness(in: model).map { RemoteNewTask(harness: $0.rawValue, harnessName: $0.displayName) }
        return snapshot
    }

    /// The harness the Mac's new-task composer starts on now, when it can start one.
    static func newTaskHarness(in model: AppModel) -> HarnessKind? {
        guard let harness = model.composerDrafts.home.harness, model.runtimeSelections.selectedURL(for: harness) != nil else {
            return nil
        }
        return harness
    }

    /// The summary and kind of the newest request a task waits on, read from the request itself.
    static func requestSummary(of session: SessionRecord, in model: AppModel) -> (summary: String?, kind: String)? {
        guard let requestID = model.newestPendingApproval(in: session)?.id else { return nil }
        if let request = model.heldRequests(in: session.id).first(where: { $0.id == requestID }) {
            return (RemoteTaskProjection.requestSummary(request), RemoteTaskProjection.requestKind(request))
        }
        if let state = model.codexPresentationBySessionID[session.id]?.serverRequestsByID[requestID] {
            let request = CodexRequestResponseProjection.request(state)
            return (RemoteTaskProjection.requestSummary(request), RemoteTaskProjection.requestKind(request))
        }
        for entry in (model.transcriptBySessionID[session.id] ?? []).reversed() {
            if case let .permission(request, .pending) = entry.content, request.id == requestID {
                return (RemoteTaskProjection.requestSummary(request), RemoteTaskProjection.requestKind(request))
            }
        }
        return nil
    }

    func conversation(of taskID: String) -> RemoteConversation? {
        guard let model, let id = UUID(uuidString: taskID) else { return nil }
        if let cached = cachedConversations[id] { return cached }
        let conversation = withObservationTracking {
            listedSession(id).map { conversation(of: $0, in: model) }
        } onChange: { [weak self] in
            Task { @MainActor in self?.conversationChanged(id) }
        }
        if let conversation { cachedConversations[id] = conversation }
        return conversation
    }

    /// The conversation the task's `ConversationTimeline` draws: the Codex thread once it has turns,
    /// else the shared transcript, with the earlier history the provider still holds and a provider
    /// retry on the running turn's status line, as the timeline adds them.
    private func conversation(of session: SessionRecord, in model: AppModel) -> RemoteConversation {
        let cache = projectionCaches[session.id] ?? ConversationProjectionCache()
        projectionCaches[session.id] = cache
        var presentation: ConversationPresentation
        if HarnessPresentationPolicy(harness: session.harness).usesCodexTimeline,
           let state = model.codexPresentationBySessionID[session.id], state.thread?.turns.isEmpty == false {
            presentation = cache.codex(state, workspaceURL: session.workspaceURL, historySelection: nil)
        } else {
            presentation = cache.transcript(
                model.transcriptBySessionID[session.id] ?? [], harness: session.harness, status: session.status,
                latestTurnIsComplete: session.completionState == .completed)
            if model.hasEarlierClaudeHistory(session) { presentation.earlier = .providerFile }
        }
        if let retry = model.providerRetryBySessionID[session.id], let last = presentation.turns.indices.last,
           presentation.turns[last].status == .running {
            presentation.turns[last].progress = .reconnecting(ProviderNoticeText.retry(retry))
        }
        // What Yardlet holds in the task, as the Mac's timeline draws it.
        presentation.appendHeldRequests(model.heldRequests(in: session.id))
        var memos = turnMemos[session.id] ?? [:]
        var kept: [String: (turn: ConversationTurn, remote: RemoteTurn)] = [:]
        let conversation = RemoteConversationProjection.conversation(presentation, workspaceURL: session.workspaceURL) { turn in
            if let memo = memos[turn.id], memo.turn == turn {
                kept[turn.id] = memo
                return memo.remote
            }
            let remote = RemoteConversationProjection.turn(turn, harness: presentation.harness, workspaceURL: session.workspaceURL)
            kept[turn.id] = (turn, remote)
            return remote
        }
        memos = kept
        turnMemos[session.id] = memos
        return withSuggestionStates(RemoteConversationProjection.queued(model.followUps.queue(for: session.id), into: conversation),
                                    of: session, in: model)
    }

    /// What became of each suggested task, which the chip reads from the app rather than the turn
    /// (§15.9): the actions the chip offers now, or its outcome.
    private func withSuggestionStates(_ conversation: RemoteConversation, of session: SessionRecord,
                                      in model: AppModel) -> RemoteConversation {
        var conversation = conversation
        for turn in conversation.turns.indices {
            for index in conversation.turns[turn].items.indices {
                guard let id = conversation.turns[turn].items[index].suggestionId else { continue }
                var item = conversation.turns[turn].items[index]
                let resolution = model.taskSuggestions.resolution(of: id, in: session.id)
                let progress = model.taskSuggestions.progress(of: id, in: session.id)
                switch (resolution?.outcome, progress) {
                case (.started?, _):
                    item.suggestionState = "started"
                    item.startedTaskId = resolution?.startedTaskID?.uuidString
                    item.options = nil
                case (.dismissed?, _):
                    item.suggestionState = "dismissed"
                    item.options = nil
                case (.sentHere?, _):
                    item.suggestionState = "sentHere"
                    item.options = nil
                case (nil, .starting?), (nil, .sending?):
                    item.suggestionState = "starting"
                    item.options = nil
                case (nil, .failed?):
                    item.suggestionState = "failed"
                    item.options = RemoteSuggestionAction.allCases.map(\.rawValue)
                case (nil, nil):
                    item.suggestionState = "open"
                    item.options = RemoteSuggestionAction.allCases.map(\.rawValue)
                }
                conversation.turns[turn].items[index] = item
            }
        }
        return conversation
    }

    /// Opening a task on the Mac reads its latest saved history (a Claude transcript the CLI wrote,
    /// a detached Codex thread's newest page); a phone opening it reads the same way. No turn starts.
    func prepareConversation(of taskID: String) async {
        guard let model, let id = UUID(uuidString: taskID), let session = listedSession(id) else { return }
        await model.refreshConversationStatus(for: session)
    }

    /// Scrolling up to the top on the Mac: a Codex thread's earlier page, or more of a Claude transcript.
    func loadEarlierConversation(of taskID: String) async {
        guard let model, let id = UUID(uuidString: taskID), let session = listedSession(id) else { return }
        if HarnessPresentationPolicy(harness: session.harness).usesCodexTimeline,
           model.codexPresentationBySessionID[session.id]?.thread?.turnsNextCursor != nil {
            await model.loadMoreCodexTurns(for: session)
        } else if model.hasEarlierClaudeHistory(session) {
            await model.readEarlierClaudeHistory(for: session)
        }
    }

    func setWatchedTasks(_ taskIDs: Set<String>) {
        watched = Set(taskIDs.compactMap(UUID.init(uuidString:)))
        for id in Array(projectionCaches.keys) where !watched.contains(id) {
            projectionCaches[id] = nil
            turnMemos[id] = nil
            cachedConversations[id] = nil
        }
    }

    private func tasksChanged() {
        cachedSnapshot = nil
        changeHandler?(.tasks)
    }

    private func conversationChanged(_ id: UUID) {
        cachedConversations[id] = nil
        changeHandler?(.conversation(id.uuidString))
    }

    private func listedSession(_ id: UUID) -> SessionRecord? {
        model?.sidebarSessions.first { $0.id == id }
    }

    // MARK: - Commands

    func perform(_ command: RemoteCommand) async -> RemoteError? {
        guard let model else { return RemoteError(.unavailable, "Yardlet is closing") }
        switch command {
        case let .sendMessage(taskID, text):
            guard let session = session(taskID) else { return RemoteError(.notFound) }
            // The composer's own send would take the text as the edited message, or drop it.
            if model.composerDrafts.tasks.draft(for: session.id).editState != nil {
                return RemoteError(.busy, "A message is being edited on the Mac")
            }
            if model.switchingAccounts.contains(session.id) || model.sessionMutations.contains(session.id) {
                return RemoteError(.busy, "The task is changing on the Mac")
            }
            switch model.sendRefusal(for: session) {
            case .heldElsewhere?: return RemoteError(.busy, "Another app holds this conversation")
            case .folderMissing?: return RemoteError(.unavailable, "The task's folder no longer exists")
            case nil: break
            }
            // As the composer sends: an idle task starts a turn, a running one takes a follow-up.
            Task { await model.send(HarnessUserInput(text: text), to: session) }
            return nil
        case let .answerApproval(taskID, requestID, answer):
            guard let session = session(taskID) else { return RemoteError(.notFound) }
            guard let request = pendingRequest(requestID, in: session) else { return RemoteError(.requestNotFound) }
            guard let route = RemoteApprovalPolicy.route(for: answer, to: request) else {
                return RemoteError(.notAllowed, "Answer this request on the Mac")
            }
            guard model.isAttached(session.id) else { return RemoteError(.unavailable, "The task is not connected") }
            // The request card's route (`ConversationActions.respond`).
            switch route {
            case let .decision(decision): await model.respond(to: request.id, decision: decision, in: session)
            case let .providerAction(action): await model.respond(to: request.id, action: action, in: session)
            case let .codex(response): await model.respondCodex(to: request.id, response: response, in: session)
            case .answer, .structured: return RemoteError(.notAllowed)
            }
            return nil
        case let .stopTurn(taskID):
            guard let session = session(taskID) else { return RemoteError(.notFound) }
            // The stop button: a running bash command first, then the turn.
            if model.isShellCommandRunning(in: session) {
                model.stopShellCommand(in: session)
                return nil
            }
            guard session.status == .running || session.status == .waitingForApproval else {
                return RemoteError(.notRunning)
            }
            await model.interrupt(session)
            return nil
        case let .markRead(taskID):
            guard let session = session(taskID) else { return RemoteError(.notFound) }
            await model.store.markRead(id: session.id)
            return nil
        case let .answerQuestion(taskID, requestID, answers):
            guard let session = session(taskID) else { return RemoteError(.notFound) }
            guard let request = pendingRequest(requestID, in: session) else { return RemoteError(.requestNotFound) }
            guard RemoteApprovalPolicy.formAnswers(for: request).contains(RemoteProtocol.answerOption),
                  let response = request.responses.first(where: { $0.route == .structured }),
                  let input = Self.formInput(answers, for: request.form?.questionSteps ?? []),
                  let route = request.route(for: response, input: input) else {
                return RemoteError(.notAllowed, "Those answers do not answer this request")
            }
            return await answer(request, in: session, by: route)
        case let .reviewPlan(taskID, requestID, decision, reason):
            guard let session = session(taskID) else { return RemoteError(.notFound) }
            guard let request = pendingRequest(requestID, in: session) else { return RemoteError(.requestNotFound) }
            guard !RemoteApprovalPolicy.formAnswers(for: request).isEmpty, case .planReview = request.form else {
                return RemoteError(.notAllowed, "Review this plan on the Mac")
            }
            let route: ConversationRequestRoute?
            switch decision {
            case .approve:
                route = request.responses.first { $0.route == .decision(.allow) }?.route
            case .keepPlanning:
                var input = ConversationRequestFormInput()
                input.reason = reason ?? ""
                route = request.responses.first { $0.route == .structured }.flatMap { request.route(for: $0, input: input) }
            }
            guard let route else { return RemoteError(.notAllowed) }
            return await answer(request, in: session, by: route)
        case let .actOnSuggestion(taskID, suggestionID, action):
            guard let session = session(taskID) else { return RemoteError(.notFound) }
            guard let suggestion = suggestion(suggestionID, in: session) else { return RemoteError(.notFound) }
            guard model.taskSuggestions.resolution(of: suggestionID, in: session.id) == nil,
                  model.taskSuggestions.progress(of: suggestionID, in: session.id)?.isUnderWay != true else {
                return RemoteError(.notAllowed, "The suggestion was already acted on")
            }
            // The chip's buttons.
            switch action {
            case .start: Task { await model.startTaskSuggestion(suggestion, from: session.id) }
            case .here: Task { await model.doTaskSuggestionHere(suggestion, in: session.id) }
            case .dismiss: model.dismissTaskSuggestion(suggestionID, in: session.id)
            }
            return nil
        case let .setPinned(taskID, pinned):
            guard let session = session(taskID) else { return RemoteError(.notFound) }
            // The sidebar's Pin and Unpin.
            if model.pinnedSidebarSessionIDs.contains(session.id) != pinned { await model.togglePinned(session) }
            return nil
        case let .archiveTask(taskID):
            guard let session = session(taskID) else { return RemoteError(.notFound) }
            if session.status == .running || session.status == .waitingForApproval || model.isShellCommandRunning(in: session) {
                return RemoteError(.busy, "Stop the task before archiving it")
            }
            await model.archive(session)
            return nil
        }
    }

    /// Sends a request's answer by its route, as the card does (`ConversationActions.respond`).
    private func answer(_ request: ConversationRequest, in session: SessionRecord,
                        by route: ConversationRequestRoute) async -> RemoteError? {
        guard let model else { return RemoteError(.unavailable) }
        guard model.isAttached(session.id) else { return RemoteError(.unavailable, "The task is not connected") }
        switch route {
        case let .decision(decision): await model.respond(to: request.id, decision: decision, in: session)
        case let .providerAction(action): await model.respond(to: request.id, action: action, in: session)
        case let .answer(answer): await model.respond(to: request.id, answer: answer, in: session)
        case let .codex(response): await model.respondCodex(to: request.id, response: response, in: session)
        case .structured: return RemoteError(.notAllowed)
        }
        return nil
    }

    /// A phone's answers as the card's form input (§15.3), or nil when they do not fit the steps: an
    /// unknown question or label, several picks for a one-answer question, own words where none are
    /// taken, a skip where none is allowed.
    static func formInput(_ answers: [RemoteQuestionAnswer], for steps: [ConversationQuestionStep]) -> ConversationRequestFormInput? {
        var input = ConversationRequestFormInput()
        for answer in answers {
            guard let step = steps.first(where: { $0.id == answer.questionId }), !step.isSecret else { return nil }
            if answer.skipped == true {
                guard step.canSkip else { return nil }
                input.skipped.insert(step.id)
                continue
            }
            let picked = answer.options ?? []
            guard picked.allSatisfy({ label in step.options.contains { $0.label == label } }),
                  step.allowsMultipleSelections || picked.count <= 1 else { return nil }
            if !picked.isEmpty { input.selections[step.id] = Set(picked) }
            if let text = answer.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                guard step.allowsCustomAnswer else { return nil }
                input.text[step.id] = text
            }
        }
        return input
    }

    func createTask(projectID: String, text: String) async -> Result<String, RemoteError> {
        guard let model else { return .failure(RemoteError(.unavailable, "Yardlet is closing")) }
        let sessions = model.store.sessions
        var folder: URL?
        var project: Project?
        if projectID != RemoteTaskProjection.chatsProjectID {
            guard let group = model.projects.visibleGroups(sessions: sessions)
                .first(where: { RemoteTaskProjection.projectID(for: $0) == projectID }) else { return .failure(RemoteError(.notFound)) }
            project = group.project
            folder = group.project?.primaryRoot ?? group.workspaceURL
            var isDirectory: ObjCBool = false
            guard let folder, FileManager.default.fileExists(atPath: folder.path(percentEncoded: false), isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                return .failure(RemoteError(.unavailable, "The project's folder no longer exists"))
            }
        }
        // As the Mac's home composer would start it with this project chosen.
        let draft = model.composerDrafts.home
        guard let harness = Self.newTaskHarness(in: model), let runtime = model.runtimeSelections.selectedURL(for: harness) else {
            return .failure(RemoteError(.unavailable, "No harness can start a task"))
        }
        let submission = NewTaskDraft.Submission(
            originalText: text, attachments: [], harness: harness, workspaceURL: folder, projectID: project?.id,
            runtimeURL: runtime, connection: model.connections.selected(for: harness),
            startsInNewWorktree: folder != nil && draft.startsInNewWorktree(projectID: project?.id),
            providerOptions: draft.modelChoices[harness]?.providerOptions(for: harness) ?? [:],
            selectsTask: false)
        let previousError = model.bootstrapError
        do {
            guard let created = try await model.createTask(submission) else {
                let reason = model.bootstrapError != previousError ? model.bootstrapError : nil
                return .failure(RemoteError(.internal, reason ?? "The task did not start"))
            }
            return .success(created.id.uuidString)
        } catch {
            return .failure(RemoteError(.internal, error.localizedDescription))
        }
    }

    func itemDetail(taskID: String, itemID: String) async -> Result<RemoteItemDetail, RemoteError> {
        guard let model, let session = session(taskID) else { return .failure(RemoteError(.notFound)) }
        guard let item = item(itemID, in: presentation(of: session, in: model)) else { return .failure(RemoteError(.notFound)) }
        var detail = RemoteItemDetail()
        switch item.kind {
        case let .command(command):
            (detail.output, detail.outputTruncated) = Self.tail(command.output)
        case let .tool(tool):
            (detail.output, detail.outputTruncated) = Self.tail(tool.output)
            if let diff = tool.diff, let patch = ConversationFileChangeProjection.unifiedDiff(for: diff, workspaceURL: session.workspaceURL) {
                detail.diffs = [Self.diff(path: diff.path, patch: patch, counts: nil)]
            }
        case let .fileChange(change):
            let rows = change.placesRowsInWorkspace ? change.rows.map { $0.placed(in: session.workspaceURL) } : change.rows
            detail.diffs = rows.prefix(RemoteItemDetail.diffCount).compactMap { row in
                let patch = CodexFileChangeDiff.unifiedDiff(for: row.change, workspaceURL: nil)
                    ?? Self.patch(from: row.previewLines)
                return patch.map { Self.diff(path: row.displayPath, patch: $0, counts: row.lineCounts) }
            }
        default:
            break
        }
        guard detail.output != nil || !detail.diffs.isEmpty else { return .failure(RemoteError(.unavailable)) }
        return .success(detail)
    }

    /// The line a phone's item ID names (`i:` and the item's own ID).
    private func item(_ itemID: String, in presentation: ConversationPresentation) -> ConversationItem? {
        guard itemID.hasPrefix("i:") else { return nil }
        for turn in presentation.turns {
            let items: [ConversationItem] = turn.prompt + turn.notices + turn.work + turn.answers
            if let item = items.first(where: { "i:\($0.id)" == itemID }) { return item }
        }
        return nil
    }

    private static func tail(_ output: String?) -> (String?, Bool) {
        guard let output, !output.isEmpty else { return (nil, false) }
        guard output.count > RemoteItemDetail.outputLimit else { return (output, false) }
        return (String(output.suffix(RemoteItemDetail.outputLimit)), true)
    }

    private static func diff(path: String, patch: String, counts: CodexFileChangeCardProjection.LineCounts?) -> RemoteDiff {
        let capped = RemoteText.capped(patch, RemoteItemDetail.diffLimit)
        return RemoteDiff(path: path, patch: capped.text, additions: counts?.additions, deletions: counts?.deletions,
                          truncated: capped.truncated ? true : nil)
    }

    /// The lines a card draws, as diff text, where the change holds no diff of its own.
    private static func patch(from preview: CodexFileChangeCardProjection.Preview) -> String? {
        guard !preview.lines.isEmpty else { return nil }
        return preview.lines.map { line in
            switch line.kind {
            case .addition: "+" + line.text
            case .deletion: "-" + line.text
            case .context: " " + line.text
            case .separator: "@@"
            }
        }.joined(separator: "\n")
    }

    private func suggestion(_ id: String, in session: SessionRecord) -> ConversationTaskSuggestion? {
        guard let model else { return nil }
        for turn in presentation(of: session, in: model).turns {
            for item in turn.work + turn.answers {
                if case let .taskSuggestion(suggestion) = item.kind, suggestion.id == id { return suggestion }
            }
        }
        return nil
    }

    private func session(_ taskID: String) -> SessionRecord? {
        UUID(uuidString: taskID).flatMap(listedSession)
    }

    /// The request still waiting under that ID, as the task's conversation draws it now.
    private func pendingRequest(_ requestID: String, in session: SessionRecord) -> ConversationRequest? {
        guard let model else { return nil }
        if let request = model.heldRequests(in: session.id).first(where: { $0.id == requestID }) {
            return request
        }
        return presentation(of: session, in: model).turns.lazy.flatMap(\.requests)
            .first { $0.id == requestID && $0.state == .pending }
    }

    /// The task's conversation as the timeline draws it now, uncached.
    private func presentation(of session: SessionRecord, in model: AppModel) -> ConversationPresentation {
        if HarnessPresentationPolicy(harness: session.harness).usesCodexTimeline,
           let state = model.codexPresentationBySessionID[session.id], state.thread?.turns.isEmpty == false {
            return CodexConversationProjection.presentation(state, workspaceURL: session.workspaceURL, historySelection: nil)
        }
        return TranscriptConversationProjection.presentation(
            from: model.transcriptBySessionID[session.id] ?? [], harness: session.harness, status: session.status,
            latestTurnIsComplete: session.completionState == .completed)
    }
}
