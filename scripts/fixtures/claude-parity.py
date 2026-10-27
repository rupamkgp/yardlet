#!/usr/bin/env python3
"""Local stream-json fixture for Claude task-list and background lifecycle UI.

No provider, network, authentication or shell command is invoked. An ordinary input starts a
background card; a later 'finish', 'stop' or 'fail' terminates it after the main turn completed.
"""
import json
import sys

if "--version" in sys.argv:
    print("2.1.281 (Claude Code)")
    raise SystemExit(0)

session_id = "00000000-0000-0000-0000-000000000001"
number = 0
active = None


def send(value):
    value.setdefault("session_id", session_id)
    print(json.dumps(value, ensure_ascii=False), flush=True)


def assistant(blocks, parent=None):
    send({"type": "assistant", "parent_tool_use_id": parent,
          "message": {"role": "assistant", "content": blocks}})


for line in sys.stdin:
    frame = json.loads(line)
    if frame.get("type") == "control_request":
        send({"type": "control_response", "response": {
            "subtype": "success", "request_id": frame["request_id"], "response": {"models": []}}})
        continue
    if frame.get("type") != "user":
        continue
    text = frame.get("message", {}).get("content", "")
    if isinstance(text, list):
        text = "".join(block.get("text", "") for block in text)
    number += 1
    if text in ("finish", "stop", "fail") and active:
        status = {"finish": "completed", "stop": "killed", "fail": "failed"}[text]
        send({"type": "system", "subtype": "task_updated", "task_id": active,
              "patch": {"status": status, **({"error": "Check failed (local fixture)"} if text == "fail" else {})}})
        assistant([{"type": "text", "text": "Recorded how the background task ended."}])
        active = None
    else:
        tool_id = f"agent-{number}"
        active = f"task-{number}"
        list_id = f"list-{number}"
        assistant([{"type": "tool_use", "id": list_id, "name": "TaskList", "input": {}}])
        send({"type": "user", "tool_use_result": {"tasks": [
            {"id": "1", "subject": "Read the changed code", "status": "completed", "blockedBy": []},
            {"id": "2", "subject": "Run the checks", "status": "in_progress", "blockedBy": []}]},
            "message": {"content": [{"type": "tool_result", "tool_use_id": list_id, "content": "To-do list"}]}})
        assistant([{"type": "tool_use", "id": tool_id, "name": "Agent", "input": {
            "description": "Review the changes", "prompt": "Review the approval, question and failed-tool states."}}])
        send({"type": "system", "subtype": "task_started", "task_id": active,
              "tool_use_id": tool_id, "description": "Review the changes", "task_type": "local_agent",
              "is_backgrounded": True})
        assistant([{"type": "text", "text": "CHILD-MUST-STAY-OUT"}], parent=tool_id)
        send({"type": "user", "message": {"content": [{"type": "tool_result",
              "tool_use_id": tool_id, "content": "Background agent started"}]}})
        send({"type": "system", "subtype": "task_progress", "task_id": active,
              "tool_use_id": tool_id, "description": "Review the changes", "last_tool_name": "Read",
              "usage": {"tool_uses": 4, "total_tokens": 900, "duration_ms": 1250}})
        assistant([{"type": "text", "text": "The main turn is done. The background review is still running."}])
    send({"type": "result", "subtype": "success", "is_error": False})
