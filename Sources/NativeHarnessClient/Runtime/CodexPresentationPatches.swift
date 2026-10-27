import Foundation

/// The adapter side's projection of the native Codex presentation onto the typed `yardlet.codex`
/// wire shape. `YHPCodexCompatibilityAdapter` projects it back.
enum CodexPresentationWire {
    static func snapshot(
        _ state: CodexTaskState,
        localSessionID: UUID,
        answerableServerRequestIDs: [String]
    ) -> HarnessProtocolCodexPresentationSnapshot {
        HarnessProtocolCodexPresentationSnapshot(
            localSessionID: localSessionID,
            activeTurnID: state.activeTurnID,
            thread: state.thread.map { thread($0) },
            approvals: state.approvalsByID.values
                .sorted { $0.id < $1.id }
                .map(approval),
            serverRequests: state.serverRequestsByID.values
                .sorted { $0.id < $1.id }
                .map(serverRequest),
            answerableServerRequestIDs: answerableServerRequestIDs,
            lastAppliedSequence: state.lastAppliedSequence
        )
    }

    static func approval(_ approval: CodexApprovalState) -> HarnessProtocolCodexApproval {
        let resolution: String
        let result: JSONValue?
        switch approval.resolution {
        case .pending:
            resolution = "pending"
            result = nil
        case let .resolved(value):
            resolution = "resolved"
            result = value
        }
        return HarnessProtocolCodexApproval(
            id: approval.id,
            method: approval.method,
            threadID: approval.threadID,
            turnID: approval.turnID,
            itemID: approval.itemID,
            resolution: resolution,
            result: result,
            raw: approval.raw
        )
    }

    /// `includingTurns: false` gives the thread's own fields with an empty `turns`.
    static func thread(
        _ thread: CodexThreadState,
        includingTurns: Bool = true
    ) -> HarnessProtocolCodexThread {
        let status: String
        let activeFlags: [String]
        switch thread.status {
        case .notLoaded: status = "not_loaded"; activeFlags = []
        case .idle: status = "idle"; activeFlags = []
        case let .active(flags): status = "active"; activeFlags = flags
        case .systemError: status = "system_error"; activeFlags = []
        case .unknown: status = "unknown"; activeFlags = []
        }
        return HarnessProtocolCodexThread(
            id: thread.id,
            sessionID: thread.sessionID,
            name: thread.name,
            preview: thread.preview,
            workspacePath: thread.workspacePath,
            cliVersion: thread.cliVersion,
            modelProvider: thread.modelProvider,
            parentThreadID: thread.parentThreadID,
            forkedFromID: thread.forkedFromID,
            status: status,
            activeFlags: activeFlags,
            canAcceptDirectInput: thread.canAcceptDirectInput,
            createdAt: thread.createdAt,
            updatedAt: thread.updatedAt,
            turns: includingTurns ? thread.turns.map { turn($0) } : [],
            turnsNextCursor: thread.turnsNextCursor,
            turnsBackwardsCursor: thread.turnsBackwardsCursor,
            itemsBackwardsCursor: thread.itemsBackwardsCursor,
            raw: thread.raw
        )
    }

    /// `includingItems: false` gives the turn's own fields with an empty `items`.
    static func turn(
        _ turn: CodexTurnState,
        includingItems: Bool = true
    ) -> HarnessProtocolCodexTurn {
        let status = switch turn.status {
        case .inProgress: "in_progress"
        case .completed: "completed"
        case .interrupted: "interrupted"
        case .failed: "failed"
        case let .unknown(value): value
        }
        let itemsView = switch turn.itemsView {
        case .notLoaded: "not_loaded"
        case .summary: "summary"
        case .full: "full"
        case let .unknown(value): value
        }
        return HarnessProtocolCodexTurn(
            id: turn.id,
            status: status,
            startedAt: turn.startedAt,
            completedAt: turn.completedAt,
            durationMilliseconds: turn.durationMilliseconds,
            itemsView: itemsView,
            items: includingItems ? turn.items.map(item) : [],
            itemsNextCursor: turn.itemsNextCursor,
            plan: turn.plan.map { plan in
                HarnessProtocolCodexPlan(
                    explanation: plan.explanation,
                    steps: plan.steps.map { step in
                        HarnessProtocolCodexPlanStep(
                            id: step.id,
                            text: step.text,
                            status: planStepStatus(step.status)
                        )
                    }
                )
            },
            tokenUsage: turn.tokenUsage.map(tokenUsage),
            error: turn.error,
            raw: turn.raw,
            diff: turn.diff,
            retryingError: turn.retryingError
        )
    }

    static func item(_ item: CodexItemState) -> HarnessProtocolCodexItem {
        // YHP reconstructs typed items from this payload. The original item/started frame
        // does not contain subsequent deltas, so serialize the current streamed text.
        let raw = item.renderedPayload
        return HarnessProtocolCodexItem(
            id: item.id,
            lifecycle: item.lifecycle.rawValue,
            type: item.content.typeName,
            startedAt: item.startedAt,
            completedAt: item.completedAt,
            raw: item.raw,
            rendered: raw == item.raw ? nil : raw
        )
    }

