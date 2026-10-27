import Foundation

/// Moving a task to another project, or out of its project back to Chats, as the Codex app's
/// sidebar does ("Move to project", "Remove from <project>"). The move is Yardlet's: only the
/// task's project and the roots that come with it change. Its folder stays its cwd, and its
/// provider session, storage scope, account, history, draft, pin and status stay as they are.
/// Nothing on disk is copied or moved, and nothing is written to the provider.
enum TaskProjectMove {
    /// What a task's menus offer.
    struct Options: Equatable, Sendable {
        /// The projects the task can move to: the sidebar's visible projects, in its order, but
        /// the one the task is in.
        var destinations: [Project] = []
        /// The project the task can leave for Chats. Only a task whose folder is a chat's
        /// (`ChatWorkspaces`) can: any other folder would put it right back in that folder's
        /// project, and the Codex app keeps such a task's folder as it is too.
        var removableFrom: Project?

        static let none = Options()

        var isEmpty: Bool { destinations.isEmpty && removableFrom == nil }

        /// Whether the task can go to `destination` (nil: Chats).
        func allows(_ destination: Project?) -> Bool {
            guard let destination else { return removableFrom != nil }
            return destinations.contains { $0.id == destination.id }
        }
    }

    /// A move as one command, for the command palette, which lists commands rather than submenus.
    struct Command: Identifiable, Equatable, Sendable {
        /// The project the task moves to; nil moves it to Chats.
        let destination: Project?
        let title: String

        var id: String {
            destination.map { "move-to-project-\($0.id.uuidString)" } ?? "remove-from-project"
        }
    }

    /// - Parameters:
    ///   - visibleProjects: the projects the sidebar lists, in its order.
    ///   - projects: every project, hidden ones too, which is what a task's project resolves among.
    ///   - home: the home whose chat folders hold chats.
    static func options(
        for session: SessionRecord,
        visibleProjects: [Project],
        projects: [Project],
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Options {
        let current = ProjectProjection.project(for: session, in: projects)
        let destinations = visibleProjects.filter { !$0.isHidden && $0.id != current?.id }
        let leavesForChats = current != nil
            && ProjectProjection.isChat(moved(session, to: nil), in: projects, home: home)
        return Options(destinations: destinations, removableFrom: leavesForChats ? current : nil)
    }

    /// The submenu's title, the Codex app's ("Move to project").
    static var moveTitle: String { L10n.string("Move to project") }

    /// The Codex app's "Remove from <project>", which returns the task to Chats.
    static func removeTitle(_ project: Project) -> String {
        L10n.format("Remove from %@", project.name)
    }

    /// The moves as commands: one per destination, then the way back to Chats.
    static func commands(_ options: Options) -> [Command] {
        options.destinations.map { Command(destination: $0, title: L10n.format("Move to project: %@", $0.name)) }
            + (options.removableFrom.map { [Command(destination: nil, title: removeTitle($0))] } ?? [])
    }

    /// The roots a task in `project` hands its harness besides its own folder: the project's roots,
    /// as a task started in the project gets them, without the task's folder and, for a worktree,
    /// without the root it was checked out from, which the worktree stands in for. The task keeps
    /// running in its own folder. In Chats (nil) a task gets none, as a new chat does. The
    /// project's own roots never change.
    static func additionalRoots(for session: SessionRecord, in project: Project?) -> [String] {
        guard let project else { return [] }
        let standIn = session.originWorkspaceURL.flatMap { project.contains(root: $0) ? $0 : nil }
        return project.roots
            .filter { root in
                !Project.isSamePath(root, session.workspaceURL)
                    && !(standIn.map { Project.isSamePath(root, $0) } ?? false)
            }
            .map { ProjectSidebarPresentation.normalizedPath(for: $0) }
    }

    /// The task as it is once in `project` (nil: Chats).
    static func moved(_ session: SessionRecord, to project: Project?) -> SessionRecord {
        var copy = session
        copy.assignProject(project?.id, additionalRoots: additionalRoots(for: session, in: project))
        return copy
    }
}
