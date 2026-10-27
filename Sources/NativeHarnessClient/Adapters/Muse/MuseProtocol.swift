import Foundation

/// The stable Muse Session Protocol (MSP) v1 request surface used by Yardlet.
///
/// These shapes intentionally stay on the stable schema. In particular, command IDs are
/// caller-minted UUIDv7 values and `initialized` is sent only after a successful handshake.
enum MuseProtocol {
    static func initialize(id: Int64) -> JSONValue {
        return request(
            id: id,
            method: "initialize",
            params: .object([
                "clientInfo": .object([
                    // MSP SS1.4.1 requires a lower-case machine identifier,
                    // not the human-facing product display name.
                    "name": .string("yardlet"),
                    "version": .string("0.1.0")
                ])
            ])
        )
    }

    static var initialized: JSONValue {
        notification(method: "initialized")
    }

    static func startSession(
        id: Int64,
        commandID: String,
        workspaceURL: URL
    ) -> JSONValue {
        request(
            id: id,
            method: "session/start",
            params: .object([
                "commandId": .string(commandID),
                "workspaceRoot": .string(
                    workspaceURL.standardizedFileURL.path(percentEncoded: false)
                )
            ])
        )
    }

    static func resumeSession(
        id: Int64,
        commandID: String,
        providerSessionID: String
    ) -> JSONValue {
        request(
            id: id,
            method: "session/resume",
            params: .object([
                "commandId": .string(commandID),
                "sessionId": .string(providerSessionID)
            ])
        )
    }

    /// `turn/start` input is an ordered part list. An image is its own `image` part carrying
    /// base64 bytes and a media type; the host measures the pixel size itself, so the optional
    /// width/height pair is left out. A text-only turn keeps its single text part unchanged.
    static func startTurn(
        id: Int64,
        commandID: String,
        providerSessionID: String,
        prompt: String,
        images: [HarnessUserInput.EncodedImage] = [],
        reasoningEffort: String? = nil
    ) -> JSONValue {
        var input: [JSONValue] = []
        if images.isEmpty || !prompt.isEmpty {
            input.append(.object([
                "type": .string("text"),
                "text": .string(prompt)
            ]))
        }
        input += images.map { image in
            .object([
                "type": .string("image"),
                "base64Data": .string(image.base64Data),
                "mediaType": .string(image.mimeType)
            ])
        }
        var params: [String: JSONValue] = [
            "commandId": .string(commandID),
            "sessionId": .string(providerSessionID),
            "input": .array(input)
        ]
        if let reasoningEffort {
            params["reasoningEffort"] = .string(reasoningEffort)
        }
        return request(
            id: id,
            method: "turn/start",
            params: .object(params)
        )
    }

    static func listModels(id: Int64, providerSessionID: String) -> JSONValue {
        request(
            id: id,
            method: "model/list",
            params: .object(["sessionId": .string(providerSessionID)])
        )
    }

    static func setModel(
        id: Int64,
        commandID: String,
        providerSessionID: String,
        providerID: String,
        profileID: String?,
        modelID: String,
        displayLabel: String?
    ) -> JSONValue {
        var model: [String: JSONValue] = [
            "providerId": .string(providerID),
            "modelId": .string(modelID)
        ]
        if let profileID { model["profileId"] = .string(profileID) }
        if let displayLabel { model["displayLabel"] = .string(displayLabel) }
        return request(
            id: id,
            method: "session/setModel",
            params: .object([
                "commandId": .string(commandID),
                "sessionId": .string(providerSessionID),
                "model": .object(model)
            ])
        )
    }

    static func setApprovalMode(
        id: Int64,
        commandID: String,
        providerSessionID: String,
        mode: String
    ) -> JSONValue {
        request(
            id: id,
            method: "session/setApprovalMode",
            params: .object([
                "commandId": .string(commandID),
                "sessionId": .string(providerSessionID),
                "mode": .string(mode)
            ])
        )
    }

