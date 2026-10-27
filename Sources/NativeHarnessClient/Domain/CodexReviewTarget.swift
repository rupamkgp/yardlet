import Foundation

enum CodexReviewTarget: Codable, Equatable, Sendable {
    case uncommittedChanges
    case baseBranch(String)

    var jsonValue: JSONValue {
        switch self {
        case .uncommittedChanges: .object(["type": .string("uncommittedChanges")])
        case let .baseBranch(branch): .object(["type": .string("baseBranch"), "branch": .string(branch)])
        }
    }
}

struct CodexReviewRequest: Identifiable {
    let id = UUID()
    let session: SessionRecord
    /// The sent `/review` draft, cleared once the review starts. A choice from the command list
    /// has already removed its typed text and leaves the rest of the draft alone.
    let draft: TaskDraftSnapshot?
}