    static func serverRequest(
        _ request: CodexServerRequestState
    ) -> HarnessProtocolCodexServerRequest {
        let resolution: String
        let result: JSONValue?
        let rejectionCode: Int64?
        let rejectionMessage: String?
        switch request.resolution {
        case .pending:
            resolution = "pending"
            result = nil
            rejectionCode = nil
            rejectionMessage = nil
        case let .resolved(value):
            resolution = "resolved"
            result = value
            rejectionCode = nil
            rejectionMessage = nil
        case let .rejected(code, message):
            resolution = "rejected"
            result = nil
            rejectionCode = code
            rejectionMessage = message
        }
        return HarnessProtocolCodexServerRequest(
            id: request.id,
            method: request.method,
            kind: request.kind.wireName,
            threadID: request.threadID,
            turnID: request.turnID,
            itemID: request.itemID,
            params: request.params,
            resolution: resolution,
            result: result,
            rejectionCode: rejectionCode,
            rejectionMessage: rejectionMessage
        )
    }

    private static func planStepStatus(_ status: CodexPlanStepStatus) -> String {
        switch status {
        case .pending: "pending"
        case .inProgress: "in_progress"
        case .completed: "completed"
        case let .unknown(value): value
        }
    }

    private static func tokenUsage(
        _ usage: CodexThreadTokenUsage
    ) -> HarnessProtocolCodexThreadTokenUsage {
        HarnessProtocolCodexThreadTokenUsage(
            total: tokenUsageBreakdown(usage.total),
            last: tokenUsageBreakdown(usage.last),
            modelContextWindow: usage.modelContextWindow
        )
    }

    private static func tokenUsageBreakdown(
        _ usage: CodexTokenUsageBreakdown
    ) -> HarnessProtocolCodexTokenUsage {
        HarnessProtocolCodexTokenUsage(
            inputTokens: usage.inputTokens,
            cachedInputTokens: usage.cachedInputTokens,
            cacheWriteInputTokens: usage.cacheWriteInputTokens,
            outputTokens: usage.outputTokens,
            reasoningOutputTokens: usage.reasoningOutputTokens,
            totalTokens: usage.totalTokens
        )
    }
}

/// What changed between two native Codex presentations of one session, as a wire patch.
///
/// Successive states from the reducer share the storage of everything they did not touch, so
/// comparing an untouched turn or item is a pointer check; the work grows with what changed,
/// not with the thread.
enum CodexPresentationDiff {
    enum Outcome: Equatable, Sendable {
        /// Nothing a host projects changed.
        case unchanged
        case patch(HarnessProtocolCodexPresentationPatch)
        /// The change cannot be named by IDs; send the complete snapshot.
        case needsSnapshot
    }

    /// `base` must be a presentation whose turn and item IDs are unique (`hasUniqueIDs`).
    static func outcome(
        from base: CodexTaskState,
        baseAnswerableServerRequestIDs: [String],
        to state: CodexTaskState,
        answerableServerRequestIDs: [String],
        localSessionID: UUID,
        baseRevision: UInt64,
        revision: UInt64
    ) -> Outcome {
        let threadPatch: HarnessProtocolCodexThreadPatch?
        switch (base.thread, state.thread) {
        case (nil, nil):
            threadPatch = nil
        case let (old?, new?) where old.id == new.id:
            switch threadChange(from: old, to: new) {
            case .unchanged: threadPatch = nil
            case let .changed(patch): threadPatch = patch
            case .needsSnapshot: return .needsSnapshot
            }
        default:
            return .needsSnapshot
        }
        let approvals = changes(from: base.approvalsByID, to: state.approvalsByID)
        let serverRequests = changes(from: base.serverRequestsByID, to: state.serverRequestsByID)
        let activeTurnID = state.activeTurnID
        if threadPatch == nil,
           approvals.changed.isEmpty, approvals.removed.isEmpty,
           serverRequests.changed.isEmpty, serverRequests.removed.isEmpty,
           base.lastAppliedSequence == state.lastAppliedSequence,
           base.activeTurnID == activeTurnID,
           baseAnswerableServerRequestIDs == answerableServerRequestIDs {
            return .unchanged
        }
        return .patch(HarnessProtocolCodexPresentationPatch(
            localSessionID: localSessionID,
            revision: revision,
            baseRevision: baseRevision,
            activeTurnID: activeTurnID,
            lastAppliedSequence: state.lastAppliedSequence,
            answerableServerRequestIDs: answerableServerRequestIDs,
            thread: threadPatch,
            approvals: approvals.changed.map(CodexPresentationWire.approval),
            removedApprovalIDs: approvals.removed,
            serverRequests: serverRequests.changed.map(CodexPresentationWire.serverRequest),
            removedServerRequestIDs: serverRequests.removed
        ))
    }

