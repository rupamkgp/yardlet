import Foundation
import YardletRemote

/// A task's conversation as the phone draws it (docs/REMOTE_PROTOCOL.md §6), read from the one
/// conversation model the Mac's `ConversationTimeline` draws for every harness. Nothing is
/// interpreted again: each turn keeps the Mac's order (what was sent, notices, the header, the
/// outcome, the plan and work, the answers, the requests still waiting), each call reads the line the
/// Mac shows (`ConversationLineWording`), and each request offers only the answers the Mac's card
/// offers that the phone may give (`RemoteApprovalPolicy`). Outputs, file contents and diffs are left
/// out, and fetched one line at a time by `itemDetail` (§15.8); text is capped.
enum RemoteConversationProjection {
    static func conversation(_ presentation: ConversationPresentation, workspaceURL: URL?) -> RemoteConversation {
        conversation(presentation, workspaceURL: workspaceURL) {
            turn($0, harness: presentation.harness, workspaceURL: workspaceURL)
        }
    }

    /// The conversation with its turns projected by `project`, which a caller uses to keep the turns
    /// that did not change since it last projected them.
    static func conversation(
        _ presentation: ConversationPresentation, workspaceURL: URL?, project: (ConversationTurn) -> RemoteTurn
    ) -> RemoteConversation {
        RemoteConversation(turns: uniqued(presentation.turns.map(project)), hasEarlier: presentation.earlier != .none)
    }

    static func turn(_ turn: ConversationTurn, harness: HarnessKind, workspaceURL: URL?) -> RemoteTurn {
        var items: [RemoteItem] = []
        func add(_ item: RemoteItem?) { if let item { items.append(item) } }
        for item in turn.prompt + turn.notices {
            add(self.item(item, turnID: turn.id, harness: harness, workspaceURL: workspaceURL, inWork: false))
        }
        let headerIndex = items.count
        if let outcome = turn.outcome {
            add(self.outcome(outcome, id: "outcome:\(turn.id)", turnID: turn.id, inWork: false))
        }
        if let plan = turn.plan { add(self.plan(plan, turnID: turn.id)) }
        let kept = Set(turn.workKeptWhenFolded.map(\.id))
        for item in turn.work {
            add(self.item(item, turnID: turn.id, harness: harness, workspaceURL: workspaceURL,
                          inWork: !kept.contains(item.id)))
        }
        for item in turn.answers {
            add(self.item(item, turnID: turn.id, harness: harness, workspaceURL: workspaceURL, inWork: false))
        }
        for request in turn.requests { add(self.request(request, turnID: turn.id, inWork: false)) }
        items.insert(header(turn, workCount: items.filter { $0.inWork == true }.count), at: headerIndex)
        return RemoteTurn(id: turn.id, items: items)
    }

    /// Messages waiting in the task's follow-up queue — on the Mac, the queue chips above the composer
    /// — as `queued` user items at the end of the last turn. Each leaves when the provider takes it,
    /// and the message then reads as an ordinary sent message in its turn.
    static func queued(_ followUps: [QueuedFollowUp], into conversation: RemoteConversation) -> RemoteConversation {
        guard !followUps.isEmpty else { return conversation }
        var conversation = conversation
        if conversation.turns.isEmpty { conversation.turns.append(RemoteTurn(id: "queue", items: [])) }
        let last = conversation.turns.count - 1
        let turnID = conversation.turns[last].id
        conversation.turns[last].items += followUps.map { followUp in
            var item = RemoteItem(id: "queued:\(followUp.id.uuidString)", turnId: turnID, kind: .user)
            let sent = DiffCommentPrompt.parse(followUp.draft.text)
            setText(&item, sent?.request ?? followUp.draft.text, RemoteText.userLimit)
            if let comments = sent?.comments.count, comments > 0 { item.diffCommentCount = comments }
            let images = followUp.draft.inputs.filter { input in
                switch input {
                case .image, .localImage: true
                default: false
                }
            }.count
            if images > 0 { item.imageCount = images }
            item.queued = true
            if followUp.state == .failed { item.queueFailed = true }
            return item
        }
        return conversation
    }

    // MARK: - Turn

    private static func header(_ turn: ConversationTurn, workCount: Int) -> RemoteItem {
        var item = RemoteItem(id: "turn:\(turn.id)", turnId: turn.id, kind: .turn)
        item.status = switch turn.status {
        case .running: "running"
        case .completed: "completed"
        case .interrupted: "interrupted"
        case .failed: "failed"
        case .unknown: "unknown"
        }
        item.startedAt = turn.timing.startedAt.map(RemoteJSON.milliseconds)
        item.completedAt = turn.timing.completedAt.map(RemoteJSON.milliseconds)
        item.durationMs = turn.timing.durationMilliseconds
        if turn.timing.isApproximate { item.approximate = true }
        item.foldsWork = turn.foldsWork && workCount > 0
        item.workCount = workCount
        if turn.status == .running {
            switch turn.progress {
            case .none: break
            case .thinking: item.progress = "thinking"
            case let .reconnecting(text):
                item.progress = "reconnecting"
                item.progressText = RemoteText.short(text, RemoteText.detailLimit)
            }
        }
        return item
    }

