import Foundation

/// The latest turns a conversation draws (plan A5.3, D11): the 10 most recent. The renderer draws the
/// window's turns and counts the rest as `earlier = .local`, which scrolling up to the top and the
/// turn rail's "Load more history" bring in 10 at a time. Going back to the latest output draws the
/// latest 10 again (`ConversationTimeline`).
///
/// The renderer lays the window's turns out whole, in an eager stack (`ConversationTimeline`), so the
/// window is what a conversation costs to draw: 10 turns of a working conversation are several
/// screens, and drawing them whole cost about what drawing the latest 40 lazily did.
///
/// A shared transcript holds every turn it has (a Claude conversation read from its saved file, as
/// far back as its reads went, `ClaudeTranscriptTail`). A Codex thread holds the pages
/// it loaded, and the window applies to those: the provider's earlier pages (`earlier = .provider`)
/// are asked for only once every loaded turn is drawn.
struct ConversationTurnWindow: Equatable, Sendable {
    static let initialTurnCount = 10
    /// The turns "Load more history" and scrolling up to the top add.
    static let step = 10

    /// How many of the latest turns are drawn.
    var turnCount: Int = Self.initialTurnCount
    /// A turn kept in the window however many turns follow it, with every turn after it: one the
    /// reader went to (a find match, a saved place).
    var earliestTurnID: String? = nil

    /// `presentation` with only the window's turns, the rest counted as earlier turns. Turns the
    /// provider still holds behind its cursor stay its own until the window holds every loaded turn.
    func apply(to presentation: ConversationPresentation) -> ConversationPresentation {
        let turns = presentation.turns
        var start = max(0, turns.count - max(1, turnCount))
        if let earliestTurnID, let index = turns.firstIndex(where: { $0.id == earliestTurnID }) {
            start = min(start, index)
        }
        guard start > 0 else { return presentation }
        var windowed = presentation
        windowed.turns = Array(turns[start...])
        windowed.earlier = .local(hiddenCount: start)
        return windowed
    }

    /// The window with `step` more turns.
    func widened() -> ConversationTurnWindow {
        var window = self
        window.turnCount += Self.step
        return window
    }

    /// Whether `presentation` holds `turnID` but the window leaves it out.
    func hides(_ turnID: String, in presentation: ConversationPresentation) -> Bool {
        presentation.turns.contains { $0.id == turnID }
            && !apply(to: presentation).turns.contains { $0.id == turnID }
    }
}
