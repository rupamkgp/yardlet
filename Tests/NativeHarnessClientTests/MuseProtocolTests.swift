import Foundation
import XCTest
@testable import NativeHarnessClient

final class MuseProtocolTests: XCTestCase {
    func testStableMSPV1RequestShapesMatchOfficialSchema() throws {
        let initialize = MuseProtocol.initialize(id: 1)
        XCTAssertEqual(initialize["method"]?.stringValue, "initialize")
        XCTAssertEqual(
            initialize["params"]?["clientInfo"]?["name"]?.stringValue,
            "yardlet"
        )

        let workspace = URL(filePath: "/home/me/src/proj")
        let start = MuseProtocol.startSession(
            id: 2,
            commandID: "0198f0ab-9999-7000-8000-0000000000c1",
            workspaceURL: workspace
        )
        XCTAssertEqual(start["method"]?.stringValue, "session/start")
        XCTAssertEqual(
            start["params"],
            .object([
                "commandId": .string("0198f0ab-9999-7000-8000-0000000000c1"),
                "workspaceRoot": .string("/home/me/src/proj")
            ])
        )

        let resume = MuseProtocol.resumeSession(
            id: 9,
            commandID: "0198f0ab-8888-7000-8000-0000000000c2",
            providerSessionID: "0198f0aa-1111-7000-8000-0000000000aa"
        )
        XCTAssertEqual(resume["method"]?.stringValue, "session/resume")
        XCTAssertEqual(
            resume["params"]?["sessionId"]?.stringValue,
            "0198f0aa-1111-7000-8000-0000000000aa"
        )

        let turn = MuseProtocol.startTurn(
            id: 3,
            commandID: "018f6a1e-9b3c-7c21-a54a-2f30bd3c9f10",
            providerSessionID: "0198f0aa-1111-7000-8000-0000000000aa",
            prompt: "Run the agent test suite and summarize failures"
        )
        XCTAssertEqual(turn["method"]?.stringValue, "turn/start")
        XCTAssertEqual(
            turn["params"]?["input"],
            .array([.object([
                "type": .string("text"),
                "text": .string("Run the agent test suite and summarize failures")
            ])])
        )

        let models = MuseProtocol.listModels(
            id: 6,
            providerSessionID: "0198f0aa-1111-7000-8000-0000000000aa"
        )
        XCTAssertEqual(models["method"]?.stringValue, "model/list")
        let setModel = MuseProtocol.setModel(
            id: 7,
            commandID: "0198f0ab-7777-7000-8000-0000000000c3",
            providerSessionID: "0198f0aa-1111-7000-8000-0000000000aa",
            providerID: "meta",
            profileID: nil,
            modelID: "muse-large-3",
            displayLabel: "Muse Large 3"
        )
        XCTAssertEqual(setModel["method"]?.stringValue, "session/setModel")
        XCTAssertEqual(setModel["params"]?["model"]?["modelId"]?.stringValue, "muse-large-3")
        let approvalMode = MuseProtocol.setApprovalMode(
            id: 8,
            commandID: "0198f0ab-6666-7000-8000-0000000000c4",
            providerSessionID: "0198f0aa-1111-7000-8000-0000000000aa",
            mode: "denyUnmatched"
        )
        XCTAssertEqual(approvalMode["method"]?.stringValue, "session/setApprovalMode")
        XCTAssertEqual(approvalMode["params"]?["mode"]?.stringValue, "denyUnmatched")
        let compact = MuseProtocol.compactSession(
            id: 9,
            commandID: "0198f0ab-5555-7000-8000-0000000000c5",
            providerSessionID: "0198f0aa-1111-7000-8000-0000000000aa"
        )
        XCTAssertEqual(compact["method"]?.stringValue, "session/compact")

        let interrupt = MuseProtocol.interruptTurn(
            id: 4,
            commandID: "018f6a22-4a0f-7000-8000-00000000df0f",
            providerSessionID: "0198f0aa-1111-7000-8000-0000000000aa",
            turnID: "018f6a1e-9b3c-7c21-a54a-2f30bd3c9f10"
        )
        XCTAssertEqual(interrupt["method"]?.stringValue, "turn/interrupt")
        XCTAssertEqual(
            interrupt["params"]?["turnId"]?.stringValue,
            "018f6a1e-9b3c-7c21-a54a-2f30bd3c9f10"
        )

        let decision = MuseProtocol.decideApproval(
            id: 5,
            commandID: "018f6a2a-3333-7abc-8def-00000000d001",
            providerSessionID: "0198f0aa-1111-7000-8000-0000000000aa",
            approvalID: "0198f0ac-7777-7000-8000-0000000000e1",
            sourceIndex: 0,
            choiceID: "allow_session"
        )
        XCTAssertEqual(decision["method"]?.stringValue, "approval/decide")
        XCTAssertEqual(decision["params"]?["choiceId"]?.stringValue, "allow_session")
        XCTAssertEqual(
            decision["params"]?["requirementId"],
            .object([
                "approvalId": .string("0198f0ac-7777-7000-8000-0000000000e1"),
                "sourceIndex": .integer(0)
            ])
        )
    }

