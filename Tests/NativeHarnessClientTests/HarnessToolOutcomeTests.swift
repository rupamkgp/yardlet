import Foundation
import XCTest
@testable import NativeHarnessClient

final class HarnessToolOutcomeTests: XCTestCase {
    private let claudeCodec = ClaudeWireCodec()

    func testClaudeToolCardCompletesInsteadOfEndingStopped() throws {
        let projector = ClaudeEventProjector()
        let use = try claudeCodec.decodeLine(Data(
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"swift build","description":"Build"}}]}}"#.utf8
        ))
        let started = projector.payloads(from: use)
        guard case let .activityStarted(activity) = started.first else {
            return XCTFail("expected a started tool card")
        }
        XCTAssertEqual(activity.id, "toolu_1")
        XCTAssertEqual(activity.input, "swift build\n\ndescription: Build")

        let result = try claudeCodec.decodeLine(Data(
            #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_1","content":[{"type":"text","text":"Build complete!"}]}]}}"#.utf8
        ))
        let completed = projector.payloads(
            from: result,
            activities: [activity.id: activity]
        )
        guard case let .activityCompleted(finished) = completed.first else {
            return XCTFail("expected a completed tool card")
        }
        XCTAssertNil(finished.outcome)
        XCTAssertEqual(finished.title, "Bash")
        XCTAssertEqual(finished.output, "Build complete!")

        var builder = TranscriptBuilder()
        builder.appendUser("Build the package")
        started.forEach { builder.apply($0) }
        completed.forEach { builder.apply($0) }
        builder.apply(.turnCompleted)
        guard case let .activity(card, state) = builder.entries[1].content else {
            return XCTFail("expected an activity entry")
        }
        XCTAssertEqual(state, .completed)
        XCTAssertEqual(card.input?.split(separator: "\n").first, "swift build")
        XCTAssertEqual(card.output, "Build complete!")
    }

    func testClaudeToolInputShowsEachFieldOnce() throws {
        func input(_ tool: String, _ arguments: String) throws -> String? {
            let use = try claudeCodec.decodeLine(Data(
                #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu","name":"\#(tool)","input":\#(arguments)}]}}"#.utf8
            ))
            guard case let .activityStarted(activity) = ClaudeEventProjector().payloads(from: use).first else { return nil }
            return activity.input
        }
        XCTAssertEqual(try input("Bash", #"{"command":"python3 test_calc.py -v 2>&1","description":"Rerun the calc tests","timeout":60000,"run_in_background":false}"#),
                       "python3 test_calc.py -v 2>&1\n\ndescription: Rerun the calc tests\ntimeout: 60000")
        XCTAssertEqual(try input("Bash", #"{"command":"pwd"}"#), "pwd")
        XCTAssertEqual(try input("Read", #"{"file_path":"/repo/calc.py"}"#), "/repo/calc.py")
        XCTAssertEqual(
            try input("Edit", #"{"replace_all":false,"file_path":"/repo/calc.py","old_string":"def add(a, b):\n    return a - b","new_string":"def add(a, b):\n    return a + b"}"#),
            "/repo/calc.py\n\nold_string:\ndef add(a, b):\n    return a - b\n\nnew_string:\ndef add(a, b):\n    return a + b"
        )
        XCTAssertEqual(try input("Grep", #"{"pattern":"TODO","-i":true,"glob":"*.swift"}"#), "TODO\n\nglob: *.swift\n-i: true")
        // A field the card does not know is still shown, nested values as their JSON.
        let extra = try XCTUnwrap(input("Bash", #"{"command":"make","sandbox":{"network":true}}"#))
        XCTAssertTrue(extra.hasPrefix("make\n\nsandbox:\n{"))
        XCTAssertTrue(extra.contains(#""network" : true"#))
        // A tool without a known shape keeps its arguments as JSON.
        XCTAssertEqual(try input("mcp__docs__read", #"{"id":"doc-1"}"#), "{\n  \"id\" : \"doc-1\"\n}")
    }

    func testClaudeToolErrorResultMarksTheCardFailed() throws {
        let projector = ClaudeEventProjector()
        let result = try claudeCodec.decodeLine(Data(
            #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_2","is_error":true,"content":"No such file"}]}}"#.utf8
        ))
        let payloads = projector.payloads(from: result)
        guard case let .activityCompleted(activity) = payloads.first else {
            return XCTFail("expected a completed tool card")
        }
        XCTAssertEqual(activity.outcome, .failed)
        XCTAssertEqual(activity.output, "No such file")

        var builder = TranscriptBuilder()
        builder.apply(.activityStarted(HarnessActivity(
            id: "toolu_2", kind: "Read", title: "Read", input: "README.md"
        )))
        payloads.forEach { builder.apply($0) }
        builder.apply(.turnCompleted)
        guard case let .activity(card, state) = builder.entries[0].content else {
            return XCTFail("expected an activity entry")
        }
        XCTAssertEqual(state, .failed)
        XCTAssertEqual(card.input, "README.md")
    }

    func testMuseFailedItemStatusIsReportedAsAFailure() {
        let projector = MuseEventProjector()
        let item = JSONValue.object([
            "itemId": .string("item-1"),
            "kind": .string("toolCall"),
            "tool": .string("run_command"),
            "status": .string("failed"),
            "args": .object(["command": .string("swift test")]),
            "failureReason": .string("exit status 1")
        ])
        guard let activity = projector.activity(from: item) else {
            return XCTFail("expected an activity")
        }
        XCTAssertEqual(activity.outcome, .failed)
        XCTAssertEqual(activity.output, "exit status 1")
        XCTAssertEqual(activity.input?.contains("swift test"), true)

        var builder = TranscriptBuilder()
        builder.apply(.activityCompleted(activity))
        guard case let .activity(_, state) = builder.entries[0].content else {
            return XCTFail("expected an activity entry")
        }
        XCTAssertEqual(state, .failed)
    }

    func testMuseSucceededItemStaysCompleted() {
        let projector = MuseEventProjector()
        let item = JSONValue.object([
            "itemId": .string("item-2"),
            "kind": .string("toolCall"),
            "tool": .string("read_file"),
            "status": .string("completed"),
            "visibleOutput": .string("# Yardlet")
        ])
        XCTAssertNil(projector.activity(from: item)?.outcome)
    }

    func testPiToolErrorFailsTheCardAndKeepsTheArgumentsItStartedWith() {
        let projector = PiRPCEventProjector()
        let start = JSONValue.object([
            "type": .string("tool_execution_start"),
            "toolCallId": .string("pi-1"),
            "toolName": .string("bash"),
            "args": .object(["command": .string("ls /missing")])
        ])
        guard let started = projector.activity(from: start) else {
            return XCTFail("expected a started activity")
        }
        XCTAssertEqual(started.input, "ls /missing")

        let end = JSONValue.object([
            "type": .string("tool_execution_end"),
            "toolCallId": .string("pi-1"),
            "toolName": .string("bash"),
            "isError": .bool(true),
            "result": .object([
                "content": .array([
                    .object(["type": .string("text"), "text": .string("no such directory")])
                ])
            ])
        ])
        guard let finished = projector.activity(from: end, fallback: started) else {
            return XCTFail("expected a finished activity")
        }
        XCTAssertEqual(finished.outcome, .failed)
        XCTAssertEqual(finished.input, "ls /missing")
        XCTAssertEqual(finished.output, "no such directory")
        XCTAssertEqual(
            projector.payloads(from: end, fallback: finished),
            [.activityCompleted(finished)]
        )

        var builder = TranscriptBuilder()
        builder.apply(.activityStarted(started))
        builder.apply(.activityCompleted(finished))
        guard case let .activity(card, state) = builder.entries[0].content else {
            return XCTFail("expected an activity entry")
        }
        XCTAssertEqual(state, .failed)
        XCTAssertEqual(card.input, "ls /missing")
        XCTAssertEqual(card.output, "no such directory")
    }
}