    // MARK: - Items

    static func item(
        _ item: ConversationItem, turnID: String, harness: HarnessKind, workspaceURL: URL?, inWork: Bool
    ) -> RemoteItem? {
        var result = RemoteItem(id: "i:\(item.id)", turnId: turnID, kind: .activity)
        if inWork { result.inWork = true }
        switch item.kind {
        case let .userMessage(text, images):
            result.kind = .user
            setText(&result, text, RemoteText.userLimit)
            if !images.isEmpty { result.imageCount = images.count }
            if let comments = item.promptAttachments?.comments.count, comments > 0 { result.diffCommentCount = comments }
        case let .scheduledTaskMessage(message):
            result.kind = .user
            setText(&result, message.instructions, RemoteText.userLimit)
            result.scheduled = true
        case let .shellCommand(command, _):
            result.kind = .user
            setText(&result, command.command, RemoteText.userLimit)
            result.shell = true
        case let .answer(text, isStreaming):
            assistant(&result, text, role: "answer", isStreaming: isStreaming)
        case let .commentary(text, isStreaming):
            assistant(&result, text, role: "commentary", isStreaming: isStreaming)
        case let .proposedPlan(text, isWriting):
            assistant(&result, text, role: "proposedPlan", isStreaming: isWriting)
        case let .reasoning(summary, detail, isStreaming):
            // The Mac draws a summary row, or a "Thinking" line while it streams or has a body.
            let summary = RemoteText.short(summary, RemoteText.detailLimit)
            guard summary != nil || isStreaming || detail?.isEmpty == false else { return nil }
            activity(&result, "reasoning", isStreaming ? L10n.string("Thinking") : L10n.string("Thought process"), item.phase)
            result.detail = summary
        case let .command(command):
            let words = ConversationLineWording.command(command, phase: item.phase, harness: harness)
            activity(&result, "command", words.map(\.text).joined(separator: ", "), item.phase)
            if !ConversationLineWording.showsWholeCommand(command, words: words) {
                result.detail = RemoteText.short(firstLine(command.command), RemoteText.detailLimit)
            }
            if item.phase != .running, let code = command.exitCode { result.exitCode = code }
            if command.isApproved { result.approved = true }
            if command.output?.isEmpty == false { result.hasDetail = true }
        case let .fileChange(change):
            let rows = change.placesRowsInWorkspace ? change.rows.map { $0.placed(in: workspaceURL) } : change.rows
            let verb = rows.first?.verb ?? L10n.string("Edited")
            activity(&result, "fileChange", [verb, rows.map(\.fileName).joined(separator: ", ")]
                .filter { !$0.isEmpty }.joined(separator: " "), item.phase)
            let counts = rows.compactMap(\.lineCounts)
            if !counts.isEmpty {
                result.additions = counts.reduce(0) { $0 + $1.additions }
                result.deletions = counts.reduce(0) { $0 + $1.deletions }
            }
            result.detail = RemoteText.short(change.errorMessage, RemoteText.detailLimit)
            if change.isApproved { result.approved = true }
            if rows.contains(where: \.canExpand) { result.hasDetail = true }
        case let .tool(tool):
            let words = ConversationLineWording.tool(tool, phase: item.phase, harness: harness, workspaceURL: workspaceURL)
            activity(&result, "tool", words.text, item.phase)
            result.detail = RemoteText.short(tool.errorMessage, RemoteText.detailLimit)
            if tool.isApproved { result.approved = true }
            if tool.output?.isEmpty == false || tool.diff != nil { result.hasDetail = true }
        case let .subagent(subagent):
            activity(&result, "subagent", subagent.title, item.phase)
            result.detail = RemoteText.short(subagent.detail ?? subagent.status, RemoteText.detailLimit)
            if subagent.isApproved { result.approved = true }
        case let .taskSuggestion(suggestion):
            activity(&result, "taskSuggestion", suggestion.title ?? firstLine(suggestion.prompt), item.phase)
            result.detail = RemoteText.short(suggestion.tldr, RemoteText.detailLimit)
            // What became of it is the app's, set after projection (`AppModelRemoteBridge`).
            result.suggestionId = suggestion.id
        case let .scheduleCreated(creation):
            // A tool line on the phone, which has no Scheduled tasks to open.
            activity(&result, "tool", L10n.format("Created scheduled task: %@", creation.name), item.phase)
        case let .notice(notice):
            result.kind = .notice
            result.text = RemoteText.short(notice.displayMessage, RemoteText.detailLimit)
        case let .compaction(compaction):
            result.kind = .notice
            result.text = RemoteText.short(ProviderNoticeText.compaction(compaction), RemoteText.detailLimit)
        case let .request(request):
            return self.request(request, turnID: turnID, inWork: inWork)
        case let .outcome(outcome):
            return self.outcome(outcome, id: "i:\(item.id)", turnID: turnID, inWork: inWork)
        }
        return result
    }