    /// Muse 1.4.0 schema `TurnInputPart`: `{type: "image", base64Data, mediaType}` beside the
    /// text part; `width`/`height` are an optional pair the host measures when absent.
    func testTurnStartCarriesImagesAsTheirOwnInputParts() {
        let image = HarnessUserInput.EncodedImage(mimeType: "image/png", base64Data: "iVBORw0KGgo=")
        let turn = MuseProtocol.startTurn(
            id: 3,
            commandID: "018f6a1e-9b3c-7c21-a54a-2f30bd3c9f10",
            providerSessionID: "0198f0aa-1111-7000-8000-0000000000aa",
            prompt: "Describe the attached image.",
            images: [image]
        )
        XCTAssertEqual(
            turn["params"]?["input"],
            .array([
                .object([
                    "type": .string("text"),
                    "text": .string("Describe the attached image.")
                ]),
                .object([
                    "type": .string("image"),
                    "base64Data": .string("iVBORw0KGgo="),
                    "mediaType": .string("image/png")
                ])
            ])
        )

        // An image-only turn has no empty text part; MSP needs the list non-empty, not text.
        let imageOnly = MuseProtocol.startTurn(
            id: 4,
            commandID: "018f6a1e-9b3c-7c21-a54a-2f30bd3c9f11",
            providerSessionID: "0198f0aa-1111-7000-8000-0000000000aa",
            prompt: "",
            images: [image]
        )
        XCTAssertEqual(
            imageOnly["params"]?["input"]?.arrayValue?.map { $0["type"]?.stringValue },
            ["image"]
        )
    }

    func testCommandIDMintProducesDistinctRFC9562UUIDv7Values() {
        var mint = MuseCommandIDMint()
        let instant = Date(timeIntervalSince1970: 1_754_590_931.5)
        let first = mint.next(now: instant)
        let second = mint.next(now: instant)
        let pattern = #"^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"#
        XCTAssertNotNil(first.range(of: pattern, options: .regularExpression))
        XCTAssertNotNil(second.range(of: pattern, options: .regularExpression))
        XCTAssertNotEqual(first, second)
    }

    func testRecordedItemAndApprovalShapesProjectWithoutInventingFields() throws {
        let projector = MuseEventProjector()
        let delta = try frame(
            #"{"jsonrpc":"2.0","method":"item/delta","params":{"sessionId":"0198f0aa-1111-7000-8000-0000000000aa","viewCursor":"v:0198f0aa-1111-7000-8000-0000000000aa:7","itemId":"0198f0ac-4242-7000-8000-000000000042","field":"text","delta":"All 214 tests pass"},"emittedAtMs":1754590941100}"#
        )
        XCTAssertEqual(
            projector.assistantDelta(from: delta["params"] ?? .object([:]), itemKind: "agentMessage"),
            "All 214 tests pass"
        )

        let completed = try frame(
            #"{"jsonrpc":"2.0","method":"item/completed","params":{"sessionId":"0198f0aa-1111-7000-8000-0000000000aa","viewCursor":"v:0198f0aa-1111-7000-8000-0000000000aa:9","sourceRange":{"stream":{"kind":"run","id":"018f6a1e-9b3c-7c21-a54a-2f30bd3c9f10"},"first":{"id":"018f9008-71aa-7000-8000-000000000003","sequence":3},"last":{"id":"018f9008-71aa-7000-8000-000000000003","sequence":3}},"item":{"itemId":"0198f0ac-4242-7000-8000-000000000042","kind":"agentMessage","turnId":"018f6a1e-9b3c-7c21-a54a-2f30bd3c9f10","revision":2,"status":"completed","recordedAt":"2026-08-07T18:42:34.300Z","text":"All 214 tests pass and no failures were found."}},"emittedAtMs":1754590944300}"#
        )
        XCTAssertEqual(
            projector.assistantCompletion(from: completed["params"]?["item"] ?? .object([:])),
            "All 214 tests pass and no failures were found."
        )

        let approval = try frame(Self.recordedApprovalRequest)
        let request = try XCTUnwrap(
            projector.permissionRequest(from: approval["params"] ?? .object([:]))
        )
        XCTAssertEqual(request.id, "0198f0ac-7777-7000-8000-0000000000e1")
        XCTAssertEqual(request.actions.map(\.id), ["allow_once", "allow_session", "abort"])
        XCTAssertEqual(request.actions.map(\.decision), [.allow, .allow, .deny])
    }

