import Foundation
import XCTest
@testable import NativeHarnessClient

/// Antigravity CLI 1.4.0's `--output-format stream-json`, as the sandbox turns of 2026-10-16 printed
/// it (keys and value types as observed; every value here is a fixture), and the flags each choice
/// becomes.
final class AntigravityProtocolTests: XCTestCase {
    private let projector = StructuredHeadlessEventProjector(flavor: .antigravity)

    // MARK: - Events

    func testInitAndStepsCarryTheConversationAndUserStepsShowNothing() throws {
        let initEvent = project(#"{"event":"init","conversation_id":"agy-fixture","init":{"model":"fixture-model-low","cwd":"/tmp/fixture","tools":["run_command","view_file"],"permission_mode":"request-review"}}"#)
        XCTAssertEqual(initEvent.providerSessionID, "agy-fixture")
        XCTAssertEqual(initEvent.payloads, [])
        for step in [
            #"{"event":"step_update","step_update":{"conversation_id":"agy-fixture","step_index":0,"state":"DONE","step_type":"user_input"}}"#,
            #"{"event":"step_update","step_update":{"conversation_id":"agy-fixture","step_index":1,"state":"DONE","step_type":"system_message","duration_seconds":0.01}}"#,
            #"{"event":"step_update","step_update":{"conversation_id":"agy-fixture","step_index":2,"state":"DONE","step_type":"agent_response","duration_seconds":1.2,"usage":{"input_tokens":100,"output_tokens":5,"thinking_tokens":3,"cache_read_tokens":0,"total_tokens":108}}}"#
        ] {
            let projection = project(step)
            XCTAssertEqual(projection.providerSessionID, "agy-fixture")
            XCTAssertEqual(projection.payloads, [])
            XCTAssertFalse(projection.isTerminal)
        }
        XCTAssertEqual(
            project(#"{"event":"step_update","step_update":{"conversation_id":"agy-fixture","step_index":3,"state":"ACTIVE","step_type":"agent_response","text_delta":"Fixture"}}"#).payloads,
            [.assistantDelta("Fixture")])
    }

    /// The tool card shows the call's `parameters` and its `output` (earlier runs said `args` and
    /// `result`), and a step that ends in ERROR fails even without an error message.
    func testToolStepsShowParametersAndOutputAndTheirEndState() throws {
        let started = try XCTUnwrap(activity(project(#"{"event":"step_update","step_update":{"conversation_id":"agy-fixture","step_index":4,"state":"ACTIVE","step_type":"tool","tool_name":"run_command","tool_info":{"name":"run_command","parameters":{"CommandLine":"echo fixture"}}}}"#), completed: false))
        XCTAssertEqual(started.id, "agy-fixture-4")
        XCTAssertEqual(started.input, "echo fixture")
        XCTAssertNil(started.output)
        XCTAssertEqual(started.title, "run command")

        let done = try XCTUnwrap(activity(project(#"{"event":"step_update","step_update":{"conversation_id":"agy-fixture","step_index":4,"state":"DONE","step_type":"tool","tool_name":"run_command","duration_seconds":0.2,"tool_info":{"name":"run_command","parameters":{"CommandLine":"echo fixture"},"output":"fixture output"}}}"#), completed: true))
        XCTAssertEqual(done.output, "fixture output")
        XCTAssertNil(done.outcome)

        let failed = try XCTUnwrap(activity(project(#"{"event":"step_update","step_update":{"conversation_id":"agy-fixture","step_index":5,"state":"ERROR","step_type":"tool","tool_name":"view_file","tool_info":{"name":"view_file","parameters":{"AbsolutePath":"/tmp/fixture.txt"}}}}"#), completed: true))
        XCTAssertEqual(failed.outcome, .failed)

        let denied = try XCTUnwrap(activity(project(#"{"event":"step_update","step_update":{"conversation_id":"agy-fixture","step_index":6,"state":"ERROR","step_type":"tool","tool_name":"run_command","duration_seconds":0.1,"tool_info":{"name":"run_command","parameters":{"CommandLine":"pwd"},"error":{"type":"TOOL_ERROR","message":"fixture permission message"}}}}"#), completed: true))
        XCTAssertEqual(denied.outcome, .failed)
        XCTAssertEqual(denied.output, "fixture permission message")
        XCTAssertEqual(denied.input, "pwd")

        let canceled = try XCTUnwrap(activity(project(#"{"event":"step_update","step_update":{"conversation_id":"agy-fixture","step_index":7,"state":"CANCELED","step_type":"tool","tool_name":"run_command","tool_info":{"name":"run_command","parameters":{"CommandLine":"sleep 9"}}}}"#), completed: true))
        XCTAssertEqual(canceled.outcome, .stopped)
    }

    /// `denied_actions` lists what the run could not ask about. A turn that stopped there without a
    /// word completes with one failed row naming the actions once each.
    func testDeniedActionsAreOneFailedRowBeforeTheTurnCompletes() throws {
        let projection = project(#"{"event":"result","result":{"conversation_id":"agy-fixture","status":"SUCCESS","response":"","duration_seconds":2,"num_turns":1,"usage":{"input_tokens":100,"output_tokens":5,"thinking_tokens":0,"cache_read_tokens":0,"total_tokens":105},"denied_actions":[{"action":"command","display_name":"Run command"},{"action":"command","display_name":"Run command"},{"action":"url","display_name":"Read URL"}]}}"#)
        XCTAssertTrue(projection.isTerminal)
        XCTAssertEqual(projection.payloads.last, .turnCompleted)
        guard case let .activityCompleted(row) = projection.payloads.first else {
            return XCTFail("Expected the denied actions row, got \(projection.payloads)")
        }
        XCTAssertEqual(row.kind, "denied_actions")
        XCTAssertEqual(row.outcome, .failed)
        XCTAssertEqual(row.detail, "Run command, Read URL")
        XCTAssertEqual(row.input, "Run command\nRead URL")
        // The CLI's own refusal, and Bypass permissions as the way to let commands run.
        XCTAssertEqual(row.output, L10n.string("Antigravity CLI refused these without asking in this permission mode. To let it run commands, choose Bypass permissions."))
        XCTAssertFalse(projection.payloads.contains { if case .error = $0 { return true }; return false })

        // A turn that answered explains the refusal itself; its refused calls are failed rows already.
        let answered = projector.project(try JSONDecoder().decode(JSONValue.self, from: Data(#"{"event":"result","result":{"conversation_id":"agy-fixture","status":"SUCCESS","response":"I could not run it.","denied_actions":[{"action":"command","display_name":"Run command"}]}}"#.utf8)),
                                         hasAssistantText: true)
        XCTAssertEqual(answered.payloads, [.turnCompleted])

        // Without denials the result is as before.
        XCTAssertEqual(project(#"{"event":"result","result":{"conversation_id":"agy-fixture","status":"SUCCESS","response":"fixture answer"}}"#).payloads,
                       [.assistantMessageCompleted("fixture answer"), .turnCompleted])
    }

    /// The projector alone reports a stopped run's ERROR result as the error it says; the adapter,
    /// which knows it asked for the stop, drops it (StructuredHeadlessAdapterTests).
    func testAnInterruptedResultIsAnErrorToTheProjector() {
        let projection = project(#"{"event":"result","result":{"conversation_id":"agy-fixture","status":"ERROR","response":"part","error":"interrupted","duration_seconds":1,"num_turns":1}}"#)
        XCTAssertTrue(projection.isTerminal)
        XCTAssertEqual(projection.payloads, [.error(message: "interrupted", recoverable: true)])
    }

    // MARK: - Models and efforts

    /// `agy models` 1.4.0 lists effort variants as models of their own.
    private static let listedModels: [ProviderCapabilityChoice] = [
        ("gemini-3.8-flash-high", "Gemini 3.8 Flash (High)"),
        ("gemini-3.8-flash-medium", "Gemini 3.8 Flash (Medium)"),
        ("gemini-3.8-flash-low", "Gemini 3.8 Flash (Low)"),
        ("claude-sonnet-4-6", "Claude Sonnet 4.6 (Thinking)"),
        ("claude-opus-4-6-thinking", "Claude Opus 4.6 (Thinking)"),
        ("gpt-oss-120b-medium", "GPT-OSS 120B (Medium)")
    ].map { ProviderCapabilityChoice(value: $0.0, name: $0.1, description: nil) }

    func testTheModelListFoldsEffortVariantsIntoOneModel() {
        let catalog = AntigravityModelCatalog(choices: Self.listedModels)
        XCTAssertEqual(catalog.models.map(\.id),
                       ["gemini-3.8-flash", "claude-sonnet-4-6", "claude-opus-4-6-thinking", "gpt-oss-120b-medium"])
        XCTAssertEqual(catalog.models.map(\.name),
                       ["Gemini 3.8 Flash", "Claude Sonnet 4.6 (Thinking)", "Claude Opus 4.6 (Thinking)", "GPT-OSS 120B (Medium)"])
        XCTAssertEqual(catalog.models.first?.efforts.map(\.value), ["low", "medium", "high"])
        XCTAssertEqual(catalog.models.first?.efforts.map(\.modelID),
                       ["gemini-3.8-flash-low", "gemini-3.8-flash-medium", "gemini-3.8-flash-high"])
        // A lone variant keeps its own name and takes no effort (`/effort` says "adjustable": false).
        XCTAssertEqual(catalog.model(for: "gpt-oss-120b-medium")?.efforts, [])
        XCTAssertEqual(catalog.model(for: "gemini-3.8-flash-low")?.id, "gemini-3.8-flash")
        XCTAssertEqual(catalog.effort(carriedBy: "gemini-3.8-flash-low"), "low")
        XCTAssertNil(catalog.effort(carriedBy: "gemini-3.8-flash"))
    }

    /// `agy` 1.4.0 refuses `--model gemini-3.8-flash-low --effort high` ("conflicts") and
    /// `--effort` on a model without levels ("not supported"), so a choice never pairs them.
    func testAChoiceNeverPairsAModelWithAnEffortTheCLIRefuses() {
        let catalog = AntigravityModelCatalog(choices: Self.listedModels)
        func launch(_ model: String?, _ effort: String?, _ list: AntigravityModelCatalog? = nil) -> [String] {
            let options = StructuredHeadlessSessionOptions(model: model, reasoningEffort: effort)
            return StructuredHeadlessFlavor.antigravity.arguments(
                prompt: "p", providerSessionID: "agy-fixture", isFirstTurn: false, options: options,
                catalog: list ?? catalog)
        }
        let tail = ["--conversation=agy-fixture"]
        let head = ["--print", "p", "--output-format", "stream-json"]
        XCTAssertEqual(launch("gemini-3.8-flash", "low"), head + ["--model", "gemini-3.8-flash-low"] + tail)
        XCTAssertEqual(launch("gemini-3.8-flash", nil), head + ["--model", "gemini-3.8-flash"] + tail)
        XCTAssertEqual(launch("gemini-3.8-flash-low", "high"), head + ["--model", "gemini-3.8-flash-low"] + tail)
        XCTAssertEqual(launch("claude-opus-4-6-thinking", "low"), head + ["--model", "claude-opus-4-6-thinking"] + tail)
        XCTAssertEqual(launch(nil, nil), head + tail)
        // Without the list (it could not be read) the saved values go as they are.
        XCTAssertEqual(StructuredHeadlessFlavor.antigravity.arguments(
            prompt: "p", providerSessionID: "agy-fixture", isFirstTurn: false,
            options: .init(model: "unlisted", reasoningEffort: "high")),
            head + ["--model", "unlisted", "--effort", "high"] + tail)
    }

    // MARK: - Permission modes

    func testPermissionModesAreTheCLIsFlags() {
        XCTAssertEqual(AntigravityPermissionMode.launchArguments(nil), [])
        XCTAssertEqual(AntigravityPermissionMode.launchArguments("default"), [])
        XCTAssertEqual(AntigravityPermissionMode.launchArguments("accept-edits"), ["--mode", "accept-edits"])
        XCTAssertEqual(AntigravityPermissionMode.launchArguments("plan"), ["--mode", "plan"])
        XCTAssertEqual(AntigravityPermissionMode.launchArguments("auto"), ["--mode", "auto"])
        XCTAssertEqual(AntigravityPermissionMode.launchArguments("bypass"), ["--dangerously-skip-permissions"])
        XCTAssertTrue(AntigravityPermissionMode.isElevated("bypass"))
        XCTAssertFalse(["default", "accept-edits", "plan", "auto"].contains(where: AntigravityPermissionMode.isElevated))
        let selector = AntigravityPermissionMode.selector(current: "plan", includesAuto: false)
        XCTAssertEqual(selector.id, "permissionMode")
        XCTAssertEqual(selector.choices.map(\.value), ["default", "accept-edits", "plan", "bypass"])
        XCTAssertEqual(selector.currentValue, "plan")
        XCTAssertEqual(ConversationSessionStatusProjection.role(for: selector), .permission)
        XCTAssertEqual(AntigravityPermissionMode.selector(current: "unknown", includesAuto: true).currentValue, "default")
        XCTAssertEqual(L10n.string("Bypass permissions", languageCode: "ko"), "권한 우회")
    }

    // MARK: - Helpers

    private func project(_ line: String) -> StructuredHeadlessProjection {
        let value = try! JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
        return projector.project(value, hasAssistantText: false)
    }

    private func activity(_ projection: StructuredHeadlessProjection, completed: Bool) -> HarnessActivity? {
        guard projection.payloads.count == 1 else { return nil }
        switch projection.payloads[0] {
        case let .activityCompleted(activity) where completed: return activity
        case let .activityStarted(activity) where !completed: return activity
        default: return nil
        }
    }
}
