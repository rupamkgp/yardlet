import Foundation

/// Presentation-only bridge into the common model menu. Selection stays in Codex's typed
/// model/effort contract; these IDs never become another harness's session options.
enum CodexModelMenuProjection {
    static func model(_ catalog: CodexModelCatalog) -> ProviderCapabilitySelector {
        ProviderCapabilitySelector(id: "model", name: L10n.string("Model"), description: nil,
            category: "model", currentValue: catalog.selection?.model ?? catalog.selectedModel?.model ?? "",
            choices: catalog.models.map {
                ProviderCapabilityChoice(value: $0.model, name: $0.displayName, description: nil)
            })
    }

    static func reasoning(_ catalog: CodexModelCatalog) -> ProviderCapabilitySelector? {
        guard let model = catalog.selectedModel, !model.supportedReasoningEfforts.isEmpty else { return nil }
        return ProviderCapabilitySelector(id: "reasoningEffort", name: L10n.string("Reasoning effort"),
            description: nil, category: "thought_level", currentValue: catalog.effort ?? "",
            choices: model.supportedReasoningEfforts.map {
                ProviderCapabilityChoice(value: $0, name: CodexReasoningLabel.name($0), description: nil)
            })
    }

    /// The model's Fast tier as the shared menu's speed row, named and described as Codex names it.
    static func speed(_ catalog: CodexModelCatalog) -> ProviderCapabilitySelector? {
        guard let fast = catalog.fastTier else { return nil }
        return ProviderCapabilitySelector(id: "fastMode", name: fast.name,
            description: fast.description.isEmpty ? nil : fast.description, category: "speed",
            currentValue: catalog.isFast ? "on" : "off",
            choices: [.init(value: "off", name: L10n.string("Off"), description: nil),
                      .init(value: "on", name: L10n.string("On"), description: nil)])
    }

    static func selection(id: String, value: String, catalog: CodexModelCatalog) -> CodexModelSelection? {
        switch id {
        case "fastMode":
            guard let fast = catalog.fastTier else { return nil }
            return catalog.selectingServiceTier(value == "on" ? fast.id : "default")
        case "model":
            guard let model = catalog.models.first(where: { $0.model == value }) else { return nil }
            return catalog.selecting(model)
        case "reasoningEffort":
            guard let model = catalog.selectedModel, model.supportedReasoningEfforts.contains(value) else { return nil }
            return CodexModelSelection(model: model.model, reasoningEffort: value, serviceTier: catalog.selection?.serviceTier)
        default: return nil
        }
    }
}