    /// Muse 1.4.0 schema: a `reasoning` item streams `summary` part *n* on field `summary.n`,
    /// and its raw `text` is committed, not streamed, in v1.
    func testReasoningFollowsTheSchemaSummaryFieldsAndNotTheAnswerText() {
        let projector = MuseEventProjector()
        func params(field: String?, _ delta: String) -> JSONValue {
            var params: [String: JSONValue] = [
                "sessionId": .string("0198f0aa-1111-7000-8000-0000000000aa"),
                "itemId": .string("0198f0ac-6161-7000-8000-000000000061"),
                "delta": .string(delta)
            ]
            if let field { params["field"] = .string(field) }
            return .object(params)
        }

        XCTAssertEqual(
            projector.reasoningDelta(from: params(field: "summary.2", "Plan"), itemKind: "reasoning"),
            MuseReasoningDelta(summaryPart: 2, text: "Plan")
        )
        // Only reasoning has a summary, so a delta that outran its item's start still counts.
        XCTAssertEqual(
            projector.reasoningDelta(from: params(field: "summary.0", "Plan"), itemKind: nil),
            MuseReasoningDelta(summaryPart: 0, text: "Plan")
        )
        XCTAssertNil(projector.reasoningDelta(from: params(field: nil, "Hi"), itemKind: nil))
        XCTAssertNil(projector.reasoningDelta(from: params(field: "summary.x", "Hi"), itemKind: nil))
        XCTAssertNil(
            projector.reasoningDelta(from: params(field: "output", "ok"), itemKind: "reasoning")
        )
        XCTAssertNil(
            projector.assistantDelta(from: params(field: "summary.0", "Plan"), itemKind: "reasoning")
        )

        XCTAssertEqual(
            projector.reasoningCompletion(from: .object([
                "kind": .string("reasoning"),
                "summary": .array([.string("First."), .string(""), .string("Second.")]),
                "text": .string("raw chain")
            ])),
            "First.\n\nSecond."
        )
        XCTAssertEqual(
            projector.reasoningCompletion(from: .object([
                "kind": .string("reasoning"),
                "summary": .array([]),
                "text": .string("raw chain")
            ])),
            "raw chain"
        )
        XCTAssertNil(projector.reasoningCompletion(from: .object(["kind": .string("agentMessage")])))
    }

