import Foundation

/// Picks which provider action a plain allow or deny means when the provider offered several.
/// The narrowest scope wins so "Allow" can never silently become "always allow" because the
/// provider happened to list the broader option first.
enum PermissionActionPreference {
    enum Scope: Int, Sendable {
        case once = 0
        case unspecified = 1
        case broad = 2
    }

    static func scope(id: String, intent: String?) -> Scope {
        // "allow" contains "all", so the broad scope is matched on whole words a provider
        // actually uses for a standing decision.
        let token = [intent ?? "", id].joined(separator: " ").lowercased()
        if token.contains("always") || token.contains("session")
            || token.contains("policy") || token.contains("forever") {
            return .broad
        }
        if token.contains("once") || token.contains("approved") || token.contains("denied") {
            return .once
        }
        return .unspecified
    }

    /// The first narrowest action, keeping the provider's own order as the tiebreak.
    static func preferred<Action>(
        from actions: [Action],
        id: (Action) -> String,
        intent: (Action) -> String?
    ) -> Action? {
        actions.enumerated().min { lhs, rhs in
            let left = scope(id: id(lhs.element), intent: intent(lhs.element)).rawValue
            let right = scope(id: id(rhs.element), intent: intent(rhs.element)).rawValue
            return left == right ? lhs.offset < rhs.offset : left < right
        }?.element
    }

    static func preferred(
        from actions: [PermissionRequestAction],
        decision: PermissionDecision
    ) -> PermissionRequestAction? {
        preferred(
            from: actions.filter { $0.decision == decision },
            id: \.id,
            intent: \.kind
        )
    }
}
