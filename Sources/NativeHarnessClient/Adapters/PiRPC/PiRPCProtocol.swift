import Foundation

struct PiRPCRawFrame: Sendable {
    let value: JSONValue
    let data: Data
}

struct PiRPCWireCodec: Sendable {
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()

    init() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        self.encoder = encoder
    }

    func encodeLine(_ value: JSONValue) throws -> Data {
        var data = try encoder.encode(value)
        data.append(0x0A)
        return data
    }

    func decodeLine(_ data: Data) throws -> JSONValue {
        var trimmed = data
        if trimmed.last == 0x0D { trimmed.removeLast() }
        return try decoder.decode(JSONValue.self, from: trimmed)
    }
}

enum PiRPCProtocol {
    static func getState(id: String) -> JSONValue {
        command(id: id, type: "get_state")
    }

    static func prompt(id: String, text: String) -> JSONValue {
        prompt(id: id, text: text, images: [])
    }

    /// The RPC `prompt` command takes `images` beside `message`, each one pi's own
    /// `ImageContent` (`{type, data, mimeType}`). A prompt without images keeps the field out,
    /// so an ordinary text turn is byte-identical to what it was before attachments existed.
    static func prompt(
        id: String,
        text: String,
        images: [HarnessUserInput.EncodedImage]
    ) -> JSONValue {
        var fields: [String: JSONValue] = ["message": .string(text)]
        if !images.isEmpty {
            fields["images"] = .array(images.map { image in
                .object([
                    "type": .string("image"),
                    "data": .string(image.base64Data),
                    "mimeType": .string(image.mimeType)
                ])
            })
        }
        return command(id: id, type: "prompt", fields: fields)
    }

    static func abort(id: String) -> JSONValue {
        command(id: id, type: "abort")
    }

    static func sessionStats(id: String) -> JSONValue {
        command(id: id, type: "get_session_stats")
    }

    static func availableModels(id: String) -> JSONValue {
        command(id: id, type: "get_available_models")
    }

    static func availableThinkingLevels(id: String) -> JSONValue {
        command(id: id, type: "get_available_thinking_levels")
    }

    static func setModel(id: String, provider: String, modelID: String) -> JSONValue {
        command(
            id: id,
            type: "set_model",
            fields: ["provider": .string(provider), "modelId": .string(modelID)]
        )
    }

    static func setThinkingLevel(id: String, level: String) -> JSONValue {
        command(id: id, type: "set_thinking_level", fields: ["level": .string(level)])
    }

    static func setAutoCompaction(id: String, enabled: Bool) -> JSONValue {
        command(id: id, type: "set_auto_compaction", fields: ["enabled": .bool(enabled)])
    }

    static func compact(id: String) -> JSONValue {
        command(id: id, type: "compact")
    }

    static func switchSession(id: String, sessionPath: String) -> JSONValue {
        command(
            id: id,
            type: "switch_session",
            fields: ["sessionPath": .string(sessionPath)]
        )
    }

    static func extensionConfirmation(id: String, confirmed: Bool) -> JSONValue {
        .object([
            "type": .string("extension_ui_response"),
            "id": .string(id),
            "confirmed": .bool(confirmed)
        ])
    }

    static func cancelExtensionUI(id: String) -> JSONValue {
        .object([
            "type": .string("extension_ui_response"),
            "id": .string(id),
            "cancelled": .bool(true)
        ])
    }

    private static func command(
        id: String,
        type: String,
        fields: [String: JSONValue] = [:]
    ) -> JSONValue {
        var object = fields
        object["id"] = .string(id)
        object["type"] = .string(type)
        return .object(object)
    }
}

