import SwiftUI

private struct WorkSurfaceExpansionKey: EnvironmentKey {
    static let defaultValue: Binding<Bool>? = nil
}

struct WorkSurfaceTab: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let systemName: String
    /// A choice the task cannot open stays in the menu, dimmed, so every harness shows the same menu.
    var isAvailable = true
    /// Another task's conversation shows its harness's mark in place of the symbol.
    var harness: HarnessKind? = nil
    /// The key that opens it, which the launcher shows beside it as the Codex app's does.
    var shortcut: String? = nil
    /// Under the title in the launcher: another task's project.
    var detail: String? = nil
    /// A browser tab's page icon (PNG), shown in place of the symbol.
    var favicon: Data? = nil
    /// A browser tab whose page is loading.
    var isLoading = false
}

/// A task's side-panel tabs and + menu. They are the same for every harness.
enum TaskSidePanelTabs {
    /// The tab another task's conversation shows as.
    static func taskTab(_ session: SessionRecord, project: String? = nil) -> WorkSurfaceTab {
        WorkSurfaceTab(id: TaskSurfaceNavigationProjection.taskTabID(session.id), title: session.title,
                       systemName: "text.bubble", harness: session.harness, detail: project)
    }

    /// One of the task's browser tabs: its page's title and icon, as the Codex app's side panel shows a
    /// browser tab.
    @MainActor
    static func browserTab(_ key: UUID, in tabs: TaskBrowserTabs) -> WorkSurfaceTab {
        let tab = tabs.tab(key)
        return WorkSurfaceTab(id: TaskSurfaceNavigationProjection.browserTabID(key),
                              title: BrowserTabTitle.make(pageTitle: tab?.title ?? "", address: tab?.address),
                              systemName: "globe", favicon: tab?.favicon, isLoading: tab?.isLoading ?? false)
    }

    @MainActor
    static func tab(_ id: String, selectedFilePath: String?, browserTabs: TaskBrowserTabs? = nil) -> WorkSurfaceTab? {
        if let key = TaskSurfaceNavigationProjection.browserKey(inTab: id) {
            return browserTabs.map { browserTab(key, in: $0) }
        }
        return switch id {
        case "diff":
            WorkSurfaceTab(id: id, title: L10n.string("Review"), systemName: "plus.rectangle")
        case "files":
            WorkSurfaceTab(id: id, title: selectedFilePath.map { URL(filePath: $0).lastPathComponent } ?? L10n.string("Files"),
                           systemName: selectedFilePath == nil ? "folder" : "doc.text")
        case "sideChat":
            WorkSurfaceTab(id: id, title: L10n.string("Side chat"), systemName: "bubble.left.and.bubble.right")
        default:
            nil
        }
    }

    /// The launcher's and the + menu's choices, in the Codex app's order (`Wjl`): in a repository
    /// Review, Terminal, Browser, Files, then Side chat; elsewhere, where the Codex app offers no
    /// Changes, Files, Side chat, Browser and Terminal. Terminal opens below the conversation.
    /// - Parameter offersReview: false when no repository holds the task's folders and no turn
    ///   reported its changes; nil while that is not known yet, which offers it.
    static func choices(canOpenSideChat: Bool, offersReview: Bool? = nil) -> [WorkSurfaceTab] {
        let review = WorkSurfaceTab(id: "diff", title: L10n.string("Review"), systemName: "plus.rectangle",
                                    shortcut: "⌘2")
        let terminal = WorkSurfaceTab(id: "terminal", title: L10n.string("Terminal"), systemName: "terminal",
                                      shortcut: "⌘3")
        let browser = WorkSurfaceTab(id: "browser", title: L10n.string("Browser"), systemName: "globe",
                                     shortcut: "⌘4")
        let files = WorkSurfaceTab(id: "files", title: L10n.string("Files"), systemName: "folder")
        let sideChat = WorkSurfaceTab(id: "sideChat", title: L10n.string("Side chat"),
                                      systemName: "bubble.left.and.bubble.right", isAvailable: canOpenSideChat)
        return offersReview == false
            ? [files, sideChat, browser, terminal]
            : [review, terminal, browser, files, sideChat]
    }
}

extension TaskSidePanelTabs {
    /// The new-task screen's choices, in the order the Claude app's New session header has them:
    /// Terminal, Browser, Files. Review and Side chat need a task.
    static var draftChoices: [WorkSurfaceTab] {
        let all = choices(canOpenSideChat: false)
        return ["terminal", "browser", "files"].compactMap { id in all.first { $0.id == id } }
    }
}

