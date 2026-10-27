import Foundation

/// Predicts the person's next message after a Codex turn, the way the Codex app does
/// (26.1013, `cumberbatch` in its bundle; setting `composer-predictions-enabled`, "Show
/// predictions"). After each turn of a saved thread ends, the app forks that thread with
/// `experimentalPredictionMode` (App Server ≥ 0.162.0-alpha.20) — an ephemeral fork that starts
/// from the parent's effective config, tools and persisted history so the provider reuses the
/// prompt cache — runs one short turn there asking for `{"suggestion": string | null}`, and drops
/// the fork. The answer waits in the empty composer as faint text until Tab takes it.
///
/// The App Server also lists `thread/prediction/request` and its `thread/prediction/updated`
/// notification, but 0.163 answers the request `-32601 "thread/prediction/request is not
/// implemented yet"` and the app never sends it. Yardlet asks it first and, once a runtime says it
/// has no such method, forks as the app does for the rest of that process.
///
/// The app's instruction comes from its ChatGPT account (`/wham/predictions/config`, with sample
/// rates, unsupported models and a reasoning effort); Yardlet does not call that service, so the
/// instruction and the low effort below are Yardlet's own.
enum CodexMessagePrediction {
    static let requestMethod = "thread/prediction/request"
    static let updatedMethod = "thread/prediction/updated"
    /// The fork's `threadSource` and the turn's `turnTrigger`, as the app sends them.
    static let source = "composer_predictions"
    /// The app's trigger after a turn it watched end. (Its `catch_up` trigger, for a thread opened
    /// without one, needs a thread loaded just to predict; Yardlet loads none for that.)
    static let liveTrigger = "live"
    /// The app gives the structured turn 30 seconds, then interrupts it.
    static let timeout: Duration = .seconds(30)
    static let preferredEffort = "low"

    /// The fork mode arrived in App Server 0.162.0-alpha.20 (the app's `experimentalPredictionForkMode`).
    static func supportsForkMode(appServerVersion: String?) -> Bool {
        guard let appServerVersion, let version = HarnessRuntimeVersion(appServerVersion) else { return false }
        let core = (version.major, version.minor, version.patch)
        if core != (0, 162, 0) { return core > (0, 162, 0) }
        guard let prerelease = version.prerelease else { return true }
        guard prerelease.hasPrefix("alpha."), let number = Int(prerelease.dropFirst("alpha.".count)) else { return false }
        return number >= 20
    }

    /// `initialize` answers `userAgent` as `<client name>/<App Server version> (<platform>) …`.
    static func appServerVersion(fromUserAgent userAgent: String?) -> String? {
        guard let first = userAgent?.split(separator: " ").first,
              let slash = first.firstIndex(of: "/") else { return nil }
        let version = String(first[first.index(after: slash)...])
        return HarnessRuntimeVersion(version) == nil ? nil : version
    }

    // MARK: - App Server request (not implemented in 0.163)

    static func request(id: Int64, threadID: String, sourceTurnID: String) -> CodexRPCRequest {
        CodexRPCRequest(id: id, method: requestMethod, params: .object([
            "threadId": .string(threadID),
            "sourceTurnId": .string(sourceTurnID)
        ]))
    }

    /// A runtime without the method: 0.163's `-32601`, or an older one's unknown request variant.
    static func isUnimplemented(_ failure: CodexRPCRequestFailure) -> Bool {
        let code = failure.payload["code"]
        let message = failure.payload["message"]?.stringValue ?? ""
        return code == .integer(-32601) || (code == .integer(-32600) && message.contains("unknown variant"))
    }

    /// `thread/prediction/updated`: `{threadId, sourceTurnId, result: {type: "completed", text?} |
    /// {type: "failed"}}`.
    struct Update: Equatable, Sendable {
        enum Result: Equatable, Sendable {
            case completed(text: String?)
            case failed
        }

        let threadID: String
        let sourceTurnID: String
        let result: Result
    }

