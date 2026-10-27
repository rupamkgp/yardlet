import Foundation

/// Side by side (`horizontal`) or stacked (`vertical`).
enum SplitAxis: String, Codable, Sendable {
    case horizontal
    case vertical
}

/// Where a split places the new pane relative to the pane it splits. The menu and shortcuts
/// split right and down; a dropped task can land on any of the four sides.
enum SplitDirection: String, Codable, Sendable, CaseIterable {
    case right
    case down
    case left
    case up

    var axis: SplitAxis { self == .right || self == .left ? .horizontal : .vertical }
    var placesAfter: Bool { self == .right || self == .down }
}

/// Keyboard pane navigation inside one split view.
enum PaneFocusDirection: String, Codable, Sendable, CaseIterable {
    case left
    case right
    case up
    case down
}

/// One pane is one session. A pane without a session shows the new-task composer rather than
/// becoming an independent conversation-free surface.
struct SplitPane: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var sessionID: UUID?

    init(id: UUID = UUID(), sessionID: UUID? = nil) {
        self.id = id
        self.sessionID = sessionID
    }
}

/// A pane arrangement as a split tree, the model tmux, iTerm, and editor groups use. A branch
/// lays its children along one axis and shares that axis by `fractions`; any pane can split
/// again, so there is no fixed grid.
indirect enum SplitNode: Codable, Hashable, Sendable {
    case pane(SplitPane)
    case branch(axis: SplitAxis, children: [SplitNode], fractions: [Double])

    private enum CodingKeys: String, CodingKey {
        case kind, id, sessionID, axis, children, fractions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if try container.decodeIfPresent(String.self, forKey: .kind) == "branch" {
            self = .branch(
                axis: try container.decodeIfPresent(SplitAxis.self, forKey: .axis) ?? .horizontal,
                children: try container.decodeIfPresent([SplitNode].self, forKey: .children) ?? [],
                fractions: try container.decodeIfPresent([Double].self, forKey: .fractions) ?? []
            )
        } else {
            self = .pane(SplitPane(
                id: try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
                sessionID: try container.decodeIfPresent(UUID.self, forKey: .sessionID)
            ))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .pane(pane):
            try container.encode("pane", forKey: .kind)
            try container.encode(pane.id, forKey: .id)
            try container.encodeIfPresent(pane.sessionID, forKey: .sessionID)
        case let .branch(axis, children, fractions):
            try container.encode("branch", forKey: .kind)
            try container.encode(axis, forKey: .axis)
            try container.encode(children, forKey: .children)
            try container.encode(fractions, forKey: .fractions)
        }
    }

    // MARK: - Reading

    /// Panes in reading order: left to right, then top to bottom within each branch.
    var panes: [SplitPane] {
        switch self {
        case let .pane(pane): [pane]
        case let .branch(_, children, _): children.flatMap(\.panes)
        }
    }

    /// Each pane's rectangle inside `bounds`, used for directional focus movement.
    func frames(in bounds: SplitRect = .unit) -> [UUID: SplitRect] {
        switch self {
        case let .pane(pane):
            return [pane.id: bounds]
        case let .branch(axis, children, fractions):
            var result: [UUID: SplitRect] = [:]
            var offset = 0.0
            for (child, fraction) in zip(children, fractions) {
                let rect = axis == .horizontal
                    ? SplitRect(x: bounds.x + bounds.width * offset, y: bounds.y,
                                width: bounds.width * fraction, height: bounds.height)
                    : SplitRect(x: bounds.x, y: bounds.y + bounds.height * offset,
                                width: bounds.width, height: bounds.height * fraction)
                result.merge(child.frames(in: rect)) { first, _ in first }
                offset += fraction
            }
            return result
        }
    }

    // MARK: - Changes

    /// Places `newPane` beside `target`. A branch already laid along the split's axis gains a
    /// sibling that takes half of the target's share; otherwise the target becomes a new branch.
    func splitting(_ target: UUID, direction: SplitDirection, with newPane: SplitPane) -> SplitNode {
        switch self {
        case let .pane(pane):
            guard pane.id == target else { return self }
            let children: [SplitNode] = direction.placesAfter
                ? [.pane(pane), .pane(newPane)]
                : [.pane(newPane), .pane(pane)]
            return .branch(axis: direction.axis, children: children, fractions: [0.5, 0.5])
        case let .branch(axis, children, fractions):
            if axis == direction.axis,
               let index = children.firstIndex(where: { if case let .pane(pane) = $0 { pane.id == target } else { false } }) {
                var children = children
                var fractions = fractions
                let half = fractions[index] / 2
                fractions[index] = half
                let insertion = direction.placesAfter ? index + 1 : index
                children.insert(.pane(newPane), at: insertion)
                fractions.insert(half, at: insertion)
                return .branch(axis: axis, children: children, fractions: fractions)
            }
            return .branch(
                axis: axis,
                children: children.map { $0.splitting(target, direction: direction, with: newPane) },
                fractions: fractions
            )
        }
    }

    /// Removes a pane. A branch left with one child is replaced by that child, and a child branch
    /// that ends up on its parent's axis merges into the parent, so the tree stays minimal.
    func removing(_ target: UUID) -> SplitNode? {
        switch self {
        case let .pane(pane):
            return pane.id == target ? nil : self
        case let .branch(axis, children, fractions):
            var kept: [(SplitNode, Double)] = []
            for (child, fraction) in zip(children, fractions) {
                if let remaining = child.removing(target) { kept.append((remaining, fraction)) }
            }
            return SplitNode.branch(axis: axis, children: kept.map(\.0), fractions: kept.map(\.1))
                .normalized()
        }
    }

    func mapPanes(_ transform: (SplitPane) -> SplitPane) -> SplitNode {
        switch self {
        case let .pane(pane):
            return .pane(transform(pane))
        case let .branch(axis, children, fractions):
            return .branch(axis: axis, children: children.map { $0.mapPanes(transform) }, fractions: fractions)
        }
    }

    /// Replaces the fractions of the branch at `path` (child indexes from the root).
    func resizing(at path: [Int], fractions newFractions: [Double]) -> SplitNode {
        guard case let .branch(axis, children, fractions) = self else { return self }
        guard let first = path.first else {
            guard newFractions.count == children.count else { return self }
            return SplitNode.branch(axis: axis, children: children, fractions: newFractions).normalized() ?? self
        }
        guard children.indices.contains(first) else { return self }
        var resized = children
        resized[first] = children[first].resizing(at: Array(path.dropFirst()), fractions: newFractions)
        return .branch(axis: axis, children: resized, fractions: fractions)
    }

    /// Repairs a decoded or edited tree: fractions match children and sum to one, empty branches
    /// disappear, single-child branches collapse, and same-axis child branches merge upward.
    func normalized() -> SplitNode? {
        switch self {
        case .pane:
            return self
        case let .branch(axis, children, fractions):
            var shares = fractions.count == children.count ? fractions : Array(repeating: 1, count: children.count)
            shares = shares.map { $0.isFinite && $0 > 0 ? $0 : 1 }
            var flattened: [(SplitNode, Double)] = []
            for (child, share) in zip(children, shares) {
                guard let child = child.normalized() else { continue }
                if case let .branch(childAxis, grandchildren, childFractions) = child, childAxis == axis {
                    for (grandchild, childShare) in zip(grandchildren, childFractions) {
                        flattened.append((grandchild, share * childShare))
                    }
                } else {
                    flattened.append((child, share))
                }
            }
            guard !flattened.isEmpty else { return nil }
            guard flattened.count > 1 else { return flattened[0].0 }
            let total = flattened.map(\.1).reduce(0, +)
            return .branch(
                axis: axis,
                children: flattened.map(\.0),
                fractions: flattened.map { $0.1 / total }
            )
        }
    }
}