/// The side panel's tab strip, as in the Codex app: its open tabs, a + menu that opens another
/// panel, and closing the panel. The shown pane supplies its own tab's title and close action.
struct WorkSurfaceNavigation: Sendable {
    var tabs: [WorkSurfaceTab]
    var activeID: String?
    var choices: [WorkSurfaceTab]
    /// Recent tasks whose conversations the + menu's Tasks submenu opens as tabs; its "All Tasks…"
    /// opens the launcher (`open(launcherID)`). Read by the menu itself, so the task list it reads
    /// redraws the menu alone.
    var taskChoices: @MainActor @Sendable () -> [WorkSurfaceTab] = { [] }
    /// Shows an open tab.
    var select: @MainActor @Sendable (String) -> Void
    /// Opens a + menu choice.
    var open: @MainActor @Sendable (String) -> Void
    var closeTab: @MainActor @Sendable (String) -> Void
    /// Closes several tabs at once: a tab menu's Close Other Tabs and Close Tabs to the Right.
    var closeTabs: @MainActor @Sendable ([String]) -> Void = { _ in }
    var closePanel: @MainActor @Sendable () -> Void
    /// A browser tab's own items in its tab menu; nil leaves them out.
    var browserMenu: BrowserTabMenuActions? = nil
    /// Whose panel it is (a task, or the new-task screen's `TaskWorkspaceStore.draftID`): its tabs drag
    /// along the strip, and another task's conversation drags out to a pane or the window's tabs
    /// (`WindowDragState`). Nil where the tabs do not drag.
    var owner: UUID? = nil
}

private struct WorkSurfaceNavigationKey: EnvironmentKey {
    static let defaultValue: WorkSurfaceNavigation? = nil
}

extension EnvironmentValues {
    var workSurfaceExpansion: Binding<Bool>? {
        get { self[WorkSurfaceExpansionKey.self] }
        set { self[WorkSurfaceExpansionKey.self] = newValue }
    }
    var workSurfaceNavigation: WorkSurfaceNavigation? {
        get { self[WorkSurfaceNavigationKey.self] }
        set { self[WorkSurfaceNavigationKey.self] = newValue }
    }
}

struct WorkSurfacePanelControls: View {
    @Environment(\.workSurfaceExpansion) private var expansion
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            if let expansion {
                ParityIconButton(
                    systemName: expansion.wrappedValue ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                    help: L10n.string(expansion.wrappedValue ? "Restore split view" : "Expand panel")
                ) { expansion.wrappedValue.toggle() }
            }
            ParityIconButton(systemName: "xmark", help: L10n.string("Close panel"), action: onClose)
        }
    }
}

struct WorkSurfaceHeader<Trailing: View>: View {
    @Environment(\.workSurfaceNavigation) private var navigation
    /// The panel's tab strip shares the task area's header row (`TaskWorkspaceLayout`).
    @Environment(\.workSurfaceHeaderRow) private var sharedRow
    @Environment(\.windowDrag) private var drag
    /// The tabs' frames in the window, and the strip's, for dragging a tab along it.
    @State private var tabFrames: [String: CGRect] = [:]
    @State private var stripFrame: CGRect = .zero
    /// This strip's registration, which a strip that replaced it keeps.
    @State private var token = UUID()
    let title: String
    let systemName: String
    /// Another task's conversation shows its harness's mark in place of the symbol.
    var harness: HarnessKind? = nil
    /// A browser tab shows its page's icon in place of the symbol, and a spinner while it loads.
    var favicon: Data? = nil
    var isLoading = false
    let workspaceURL: URL
    let status: String?
    let statusTint: Color
    let onClose: () -> Void
    @ViewBuilder let trailing: () -> Trailing