    private static func assistant(_ item: inout RemoteItem, _ text: String, role: String, isStreaming: Bool) {
        item.kind = .assistant
        item.role = role
        setText(&item, text, RemoteText.assistantLimit)
        if isStreaming { item.streaming = true }
    }

    private static func activity(_ item: inout RemoteItem, _ kind: String, _ title: String, _ phase: ConversationItemPhase) {
        item.kind = .activity
        item.activity = kind
        item.title = RemoteText.capped(oneLine(title), RemoteText.titleLimit).text
        item.status = switch phase {
        case .running: "running"
        case .completed: "completed"
        case .failed: "failed"
        case .stopped: "stopped"
        }
    }

    private static func setText(_ item: inout RemoteItem, _ text: String, _ limit: Int) {
        let capped = RemoteText.capped(text, limit)
        item.text = capped.text
        if capped.truncated { item.truncated = true }
    }

    // MARK: - Requests, plans, outcomes

    static func request(_ request: ConversationRequest, turnID: String, inWork: Bool) -> RemoteItem {
        var item = RemoteItem(id: "req:\(request.id)", turnId: turnID, kind: .approval)
        if inWork { item.inWork = true }
        item.requestId = request.id
        item.requestKind = switch request.form {
        case .choices: "question"
        case .planReview: "planReview"
        case .freeText, .mcpForm: "form"
        case nil: "approval"
        }
        item.status = switch request.state {
        case .pending: "pending"
        case .allowed: "allowed"
        case .denied: "denied"
        case .answered: "answered"
        case .expired: "expired"
        case .rejected: "rejected"
        }
        item.title = RemoteText.short(request.title, RemoteText.titleLimit)
        item.detail = RemoteText.short(request.detail, RemoteText.requestDetailLimit)
        item.command = RemoteText.short(request.command, RemoteText.commandLimit)
        switch request.form {
        case let .choices(questions):
            item.questions = questions.compactMap { RemoteText.short($0.question, RemoteText.questionLimit) }
        case let .planReview(plan):
            item.text = RemoteText.short(plan, RemoteText.planTextLimit)
        case let .freeText(questions):
            item.questions = questions.compactMap { RemoteText.short($0.text, RemoteText.questionLimit) }
        case let .mcpForm(form):
            item.questions = form.fields.compactMap { RemoteText.short($0.label, RemoteText.questionLimit) }
        case nil:
            break
        }
        if request.state == .pending {
            let answers = RemoteApprovalPolicy.answers(for: request)
            let formAnswers = RemoteApprovalPolicy.formAnswers(for: request)
            item.options = answers.map(\.rawValue) + formAnswers
            if !formAnswers.isEmpty {
                if formAnswers.contains(RemoteProtocol.answerOption) {
                    item.questionSteps = request.form?.questionSteps.map(questionStep)
                }
            } else if RemoteApprovalPolicy.hasMoreOnMac(request, phoneAnswers: answers.count) {
                item.moreOnMac = true
            }
        }
        return item
    }

    private static func questionStep(_ step: ConversationQuestionStep) -> RemoteQuestionStep {
        RemoteQuestionStep(
            id: step.id, header: RemoteText.short(step.header, RemoteText.titleLimit),
            text: RemoteText.short(step.text, RemoteText.questionLimit),
            options: step.options.map {
                .init(label: $0.label, description: RemoteText.short($0.description, RemoteText.questionLimit))
            },
            multiple: step.allowsMultipleSelections, custom: step.allowsCustomAnswer, skippable: step.canSkip)
    }

    private static func plan(_ plan: ConversationPlan, turnID: String) -> RemoteItem {
        var item = RemoteItem(id: "plan:\(turnID)", turnId: turnID, kind: .plan)
        item.inWork = true
        item.explanation = RemoteText.short(plan.explanation, RemoteText.requestDetailLimit)
        item.steps = plan.steps.prefix(RemoteText.stepCount).map { step in
            let status = switch step.status {
            case .pending: "pending"
            case .inProgress: "inProgress"
            case .completed: "completed"
            case .unknown: "pending"
            }
            return RemotePlanStep(text: RemoteText.capped(step.text, RemoteText.stepLimit).text, status: status)
        }
        return item
    }

