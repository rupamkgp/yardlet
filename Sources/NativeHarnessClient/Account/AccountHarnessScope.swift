import Foundation

/// Which harnesses the accounts list covers. Before the user picks a filter it shows the harnesses
/// in use, so runtimes that merely happen to be installed stay out of the way; the filter still
/// reaches every harness the list can show.
enum AccountHarnessScope {
    /// What the app knows about how harnesses are used, outside the accounts store.
    struct Usage: Equatable {
        var withTasks: Set<HarnessKind>
        var chosenForNewTask: HarnessKind?
    }

    /// The filter the accounts list starts with.
    enum Filter: Hashable {
        case inUse
        case all
        case harness(HarnessKind)

        var harness: HarnessKind? {
            if case let .harness(value) = self { value } else { nil }
        }
    }

    /// Harnesses the list can show at all: installed, with saved accounts, or with a signed-in
    /// default login. Catalog order.
    static func available(
        catalog: [HarnessKind],
        installed: Set<HarnessKind>,
        savedAccounts: Set<HarnessKind>,
        signedInDefaults: Set<HarnessKind>
    ) -> [HarnessKind] {
        catalog.filter { installed.contains($0) || savedAccounts.contains($0) || signedInDefaults.contains($0) }
    }

    /// The available harnesses in use: with tasks, saved accounts, or chosen for the next new
    /// task. When none qualifies yet (a new install), every available harness.
    static func inUse(
        available: [HarnessKind],
        withTasks: Set<HarnessKind>,
        savedAccounts: Set<HarnessKind>,
        chosenForNewTask: HarnessKind?
    ) -> [HarnessKind] {
        let used = withTasks.union(savedAccounts).union(chosenForNewTask.map { [$0] } ?? [])
        let inUse = available.filter(used.contains)
        return inUse.isEmpty ? available : inUse
    }

    /// The harnesses whose accounts a filter lists.
    static func harnesses(for filter: Filter, available: [HarnessKind], inUse: [HarnessKind]) -> [HarnessKind] {
        switch filter {
        case .inUse: inUse
        case .all: available
        case let .harness(harness): [harness]
        }
    }
}