    init(
        title: String,
        systemName: String,
        harness: HarnessKind? = nil,
        favicon: Data? = nil,
        isLoading: Bool = false,
        workspaceURL: URL,
        status: String? = nil,
        statusTint: Color = .secondary,
        onClose: @escaping () -> Void,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.title = title
        self.systemName = systemName
        self.harness = harness
        self.favicon = favicon
        self.isLoading = isLoading
        self.workspaceURL = workspaceURL
        self.status = status
        self.statusTint = statusTint
        self.onClose = onClose
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 4) {
            if let navigation {
                // Tabs that are not shown keep their titles while they fit, then only their icons.
                ViewThatFits(in: .horizontal) {
                    tabStrip(navigation, compact: false)
                    tabStrip(navigation, compact: true)
                }
                if !navigation.choices.isEmpty {
                    WorkSurfaceOpenMenu(choices: navigation.choices, taskChoices: navigation.taskChoices,
                                        onSelect: navigation.open)
                }
            } else {
                activeTab
            }
            // In the window's title bar, the strip's empty part moves the window as the rest of the bar does.
            if row?.isTitleBar == true {
                WindowDragRegion().frame(minWidth: 0, maxWidth: .infinity)
            } else {
                Spacer(minLength: 0)
            }
            if let status {
                // The tabs keep their room; a long status shortens first.
                Text(status).font(.caption).foregroundStyle(statusTint)
                    .lineLimit(1).truncationMode(.middle).help(status)
                    .layoutPriority(-1)
            }
            trailing().fixedSize(horizontal: true, vertical: false)
            WorkSurfacePanelControls(onClose: navigation?.closePanel ?? onClose)
        }
        .padding(.horizontal, 8)
        .frame(height: row?.height ?? 42)
        .background(ParityTheme.canvas)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { stripFrame = $0 }
        .onChange(of: stripFrame, initial: true) { registerStrip() }
        .onChange(of: tabFrames, initial: true) { registerStrip() }
        .onChange(of: navigation?.tabs.map(\.id)) { registerStrip() }
        .onDisappear {
            if let owner = navigation?.owner { drag?.removePanelStrip(owner: owner, token: token) }
        }
    }

    private func registerStrip() {
        guard let navigation, let owner = navigation.owner else { return }
        let ids = navigation.tabs.map(\.id)
        let frames = ids.compactMap { tabFrames[$0] }
        guard frames.count == ids.count else { return }
        drag?.setPanelStrip(WindowDropGeometry.Strip(frame: stripFrame, tabs: frames, ids: ids.map(AnyHashable.init)),
                            owner: owner, token: token)
    }

    /// The tab of this strip being dragged along it, and the gap it would take.
    private func slide(_ index: Int, _ navigation: WorkSurfaceNavigation) -> CGFloat {
        guard let drag, let owner = navigation.owner, case let .panelTab(from, tabID)? = drag.subject, from == owner,
              let dragged = navigation.tabs.firstIndex(where: { $0.id == tabID }) else { return 0 }
        var gap: Int?
        if case let .panelTabs(target, index)? = drag.target, target == owner { gap = index }
        let width = (tabFrames[tabID]?.width ?? 0) + 4
        return drag.slide(index: index, dragged: dragged, gap: gap, width: width,
                          tabs: navigation.tabs.compactMap { tabFrames[$0.id] })
    }

    private func dragPreview(_ tab: WorkSurfaceTab) -> WindowDragPreview {
        WindowDragPreview(title: tab.title, systemName: tab.systemName, harness: tab.harness)
    }

    /// The shared row applies to the panel's own strip, the header that shows its tabs; a header drawn
    /// lower in a tab's content keeps its own height.
    private var row: WorkSurfaceHeaderRow? { navigation == nil ? nil : sharedRow }

    private func tabStrip(_ navigation: WorkSurfaceNavigation, compact: Bool) -> some View {
        HStack(spacing: 4) {
            ForEach(Array(navigation.tabs.enumerated()), id: \.element.id) { index, tab in
                Group {
                    if tab.id == navigation.activeID {
                        activeTab
                            .contextMenu { WorkSurfaceTabMenu(tabID: tab.id, navigation: navigation) }
                    } else {
                        WorkSurfaceTabButton(tab: tab, compact: compact, onSelect: { navigation.select(tab.id) },
                                             onClose: { navigation.closeTab(tab.id) }) {
                            WorkSurfaceTabMenu(tabID: tab.id, navigation: navigation)
                        }
                    }
                }
                .modifier(PanelTabDrag(owner: navigation.owner, tab: tab.id, preview: dragPreview(tab)))
                .offset(x: slide(index, navigation))
                .zIndex(drag?.subject == navigation.owner.map { .panelTab(owner: $0, tab: tab.id) } ? 1 : 0)
                // Read outside the offset: where the tab is laid out, not where it slid.
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { tabFrames[tab.id] = $0 }
            }
            // A Claude subtask shows in the panel without becoming one of its tabs.
            if !navigation.tabs.contains(where: { $0.id == navigation.activeID }) { activeTab }
        }
        .animation(.easeOut(duration: 0.15), value: drag?.target)
    }

    private var activeTab: some View {
        HStack(spacing: 8) {
            WorkSurfaceTabIcon(systemName: systemName, harness: harness, favicon: favicon, isLoading: isLoading)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.callout)
                .lineLimit(1).truncationMode(.middle)
                .help(workspaceURL.path(percentEncoded: false))
                .accessibilityValue(workspaceURL.lastPathComponent)
            ParityIconButton(systemName: "xmark", help: L10n.string("Close tab"), action: onClose)
        }
        .padding(.leading, 10).padding(.trailing, 2)
        .frame(height: 30)
        .background(ParityTheme.selectedFill, in: RoundedRectangle(cornerRadius: 9))
        .layoutPriority(1)
    }
}

/// A side panel's tab drags along its strip, or another task's conversation out to a pane or the window's
/// tabs, where the panel has an owner.
private struct PanelTabDrag: ViewModifier {
    let owner: UUID?
    let tab: String
    let preview: WindowDragPreview

