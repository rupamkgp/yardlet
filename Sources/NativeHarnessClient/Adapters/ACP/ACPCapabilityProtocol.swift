import Foundation

extension ACPProtocol {
    static func setConfigOption(
        id: Int64,
        providerSessionID: String,
        configID: String,
        value: String
    ) -> JSONValue {
        request(
            id: id,
            method: "session/set_config_option",
            params: .object([
                "sessionId": .string(providerSessionID),
                "configId": .string(configID),
                "value": .string(value)
            ])
        )
    }

    static func setMode(
        id: Int64,
        providerSessionID: String,
        modeID: String
    ) -> JSONValue {
        request(
            id: id,
            method: "session/set_mode",
            params: .object([
                "sessionId": .string(providerSessionID),
                "modeId": .string(modeID)
            ])
        )
    }

    static func setModel(
        id: Int64,
        providerSessionID: String,
        modelID: String,
        reasoningEffort: String? = nil
    ) -> JSONValue {
        var params: [String: JSONValue] = [
            "sessionId": .string(providerSessionID),
            "modelId": .string(modelID)
        ]
        if let reasoningEffort {
            params["_meta"] = .object([
                "reasoningEffort": .string(reasoningEffort)
            ])
        }
        return request(
            id: id,
            method: "session/set_model",
            params: .object(params)
        )
    }
}

struct ACPCapabilityProjector: Sendable {
    func state(
        from result: JSONValue,
        harness: HarnessKind,
        selectedModelID: String? = nil,
        selectedReasoningEffort: String? = nil
    ) -> ProviderCapabilityState {
        let selectors = selectors(
            from: result,
            harness: harness,
            selectedModelID: selectedModelID,
            selectedReasoningEffort: selectedReasoningEffort
        )
        if !selectors.isEmpty {
            var notes = [L10n.string("These controls are provided by the active ACP session.")]
            if harness == .grokBuild {
                notes.append(
                    L10n.string(
                        "Grok permissions are controlled from tool request cards; Yardlet preserves Grok's once/always choices."
                    )
                )
            }
            return ProviderCapabilityState(
                selectors: selectors,
                notes: notes
            )
        }
        if let legacy = legacyMode(from: result) {
            return ProviderCapabilityState(
                selectors: [legacy],
                notes: [L10n.string("This agent exposes the legacy ACP mode selector.")]
            )
        }
        return ProviderCapabilityState(
            notes: [L10n.format(
                "%@ did not expose configurable options for this session.",
                harness.displayName
            )]
        )
    }

    func selectors(
        from result: JSONValue,
        harness: HarnessKind,
        selectedModelID: String? = nil,
        selectedReasoningEffort: String? = nil
    ) -> [ProviderCapabilitySelector] {
        var selectors = configOptions(from: result)

        let hasModel = selectors.contains { $0.id == "model" }
        let hasReasoning = selectors.contains {
            $0.id == "reasoning_effort" || $0.id == "thought_level"
        }
        let modelSelectors = modelSelectors(
            from: result,
            selectedModelID: selectedModelID,
            selectedReasoningEffort: selectedReasoningEffort
        )
        if !hasModel, let model = modelSelectors.first(where: { $0.id == "model" }) {
            selectors.append(model)
        }
        if !hasReasoning,
           let reasoning = modelSelectors.first(where: { $0.id == "reasoning_effort" }) {
            selectors.append(reasoning)
        }

        if selectors.isEmpty, harness == .grokBuild {
            selectors = grokExtensionSelectors(from: result)
        }
        return selectors
    }

    func configOptions(from result: JSONValue) -> [ProviderCapabilitySelector] {
        (result["configOptions"]?.arrayValue ?? []).compactMap {
            option -> ProviderCapabilitySelector? in
            guard option["type"]?.stringValue == "select",
                  let id = option["id"]?.stringValue,
                  let name = option["name"]?.stringValue,
                  let current = option["currentValue"]?.stringValue
            else { return nil }
            let choices = (option["options"]?.arrayValue ?? []).compactMap {
                choice -> ProviderCapabilityChoice? in
                guard let value = choice["value"]?.stringValue,
                      let name = choice["name"]?.stringValue else { return nil }
                return ProviderCapabilityChoice(
                    value: value,
                    name: name,
                    description: choice["description"]?.stringValue
                )
            }
            guard !choices.isEmpty else { return nil }
            return ProviderCapabilitySelector(
                id: id,
                name: name,
                description: option["description"]?.stringValue,
                category: option["category"]?.stringValue,
                currentValue: choices.contains { $0.value == current }
                    ? current
                    : choices[0].value,
                choices: choices
            )
        }
    }