struct PiRPCEventProjector: Sendable {
    func payloads(from value: JSONValue, fallback: HarnessActivity? = nil)
        -> [HarnessEventPayload] {
        switch value["type"]?.stringValue {
        case "message_update":
            let event = value["assistantMessageEvent"]
            if event?["type"]?.stringValue == "thinking_delta",
               let delta = event?["delta"]?.stringValue ?? event?["thinking"]?.stringValue {
                return [.reasoningDelta(delta)]
            }
            if event?["type"]?.stringValue == "thinking_end" {
                guard let text = event?["thinking"]?.stringValue
                    ?? event?["text"]?.stringValue else { return [] }
                return [.reasoningCompleted(text)]
            }
            guard event?["type"]?.stringValue == "text_delta",
                  let delta = event?["delta"]?.stringValue else { return [] }
            return [.assistantDelta(delta)]

        case "thinking_delta":
            guard let delta = value["delta"]?.stringValue
                ?? value["thinking"]?.stringValue else { return [] }
            return [.reasoningDelta(delta)]

        case "message_end":
            guard value["message"]?["role"]?.stringValue == "assistant" else { return [] }
            if let error = value["message"]?["errorMessage"]?.stringValue {
                return [.error(message: providerErrorMessage(from: error), recoverable: true)]
            }
            guard let text = assistantText(from: value["message"]) else { return [] }
            return [.assistantMessageCompleted(text)]

        case "tool_execution_start":
            guard let activity = activity(from: value, fallback: fallback) else { return [] }
            return [.activityStarted(activity)]

        case "tool_execution_update":
            guard let activity = activity(from: value, fallback: fallback) else { return [] }
            return [.activityUpdated(activity)]

        case "tool_execution_end":
            guard let activity = activity(from: value, fallback: fallback) else { return [] }
            return [.activityCompleted(activity)]

        case "extension_error":
            guard let message = value["error"]?.stringValue else { return [] }
            return [.error(message: message, recoverable: true)]

        default:
            return []
        }
    }

    func activity(from value: JSONValue, fallback: HarnessActivity? = nil)
        -> HarnessActivity? {
        guard let id = value["toolCallId"]?.stringValue ?? fallback?.id else { return nil }
        let name = value["toolName"]?.stringValue ?? fallback?.title
            ?? L10n.string("Tool call")
        let details = value["result"]?["details"] ?? value["partialResult"]?["details"]
        return HarnessActivity(
            id: id,
            kind: name,
            title: name,
            detail: command(from: value) ?? resultText(from: value) ?? fallback?.detail,
            // `tool_execution_end` reports the failure on the result frame itself.
            outcome: value["isError"]?.boolValue == true
                || value["result"]?["isError"]?.boolValue == true ? .failed : nil,
            // The start frame carries `args` and the end frame carries the result. Keeping them
            // in one slot let the output overwrite the command that produced it.
            input: inputText(from: value) ?? fallback?.input,
            output: resultText(from: value) ?? detailOutput(from: details) ?? fallback?.output,
            diff: diff(from: details) ?? fallback?.diff
        )
    }

    /// Reads the token counts, cost, and context usage from a `get_session_stats` reply.
    /// Only fields the runtime actually returned are published.
    func usage(from value: JSONValue) -> HarnessProtocolUsage? {
        let tokens = value["tokens"] ?? value["usage"] ?? value
        let context = value["contextUsage"] ?? value["context"] ?? value
        let inputTokens = unsigned(
            tokens["input"] ?? tokens["inputTokens"] ?? tokens["input_tokens"]
                ?? tokens["promptTokens"]
        )
        let cachedInputTokens = unsigned(
            tokens["cacheRead"] ?? tokens["cachedInput"] ?? tokens["cacheReadTokens"]
                ?? tokens["cachedInputTokens"] ?? tokens["cache_read_input_tokens"]
        )
        let outputTokens = unsigned(
            tokens["output"] ?? tokens["outputTokens"] ?? tokens["output_tokens"]
                ?? tokens["completionTokens"]
        )
        let reasoningTokens = unsigned(
            tokens["reasoning"] ?? tokens["reasoningTokens"] ?? tokens["thinkingTokens"]
        )
        let totalCostUSD = (
            value["cost"] ?? value["costUSD"] ?? value["costUsd"]
                ?? value["totalCostUsd"] ?? tokens["cost"]
        )?.doubleValue
        let contextWindowTokens = unsigned(
            context["maxTokens"] ?? context["contextWindow"] ?? context["limit"]
                ?? value["contextWindow"]
        )
        // Pi's `ContextUsage` is `{tokens, contextWindow, percent}`; `tokens` is null right after a
        // compaction, until the next response.
        let contextUsedTokens = unsigned(
            context["usedTokens"] ?? context["used"] ?? (value["contextUsage"] != nil ? context["tokens"] : nil)
                ?? value["contextTokens"]
        )
        guard inputTokens != nil || cachedInputTokens != nil || outputTokens != nil
                || reasoningTokens != nil || totalCostUSD != nil
                || contextWindowTokens != nil || contextUsedTokens != nil else { return nil }
        return HarnessProtocolUsage(
            inputTokens: inputTokens,
            cachedInputTokens: cachedInputTokens,
            outputTokens: outputTokens,
            reasoningTokens: reasoningTokens,
            totalCostUSD: totalCostUSD,
            contextWindowTokens: contextWindowTokens,
            contextUsedTokens: contextUsedTokens,
            extensionValues: [:]
        )
    }

