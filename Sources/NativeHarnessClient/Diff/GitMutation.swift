import Foundation

enum GitMutation: Equatable, Sendable {
    case stage, unstage, discard
}

struct GitDiscardRequest: Identifiable {
    let id = UUID()
    let workspaceURL: URL
    let snapshot: DiffSnapshot
}