    /// Nil for anything that is not a complete update; an unknown result type is no update either.
    static func update(from params: JSONValue?) -> Update? {
        guard let threadID = params?["threadId"]?.stringValue,
              let sourceTurnID = params?["sourceTurnId"]?.stringValue,
              let result = params?["result"] else { return nil }
        switch result["type"]?.stringValue {
        case "completed":
            return Update(threadID: threadID, sourceTurnID: sourceTurnID,
                          result: .completed(text: result["text"]?.stringValue))
        case "failed":
            return Update(threadID: threadID, sourceTurnID: sourceTurnID, result: .failed)
        default:
            return nil
        }
    }

    // MARK: - The app's fork

    /// `experimentalPredictionMode` takes no overrides: the fork is the parent as it is loaded.
    static func forkThread(id: Int64, threadID: String) -> CodexRPCRequest {
        CodexRPCRequest(id: id, method: "thread/fork", params: .object([
            "threadId": .string(threadID),
            "experimentalPredictionMode": .bool(true),
            "ephemeral": .bool(true),
            "excludeTurns": .bool(true),
            "threadSource": .string(source)
        ]))
    }

    /// The fork's one turn. As in the app, the schema rides in the prompt (no `outputSchema`) and
    /// only the effort is set; the metadata tells the provider what the turn is for.
    static func startTurn(id: Int64, forkThreadID: String, sourceThreadID: String, sourceTurnID: String,
                          effort: String?, clientUserMessageID: String = UUID().uuidString) -> CodexRPCRequest {
        var params: [String: JSONValue] = [
            "threadId": .string(forkThreadID),
            "turnTrigger": .string(source),
            "responsesapiClientMetadata": .object([
                "prediction_source_thread_id": .string(sourceThreadID),
                "prediction_source_turn_id": .string(sourceTurnID),
                "prediction_trigger": .string(liveTrigger)
            ]),
            "clientUserMessageId": .string(clientUserMessageID),
            "input": .array([CodexUserInput.text(prompt).jsonValue])
        ]
        if let effort { params["effort"] = .string(effort) }
        return CodexRPCRequest(id: id, method: "turn/start", params: .object(params))
    }

    /// Low when the thread's model offers it; otherwise the fork keeps the thread's own effort.
    static func effort(for model: CodexModelOption?) -> String? {
        model?.supportedReasoningEfforts.contains(preferredEffort) == true ? preferredEffort : nil
    }

    static let responseSchema = #"{"type":"object","properties":{"suggestion":{"type":["string","null"]}},"required":["suggestion"],"additionalProperties":false}"#

    /// The app's form: its instruction, a blank line, then "Return only JSON matching this schema".
    static let prompt = """
        Predict the next message the user will type into the composer of this conversation, now \
        that your last reply has ended. Write it as the user would send it to you: in the language \
        and tone the user writes in, one short line of at most about 15 words, an instruction or \
        question, not an answer. Prefer the natural next step of the work under way, such as \
        checking a result, continuing, or asking for a change. Use null when no next message is \
        clearly likely. This turn only predicts: make 0 tool calls, run nothing, and do not continue \
        the work.

        Return only JSON matching this schema: \(responseSchema).
        """

    /// The suggestion from the turn's final message, read as the app reads it: the whole message
    /// must be that JSON. A null suggestion (the model abstained) or anything else is none.
    static func suggestion(fromFinalMessage message: String?) -> String? {
        guard let data = message?.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
        return NextMessageSuggestionText.normalized(value["suggestion"]?.stringValue)
    }

    /// Item kinds the prediction turn may produce (App Server 0.163 `ThreadItem`). Any other is the
    /// model acting — a command, an edit, a tool — which a prediction must not do, so the turn is
    /// stopped at once and nothing is suggested. The fork keeps the thread's tools and sandbox for
    /// the cache, so this is the guard, not the prompt alone.
    static let quietItemTypes: Set<String> = [
        "userMessage", "hookPrompt", "agentMessage", "plan", "reasoning", "contextCompaction"
    ]
}
