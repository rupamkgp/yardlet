import Foundation

/// Which harness runs a subagent or a background task, and on which model: "Claude · Opus 5.5"
/// (2026-10-16 user decision). The model is the one the provider reported — the model Claude Code's
/// Agent call asked for or its result resolved (`resolvedModel`), the model a Codex child thread
/// was spawned with, else the Codex thread's own — in the words the composer names it, from the list
/// the harness last advertised for the task's account. Without a reported model the label names the
/// harness alone; nothing is guessed.
struct HarnessModelNames: Equatable, Sendable {
    let harness: HarnessKind
    /// The models Claude Code last listed for the task's account.
    var claude: [HarnessModelOption] = []
    /// The models Codex last listed for the task's account.
    var codex: [CodexModelOption] = []
    /// The model the task's own thread runs on, which a Codex child thread spawned without one
    /// inherits.
    var threadModel: String? = nil

    /// The harness's short name, as its icon's label reads ("Claude", "Codex").
    var harnessName: String {
        HarnessCatalog.descriptor(for: harness)?.shortName ?? harness.displayName
    }

    /// A model as the composer names it.
    func modelName(_ model: String) -> String {
        if harness == .claudeCode {
            return ClaudeComposerModelProjection.option(for: model, in: claude)?.name
                ?? ClaudeComposerModelProjection.displayName(model)
        }
        if harness == .codex, let option = codex.first(where: { $0.model == model || $0.id == model }) {
            return option.displayName
        }
        return model
    }

    /// "Claude · Opus 5.5", or the harness alone when no model was reported. A Codex subagent
    /// spawned without a model runs on its thread's.
    func label(model: String?) -> String {
        let reported = model ?? (harness == .codex ? threadModel : nil)
        guard let reported, !reported.isEmpty else { return harnessName }
        return L10n.format("%@ · %@", harnessName, modelName(reported))
    }
}