    /// Muse 1.4.0 schema: a client renders a kind it does not recognize by its kind name, its
    /// `status` and the item's `fallbackText`. `reminderChild` has no card of its own here, so its
    /// summary titles the card, with the kind and status beside it as for any activity.
    func testAKindWithoutItsOwnCardIsTitledByTheServersFallbackText() throws {
        let projector = MuseEventProjector()
        let completed = try frame(
            #"{"jsonrpc":"2.0","method":"item/completed","params":{"sessionId":"0198f0aa-1111-7000-8000-0000000000aa","viewCursor":"v:0198f0aa-1111-7000-8000-0000000000aa:12","sourceRange":{"stream":{"kind":"run","id":"018f6a1e-9b3c-7c21-a54a-2f30bd3c9f10"},"first":{"id":"018f9008-71aa-7000-8000-000000000011","sequence":11},"last":{"id":"018f9008-71aa-7000-8000-000000000012","sequence":12}},"item":{"itemId":"018f9008-71aa-7000-8000-000000000011","kind":"reminderChild","turnId":"018f6a1e-9b3c-7c21-a54a-2f30bd3c9f10","revision":2,"status":"completed","recordedAt":"2026-08-07T18:42:35.100Z","fallbackText":"Reminder child session","childSessionId":"0198f0ad-2222-7000-8000-0000000000c1","reminderAgentId":"memory","generationId":1,"taskId":"0198f0ad-3333-7000-8000-0000000000d1"}},"emittedAtMs":1754590955100}"#
        )
        let item = completed["params"]?["item"] ?? .object([:])
        let activity = try XCTUnwrap(projector.activity(from: item))
        XCTAssertEqual(activity.title, "Reminder child session")
        XCTAssertEqual(activity.kind, "reminderChild")
        XCTAssertNil(activity.outcome)

        // A revision that leaves the summary out keeps the title the card already has.
        let bare: JSONValue = .object([
            "itemId": .string("018f9008-71aa-7000-8000-000000000011"),
            "kind": .string("reminderChild"),
            "revision": .integer(3),
            "status": .string("failed")
        ])
        let failed = try XCTUnwrap(projector.activity(from: bare, fallback: activity))
        XCTAssertEqual(failed.title, "Reminder child session")
        XCTAssertEqual(failed.outcome, .failed)

        // With no summary at all the kind name stands in, as it did before.
        XCTAssertEqual(projector.activity(from: bare)?.title, "ReminderChild")

        // A tool call keeps its tool name whatever summary it carries.
        let toolCall = try XCTUnwrap(projector.activity(from: .object([
            "itemId": .string("0198f0ac-4242-7000-8000-000000000042"),
            "kind": .string("toolCall"),
            "revision": .integer(1),
            "status": .string("inProgress"),
            "tool": .string("write_file"),
            "fallbackText": .string("Writing Cargo.toml")
        ])))
        XCTAssertEqual(toolCall.title, "Write File")
    }

    func testUserInputRequestBecomesTheSharedQuestionCard() throws {
        let params = try frame(Self.userInputRequest)["params"] ?? .object([:])
        let prompt = try XCTUnwrap(MuseEventProjector().userInputPrompt(from: params))
        XCTAssertEqual(prompt.userInputID, Self.userInputID)
        // The request names no tool, so the card keeps a neutral title.
        XCTAssertEqual(prompt.title, L10n.string("Question"))
        let request = prompt.permissionRequest
        XCTAssertEqual(request.id, Self.userInputID)
        XCTAssertEqual(request.actions, [])
        XCTAssertEqual(request.structured, .questions([
            PermissionQuestion(
                question: "Which verification target should run?",
                header: "Target",
                options: [
                    PermissionQuestionOption(label: "Unit tests", description: "swift test --filter"),
                    PermissionQuestionOption(label: "Full suite")
                ],
                // MSP answers only with its options, for every question: no own answer, no skip.
                requiresAnswer: true
            ),
            PermissionQuestion(
                question: "Which platforms should it cover?",
                options: [
                    PermissionQuestionOption(label: "macOS"),
                    PermissionQuestionOption(label: "Linux")
                ],
                allowsMultipleSelections: true,
                requiresAnswer: true
            )
        ]))

        var named = params.objectValue ?? [:]
        named["toolName"] = .string("ask_user")
        XCTAssertEqual(MuseEventProjector().userInputPrompt(from: .object(named))?.title, "Ask User")
    }