    static func compactSession(
        id: Int64,
        commandID: String,
        providerSessionID: String
    ) -> JSONValue {
        request(
            id: id,
            method: "session/compact",
            params: .object([
                "commandId": .string(commandID),
                "sessionId": .string(providerSessionID)
            ])
        )
    }

    static func interruptTurn(
        id: Int64,
        commandID: String,
        providerSessionID: String,
        turnID: String?
    ) -> JSONValue {
        var params: [String: JSONValue] = [
            "commandId": .string(commandID),
            "sessionId": .string(providerSessionID)
        ]
        if let turnID {
            params["turnId"] = .string(turnID)
        }
        return request(id: id, method: "turn/interrupt", params: .object(params))
    }

    static func decideApproval(
        id: Int64,
        commandID: String,
        providerSessionID: String,
        approvalID: String,
        sourceIndex: Int64,
        choiceID: String
    ) -> JSONValue {
        request(
            id: id,
            method: "approval/decide",
            params: .object([
                "commandId": .string(commandID),
                "sessionId": .string(providerSessionID),
                "approvalId": .string(approvalID),
                "requirementId": .object([
                    "approvalId": .string(approvalID),
                    "sourceIndex": .integer(sourceIndex)
                ]),
                "choiceId": .string(choiceID)
            ])
        )
    }

    /// `userInput/answer` answers every question of an open prompt. Like `approval/decide`, it is
    /// an idempotent command; the server request that opened the prompt only asked for a receipt.
    static func answerUserInput(
        id: Int64,
        commandID: String,
        providerSessionID: String,
        userInputID: String,
        answers: [JSONValue]
    ) -> JSONValue {
        request(
            id: id,
            method: "userInput/answer",
            params: .object([
                "commandId": .string(commandID),
                "sessionId": .string(providerSessionID),
                "userInputId": .string(userInputID),
                "answers": .array(answers)
            ])
        )
    }

    /// `userInput/cancel` declines an open prompt; the model receives a cancelled tool result.
    static func cancelUserInput(
        id: Int64,
        commandID: String,
        providerSessionID: String,
        userInputID: String,
        reason: String
    ) -> JSONValue {
        request(
            id: id,
            method: "userInput/cancel",
            params: .object([
                "commandId": .string(commandID),
                "sessionId": .string(providerSessionID),
                "userInputId": .string(userInputID),
                "reason": .string(reason)
            ])
        )
    }

    /// `usage/read` takes no params and reads the host's last-observed subscription usage without
    /// a model call.
    static func readUsage(id: Int64) -> JSONValue {
        .object([
            "jsonrpc": .string("2.0"),
            "id": .integer(id),
            "method": .string("usage/read")
        ])
    }

    static func acknowledgeServerRequest(id: JSONValue) -> JSONValue {
        response(id: id, result: .object([:]))
    }

    /// The error receipt MSP reads as "this connection could not present the request": the
    /// prompt stays pending on the host, which re-issues it on the next subscribe or resume.
    static func cannotPresent(id: JSONValue) -> JSONValue {
        .object([
            "jsonrpc": .string("2.0"),
            "id": id,
            "error": .object([
                "code": .integer(-32602),
                "message": .string("Yardlet cannot present this request")
            ])
        ])
    }

    static func methodNotFound(id: JSONValue) -> JSONValue {
        .object([
            "jsonrpc": .string("2.0"),
            "id": id,
            "error": .object([
                "code": .integer(-32601),
                "message": .string("Method not supported by Yardlet")
            ])
        ])
    }

    private static func request(id: Int64, method: String, params: JSONValue) -> JSONValue {
        .object([
            "jsonrpc": .string("2.0"),
            "id": .integer(id),
            "method": .string(method),
            "params": params
        ])
    }

    private static func notification(method: String) -> JSONValue {
        .object([
            "jsonrpc": .string("2.0"),
            "method": .string(method)
        ])
    }

