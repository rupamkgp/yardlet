import Foundation
import Observation

/// What the rail's Preview card shows while the agent works where the person cannot see it: the
/// task's browser tab the agent drives, or the screen a computer-use tool last returned. It is the
/// Codex app's Computer Use picture in picture (`computer-use-pip`, Browser Use and Computer Use
/// previews): there it appears once a computer-use or browser-use call starts in the thread, goes at
/// `turn/completed` (or when the browser session ends or has no tab), and is left out while the side
/// panel shows the browser tab itself. Yardlet follows the same: the card is there while the task's
/// turn runs after the agent used the browser or a computer-use tool in it, and not while the side
/// panel shows that browser tab (another of the task's browser tabs there does not hide it).
struct SessionRailPreview: Equatable {
    enum Source: Equatable {
        /// The task's browser tab the agent last drove, drawn from the frames the host already sends.
        case browser(tab: BrowserTabID)
        /// The last screenshot a Codex computer-use call returned in the running turn (Yardlet has
        /// no computer use of its own).
        case computer(SessionRailComputerFrame)
    }

    var source: Source
    /// The page's title, or the tool that took the screenshot.
    var caption: String

    /// The folded card's words: what is being used.
    var title: String {
        switch source {
        case .browser: L10n.string("Browser")
        case .computer: L10n.string("Computer use")
        }
    }

    /// The browser preview, when the agent used the task's browser in the turn running now and the
    /// side panel does not show the tab it used.
    static func browser(tab: BrowserTabID?, title: String?, isTurnRunning: Bool, panelShowsBrowser: Bool) -> Self? {
        guard let tab, isTurnRunning, !panelShowsBrowser else { return nil }
        let caption = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return SessionRailPreview(source: .browser(tab: tab), caption: caption.isEmpty ? L10n.string("Browser") : caption)
    }
}

/// A computer-use screenshot: the call that returned it and its image. Two frames are the same when
/// they come from the same block, so the card does not compare image bytes as the task streams.
struct SessionRailComputerFrame: Equatable {
    let id: String
    let data: Data
    let mimeType: String

    static func == (left: Self, right: Self) -> Bool { left.id == right.id }

    /// The servers the Codex app counts as computer use (`Nce`: `computer-use`), and the plugin's
    /// other names for the same tools.
    static func isComputerUse(server: String) -> Bool {
        let name = server.lowercased()
        return name == "computer-use" || name == "computer_use" || name.hasSuffix("computer-use")
    }

    /// The newest screenshot a computer-use call returned in the Codex thread's running turn; nil
    /// when no turn runs or no such call returned an image. A block's bytes are decoded once.
    @MainActor
    static func latest(in state: CodexTaskState?) -> SessionRailComputerFrame? {
        guard let state, let turnID = state.activeTurnID,
              let turn = state.thread?.turns.last(where: { $0.id == turnID }) else { return nil }
        for item in turn.items.reversed() {
            guard case let .mcpToolCall(tool) = item.content, isComputerUse(server: tool.server),
                  let result = tool.result else { continue }
            let key = "\(state.thread?.id ?? "")|\(turnID)|\(item.id)"
            if let cached = cache[key] { return cached }
            let blocks = CodexMCPResultProjection(result: result, itemID: item.id).blocks
            for block in blocks.reversed() {
                if case let .image(id, data, mimeType) = block {
                    let frame = SessionRailComputerFrame(id: id, data: data, mimeType: mimeType)
                    remember(frame, for: key)
                    return frame
                }
            }
        }
        return nil
    }

    /// Decoded frames by thread, turn and item, newest few only: a turn moves on to the next screenshot.
    @MainActor private static var cache: [String: SessionRailComputerFrame] = [:]
    @MainActor private static var cacheOrder: [String] = []

    @MainActor private static func remember(_ frame: SessionRailComputerFrame, for key: String) {
        cache[key] = frame
        cacheOrder.append(key)
        while cacheOrder.count > 4 { cache[cacheOrder.removeFirst()] = nil }
    }
}

/// The browser tab the agent drives in each task's running turn: set as the agent uses a tab
/// (`BrowserHostClient.onAgentActivity`), cleared when the task's turn ends or the tab closes. Only a
/// change of tab is published, so the agent's many calls do not redraw the rail.
@MainActor
@Observable
final class BrowserAgentUse {
    static let shared = BrowserAgentUse()

    private(set) var tabs: [UUID: BrowserTabID] = [:]

    func noteUse(session: UUID, tab: BrowserTabID) {
        guard tabs[session] != tab else { return }
        tabs[session] = tab
    }

    /// The task's turn ended: the preview goes, as the Codex app's at `turn/completed`.
    func endTurn(session: UUID) {
        guard tabs[session] != nil else { return }
        tabs[session] = nil
    }

    func tabClosed(_ tab: BrowserTabID) {
        for (session, used) in tabs where used == tab { tabs[session] = nil }
    }
}
