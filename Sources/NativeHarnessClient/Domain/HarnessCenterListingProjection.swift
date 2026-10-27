import Foundation

enum HarnessCenterFilter: String, CaseIterable, Identifiable {
    case all, connected, attention
    var id: Self { self }
    var title: String {
        switch self {
        case .all: L10n.string("All harnesses")
        case .connected: L10n.string("Connected")
        case .attention: L10n.string("Needs setup")
        }
    }
}

enum HarnessCenterListingProjection {
    static func matches(
        _ descriptor: HarnessDescriptor,
        snapshot: HarnessAccountSnapshot?,
        query: String,
        filter: HarnessCenterFilter
    ) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.isEmpty || descriptor.displayName.localizedStandardContains(query)
                || descriptor.id.rawValue.localizedStandardContains(query) else { return false }
        switch filter {
        case .all: return true
        case .connected: return snapshot?.state == .signedIn
        case .attention:
            // Missing evidence is not proof of either a connection or a setup problem.
            return snapshot.map { [.signedOut, .actionRequired, .unavailable].contains($0.state) } ?? false
        }
    }
}
