#!/usr/bin/env python3
"""Dependency-free Yardlet Harness Protocol v1 sample adapter.

The fake provider intentionally has no knowledge of Yardlet's Swift types. It
speaks deterministic JSONL over stdin/stdout so it can be copied, installed,
and conformance-tested as an independent process.
"""

import json
import os
import sys
import time
import uuid


VERSION = {"major": 1, "minor": 0}
CAPABILITIES = [
    "runtime.discovery",
    "session.close",
    "session.create",
    "session.resume",
    "timeline.streaming",
    "turn.interrupt",
    "turn.send",
]
MANIFEST = {
    "adapterID": "dev.yardlet.sample.echo",
    "harness": "sample-echo",
    "displayName": "Yardlet Sample Echo Adapter",
    "protocolVersions": [VERSION],
    "capabilities": CAPABILITIES,
    "extensionNamespaces": ["sample.fixture"],
}


def write_frame(frame):
    sys.stdout.write(json.dumps(frame, sort_keys=True, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def response(request_id, result=None, error=None):
    body = {"id": request_id}
    if error is None:
        body["result"] = result
    else:
        body["error"] = error
    write_frame({"type": "response", "version": VERSION, "response": body})


def event(local_session_id, sequence, payload):
    write_frame(
        {
            "type": "event",
            "version": VERSION,
            "event": {
                "id": str(uuid.uuid4()),
                "localSessionID": local_session_id,
                "timestamp": time.time(),
                "sequence": sequence,
                "payload": payload,
            },
        }
    )


def text_from_content(content):
    return " ".join(
        block.get("text", "")
        for block in content
        if isinstance(block, dict) and block.get("type") == "text"
    ).strip()


class SampleAdapter:
    def __init__(self):
        self.sessions = {}
        self.provider_sessions = {}

    def next_sequence(self, local_session_id):
        session = self.sessions[local_session_id]
        value = session["sequence"]
        session["sequence"] += 1
        return value

    def emit_session_started(self, local_session_id, provider_session_id, config):
        workspace_path = config["workspacePath"]
        if os.environ.get("YARDLET_SAMPLE_MALFORMED") == "sequence-gap":
            sequence = 1
        else:
            sequence = self.next_sequence(local_session_id)
        event(
            local_session_id,
            sequence,
            {
                "kind": "session.started",
                "session": {
                    "localSessionID": local_session_id,
                    "providerSessionID": provider_session_id,
                    "workspacePath": workspace_path,
                },
            },
        )
        if os.environ.get("YARDLET_SAMPLE_MALFORMED") == "sequence-gap":
            return
        event(
            local_session_id,
            self.next_sequence(local_session_id),
            {
                "kind": "extension",
                "extensionEvent": {
                    "namespace": "sample.fixture",
                    "name": "session.configured",
                    "payload": {
                        "sample.fixture.mode": config.get("extensionValues", {}).get(
                            "sample.fixture.mode"
                        )
                    },
                },
            },
        )

    def attach(self, local_session_id, provider_session_id, config):
        descriptor = {
            "localSessionID": local_session_id,
            "providerSessionID": provider_session_id,
            "workspacePath": config["workspacePath"],
        }
        self.sessions[local_session_id] = {
            "providerSessionID": provider_session_id,
            "workspacePath": config["workspacePath"],
            "sequence": 0,
            "activeTurnID": None,
        }
        self.provider_sessions[provider_session_id] = config["workspacePath"]
        self.emit_session_started(local_session_id, provider_session_id, config)
        return descriptor

    def handle(self, request):
        request_id = request.get("id", "")
        method = request.get("method")
        params = request.get("params", {})

        if method == "runtime.probe":
            response(
                request_id,
                {
                    "harness": MANIFEST["harness"],
                    "executablePath": os.path.abspath(sys.argv[0]),
                    "version": "1.0.0",
                    "capabilities": CAPABILITIES,
                    "fingerprint": "sample-echo-v1",
                },
            )
            return

        if method == "sample.fixture.echo":
            response(request_id, params)
            return

        if method == "session.create":
            local_session_id = params["localSessionID"]
            provider_session_id = "sample-" + local_session_id
            descriptor = self.attach(local_session_id, provider_session_id, params["config"])
            response(request_id, descriptor)
            return

        if method == "session.resume":
            local_session_id = params["localSessionID"]
            provider_session_id = params["providerSessionID"]
            if provider_session_id not in self.provider_sessions:
                response(
                    request_id,
                    error={
                        "code": "sample.unknown_session",
                        "message": "Unknown provider session",
                    },
                )
                return
            descriptor = self.attach(local_session_id, provider_session_id, params["config"])
            response(request_id, descriptor)
            return

        if method == "session.send":
            local_session_id = params["localSessionID"]
            session = self.sessions.get(local_session_id)
            if session is None:
                response(
                    request_id,
                    error={"code": "sample.missing_session", "message": "Missing session"},
                )
                return
            turn_id = "turn-" + params["clientMessageID"]
            session["activeTurnID"] = turn_id
            event(
                local_session_id,
                self.next_sequence(local_session_id),
                {
                    "kind": "turn.started",
                    "turnID": turn_id,
                    "turn": {"id": turn_id, "localSessionID": local_session_id},
                },
            )
            text = text_from_content(params.get("content", []))
            if text != "hold":
                event(
                    local_session_id,
                    self.next_sequence(local_session_id),
                    {
                        "kind": "message.assistant_delta",
                        "turnID": turn_id,
                        "messageID": "message-" + params["clientMessageID"],
                        "text": "echo: " + text,
                    },
                )
                event(
                    local_session_id,
                    self.next_sequence(local_session_id),
                    {"kind": "turn.completed", "turnID": turn_id},
                )
                session["activeTurnID"] = None
            response(request_id, {"accepted": True})
            return

        if method == "session.interrupt":
            local_session_id = params["localSessionID"]
            session = self.sessions.get(local_session_id)
            if session is None or session["activeTurnID"] is None:
                response(
                    request_id,
                    error={"code": "sample.no_active_turn", "message": "No active turn"},
                )
                return
            event(
                local_session_id,
                self.next_sequence(local_session_id),
                {
                    "kind": "turn.canceled",
                    "turnID": session["activeTurnID"],
                    "reason": "interrupted",
                },
            )
            session["activeTurnID"] = None
            response(request_id, {"accepted": True})
            return

        if method == "session.close":
            self.sessions.pop(params["localSessionID"], None)
            response(request_id, {"accepted": True})
            return

        response(
            request_id,
            error={"code": "sample.unsupported_method", "message": "Unsupported method"},
        )


def main():
    write_frame({"type": "hello", "manifest": MANIFEST})
    ready_line = sys.stdin.readline()
    if not ready_line:
        return 10
    ready = json.loads(ready_line)
    if ready.get("type") != "ready" or ready.get("version") != VERSION:
        return 11

    adapter = SampleAdapter()
    for line in sys.stdin:
        if not line.strip():
            continue
        frame = json.loads(line)
        if frame.get("type") != "request" or frame.get("version") != VERSION:
            return 12
        adapter.handle(frame["request"])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
