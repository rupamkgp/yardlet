import Foundation

/// One tab of the window's tab strip: what the tab shows and the state its mark carries, the same
/// state the item's sidebar row shows.
struct WindowTab: Identifiable, Equatable {
    enum Kind: Equatable {
        case newTask
        case task(HarnessKind)
        case split(isVertical: Bool)
    }

    let id: WindowItem
    let title: String
    let kind: Kind
    let status: SidebarTaskStatus?
    let hasUnreadUpdate: Bool
}

enum WindowTabProjection {
    /// The tabs in order. A tab whose task is not in the index yet (while it loads) is left out
    /// rather than drawn without a title.
    static func tabs(
        _ items: [WindowItem],
        sessions: [SessionRecord],
        splits: [SplitGroup],
        details: [UUID: TaskAttentionDetail] = [:],
        shellBusy: Set<UUID> = []
    ) -> [WindowTab] {
        let byID = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return items.compactMap { item in
            switch item {
            case .home:
                return WindowTab(id: item, title: L10n.string("New task"), kind: .newTask,
                                 status: nil, hasUnreadUpdate: false)
            case let .session(id):
                guard let session = byID[id] else { return nil }
                return WindowTab(
                    id: item, title: session.title, kind: .task(session.harness),
                    status: SidebarTaskIndicatorProjection.status(of: session, detail: details[id],
                                                                  isShellBusy: shellBusy.contains(id)),
                    hasUnreadUpdate: session.hasUnreadUpdate)
            case let .split(id):
                guard let split = splits.first(where: { $0.id == id }) else { return nil }
                let members = split.sessionIDs.compactMap { byID[$0] }
                guard !members.isEmpty else { return nil }
                var isVertical = false
                if case let .branch(axis, _, _) = split.root { isVertical = axis == .vertical }
                return WindowTab(
                    id: item,
                    title: split.customName ?? members.map(\.title).joined(separator: " + "),
                    kind: .split(isVertical: isVertical),
                    status: SidebarTaskIndicatorProjection.summary(of: members, details: details, shellBusy: shellBusy),
                    hasUnreadUpdate: members.contains(where: \.hasUnreadUpdate))
            }
        }
    }
}
