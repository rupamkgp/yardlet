import Foundation

/// The app-local Codex cards a task keeps across launches (`CodexPersistedTimelineItem`): which
/// of a presentation's items are saved, and which saved ones supplement a presentation the
/// provider loaded without them.
///
/// Both run on the main actor for every presentation a streaming task publishes. Successive
/// presentations share the storage of every turn they did not change, so each remembers what a
/// turn gave last time and redoes only the turns whose items or status changed; the cost follows
/// what changed rather than the conversation's length.
struct CodexPersistedTimeline {
    static let limit = 500

    private struct SavedTurn {
        let interrupted: Bool
        let items: [CodexItemState]
        /// The turn's kept items and the saved card each gave, oldest first.
        let sources: [CodexItemState]
        let cards: [CodexPersistedTimelineItem]
    }

    private var savedTurns: [String: SavedTurn] = [:]

    /// The newest `limit` cards of `state` worth keeping across a resume, oldest first.
    mutating func items(from state: CodexTaskState) -> [CodexPersistedTimelineItem] {
        guard let turns = state.thread?.turns else {
            savedTurns.removeAll()
            return []
        }
        var newestFirst: [ArraySlice<CodexPersistedTimelineItem>] = []
        var count = 0
        var visited: [String: SavedTurn] = [:]
        for turnIndex in turns.indices.reversed() {
            guard count < Self.limit else { break }
            let saved = savedTurn(turns[turnIndex])
            visited[turns[turnIndex].id] = saved
            let cards = saved.cards.suffix(Self.limit - count)
            newestFirst.append(cards)
            count += cards.count
        }
        savedTurns = visited
        var items: [CodexPersistedTimelineItem] = []
        items.reserveCapacity(count)
        for cards in newestFirst.reversed() { items.append(contentsOf: cards) }
        return items
    }

    private func savedTurn(_ turn: CodexTurnState) -> SavedTurn {
        let interrupted = turn.status == .interrupted
        let previous = savedTurns[turn.id]
        if let previous, previous.interrupted == interrupted, previous.items == turn.items {
            return previous
        }
        // A changed turn keeps the cards of its items that did not change.
        var reusable: [String: Int] = [:]
        for index in (previous?.sources ?? []).indices.reversed() { reusable[previous!.sources[index].id] = index }
        var sources: [CodexItemState] = []
        var cards: [CodexPersistedTimelineItem] = []
        for index in turn.items.indices where Self.isKept(turn.items[index].content, interrupted: interrupted) {
            let item = turn.items[index]
            if let previous, let kept = reusable[item.id], previous.sources[kept] == item {
                cards.append(previous.cards[kept])
            } else {
                cards.append(CodexPersistedTimelineItem(turnID: turn.id, item: item))
            }
            sources.append(item)
        }
        return SavedTurn(interrupted: interrupted, items: turn.items, sources: sources, cards: cards)
    }

    private static func isKept(_ content: CodexItemContent, interrupted: Bool) -> Bool {
        if content.shouldPersistAcrossResume { return true }
        if interrupted, case let .agentMessage(message) = content, !message.text.isEmpty { return true }
        return false
    }

    /// The saved cards that belong in `state` and are missing from it, or that got further than
    /// its copy, such as a finished card the provider's history leaves as started. A saved copy
    /// of a still-running card lags its live output and is left out. A saved answer only fills an
    /// interrupted turn whose provider omitted it; a provider's own item, even an intentionally
    /// empty one, always wins. Cards never manufacture a turn the presentation has not loaded.
    mutating func supplementEntries(
        for state: CodexTaskState,
        saved: [CodexPersistedTimelineItem]
    ) -> [CodexItemPageEntry] {
        guard !saved.isEmpty, let turns = state.thread?.turns, !turns.isEmpty else {
            supplements = nil
            return []
        }
        if supplements?.saved != saved {
            supplements = Supplements(saved: saved)
        }
        var indicesByTurnID: [String: [Int]] = [:]
        for index in turns.indices where supplements!.cardsByTurnID[turns[index].id] != nil {
            indicesByTurnID[turns[index].id, default: []].append(index)
        }
        var found: [(position: Int, entry: CodexItemPageEntry)] = []
        var results: [String: Supplements.TurnResult] = [:]
        for (turnID, indices) in indicesByTurnID {
            let itemsByIndex = indices.map { turns[$0].items }
            let firstStatus = turns[indices[0]].status
            let result: Supplements.TurnResult
            if let previous = supplements!.results[turnID],
               previous.firstStatus == firstStatus, previous.items == itemsByIndex {
                result = previous
            } else {
                result = Supplements.TurnResult(
                    items: itemsByIndex,
                    firstStatus: firstStatus,
                    entries: Self.supplement(
                        supplements!.cardsByTurnID[turnID] ?? [],
                        turns: indices.map { turns[$0] }
                    )
                )
            }
            results[turnID] = result
            found.append(contentsOf: result.entries)
        }
        supplements!.results = results
        return found.sorted { $0.position < $1.position }.map(\.entry)
    }

    private var supplements: Supplements?

    /// The saved cards grouped by turn, and what each loaded turn took from them last time.
    private struct Supplements {
        struct TurnResult {
            let items: [[CodexItemState]]
            let firstStatus: CodexTurnStatus
            let entries: [(position: Int, entry: CodexItemPageEntry)]
        }

        let saved: [CodexPersistedTimelineItem]
        let cardsByTurnID: [String: [(position: Int, card: CodexPersistedTimelineItem)]]
        var results: [String: TurnResult] = [:]

        init(saved: [CodexPersistedTimelineItem]) {
            self.saved = saved
            var cards: [String: [(position: Int, card: CodexPersistedTimelineItem)]] = [:]
            for (position, card) in saved.enumerated() {
                cards[card.turnID, default: []].append((position, card))
            }
            cardsByTurnID = cards
        }
    }

    /// `turns` are every loaded turn with the cards' turn ID, in thread order.
    private static func supplement(
        _ cards: [(position: Int, card: CodexPersistedTimelineItem)],
        turns: [CodexTurnState]
    ) -> [(position: Int, entry: CodexItemPageEntry)] {
        var live: [String: CodexItemLifecycle] = [:]
        for turn in turns {
            for index in turn.items.indices {
                let id = turn.items[index].id
                let lifecycle = turn.items[index].lifecycle
                live[id] = max(live[id] ?? lifecycle, lifecycle)
            }
        }
        var entries: [(position: Int, entry: CodexItemPageEntry)] = []
        for (position, card) in cards {
            let itemID = card.raw["id"]?.stringValue ?? card.id
            let lifecycle = CodexItemLifecycle(rawValue: card.lifecycleRawValue) ?? .historical
            if let current = live[itemID], current >= lifecycle { continue }
            let entry = card.pageEntry
            if case .agentMessage = entry.item.content {
                guard turns[0].status == .interrupted,
                      !turns[0].items.contains(where: { $0.id == entry.item.id }) else { continue }
            }
            entries.append((position, entry))
        }
        return entries
    }
}
