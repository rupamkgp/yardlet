import Foundation

/// The frames a real Claude Code 2.1.291 run (haiku, 2026-10-08) sent around Send now pressed while
/// a foreground Bash command ran: Yardlet wrote the message (`priority: "next"`, `origin: {kind:
/// "human"}`), the CLI reported it `queued`, and Yardlet sent `interrupt{send_now: true,
/// message_uuid}`. Recorded by `RealModelParityLiveTests.testClaudeSendNowMovesTheRunningCommandToTheBackground`
/// (`.build/live-parity/…jsonl`); usage blobs are left out, the message's uuid is the test's own.
enum SendNowFrames {
    static let sessionID = "e02d3f46-0312-445a-a5dc-ffbc936ea60a"
    static let text = "Reply with exactly NOW_OK right away. Do not wait for the command."
    static let toolUseID = "toolu_01B7rRvVrPDB7ViGwP155jYZ"
    static let taskID = "bm2z66s29"

    /// `system/init`, at the start of each turn; only its capabilities matter here.
    static let initFrame = #"""
    {"type":"system","subtype":"init","session_id":"e02d3f46-0312-445a-a5dc-ffbc936ea60a",
     "capabilities":["interrupt_receipt_v1","interrupt_cancel_queued_v1","interrupt_send_now_v1","msg_lifecycle_v1","sdk_mcp_tools_list_changed","sdk_mcp_manifests","mcp_read_resource_v1","mcp_tool_ui_meta_v1","ui_surface_v1"]}
    """#

    static let toolUse = #"""
    {"message":{"role":"assistant","content":[{"caller":{"type":"direct"},"id":"toolu_01B7rRvVrPDB7ViGwP155jYZ","input":{"command":"sleep 20 && echo done","description":"Run sleep 20 seconds then print done"},"name":"Bash","type":"tool_use"}],"id":"msg_011Cfoo7uavCH2Yz9GJeBJFX","model":"claude-haiku-4-5-20251001","stop_reason":null},"parent_tool_use_id":null,"request_id":"req_011Cfoo7uM35VJo9iPTJ8vj5","session_id":"e02d3f46-0312-445a-a5dc-ffbc936ea60a","timestamp":"2026-10-08T00:07:34.301Z","type":"assistant","uuid":"5b2108db-14f6-43bd-9840-73905beb4c69"}
    """#

    static let taskStarted = #"""
    {"description":"Run sleep 20 seconds then print done","is_backgrounded":false,"session_id":"e02d3f46-0312-445a-a5dc-ffbc936ea60a","subtype":"task_started","task_id":"bm2z66s29","task_type":"local_bash","tool_use_id":"toolu_01B7rRvVrPDB7ViGwP155jYZ","type":"system","uuid":"ece79bc5-8e1b-4188-8588-2a119d46d196"}
    """#

    /// The `interrupt` answer, 2 ms after the request.
    static func receipt(_ messageID: String) -> String {
        #"{"send_now":"delivering","still_queued":["\#(messageID)"]}"#
    }

    // What the CLI sent next, in this order: the command goes to the background (1 s after the
    // press its call returns), the turn takes the message in and answers it.

    static let backgroundTasksChanged = #"""
    {"session_id":"e02d3f46-0312-445a-a5dc-ffbc936ea60a","subtype":"background_tasks_changed","tasks":[{"description":"Run sleep 20 seconds then print done","task_id":"bm2z66s29","task_type":"local_bash"}],"type":"system","uuid":"1218b324-e1f8-45f6-a7a4-38b2147046ad"}
    """#

    static let backgrounded = #"""
    {"patch":{"is_backgrounded":true},"session_id":"e02d3f46-0312-445a-a5dc-ffbc936ea60a","subtype":"task_updated","task_id":"bm2z66s29","type":"system","uuid":"db0c60be-a003-4836-afa7-5cce79bb784c"}
    """#

    static let movedOutput = "Command was moved to the background (ID: bm2z66s29) so that a message that arrived while it was running can reach you; it was not interrupted. Output is being written to: /private/tmp/claude-501/-Users-someone-Desktop-workspace-yardlet-sandbox/e02d3f46-0312-445a-a5dc-ffbc936ea60a/tasks/bm2z66s29.output. You will be notified when it completes. If it is still running after 30m in the background, it will be stopped and you will be notified. To check interim output, use Read on that file path."

    static let movedResult = #"""
    {"message":{"content":[{"content":"Command was moved to the background (ID: bm2z66s29) so that a message that arrived while it was running can reach you; it was not interrupted. Output is being written to: /private/tmp/claude-501/-Users-someone-Desktop-workspace-yardlet-sandbox/e02d3f46-0312-445a-a5dc-ffbc936ea60a/tasks/bm2z66s29.output. You will be notified when it completes. If it is still running after 30m in the background, it will be stopped and you will be notified. To check interim output, use Read on that file path.","is_error":false,"tool_use_id":"toolu_01B7rRvVrPDB7ViGwP155jYZ","type":"tool_result"}],"role":"user"},"parent_tool_use_id":null,"session_id":"e02d3f46-0312-445a-a5dc-ffbc936ea60a","timestamp":"2026-10-08T00:07:39.842Z","tool_use_result":{"backgroundTaskId":"bm2z66s29","backgroundedToDeliverMessage":true,"interrupted":false,"isImage":false,"noOutputExpected":false,"stderr":"","stdout":""},"type":"user","uuid":"b7624073-e531-4ddc-b6d5-f0883bf5c018"}
    """#

    static let answer = #"""
    {"message":{"role":"assistant","content":[{"text":"NOW_OK","type":"text"}],"id":"msg_011Cfoo8StLy54qQwZq2KD82","model":"claude-haiku-4-5-20251001","stop_reason":null},"parent_tool_use_id":null,"request_id":"req_011Cfoo8SfCoU1RtiwuBxRGK","session_id":"e02d3f46-0312-445a-a5dc-ffbc936ea60a","timestamp":"2026-10-08T00:07:41.274Z","type":"assistant","uuid":"7df53051-5e9a-4787-8d6b-431f47cad990"}
    """#

    static func turnResult(_ messageID: String) -> String {
        #"""
        {"api_error_status":null,"duration_api_ms":3981,"duration_ms":8822,"is_error":false,"num_turns":2,"queued_turn_count":0,"result":"NOW_OK","result_index":0,"session_id":"e02d3f46-0312-445a-a5dc-ffbc936ea60a","stop_reason":"end_turn","subtype":"success","terminal_reason":"completed","type":"result","user_message_uuid":"\#(messageID)","user_message_uuids":["\#(messageID)"],"uuid":"9a369778-9d8b-420c-a051-8ff6915fd998"}
        """#
    }

    // About 15 s later the command ends; the CLI reports it and starts a turn of its own.

    static let backgroundTasksEmptied = #"""
    {"session_id":"e02d3f46-0312-445a-a5dc-ffbc936ea60a","subtype":"background_tasks_changed","tasks":[],"type":"system","uuid":"d5373c39-477a-445a-b1dc-31aadc4fc866"}
    """#

    static let taskCompleted = #"""
    {"patch":{"end_time":1791418074843,"status":"completed"},"session_id":"e02d3f46-0312-445a-a5dc-ffbc936ea60a","subtype":"task_updated","task_id":"bm2z66s29","type":"system","uuid":"cf97e70a-6f58-4af8-961b-7919688c8cdc"}
    """#

    static let notificationSummary = #"Background command "Run sleep 20 seconds then print done" completed (exit code 0)"#

    static let notification = #"""
    {"output_file":"/private/tmp/claude-501/-Users-someone-Desktop-workspace-yardlet-sandbox/e02d3f46-0312-445a-a5dc-ffbc936ea60a/tasks/bm2z66s29.output","session_id":"e02d3f46-0312-445a-a5dc-ffbc936ea60a","status":"completed","subtype":"task_notification","summary":"Background command \"Run sleep 20 seconds then print done\" completed (exit code 0)","task_id":"bm2z66s29","tool_use_id":"toolu_01B7rRvVrPDB7ViGwP155jYZ","type":"system","uuid":"84c76b2b-68db-405e-92b2-3d1075eaa95f"}
    """#

    static let notificationAnswerText = "The command finished. `sleep 20 && echo done` ran successfully and exited with code 0."

    static let notificationAnswer = #"""
    {"message":{"role":"assistant","content":[{"text":"The command finished. `sleep 20 && echo done` ran successfully and exited with code 0.","type":"text"}],"id":"msg_011Cfoo9ZQHYm8ABScGaYyDh","model":"claude-haiku-4-5-20251001","stop_reason":null},"parent_tool_use_id":null,"request_id":"req_011Cfoo9ZBPfdWgRmotxcTwr","session_id":"e02d3f46-0312-445a-a5dc-ffbc936ea60a","timestamp":"2026-10-08T00:07:57.643Z","type":"assistant","uuid":"e1810a7a-ca7c-4279-818c-8e034158a039"}
    """#

    static let notificationTurnResult = #"""
    {"api_error_status":null,"duration_api_ms":6706,"duration_ms":2752,"is_error":false,"num_turns":1,"origin":{"kind":"task-notification","producer":"session-task"},"queued_turn_count":0,"result":"The command finished. `sleep 20 && echo done` ran successfully and exited with code 0.","result_index":1,"session_id":"e02d3f46-0312-445a-a5dc-ffbc936ea60a","stop_reason":"end_turn","subtype":"success","terminal_reason":"completed","type":"result","uuid":"3e47d9ca-9b47-4d42-84c3-e052a831696c"}
    """#

    /// The lifecycle frame's shape, under the test's own message uuid.
    static func lifecycle(_ messageID: String, _ state: String) -> String {
        #"{"command_uuid":"\#(messageID)","session_id":"e02d3f46-0312-445a-a5dc-ffbc936ea60a","state":"\#(state)","type":"command_lifecycle","uuid":"\#(UUID().uuidString.lowercased())"}"#
    }
}
