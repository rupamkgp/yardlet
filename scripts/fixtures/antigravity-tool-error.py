#!/usr/bin/python3
"""Provider-free native UI fixture. Copy to a scratch file named agy to run.

Derived from an observed tool_info error, not an exact upstream stream capture.
It never reads requested paths, connects to a provider, or accesses credentials.
Send 'recover' to exercise a successful follow-up in the same fixture session.
"""
import json
import sys


def emit(event, body):
    print(json.dumps({"event": event, event: body}), flush=True)


if "--print" not in sys.argv:
    if "models" in sys.argv or "agents" in sys.argv:
        print("fixture (default)")
    else:
        print("Antigravity local fixture")
    raise SystemExit(0)

prompt = sys.argv[sys.argv.index("--print") + 1]
emit("init", {"conversation_id": "lifecycle-thread"})
step = {"conversation_id": "lifecycle-thread", "step_index": 3 if "recover" in prompt.lower() else 1,
        "step_type": "TOOL", "state": "RUNNING", "tool_name": "list_dir",
        "tool_info": {"name": "list_dir", "parameters": {"DirectoryPath": "/tmp/yardlet-fixture"}}}
emit("step_update", step)
if "recover" in prompt.lower():
    step["state"] = "DONE"
    emit("step_update", step)
    emit("result", {"status": "SUCCESS", "response": "Local fixture follow-up succeeded. No provider was contacted."})
else:
    step.pop("state")
    step["tool_info"]["parameters"]["padding"] = "x" * 800
    message = 'permission check failed for read_file "/tmp/yardlet-fixture": user denied permission for read_file(/tmp/yardlet-fixture)'
    step["tool_info"]["error"] = {"type": "TOOL_ERROR", "message": message}
    emit("step_update", step)
    emit("step_update", {"step_index": 2, "conversation_id": "lifecycle-thread",
                         "state": "RUNNING", "tool_info": {"name": "pending_fixture_tool"}})
    emit("result", {"status": "ERROR", "error": message})