    func body(content: Content) -> some View {
        if let owner {
            content.windowDraggable(.panelTab(owner: owner, tab: tab), preview: preview)
        } else {
            content
        }
    }
}

/// A tab that is open in the side panel but not shown. Hovering a titled tab shows its close
/// button over the end of the title, so the strip does not shift; every tab closes from its menu.
private struct WorkSurfaceTabButton<Menu: View>: View {
    let tab: WorkSurfaceTab
    let compact: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    @ViewBuilder let menu: () -> Menu
    @State private var isHovering = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                WorkSurfaceTabIcon(systemName: tab.systemName, harness: tab.harness, favicon: tab.favicon,
                                   isLoading: tab.isLoading)
                if !compact {
                    Text(tab.title).font(.callout).lineLimit(1).truncationMode(.middle)
                }
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, compact ? 8 : 10)
            .frame(height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .parityPointer()
        .help(tab.title)
        .accessibilityLabel(tab.title)
        .accessibilityAction(named: Text(L10n.string("Close tab")), onClose)
        .contextMenu { menu() }
        .overlay(alignment: .trailing) {
            if isHovering, !compact {
                ParityIconButton(systemName: "xmark", help: L10n.string("Close tab"), action: onClose)
                    .background(ParityTheme.canvas, in: Circle())
                    .padding(.trailing, 2)
            }
        }
        .background(isHovering ? ParityTheme.hoverFill : .clear, in: RoundedRectangle(cornerRadius: 9))
        .onHover { isHovering = $0 }
    }
}

/// A tab's symbol, for another task's conversation its harness's mark, and for a browser tab its
/// page's icon, or a spinner while the page loads (the Codex app's browser tab icon, `YXa`).
struct WorkSurfaceTabIcon: View {
    let systemName: String
    var harness: HarnessKind? = nil
    var favicon: Data? = nil
    var isLoading = false

    var body: some View {
        if isLoading {
            ProgressView().controlSize(.mini).frame(width: 16, height: 16)
        } else if let harness {
            HarnessIdentityIcon(harness: harness, size: 14)
        } else if let favicon, let image = BrowserFaviconImage.image(favicon) {
            Image(nsImage: image).resizable().interpolation(.high).frame(width: 16, height: 16)
                .clipShape(RoundedRectangle(cornerRadius: 3))
        } else {
            Image(systemName: systemName)
        }
    }
}

/// The + menu that opens another panel in the side panel, or the terminal below, and under Tasks
/// another task's conversation.
private struct WorkSurfaceOpenMenu: View {
    let choices: [WorkSurfaceTab]
    var taskChoices: @MainActor @Sendable () -> [WorkSurfaceTab] = { [] }
    let onSelect: @MainActor @Sendable (String) -> Void
    @State private var isHovering = false

    var body: some View {
        let taskChoices = taskChoices()
        return Menu {
            ForEach(choices) { choice in
                Button { onSelect(choice.id) } label: { Label(choice.title, systemImage: choice.systemName) }
                    .disabled(!choice.isAvailable)
            }
            if !taskChoices.isEmpty {
                Divider()
                Menu(L10n.string("Tasks")) {
                    ForEach(taskChoices) { choice in
                        Button { onSelect(choice.id) } label: {
                            Label {
                                Text(choice.title)
                            } icon: {
                                if let harness = choice.harness,
                                   let image = HarnessLogoCatalog.icon(for: harness, size: 16) {
                                    Image(nsImage: image)
                                } else {
                                    Image(systemName: choice.systemName)
                                }
                            }
                        }
                    }
                    Divider()
                    Button(L10n.string("All Tasks…")) { onSelect(TaskSurfaceNavigationProjection.launcherID) }
                }
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 30, height: 30)
                .background(Circle().fill(isHovering ? ParityTheme.hoverFill : .clear))
                .contentShape(Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .parityPointer()
        .onHover { isHovering = $0 }
        .help(L10n.string("Open panel"))
        .accessibilityLabel(L10n.string("Open panel"))
    }
}

/// What a panel shows when it has nothing to show. A state that is no failure, such as no changes
/// or no repository, has no symbol and says so in secondary text, as the Claude app's Changes pane
/// does; a failure keeps its symbol.
struct WorkSurfaceEmptyState: View {
    let title: String
    var message: String? = nil
    var systemName: String? = nil

    var body: some View {
        VStack(spacing: 9) {
            if let systemName {
                Image(systemName: systemName)
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
            Text(title)
                .font(.callout.weight(systemName == nil ? .regular : .semibold))
                .foregroundStyle(systemName == nil ? .secondary : .primary)
                .multilineTextAlignment(.center)
            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
