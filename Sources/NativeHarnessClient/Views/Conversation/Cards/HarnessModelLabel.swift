import SwiftUI

private struct HarnessModelNamesKey: EnvironmentKey {
    static let defaultValue: HarnessModelNames? = nil
}

extension EnvironmentValues {
    /// How the task's subagent cards and background-task rows name their harness and model; nil
    /// where nothing set it, and the label is not drawn.
    var harnessModelNames: HarnessModelNames? {
        get { self[HarnessModelNamesKey.self] }
        set { self[HarnessModelNamesKey.self] = newValue }
    }
}

/// The small harness · model label beside a subagent's title or a background task's row: "Claude ·
/// Opus 5.5" (`HarnessModelNames`).
struct HarnessModelLabel: View {
    /// The model the provider reported for the subagent; nil names the harness alone.
    let model: String?

    @Environment(\.harnessModelNames) private var names
    @Environment(\.yardletInterfaceScale) private var interfaceScale

    var body: some View {
        if let names {
            Text(names.label(model: model))
                .font(.system(size: 11 * interfaceScale))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .fixedSize()
                .accessibilityLabel(names.label(model: model))
        }
    }
}