    func testUserInputAnswersNameEveryQuestionByItsIDInThePromptsOrder() throws {
        let params = try frame(Self.userInputRequest)["params"] ?? .object([:])
        let prompt = try XCTUnwrap(MuseEventProjector().userInputPrompt(from: params))
        let answers = try XCTUnwrap(prompt.wireAnswers(for: [
            PermissionQuestionAnswer(question: "Which platforms should it cover?", selectedLabels: ["macOS", "Linux"]),
            PermissionQuestionAnswer(question: "Which verification target should run?", selectedLabels: ["Full suite"])
        ]))
        XCTAssertEqual(answers, [
            .object(["questionId": .string("q-target"), "selectedLabel": .string("Full suite")]),
            .object([
                "questionId": .string("q-platforms"),
                "selectedLabels": .array([.string("macOS"), .string("Linux")])
            ])
        ])

        // MSP answers every question: an unanswered one, two picks for a single choice, or a
        // label the prompt never offered leaves nothing to send.
        XCTAssertNil(prompt.wireAnswers(for: [
            PermissionQuestionAnswer(question: "Which verification target should run?", selectedLabels: ["Unit tests"])
        ]))
        XCTAssertNil(prompt.wireAnswers(for: [
            PermissionQuestionAnswer(question: "Which verification target should run?", selectedLabels: ["Unit tests", "Full suite"]),
            PermissionQuestionAnswer(question: "Which platforms should it cover?", selectedLabels: ["macOS"])
        ]))
        XCTAssertNil(prompt.wireAnswers(for: [
            PermissionQuestionAnswer(question: "Which verification target should run?", selectedLabels: ["Unit tests"]),
            PermissionQuestionAnswer(question: "Which platforms should it cover?", selectedLabels: ["Windows"])
        ]))
    }

    func testUserInputShapesTheCardCannotAnswerAreNotPresented() throws {
        let params = try frame(Self.userInputRequest)["params"] ?? .object([:])
        let projector = MuseEventProjector()
        func variant(_ change: (inout [String: JSONValue]) -> Void) -> JSONValue {
            var question = params["questions"]?.arrayValue?.first?.objectValue ?? [:]
            change(&question)
            var object = params.objectValue ?? [:]
            object["questions"] = .array([.object(question)])
            return .object(object)
        }
        XCTAssertNotNil(projector.userInputPrompt(from: variant { _ in }))
        // A free-text question has no options for the card to offer.
        XCTAssertNil(projector.userInputPrompt(from: variant { $0["options"] = .array([]) }))
        // A selection mode other than MSP v1's two is not guessed at, nor is a missing one.
        XCTAssertNil(projector.userInputPrompt(from: variant {
            $0["selection"] = .object(["mode": .string("ranked")])
        }))
        XCTAssertNil(projector.userInputPrompt(from: variant { $0.removeValue(forKey: "selection") }))
        XCTAssertNil(projector.userInputPrompt(from: variant { $0.removeValue(forKey: "id") }))

        var duplicate = params.objectValue ?? [:]
        let first = params["questions"]?.arrayValue?.first ?? .null
        var copy = first.objectValue ?? [:]
        copy["id"] = .string("q-again")
        duplicate["questions"] = .array([first, .object(copy)])
        XCTAssertNil(projector.userInputPrompt(from: .object(duplicate)))

        var empty = params.objectValue ?? [:]
        empty["questions"] = .array([])
        XCTAssertNil(projector.userInputPrompt(from: .object(empty)))
    }

    func testUserInputCommandsAndUsageReadFollowTheSchema() {
        let answer = MuseProtocol.answerUserInput(
            id: 11,
            commandID: "0198f0ab-7777-7000-8000-0000000000c3",
            providerSessionID: "0198f0aa-1111-7000-8000-0000000000aa",
            userInputID: Self.userInputID,
            answers: [.object(["questionId": .string("q-target"), "selectedLabel": .string("Unit tests")])]
        )
        XCTAssertEqual(answer["method"]?.stringValue, "userInput/answer")
        XCTAssertEqual(answer["params"], .object([
            "commandId": .string("0198f0ab-7777-7000-8000-0000000000c3"),
            "sessionId": .string("0198f0aa-1111-7000-8000-0000000000aa"),
            "userInputId": .string(Self.userInputID),
            "answers": .array([.object([
                "questionId": .string("q-target"), "selectedLabel": .string("Unit tests")
            ])])
        ]))

        let cancel = MuseProtocol.cancelUserInput(
            id: 12,
            commandID: "0198f0ab-7777-7000-8000-0000000000c4",
            providerSessionID: "0198f0aa-1111-7000-8000-0000000000aa",
            userInputID: Self.userInputID,
            reason: "The user declined to answer."
        )
        XCTAssertEqual(cancel["method"]?.stringValue, "userInput/cancel")
        XCTAssertEqual(cancel["params"]?["reason"]?.stringValue, "The user declined to answer.")
        XCTAssertEqual(cancel["params"]?["userInputId"]?.stringValue, Self.userInputID)

        // `usage/read` declares no params type, so the request carries none.
        let usage = MuseProtocol.readUsage(id: 13)
        XCTAssertEqual(usage["method"]?.stringValue, "usage/read")
        XCTAssertNil(usage["params"])

        let receipt = MuseProtocol.cannotPresent(id: .integer(7))
        XCTAssertEqual(receipt["id"], .integer(7))
        XCTAssertNil(receipt["result"])
        XCTAssertEqual(receipt["error"]?["code"]?.integerValue, -32602)
    }

