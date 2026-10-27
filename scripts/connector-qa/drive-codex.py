#!/usr/bin/env python3
"""Checks that Codex takes the Yardlet MCP server, connector tools included, the way Yardlet injects
it, with no model turn: an ephemeral `thread/start` whose `config` carries the server from the launch
a DEBUG Yardlet wrote for YARDLET_AGENT_TOOLS_QA, then `mcpServerStatus/list` and one
`mcpServer/tool/call`. CODEX_HOME must name an empty temporary directory.

usage: CODEX_HOME=<empty dir> drive-codex.py CODEX_BINARY LAUNCH_JSON TOOL ARGUMENTS_JSON
"""
import json
import os
import subprocess
import sys
import tempfile
import time


def main():
    codex, launch_path, tool, arguments = sys.argv[1:5]
    home = os.environ.get("CODEX_HOME", "")
    if not home or os.listdir(home) not in ([], ["tmp"]):
        raise SystemExit("CODEX_HOME must be an empty temporary directory")
    launch = json.load(open(launch_path))
    process = subprocess.Popen([codex, "app-server"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                               stderr=subprocess.DEVNULL, text=True)
    next_id = 0
    notifications = []

    def send(message):
        process.stdin.write(json.dumps(message) + "\n")
        process.stdin.flush()

    def request(method, params):
        nonlocal next_id
        next_id += 1
        send({"jsonrpc": "2.0", "id": next_id, "method": method, "params": params})
        while True:
            line = process.stdout.readline()
            if not line:
                raise SystemExit(f"codex closed its output during {method}")
            message = json.loads(line)
            if message.get("id") == next_id and ("result" in message or "error" in message):
                return message
            if "method" in message:
                notifications.append(message["method"])

    results = {}
    results["initialize"] = request("initialize", {
        "clientInfo": {"name": "connector-qa", "title": "Yardlet connector QA", "version": "1"},
        "capabilities": {"experimentalApi": True, "requestAttestation": False},
    })
    send({"jsonrpc": "2.0", "method": "initialized"})
    server = {"command": launch["command"], "args": [], "env": launch["env"], "tool_timeout_sec": 120}
    started = request("thread/start", {
        "ephemeral": True,
        "cwd": tempfile.gettempdir(),
        "config": {"mcp_servers": {"yardlet": server}},
    })
    results["thread/start"] = {"error": started.get("error")} if "error" in started else {"ok": True}
    thread = started.get("result", {}).get("thread", {}).get("id")
    status = None
    for _ in range(40):
        status = request("mcpServerStatus/list", {"threadId": thread})
        servers = status.get("result", {}).get("data", [])
        yardlet = next((entry for entry in servers if entry.get("name") == "yardlet"), None)
        if yardlet and yardlet.get("status") not in ("starting", "notStarted"):
            break
        time.sleep(0.25)
    yardlet = next((entry for entry in status.get("result", {}).get("data", []) if entry.get("name") == "yardlet"), {})
    tools = yardlet.get("tools") or {}
    results["yardlet"] = {"status": yardlet.get("status"), "authStatus": yardlet.get("authStatus"),
                          "tools": sorted(tools.keys() if isinstance(tools, dict) else [t.get("name") for t in tools])}
    call = request("mcpServer/tool/call", {"threadId": thread, "server": "yardlet", "tool": tool,
                                           "arguments": json.loads(arguments)})
    results["call"] = call.get("result", call.get("error"))
    process.stdin.close()
    process.terminate()
    process.wait(timeout=10)
    json.dump(results, sys.stdout, ensure_ascii=False, indent=2)


if __name__ == "__main__":
    main()
