import Foundation
import XCTest
@testable import NativeHarnessClient

/// `ConversationPlan.parse` reads the plan strings the adapters write as steps, and leaves
/// anything else as the provider's text.
final class ConversationPlanParseTests: XCTestCase {
    func testClaudeTaskListReadsAsSteps() {
        XCTAssertEqual(ConversationPlan.parse("☑ Read the code\n◉ Run checks\n☐ Write the summary", stepIDPrefix: "e"), steps(nil, [
            ("e:plan:0", "Read the code", .completed),
            ("e:plan:1", "Run checks", .inProgress),
            ("e:plan:2", "Write the summary", .pending)
        ]))
    }

    func testClaudeTaskListAsTheAdapterWritesIt() {
        // The strings the Claude projection emits, straight from its own tool results.
        var tasks = ClaudeTaskListProjection()
        let input = JSONValue.object(["todos": .array([
            .object(["content": .string("Read the code"), "status": .string("completed")]),
            .object(["content": .string("Run checks"), "status": .string("in_progress")]),
            .object(["content": .string("Ship"), "status": .string("pending")])
        ])])
        let text = tasks.completedTool(name: "TodoWrite", input: input, result: nil)!
        XCTAssertEqual(ConversationPlan.parse(text), steps(nil, [
            ("plan:plan:0", "Read the code", .completed),
            ("plan:plan:1", "Run checks", .inProgress),
            ("plan:plan:2", "Ship", .pending)
        ]))
        // An empty list is Claude's own words, not an empty plan.
        let empty = tasks.completedTool(name: "TodoWrite", input: .object(["todos": .array([])]), result: nil)!
        XCTAssertEqual(ConversationPlan.parse(empty), block(empty))
    }

    func testACPEntriesReadAsStepsAndKeepAnUnknownStatus() {
        XCTAssertEqual(
            ConversationPlan.parse("[completed] Inspect\n[in_progress] Implement\n[pending] Verify\n[blocked] Ship"),
            steps(nil, [
                ("plan:plan:0", "Inspect", .completed),
                ("plan:plan:1", "Implement", .inProgress),
                ("plan:plan:2", "Verify", .pending),
                ("plan:plan:3", "Ship", .unknown("blocked"))
            ])
        )
    }

    func testCodexCommonEventKeepsItsExplanationParagraph() {
        XCTAssertEqual(ConversationPlan.parse("Two steps left.\n\n[x] Inspect\n[~] Implement\n[ ] Verify"), steps("Two steps left.", [
            ("plan:plan:0", "Inspect", .completed),
            ("plan:plan:1", "Implement", .inProgress),
            ("plan:plan:2", "Verify", .pending)
        ]))
        XCTAssertEqual(ConversationPlan.parse("[x] Inspect\n[~] Implement"), steps(nil, [
            ("plan:plan:0", "Inspect", .completed),
            ("plan:plan:1", "Implement", .inProgress)
        ]))
    }

    func testBlankLinesBetweenStepsAndWindowsLineEndingsAreSteps() {
        XCTAssertEqual(ConversationPlan.parse("☐ One\r\n\r\n☑ Two\n"), steps(nil, [
            ("plan:plan:0", "One", .pending),
            ("plan:plan:1", "Two", .completed)
        ]))
    }

    func testAnythingElseStaysOneTextBlock() {
        for text in [
            "1. Preserve event order\n2. Group completed work\n3. Render the final answer",
            "# Plan\n\n- [ ] Inspect\n- [x] Implement",
            // A step whose text runs onto another line is not a step list.
            "[pending] Inspect\n  the adapter",
            // An explanation glued to the steps is not Codex's paragraph.
            "Plan:\n☐ Inspect",
            "[link](https://example.invalid) is not a step",
            "☐",
            "",
            "Just prose."
        ] {
            XCTAssertEqual(ConversationPlan.parse(text), block(text), text)
        }
    }

    func testParseLeavesTheSourceToTheProjection() {
        XCTAssertNil(ConversationPlan.parse("☐ One").source)
    }

    private func steps(_ explanation: String?, _ steps: [(String, String, ConversationPlan.StepStatus)]) -> ConversationPlan {
        ConversationPlan(explanation: explanation, steps: steps.map { ConversationPlan.Step(id: $0.0, text: $0.1, status: $0.2) })
    }

    /// Text that is not a step list: one block, the explanation of a plan with no steps.
    private func block(_ text: String) -> ConversationPlan {
        ConversationPlan(explanation: text, steps: [])
    }
}