    private func frame(_ raw: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(raw.utf8))
    }

    static let userInputID = "0198f0ae-5555-7000-8000-0000000000f1"

    /// `userInput/request` with the member names of the MSP v1 schema that Muse Code
    /// 1.4.0-R4161.1 embeds (`UserInputRequestParams`, `UserInputQuestion`, `UserInputSelection`,
    /// `UserInputOption`, `UserInputOptionPreview`). Assembled from that schema; no live prompt
    /// was recorded, because doing so needs a model turn.
    static let userInputRequest = #"{"jsonrpc":"2.0","id":7,"method":"userInput/request","params":{"sessionId":"0198f0aa-1111-7000-8000-0000000000aa","userInputId":"0198f0ae-5555-7000-8000-0000000000f1","turnId":"018f6a1e-9b3c-7c21-a54a-2f30bd3c9f10","itemId":"0198f0ac-4343-7000-8000-000000000043","toolCallId":"call_ask_1","viewCursor":"v:0198f0aa-1111-7000-8000-0000000000aa:13","sourceRange":{"stream":{"kind":"session","id":"0198f0aa-1111-7000-8000-0000000000aa"},"first":{"id":"0198f0ae-0001-7000-8000-000000000001","sequence":40},"last":{"id":"0198f0ae-0001-7000-8000-000000000001","sequence":40}},"questions":[{"id":"q-target","header":"Target","question":"Which verification target should run?","selection":{"mode":"single"},"options":[{"label":"Unit tests","description":"swift test --filter"},{"label":"Full suite","preview":{"format":"text","content":"swift test"}}]},{"id":"q-platforms","question":"Which platforms should it cover?","selection":{"mode":"multiple","minSelections":1,"maxSelections":2},"options":[{"label":"macOS"},{"label":"Linux"}]}]}}"#

    static let recordedApprovalRequest = #"{"jsonrpc":"2.0","id":1,"method":"approval/request","params":{"sessionId":"0198f0aa-1111-7000-8000-0000000000aa","viewCursor":"v:0198f0aa-1111-7000-8000-0000000000aa:7","sourceRange":{"stream":{"kind":"approval.review","id":"0198f0ac-6000-7000-8000-0000000000b1"},"first":{"id":"0198f0ad-0001-7000-8000-000000000001","sequence":1},"last":{"id":"0198f0ad-0001-7000-8000-000000000001","sequence":1}},"approvalId":"0198f0ac-7777-7000-8000-0000000000e1","turnId":"018f6a1e-9b3c-7c21-a54a-2f30bd3c9f10","taskId":"0198f0ac-4000-7000-8000-000000000010","itemId":"0198f0ac-4242-7000-8000-000000000042","toolCallId":"call_9f21","toolName":"write_file","rawArgs":"{\"path\":\"Cargo.toml\"}","subject":{"kind":"fileAccess","toolName":"write_file","path":"/home/me/src/proj/Cargo.toml","access":"write"},"currentRequirementId":{"approvalId":"0198f0ac-7777-7000-8000-0000000000e1","sourceIndex":0},"availableChoices":[{"choiceId":"allow_once","label":"Allow once","decision":"approved","scope":"once"},{"choiceId":"allow_session","label":"Allow for this session","decision":"approvedForSession","scope":"session","rulePreview":"write /home/me/src/proj/Cargo.toml"},{"choiceId":"abort","label":"Reject","decision":"abort","scope":"once","acceptsFeedback":true}],"protectedWrite":false,"judgeEscalated":false}}"#
}