    private static func response(id: JSONValue, result: JSONValue) -> JSONValue {
        .object([
            "jsonrpc": .string("2.0"),
            "id": id,
            "result": result
        ])
    }
}

/// One streamed piece of a `reasoning` item: summary part `summaryPart`, or raw text when nil.
struct MuseReasoningDelta: Equatable, Sendable {
    /// Summary parts read as paragraphs in the thought block.
    static let partSeparator = "\n\n"

    let summaryPart: Int?
    let text: String
}

/// An open MSP user-input prompt in the shape the shared question card answers: every question
/// is single or multiple choice over the provider's own option labels. MSP also accepts a
/// free-text answer and a note; the card offers neither, so Yardlet never sends them.
struct MuseUserInputPrompt: Equatable, Sendable {
    struct Question: Equatable, Sendable {
        let id: String
        let question: PermissionQuestion
    }

    let userInputID: String
    let title: String
    let questions: [Question]

    var permissionRequest: PermissionRequest {
        PermissionRequest(
            id: userInputID,
            title: title,
            detail: nil,
            command: nil,
            structured: .questions(questions.map(\.question))
        )
    }

    /// The `userInput/answer` entries for the card's picks, in the prompt's question order, or nil
    /// when a question has no usable pick: MSP rejects an answer that leaves a question out. A
    /// single-selection question takes `selectedLabel`, a multiple-selection one `selectedLabels`.
    func wireAnswers(for answers: [PermissionQuestionAnswer]) -> [JSONValue]? {
        var result: [JSONValue] = []
        for entry in questions {
            let offered = Set(entry.question.options.map(\.label))
            let picked = answers
                .first { $0.question == entry.question.question }?
                .selectedLabels
                .filter(offered.contains) ?? []
            if entry.question.allowsMultipleSelections {
                guard !picked.isEmpty else { return nil }
                result.append(.object([
                    "questionId": .string(entry.id),
                    "selectedLabels": .array(picked.map(JSONValue.string))
                ]))
            } else {
                guard picked.count == 1 else { return nil }
                result.append(.object([
                    "questionId": .string(entry.id),
                    "selectedLabel": .string(picked[0])
                ]))
            }
        }
        return result
    }
}

struct MuseEventProjector: Sendable {
    func assistantDelta(from params: JSONValue, itemKind: String?) -> String? {
        let field = params["field"]?.stringValue ?? "text"
        guard field == "text", itemKind == nil || itemKind == "agentMessage" else {
            return nil
        }
        return params["delta"]?.stringValue
    }

    func assistantCompletion(from item: JSONValue) -> String? {
        guard item["kind"]?.stringValue == "agentMessage" else { return nil }
        return item["text"]?.stringValue ?? ""
    }

    /// MSP reports the model's own thinking as a `reasoning` item. Its summary streams part by
    /// part on the `summary.<n>` field, and a new index starts the next part; raw `text` is
    /// committed on completion where the provider exposes it. Only the summary belongs to no
    /// other kind, so it is claimed even for an item whose start was not seen.
    func reasoningDelta(from params: JSONValue, itemKind: String?) -> MuseReasoningDelta? {
        guard let delta = params["delta"]?.stringValue else { return nil }
        let field = params["field"]?.stringValue ?? "text"
        if field.hasPrefix(Self.summaryFieldPrefix),
           let part = Int(field.dropFirst(Self.summaryFieldPrefix.count)), part >= 0,
           itemKind == nil || itemKind == "reasoning" {
            return MuseReasoningDelta(summaryPart: part, text: delta)
        }
        guard itemKind == "reasoning", field == "text" else { return nil }
        return MuseReasoningDelta(summaryPart: nil, text: delta)
    }