    private static func outcome(_ outcome: ConversationTurnOutcome, id: String, turnID: String, inWork: Bool) -> RemoteItem {
        var item = RemoteItem(id: id, turnId: turnID, kind: .error)
        if inWork { item.inWork = true }
        switch outcome {
        case let .error(error):
            item.errorKind = "error"
            item.title = RemoteText.short(error.title, RemoteText.titleLimit)
            item.message = RemoteText.short(error.summary.isEmpty ? error.message : error.summary, RemoteText.errorLimit)
            item.recoverable = error.isRecoverable
        case let .usageLimit(limit, _):
            item.errorKind = "usageLimit"
            item.title = RemoteText.short(ProviderNoticeText.limitHeadline(limit), RemoteText.titleLimit)
            item.message = RemoteText.short(limit.message ?? ProviderNoticeText.limitReset(limit), RemoteText.errorLimit)
            item.resetsAt = limit.resetsAt.map(RemoteJSON.milliseconds)
        }
        return item
    }

    // MARK: - Text

    private static func firstLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
    }

    private static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).joined(separator: " ")
    }

    /// Item IDs are unique across the conversation, as the phone's changes name items by ID. A repeat
    /// (one provider ID drawn twice) gets a suffix by its order.
    private static func uniqued(_ turns: [RemoteTurn]) -> [RemoteTurn] {
        var seen: [String: Int] = [:]
        return turns.map { turn in
            var turn = turn
            for index in turn.items.indices {
                let id = turn.items[index].id
                let count = seen[id, default: 0]
                seen[id] = count + 1
                if count > 0 { turn.items[index].id = "\(id)#\(count + 1)" }
            }
            return turn
        }
    }
}

/// The answers the phone may give a waiting request (§4.4 `answerApproval`): "Allow once", the
/// narrowest allow the Mac's card offers — the same one the Mac notification's "Allow once" gives
/// (`NotificationApprovalProjection`) — and the card's plain deny. Questions, plan reviews, forms and
/// answers that set a standing rule stay on the Mac.
enum RemoteApprovalPolicy {
    static func answers(for request: ConversationRequest) -> [RemoteApprovalAnswer] {
        [allowOnce(request) == nil ? nil : RemoteApprovalAnswer.allowOnce, deny(request) == nil ? nil : .deny]
            .compactMap { $0 }
    }

    static func route(for answer: RemoteApprovalAnswer, to request: ConversationRequest) -> ConversationRequestRoute? {
        switch answer {
        case .allowOnce: allowOnce(request)
        case .deny: deny(request)
        }
    }

    static func allowOnce(_ request: ConversationRequest) -> ConversationRequestRoute? {
        guard request.state == .pending, request.form == nil else { return nil }
        switch request.source {
        case let .transcript(entry):
            guard case let .permission(permission, _) = entry.content else { return nil }
            return NotificationApprovalProjection.allowOnce(for: permission)
        case let .codexServerRequest(state):
            return NotificationApprovalProjection.allowOnce(for: state)
        case .codexApproval:
            return nil
        }
    }

    static func deny(_ request: ConversationRequest) -> ConversationRequestRoute? {
        guard request.state == .pending, request.form == nil else { return nil }
        let routes = request.responses.filter { $0.role == .destructive }.map(\.route)
        if let action = PermissionActionPreference.preferred(from: request.providerActions, decision: .deny) {
            guard PermissionActionPreference.scope(id: action.id, intent: action.kind) != .broad,
                  routes.contains(.providerAction(action)) else { return nil }
            return .providerAction(action)
        }
        return routes.first { route in
            switch route {
            case .decision(.deny), .codex: true
            default: false
            }
        }
    }

    /// What a v2 phone may answer a form with (§15.2): a question form's answers, unless one is a
    /// secret, and a plan review's two answers. MCP forms stay on the Mac.
    static func formAnswers(for request: ConversationRequest) -> [String] {
        guard request.state == .pending, request.unanswerableReason == nil else { return [] }
        let structured = request.responses.contains { $0.route == .structured }
        switch request.form {
        case .choices?, .freeText?:
            let steps = request.form?.questionSteps ?? []
            return structured && !steps.isEmpty && !steps.contains(where: \.isSecret) ? [RemoteProtocol.answerOption] : []
        case .planReview?:
            let approves = request.responses.contains { $0.route == .decision(.allow) }
            return structured && approves ? [RemoteProtocol.keepPlanningOption, RemoteProtocol.approvePlanOption] : []
        case .mcpForm?, nil:
            return []
        }
    }

    /// The Mac's card offers more than the phone does.
    static func hasMoreOnMac(_ request: ConversationRequest, phoneAnswers: Int) -> Bool {
        guard request.state == .pending else { return false }
        return request.form != nil || request.unanswerableReason != nil || request.responses.count > phoneAnswers
    }
}