    private func unsigned(_ value: JSONValue?) -> UInt64? {
        guard let number = value?.doubleValue,
              number.isFinite,
              number >= 0,
              number <= Double(UInt64.max) else { return nil }
        return UInt64(number)
    }

    private func assistantText(from message: JSONValue?) -> String? {
        if let text = message?["content"]?.stringValue { return text }
        let chunks = message?["content"]?.arrayValue?.compactMap { block -> String? in
            guard block["type"]?.stringValue == "text" else { return nil }
            return block["text"]?.stringValue
        } ?? []
        return chunks.isEmpty ? nil : chunks.joined()
    }

    private func providerErrorMessage(from rawValue: String) -> String {
        var candidate = rawValue
        for _ in 0..<4 {
            guard let data = candidate.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let message = deepestMessage(in: object),
                  message != candidate else { break }
            candidate = message
        }
        return candidate
    }

    private func deepestMessage(in value: Any) -> String? {
        if let object = value as? [String: Any] {
            if let nested = object["error"], let message = deepestMessage(in: nested) {
                return message
            }
            if let message = object["message"] as? String { return message }
            for nested in object.values {
                if let message = deepestMessage(in: nested) { return message }
            }
        } else if let values = value as? [Any] {
            for nested in values {
                if let message = deepestMessage(in: nested) { return message }
            }
        }
        return nil
    }

    private func command(from value: JSONValue) -> String? {
        value["args"]?["command"]?.stringValue
    }

    private func inputText(from value: JSONValue) -> String? {
        guard let args = value["args"] else { return nil }
        guard let command = command(from: value) else { return args.readableText }
        guard case let .object(object) = args, object.count > 1 else { return command }
        return "\(command)\n\n\(args.readableText ?? "")"
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func resultText(from value: JSONValue) -> String? {
        let result = value["partialResult"] ?? value["result"]
        let chunks = result?["content"]?.arrayValue?.compactMap { block in
            block["type"]?.stringValue == "text" ? block["text"]?.stringValue : nil
        } ?? []
        return chunks.isEmpty ? nil : chunks.joined(separator: "\n")
    }

    /// Pi attaches structured tool results under `result.details`. Yardlet renders a file change
    /// as a diff when the provider described one and otherwise keeps the payload as output.
    private func diff(from details: JSONValue?) -> HarnessActivityDiff? {
        guard let details else { return nil }
        let candidate = details["diff"] ?? details
        guard let path = candidate["path"]?.stringValue
            ?? candidate["filePath"]?.stringValue
            ?? candidate["file"]?.stringValue else { return nil }
        let oldText = candidate["oldText"]?.stringValue ?? candidate["oldString"]?.stringValue
        let newText = candidate["newText"]?.stringValue ?? candidate["newString"]?.stringValue
        let unified = candidate["unifiedDiff"]?.stringValue
            ?? candidate["patch"]?.stringValue
            ?? (candidate["diff"]?.stringValue)
        guard oldText != nil || newText != nil || unified != nil else { return nil }
        return HarnessActivityDiff(
            path: path,
            oldText: oldText,
            newText: newText,
            unified: unified
        )
    }

    private func detailOutput(from details: JSONValue?) -> String? {
        guard let details, diff(from: details) == nil else { return nil }
        return details.readableText
    }
}