    /// Whether every turn ID in the thread, and every item ID in each turn, is unique.
    static func hasUniqueIDs(_ state: CodexTaskState) -> Bool {
        guard let turns = state.thread?.turns else { return true }
        return isUnique(turns.map(\.id)) && turns.allSatisfy { isUnique($0.items.map(\.id)) }
    }

    private enum Change<Value> {
        case unchanged
        case changed(Value)
        case needsSnapshot
    }

    private static func threadChange(
        from old: CodexThreadState,
        to new: CodexThreadState
    ) -> Change<HarnessProtocolCodexThreadPatch> {
        var oldFields = old
        oldFields.turns = []
        var newFields = new
        newFields.turns = []
        let fieldsChanged = oldFields != newFields

        let orderChanged = !sameOrder(old.turns, new.turns)
        var turnPatches: [HarnessProtocolCodexTurnPatch] = []
        if orderChanged {
            guard isUnique(new.turns.map(\.id)) else { return .needsSnapshot }
            let oldByID = Dictionary(old.turns.map { ($0.id, $0) }) { first, _ in first }
            for turn in new.turns {
                let change = oldByID[turn.id].map { turnChange(from: $0, to: turn) }
                    ?? addedTurn(turn)
                switch change {
                case .unchanged: continue
                case let .changed(patch): turnPatches.append(patch)
                case .needsSnapshot: return .needsSnapshot
                }
            }
        } else {
            // Untouched turns share their storage, so this is a pointer check for each of them.
            let changed = old.turns.withUnsafeBufferPointer { oldTurns in
                new.turns.withUnsafeBufferPointer { newTurns in
                    newTurns.indices.filter { oldTurns[$0] != newTurns[$0] }
                }
            }
            for index in changed {
                switch turnChange(from: old.turns[index], to: new.turns[index]) {
                case .unchanged: continue
                case let .changed(patch): turnPatches.append(patch)
                case .needsSnapshot: return .needsSnapshot
                }
            }
        }
        guard fieldsChanged || orderChanged || !turnPatches.isEmpty else { return .unchanged }
        return .changed(HarnessProtocolCodexThreadPatch(
            fields: fieldsChanged ? CodexPresentationWire.thread(new, includingTurns: false) : nil,
            turnIDs: orderChanged ? new.turns.map(\.id) : nil,
            turns: turnPatches
        ))
    }

    private static func addedTurn(_ turn: CodexTurnState) -> Change<HarnessProtocolCodexTurnPatch> {
        guard isUnique(turn.items.map(\.id)) else { return .needsSnapshot }
        return .changed(HarnessProtocolCodexTurnPatch(
            id: turn.id,
            fields: CodexPresentationWire.turn(turn, includingItems: false),
            itemIDs: turn.items.map(\.id),
            items: turn.items.map(CodexPresentationWire.item)
        ))
    }

    private static func turnChange(
        from old: CodexTurnState,
        to new: CodexTurnState
    ) -> Change<HarnessProtocolCodexTurnPatch> {
        if old == new { return .unchanged }
        var oldFields = old
        oldFields.items = []
        var newFields = new
        newFields.items = []
        let fieldsChanged = oldFields != newFields

        let orderChanged = !sameOrder(old.items, new.items)
        var items: [HarnessProtocolCodexItem] = []
        if orderChanged {
            guard isUnique(new.items.map(\.id)) else { return .needsSnapshot }
            let oldByID = Dictionary(old.items.map { ($0.id, $0) }) { first, _ in first }
            for item in new.items where oldByID[item.id] != item {
                items.append(CodexPresentationWire.item(item))
            }
        } else if old.items != new.items {
            for index in new.items.indices where old.items[index] != new.items[index] {
                items.append(CodexPresentationWire.item(new.items[index]))
            }
        }
        guard fieldsChanged || orderChanged || !items.isEmpty else { return .unchanged }
        return .changed(HarnessProtocolCodexTurnPatch(
            id: new.id,
            fields: fieldsChanged ? CodexPresentationWire.turn(new, includingItems: false) : nil,
            itemIDs: orderChanged ? new.items.map(\.id) : nil,
            items: items
        ))
    }

    private static func changes<Value: Equatable>(
        from old: [String: Value],
        to new: [String: Value]
    ) -> (changed: [Value], removed: [String]) {
        guard old != new else { return ([], []) }
        let changed = new.keys.sorted().compactMap { key -> Value? in
            let value = new[key]
            return old[key] == value ? nil : value
        }
        let removed = old.keys.filter { new[$0] == nil }.sorted()
        return (changed, removed)
    }

    private static func sameOrder<Element: Identifiable>(
        _ old: [Element],
        _ new: [Element]
    ) -> Bool where Element.ID == String {
        guard old.count == new.count else { return false }
        return old.withUnsafeBufferPointer { old in
            new.withUnsafeBufferPointer { new in old.indices.allSatisfy { old[$0].id == new[$0].id } }
        }
    }

    private static func isUnique(_ ids: [String]) -> Bool {
        Set(ids).count == ids.count
    }
}