/// A rectangle in the split view's unit square.
struct SplitRect: Equatable, Sendable {
    static let unit = SplitRect(x: 0, y: 0, width: 1, height: 1)

    var x: Double
    var y: Double
    var width: Double
    var height: Double

    var maxX: Double { x + width }
    var maxY: Double { y + height }
    var midX: Double { x + width / 2 }
    var midY: Double { y + height / 2 }
}

/// A split view: several sessions arranged in one window, shown in the sidebar as one row beside
/// ordinary task rows. The split owns which session sits in which pane and which pane has focus;
/// the session layer inside a pane keeps its own panel state.
struct SplitGroup: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    /// A name the user gave the split. Without one, the row reads its sessions' titles.
    var customName: String?
    var isPinned: Bool
    /// The first session placed. Its project is where the row appears in the sidebar.
    private(set) var anchorSessionID: UUID?
    private(set) var root: SplitNode
    private(set) var focusedPaneID: UUID

    init(
        id: UUID = UUID(),
        customName: String? = nil,
        isPinned: Bool = false,
        anchorSessionID: UUID? = nil,
        root: SplitNode,
        focusedPaneID: UUID? = nil
    ) {
        self.id = id
        self.customName = customName
        self.isPinned = isPinned
        self.anchorSessionID = anchorSessionID
        self.root = root
        self.focusedPaneID = focusedPaneID ?? root.panes.first?.id ?? UUID()
        normalize()
    }

    private enum CodingKeys: String, CodingKey {
        case id, customName, isPinned, anchorSessionID, root, focusedPaneID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        customName = try container.decodeIfPresent(String.self, forKey: .customName)
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        anchorSessionID = try container.decodeIfPresent(UUID.self, forKey: .anchorSessionID)
        root = try container.decodeIfPresent(SplitNode.self, forKey: .root) ?? .pane(SplitPane())
        focusedPaneID = try container.decodeIfPresent(UUID.self, forKey: .focusedPaneID) ?? UUID()
        normalize()
    }

    // MARK: - Reading

    var panes: [SplitPane] { root.panes }

    var focusedPane: SplitPane {
        panes.first { $0.id == focusedPaneID } ?? panes[0]
    }

    var focusedSessionID: UUID? { focusedPane.sessionID }

    var sessionIDs: [UUID] { panes.compactMap(\.sessionID) }

    /// A split exists to show more than one pane; one left means the split has ended.
    var isComplete: Bool { panes.count > 1 && !sessionIDs.isEmpty }

    func pane(hosting sessionID: UUID) -> SplitPane? {
        panes.first { $0.sessionID == sessionID }
    }

    // MARK: - Layout changes

    @discardableResult
    mutating func split(
        _ direction: SplitDirection,
        from paneID: UUID? = nil,
        placing sessionID: UUID? = nil
    ) -> UUID {
        let target = paneID.flatMap { id in panes.contains { $0.id == id } ? id : nil } ?? focusedPaneID
        let pane = SplitPane(sessionID: sessionID)
        root = root.splitting(target, direction: direction, with: pane)
        focusedPaneID = pane.id
        normalize()
        return pane.id
    }

    /// Removes a pane and returns it. Focus moves to the pane nearest the removed one.
    @discardableResult
    mutating func closePane(_ id: UUID) -> SplitPane? {
        guard let removed = panes.first(where: { $0.id == id }), panes.count > 1 else { return nil }
        let frames = root.frames()
        guard let remaining = root.removing(id) else { return nil }
        root = remaining
        if focusedPaneID == id, let removedFrame = frames[id] {
            focusedPaneID = nearestPane(to: removedFrame, among: frames)?.id ?? panes[0].id
        }
        normalize()
        return removed
    }

    @discardableResult
    mutating func focus(paneID: UUID) -> Bool {
        guard panes.contains(where: { $0.id == paneID }), focusedPaneID != paneID else { return false }
        focusedPaneID = paneID
        return true
    }

    /// Moves focus to the nearest pane in `direction`, preferring panes that overlap the current
    /// pane across the movement axis.
    @discardableResult
    mutating func moveFocus(_ direction: PaneFocusDirection) -> Bool {
        let frames = root.frames()
        guard let current = frames[focusedPaneID] else { return false }
        let epsilon = 1e-6
        let candidates = panes.compactMap { pane -> (SplitPane, SplitRect)? in
            guard pane.id != focusedPaneID, let rect = frames[pane.id] else { return nil }
            let inDirection = switch direction {
            case .left: rect.maxX <= current.x + epsilon
            case .right: rect.x >= current.maxX - epsilon
            case .up: rect.maxY <= current.y + epsilon
            case .down: rect.y >= current.maxY - epsilon
            }
            return inDirection ? (pane, rect) : nil
        }
        guard let target = candidates.min(by: {
            navigationKey($0.1, direction: direction, from: current)
                < navigationKey($1.1, direction: direction, from: current)
        }) else { return false }
        return focus(paneID: target.0.id)
    }

    mutating func resize(at path: [Int], fractions: [Double]) {
        root = root.resizing(at: path, fractions: fractions)
        normalize()
    }

    // MARK: - Session placement

    /// Puts a session in a pane, replacing whatever the pane showed.
    mutating func place(_ sessionID: UUID, in paneID: UUID) {
        root = root.mapPanes { pane in
            var pane = pane
            if pane.id == paneID { pane.sessionID = sessionID }
            else if pane.sessionID == sessionID { pane.sessionID = nil }
            return pane
        }
        focusedPaneID = paneID
        normalize()
    }

    /// Two panes change places: each shows the other's task, and the focus goes with the first's task.
    mutating func swap(_ first: UUID, _ second: UUID) {
        guard let a = panes.first(where: { $0.id == first }), let b = panes.first(where: { $0.id == second }),
              first != second else { return }
        root = root.mapPanes { pane in
            var pane = pane
            if pane.id == first { pane.sessionID = b.sessionID }
            else if pane.id == second { pane.sessionID = a.sessionID }
            return pane
        }
        focusedPaneID = second
        normalize()
    }

    /// Removes a session's pane. The split may end up with a single pane, which the owner treats
    /// as the split having ended.
    mutating func removeSession(_ sessionID: UUID) {
        guard let pane = pane(hosting: sessionID) else { return }
        if panes.count > 1 {
            closePane(pane.id)
        } else {
            root = .pane(SplitPane(id: pane.id))
            normalize()
        }
    }

    /// Restoration drops sessions that no longer exist.
    mutating func retainSessions(_ known: Set<UUID>) {
        for sessionID in sessionIDs where !known.contains(sessionID) {
            removeSession(sessionID)
        }
    }

    // MARK: - Internals

    private func nearestPane(to rect: SplitRect, among frames: [UUID: SplitRect]) -> SplitPane? {
        panes.min { lhs, rhs in
            distance(frames[lhs.id], rect) < distance(frames[rhs.id], rect)
        }
    }

    private func distance(_ lhs: SplitRect?, _ rhs: SplitRect) -> Double {
        guard let lhs else { return .infinity }
        return abs(lhs.midX - rhs.midX) + abs(lhs.midY - rhs.midY)
    }

    private func navigationKey(
        _ rect: SplitRect,
        direction: PaneFocusDirection,
        from current: SplitRect
    ) -> (Double, Double) {
        switch direction {
        case .left: (current.x - rect.maxX, abs(rect.midY - current.midY))
        case .right: (rect.x - current.maxX, abs(rect.midY - current.midY))
        case .up: (current.y - rect.maxY, abs(rect.midX - current.midX))
        case .down: (rect.y - current.maxY, abs(rect.midX - current.midX))
        }
    }

    private mutating func normalize() {
        var root = self.root.normalized() ?? .pane(SplitPane())
        var usedPanes = Set<UUID>()
        var usedSessions = Set<UUID>()
        root = root.mapPanes { pane in
            var pane = pane
            if !usedPanes.insert(pane.id).inserted { pane.id = UUID() }
            if let sessionID = pane.sessionID, !usedSessions.insert(sessionID).inserted {
                pane.sessionID = nil
            }
            return pane
        }
        self.root = root
        if !root.panes.contains(where: { $0.id == focusedPaneID }) {
            focusedPaneID = root.panes[0].id
        }
        let sessions = root.panes.compactMap(\.sessionID)
        if anchorSessionID.map({ !sessions.contains($0) }) ?? true {
            anchorSessionID = sessions.first
        }
        if let name = customName?.trimmingCharacters(in: .whitespacesAndNewlines), name.isEmpty {
            customName = nil
        }
    }
}

/// What the window shows: the new-task composer, one task, or a split view.
enum WindowItem: Codable, Hashable, Sendable {
    case home
    case session(UUID)
    case split(UUID)

    private enum CodingKeys: String, CodingKey {
        case kind, id
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decodeIfPresent(UUID.self, forKey: .id)
        switch try container.decodeIfPresent(String.self, forKey: .kind) {
        case "session": self = id.map(WindowItem.session) ?? .home
        case "split": self = id.map(WindowItem.split) ?? .home
        default: self = .home
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .home:
            try container.encode("home", forKey: .kind)
        case let .session(id):
            try container.encode("session", forKey: .kind)
            try container.encode(id, forKey: .id)
        case let .split(id):
            try container.encode("split", forKey: .kind)
            try container.encode(id, forKey: .id)
        }
    }
}