    /// The completed item is authoritative. Its summary parts are what streamed, joined the
    /// same way the stream separated them; raw text stands in only when there is no summary.
    func reasoningCompletion(from item: JSONValue) -> String? {
        guard item["kind"]?.stringValue == "reasoning" else { return nil }
        let summary = (item["summary"]?.arrayValue ?? [])
            .compactMap(\.stringValue)
            .filter { !$0.isEmpty }
        if !summary.isEmpty {
            return summary.joined(separator: MuseReasoningDelta.partSeparator)
        }
        return item["text"]?.stringValue ?? ""
    }

    private static let summaryFieldPrefix = "summary."

    /// `session/tokenUsage` reports one model call beside the session's running totals. MSP
    /// counts prompt tokens once under the provider's cache convention and says clients sum
    /// those, never the raw per-call counters, so only the totals are published.
    func usage(fromTokenUsage params: JSONValue) -> HarnessProtocolUsage? {
        let cumulative = params["cumulative"]
        let promptTokens = unsigned(cumulative?["promptTokens"])
        let outputTokens = unsigned(cumulative?["outputTokens"])
        guard promptTokens != nil || outputTokens != nil else { return nil }
        return HarnessProtocolUsage(
            inputTokens: promptTokens,
            cachedInputTokens: nil,
            outputTokens: outputTokens,
            reasoningTokens: nil,
            totalCostUSD: nil,
            contextWindowTokens: nil,
            contextUsedTokens: nil,
            extensionValues: [:]
        )
    }

