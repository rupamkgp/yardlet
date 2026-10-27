#!/usr/bin/env python3
"""Starts yardlet-mcp the way a harness would, from the launch a DEBUG Yardlet wrote for
YARDLET_AGENT_TOOLS_QA, and speaks MCP to it over stdio: initialize, tools/list, then each call
given as NAME=JSON. Prints one JSON document with every reply.

usage: drive-mcp.py LAUNCH_JSON [TOOL=ARGUMENTS_JSON ...]
"""
import json
import os
import subprocess
import sys


def main():
    launch = json.load(open(sys.argv[1]))
    environment = dict(os.environ)
    environment.update(launch["env"])
    process = subprocess.Popen([launch["command"]], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                               env=environment, text=True)
    next_id = 0

    def request(method, params=None):
        nonlocal next_id
        next_id += 1
        message = {"jsonrpc": "2.0", "id": next_id, "method": method}
        if params is not None:
            message["params"] = params
        process.stdin.write(json.dumps(message) + "\n")
        process.stdin.flush()
        while True:
            line = process.stdout.readline()
            if not line:
                raise SystemExit("yardlet-mcp closed its output")
            reply = json.loads(line)
            if reply.get("id") == next_id:
                return reply

    results = {"initialize": request("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                                    "clientInfo": {"name": "connector-qa", "version": "1"}})}
    process.stdin.write(json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}) + "\n")
    results["tools/list"] = request("tools/list")
    results["calls"] = []
    for argument in sys.argv[2:]:
        name, _, arguments = argument.partition("=")
        results["calls"].append({"tool": name, "reply": request("tools/call", {
            "name": name, "arguments": json.loads(arguments or "{}")})})
    process.stdin.close()
    process.wait(timeout=10)
    json.dump(results, sys.stdout, ensure_ascii=False, indent=2)


if __name__ == "__main__":
    main()