    private func modelSelectors(
        from result: JSONValue,
        selectedModelID: String?,
        selectedReasoningEffort: String?
    ) -> [ProviderCapabilitySelector] {
        guard let models = result["models"],
              let advertisedCurrent = models["currentModelId"]?.stringValue else { return [] }
        let available = models["availableModels"]?.arrayValue ?? []
        let modelChoices = available.compactMap { model -> ProviderCapabilityChoice? in
            guard let id = model["modelId"]?.stringValue else { return nil }
            return ProviderCapabilityChoice(
                value: id,
                name: model["name"]?.stringValue ?? id,
                description: model["description"]?.stringValue
            )
        }
        guard !modelChoices.isEmpty else { return [] }

        let currentModelID = selectedModelID.flatMap { selected in
            modelChoices.contains { $0.value == selected } ? selected : nil
        } ?? advertisedCurrent
        var selectors = [ProviderCapabilitySelector(
            id: "model",
            name: L10n.string("Model"),
            description: nil,
            category: "model",
            currentValue: currentModelID,
            choices: modelChoices
        )]

        guard let currentModel = available.first(where: {
            $0["modelId"]?.stringValue == currentModelID
        }), currentModel["_meta"]?["supportsReasoningEffort"]?.boolValue == true else {
            return selectors
        }
        let meta = currentModel["_meta"]
        let effortChoices = (meta?["reasoningEfforts"]?.arrayValue ?? []).compactMap {
            effort -> ProviderCapabilityChoice? in
            guard let value = effort["id"]?.stringValue
                    ?? effort["value"]?.stringValue else { return nil }
            return ProviderCapabilityChoice(
                value: value,
                name: effort["label"]?.stringValue ?? value,
                description: effort["description"]?.stringValue
            )
        }
        guard !effortChoices.isEmpty else { return selectors }
        let currentEffortValue = meta?["reasoningEffort"]?.stringValue
        let currentEffort = selectedReasoningEffort.flatMap { selected in
            effortChoices.contains { $0.value == selected } ? selected : nil
        } ?? effortChoices.first(where: { choice in
            guard let raw = meta?["reasoningEfforts"]?.arrayValue?.first(where: {
                ($0["id"]?.stringValue ?? $0["value"]?.stringValue) == choice.value
            }) else { return false }
            return raw["value"]?.stringValue == currentEffortValue
                || raw["id"]?.stringValue == currentEffortValue
        })?.value ?? effortChoices.first(where: { choice in
            (meta?["reasoningEfforts"]?.arrayValue ?? []).contains { effort in
                (effort["id"]?.stringValue ?? effort["value"]?.stringValue) == choice.value
                    && effort["default"]?.boolValue == true
            }
        })?.value ?? effortChoices[0].value
        selectors.append(ProviderCapabilitySelector(
            id: "reasoning_effort",
            name: L10n.string("Reasoning effort"),
            description: L10n.string("Controls how much reasoning Grok applies to this session."),
            category: "thought_level",
            currentValue: currentEffort,
            choices: effortChoices
        ))
        return selectors
    }

    private func grokExtensionSelectors(from result: JSONValue) -> [ProviderCapabilitySelector] {
        let options = result["_meta"]?["x.ai/sessionConfig"]?["options"]?.arrayValue ?? []
        return [("model", "model"), ("mode", "reasoning_effort")].compactMap { pair in
            let (category, id) = pair
            let matching = options.filter { $0["category"]?.stringValue == category }
            let choices = matching.compactMap { option -> ProviderCapabilityChoice? in
                guard let value = option["id"]?.stringValue else { return nil }
                return ProviderCapabilityChoice(
                    value: value,
                    name: option["label"]?.stringValue ?? value,
                    description: option["description"]?.stringValue
                )
            }
            guard !choices.isEmpty else { return nil }
            let current = matching.first(where: {
                $0["selected"]?.boolValue == true
            })?["id"]?.stringValue ?? choices[0].value
            return ProviderCapabilitySelector(
                id: id,
                name: category == "model"
                    ? L10n.string("Model")
                    : L10n.string("Reasoning effort"),
                description: category == "model"
                    ? nil
                    : L10n.string("Controls how much reasoning Grok applies to this session."),
                category: category == "model" ? "model" : "thought_level",
                currentValue: current,
                choices: choices
            )
        }
    }

    private func legacyMode(from result: JSONValue) -> ProviderCapabilitySelector? {
        guard let modes = result["modes"],
              let current = modes["currentModeId"]?.stringValue else { return nil }
        let choices = (modes["availableModes"]?.arrayValue ?? []).compactMap {
            mode -> ProviderCapabilityChoice? in
            guard let id = mode["id"]?.stringValue,
                  let name = mode["name"]?.stringValue else { return nil }
            return ProviderCapabilityChoice(
                value: id,
                name: name,
                description: mode["description"]?.stringValue
            )
        }
        guard !choices.isEmpty else { return nil }
        return ProviderCapabilitySelector(
            id: "mode",
            name: L10n.string("Session mode"),
            description: nil,
            category: "mode",
            currentValue: choices.contains { $0.value == current }
                ? current
                : choices[0].value,
            choices: choices
        )
    }
}
