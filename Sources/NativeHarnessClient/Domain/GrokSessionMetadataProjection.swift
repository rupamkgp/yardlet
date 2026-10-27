import Foundation

/// Read-only projection of Grok's provider-owned session metadata. This is used for detached
/// sessions because opening a conversation must not silently launch or resume its runtime.
struct GrokSessionMetadataSnapshot: Equatable, Sendable {
    let usage: HarnessProtocolUsage?
    let modelID: String?
    let reasoningEffort: String?

    var detachedCapabilityState: ProviderCapabilityState? {
        var selectors: [ProviderCapabilitySelector] = []
        if let modelID, !modelID.isEmpty {
            selectors.append(ProviderCapabilitySelector(
                id: "model",
                name: L10n.string("Model"),
                description: nil,
                category: "model",
                currentValue: modelID,
                choices: [ProviderCapabilityChoice(
                    value: modelID,
                    name: Self.modelDisplayName(modelID),
                    description: nil
                )]
            ))
        }
        if let reasoningEffort, !reasoningEffort.isEmpty {
            selectors.append(ProviderCapabilitySelector(
                id: "reasoning_effort",
                name: L10n.string("Reasoning effort"),
                description: nil,
                category: "thought_level",
                currentValue: reasoningEffort,
                choices: [ProviderCapabilityChoice(
                    value: reasoningEffort,
                    name: Self.reasoningEffortDisplayName(reasoningEffort),
                    description: nil
                )]
            ))
        }
        guard !selectors.isEmpty else { return nil }
        return ProviderCapabilityState(
            selectors: selectors,
            notes: [L10n.string("Saved Grok session values. Resume the task to change them.")]
        )
    }

    private static func modelDisplayName(_ identifier: String) -> String {
        switch identifier.lowercased() {
        case "grok-4.6": "Grok 4.6"
        case "grok-4.5": "Grok 4.5"
        case "grok-4.6-build": "Grok 4.6 Build"
        default: identifier
        }
    }

    private static func reasoningEffortDisplayName(_ value: String) -> String {
        switch value.lowercased() {
        case "minimal": "Minimal Effort"
        case "low": "Low Effort"
        case "medium": "Medium Effort"
        case "high": "High Effort"
        case "xhigh", "extra-high", "extra_high": "Extra High Effort"
        default: value
        }
    }
}

enum GrokSessionMetadataProjection {
    static func snapshot(
        providerSessionID: String,
        grokSessionsRoot: URL = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".grok/sessions", directoryHint: .isDirectory)
    ) -> GrokSessionMetadataSnapshot? {
        guard let sessionURL = uniqueSessionURL(
            providerSessionID: providerSessionID,
            grokSessionsRoot: grokSessionsRoot
        ) else { return nil }

        let summary = jsonObject(
            at: sessionURL.appending(path: "summary.json"),
            maximumSize: 2 * 1_024 * 1_024
        )
        let signals = jsonObject(
            at: sessionURL.appending(path: "signals.json"),
            maximumSize: 2 * 1_024 * 1_024
        )
        let turnUsage = lastTurnUsage(
            at: sessionURL.appending(path: "updates.jsonl"),
            maximumSize: 32 * 1_024 * 1_024
        )
        let contextWindowTokens = unsigned(signals?["contextWindowTokens"])
        let contextUsedTokens = unsigned(signals?["contextTokensUsed"])
        let usage: HarnessProtocolUsage?
        if turnUsage != nil || contextWindowTokens != nil || contextUsedTokens != nil {
            usage = HarnessProtocolUsage(
                inputTokens: unsigned(turnUsage?["inputTokens"]),
                cachedInputTokens: unsigned(
                    turnUsage?["cachedReadTokens"] ?? turnUsage?["cacheReadInputTokens"]
                ),
                outputTokens: unsigned(turnUsage?["outputTokens"]),
                reasoningTokens: unsigned(turnUsage?["reasoningTokens"]),
                totalCostUSD: cost(from: turnUsage),
                contextWindowTokens: contextWindowTokens,
                contextUsedTokens: contextUsedTokens,
                extensionValues: [:]
            )
        } else {
            usage = nil
        }

        let modelID = summary?["current_model_id"]?.stringValue
        let reasoningEffort = summary?["reasoning_effort"]?.stringValue
        guard usage != nil || modelID != nil || reasoningEffort != nil else { return nil }
        return GrokSessionMetadataSnapshot(
            usage: usage,
            modelID: modelID,
            reasoningEffort: reasoningEffort
        )
    }

    private static func uniqueSessionURL(
        providerSessionID: String,
        grokSessionsRoot: URL
    ) -> URL? {
        guard !providerSessionID.isEmpty,
              providerSessionID != ".",
              providerSessionID != "..",
              !providerSessionID.contains("/") else { return nil }
        guard let workspaceDirectories = try? FileManager.default.contentsOfDirectory(
            at: grokSessionsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        let candidates = workspaceDirectories.compactMap { workspaceURL -> URL? in
            let sessionURL = workspaceURL.appending(
                path: providerSessionID,
                directoryHint: .isDirectory
            )
            let summaryURL = sessionURL.appending(path: "summary.json")
            let updatesURL = sessionURL.appending(path: "updates.jsonl")
            return FileManager.default.fileExists(atPath: summaryURL.path)
                || FileManager.default.fileExists(atPath: updatesURL.path)
                ? sessionURL : nil
        }
        return candidates.count == 1 ? candidates[0] : nil
    }

    private static func jsonObject(at url: URL, maximumSize: Int) -> JSONValue? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize,
              size <= maximumSize,
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    private static func lastTurnUsage(at url: URL, maximumSize: Int) -> JSONValue? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize,
              size <= maximumSize,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        for line in text.split(whereSeparator: \Character.isNewline).reversed() {
            guard let data = String(line).data(using: .utf8),
                  let event = try? JSONDecoder().decode(JSONValue.self, from: data),
                  event["method"]?.stringValue == "_x.ai/session/update",
                  event["params"]?["update"]?["sessionUpdate"]?.stringValue == "turn_completed",
                  let usage = event["params"]?["update"]?["usage"] else { continue }
            return usage
        }
        return nil
    }

    private static func unsigned(_ value: JSONValue?) -> UInt64? {
        guard let number = value?.doubleValue,
              number.isFinite,
              number >= 0,
              number <= Double(UInt64.max) else { return nil }
        return UInt64(number)
    }

    private static func cost(from usage: JSONValue?) -> Double? {
        if let direct = (usage?["costUSD"] ?? usage?["costUsd"])?.doubleValue {
            return direct
        }
        return usage?["costUsdTicks"]?.doubleValue.map { $0 / 10_000_000_000 }
    }
}