    /// `session/contextUsage` replaces the session's occupancy. The window is absent when the
    /// host's basis has no limit, and it stays unknown rather than borrowed from the catalog.
    func usage(fromContextUsage params: JSONValue) -> HarnessProtocolUsage? {
        guard let usedTokens = unsigned(params["usedTokens"]) else { return nil }
        return HarnessProtocolUsage(
            inputTokens: nil,
            cachedInputTokens: nil,
            outputTokens: nil,
            reasoningTokens: nil,
            totalCostUSD: nil,
            contextWindowTokens: unsigned(params["windowTokens"]),
            contextUsedTokens: usedTokens,
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

    func activity(from item: JSONValue, fallback: HarnessActivity? = nil) -> HarnessActivity? {
        guard let itemID = item["itemId"]?.stringValue ?? fallback?.id,
              let kind = item["kind"]?.stringValue ?? fallback?.kind,
              kind != "userMessage",
              kind != "agentMessage",
              kind != "reasoning" else { return nil }
        // MSP asks a client to show a kind it has no card for, such as `reminderChild`, by its
        // kind name, status and the server's one-line `fallbackText`. The card already shows the
        // kind and status, so an item that names no tool is titled by that summary.
        let summary = item["fallbackText"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        let cardTitle = item["tool"]?.stringValue.map(title(for:))
            ?? summary
            ?? fallback?.title
            ?? title(for: kind)
        let output = item["visibleOutput"]?.readableText
            ?? item["failureReason"]?.stringValue
            ?? item["text"]?.stringValue
        return HarnessActivity(
            id: itemID,
            kind: kind,
            title: cardTitle,
            detail: item["visibleOutput"]?.stringValue
                ?? item["failureReason"]?.stringValue
                ?? item["args"]?.stringValue
                ?? item["text"]?.stringValue
                ?? fallback?.detail,
            // MSP reports a failed item with `status`, not with a separate error event.
            outcome: item["status"]?.stringValue == "failed" ? .failed : nil,
            input: item["args"]?.readableText ?? fallback?.input,
            output: output ?? fallback?.output
        )
    }

    func updatedActivity(
        from params: JSONValue,
        fallback: HarnessActivity
    ) -> HarnessActivity? {
        let field = params["field"]?.stringValue ?? "text"
        guard field == "output", let delta = params["delta"]?.stringValue else {
            return nil
        }
        return HarnessActivity(
            id: fallback.id,
            kind: fallback.kind,
            title: fallback.title,
            detail: (fallback.detail ?? "") + delta,
            outcome: fallback.outcome,
            input: fallback.input,
            output: (fallback.output ?? "") + delta,
            diff: fallback.diff
        )
    }

    func permissionRequest(from params: JSONValue) -> PermissionRequest? {
        guard let approvalID = params["approvalId"]?.stringValue else { return nil }
        let toolName = params["toolName"]?.stringValue ?? L10n.string("Approve tool call")
        let subject = params["subject"]
        let detail = [
            subject?["kind"]?.stringValue,
            subject?["path"]?.stringValue,
            subject?["host"]?.stringValue
        ].compactMap { $0 }.joined(separator: " · ")
        let actions: [PermissionRequestAction] = params["availableChoices"]?.arrayValue?.compactMap { choice -> PermissionRequestAction? in
            guard let choiceID = choice["choiceId"]?.stringValue,
                  let decisionName = choice["decision"]?.stringValue,
                  let decision = permissionDecision(for: decisionName) else { return nil }
            return PermissionRequestAction(
                id: choiceID,
                label: choice["label"]?.stringValue ?? choiceID,
                decision: decision,
                kind: decisionName
            )
        } ?? []
        return PermissionRequest(
            id: approvalID,
            title: title(for: toolName),
            detail: detail.isEmpty ? params["rawArgs"]?.stringValue : detail,
            command: subject?["command"]?.stringValue,
            actions: actions
        )
    }

    /// Reads `userInput/request`, whose params are the same as `userInput/requested`. Each question
    /// needs its id, its text, a `single` or `multiple` selection mode and at least one labelled
    /// option, and question texts must differ because the card returns answers keyed by text.
    /// Anything else cannot be answered through the card, so it yields nil rather than a form
    /// whose answer MSP would reject.
    func userInputPrompt(from params: JSONValue) -> MuseUserInputPrompt? {
        guard let userInputID = params["userInputId"]?.stringValue, !userInputID.isEmpty,
              let entries = params["questions"]?.arrayValue, !entries.isEmpty else { return nil }
        var questions: [MuseUserInputPrompt.Question] = []
        for entry in entries {
            guard let id = entry["id"]?.stringValue, !id.isEmpty,
                  let text = entry["question"]?.stringValue, !text.isEmpty,
                  !questions.contains(where: { $0.question.question == text }) else { return nil }
            let mode = entry["selection"]?["mode"]?.stringValue
            guard mode == "single" || mode == "multiple" else { return nil }
            let options = (entry["options"]?.arrayValue ?? []).compactMap { option in
                option["label"]?.stringValue.flatMap { label in
                    label.isEmpty ? nil : PermissionQuestionOption(
                        label: label,
                        description: option["description"]?.stringValue
                    )
                }
            }
            guard !options.isEmpty else { return nil }
            questions.append(MuseUserInputPrompt.Question(
                id: id,
                question: PermissionQuestion(
                    question: text,
                    header: entry["header"]?.stringValue,
                    options: options,
                    allowsMultipleSelections: mode == "multiple",
                    // MSP takes only the options it offered, for every question it asked.
                    requiresAnswer: true
                )
            ))
        }
        let toolName = params["toolName"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        return MuseUserInputPrompt(
            userInputID: userInputID,
            title: toolName.map(title(for:)) ?? L10n.string("Question"),
            questions: questions
        )
    }

    func permissionDecision(for MSPDecision: String) -> PermissionDecision? {
        if MSPDecision == "approved"
            || MSPDecision == "approvedForSession"
            || MSPDecision == "approvedPolicyAmendment" {
            return .allow
        }
        if MSPDecision == "denied"
            || MSPDecision == "deniedPolicyAmendment"
            || MSPDecision == "timedOut"
            || MSPDecision == "abort" {
            return .deny
        }
        return nil
    }

    private func title(for value: String) -> String {
        value
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { word in
                guard let first = word.first else { return "" }
                return first.uppercased() + word.dropFirst()
            }
            .joined(separator: " ")
    }
}
