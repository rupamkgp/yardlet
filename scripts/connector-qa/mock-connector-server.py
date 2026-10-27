#!/usr/bin/env python3
"""A stand-in connector for QA without a real service: an OAuth 2.1 authorization server and a
Streamable HTTP MCP server on 127.0.0.1, shaped like the real ones Yardlet connects to
(docs/CONNECTORS.md). Authorization approves at once and redirects back, so a QA build that
follows redirects (YARDLET_CONNECTOR_QA_FOLLOW_SIGN_IN=1) signs in without a browser.

It checks what a real server would: the registered redirect URI, PKCE S256, the resource
indicator, bearer tokens, and the MCP session. Every request is appended to requests.jsonl in the
output directory, and the chosen port is written to `port`.

usage: mock-connector-server.py --output-dir DIR [--port N]
"""
import argparse
import base64
import hashlib
import json
import secrets
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlencode, urlparse

LOCK = threading.Lock()
STATE = {"clients": {}, "codes": {}, "access": {}, "refresh": {}, "sessions": set()}
TOOLS = [
    {
        "name": "echo",
        "title": "Echo",
        "description": "Returns the text it is given.",
        "inputSchema": {"type": "object", "properties": {"text": {"type": "string"}}, "required": ["text"]},
        "annotations": {"readOnlyHint": True},
    },
    {
        "name": "whoami",
        "description": "Names the account the token belongs to.",
        "inputSchema": {"type": "object"},
    },
]


def base64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    @property
    def origin(self):
        return f"http://127.0.0.1:{self.server.server_port}"

    def record(self, extra=None):
        entry = {"time": time.time(), "method": self.command, "path": self.path.split("?")[0]}
        entry.update(extra or {})
        with open(self.server.log_path, "a") as log:
            log.write(json.dumps(entry) + "\n")

    def send(self, status, body=b"", content_type="application/json", headers=None):
        self.send_response(status)
        if body:
            self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        self.end_headers()
        if body:
            self.wfile.write(body)

    def send_json(self, status, value, headers=None):
        self.send(status, json.dumps(value).encode(), headers=headers)

    def body(self):
        length = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(length) if length else b""

    def do_GET(self):
        url = urlparse(self.path)
        if url.path == "/.well-known/oauth-protected-resource/mcp":
            self.record()
            return self.send_json(200, {
                "resource": f"{self.origin}/mcp",
                "authorization_servers": [self.origin],
                "scopes_supported": ["docs.read", "docs.write"],
                "bearer_methods_supported": ["header"],
            })
        if url.path == "/.well-known/oauth-authorization-server":
            self.record()
            return self.send_json(200, {
                "issuer": self.origin,
                "authorization_endpoint": f"{self.origin}/authorize",
                "token_endpoint": f"{self.origin}/token",
                "registration_endpoint": f"{self.origin}/register",
                "response_types_supported": ["code"],
                "grant_types_supported": ["authorization_code", "refresh_token"],
                "token_endpoint_auth_methods_supported": ["none"],
                "code_challenge_methods_supported": ["S256"],
            })
        if url.path == "/authorize":
            query = {key: values[0] for key, values in parse_qs(url.query).items()}
            problems = []
            with LOCK:
                client = STATE["clients"].get(query.get("client_id"))
            if not client:
                problems.append("unknown client")
            elif query.get("redirect_uri") not in client["redirect_uris"]:
                problems.append("redirect_uri not registered")
            if query.get("response_type") != "code":
                problems.append("response_type")
            if query.get("code_challenge_method") != "S256" or not query.get("code_challenge"):
                problems.append("pkce")
            if query.get("resource") != f"{self.origin}/mcp":
                problems.append("resource")
            self.record({"problems": problems, "scope": query.get("scope"), "resource": query.get("resource")})
            if problems:
                return self.send_json(400, {"error": "invalid_request", "error_description": ", ".join(problems)})
            code = secrets.token_urlsafe(16)
            with LOCK:
                STATE["codes"][code] = {
                    "client_id": query["client_id"],
                    "redirect_uri": query["redirect_uri"],
                    "challenge": query["code_challenge"],
                    "scope": query.get("scope"),
                }
            location = query["redirect_uri"] + "?" + urlencode({"code": code, "state": query.get("state", "")})
            return self.send(302, headers={"Location": location})
        self.record({"status": 404})
        self.send(404)

    def do_POST(self):
        url = urlparse(self.path)
        raw = self.body()
        if url.path == "/register":
            request = json.loads(raw or b"{}")
            client_id = "qa-client-" + secrets.token_hex(4)
            with LOCK:
                STATE["clients"][client_id] = {"redirect_uris": request.get("redirect_uris", [])}
            self.record({"client_name": request.get("client_name"), "redirect_uris": request.get("redirect_uris"),
                         "auth_method": request.get("token_endpoint_auth_method")})
            return self.send_json(201, {"client_id": client_id, "token_endpoint_auth_method": "none",
                                        "redirect_uris": request.get("redirect_uris", [])})
        if url.path == "/token":
            form = {key: values[0] for key, values in parse_qs(raw.decode()).items()}
            return self.token(form)
        if url.path == "/mcp":
            return self.mcp(raw)
        self.record({"status": 404})
        self.send(404)

    def token(self, form):
        grant = form.get("grant_type")
        problems = []
        with LOCK:
            if grant == "authorization_code":
                issued = STATE["codes"].pop(form.get("code"), None)
                if not issued:
                    problems.append("unknown code")
                else:
                    verifier = form.get("code_verifier", "")
                    if base64url(hashlib.sha256(verifier.encode()).digest()) != issued["challenge"]:
                        problems.append("pkce verifier")
                    if form.get("redirect_uri") != issued["redirect_uri"]:
                        problems.append("redirect_uri")
                    if form.get("client_id") != issued["client_id"]:
                        problems.append("client_id")
            elif grant == "refresh_token":
                if form.get("refresh_token") not in STATE["refresh"]:
                    problems.append("unknown refresh token")
            else:
                problems.append("grant_type")
            if form.get("resource") != f"{self.origin}/mcp":
                problems.append("resource")
            if not problems:
                access = "qa-access-" + secrets.token_hex(8)
                refresh = form.get("refresh_token") or "qa-refresh-" + secrets.token_hex(8)
                STATE["access"][access] = time.time() + 3600
                STATE["refresh"][refresh] = True
        self.record({"grant_type": grant, "problems": problems})
        if problems:
            return self.send_json(400, {"error": "invalid_grant", "error_description": ", ".join(problems)})
        self.send_json(200, {"access_token": access, "token_type": "Bearer", "expires_in": 3600,
                             "refresh_token": refresh, "scope": "docs.read docs.write"})

    def mcp(self, raw):
        authorization = self.headers.get("Authorization", "")
        token = authorization[7:] if authorization.startswith("Bearer ") else None
        with LOCK:
            valid = token is not None and STATE["access"].get(token, 0) > time.time()
        message = json.loads(raw or b"{}")
        method = message.get("method")
        if not valid:
            self.record({"rpc": method, "status": 401})
            return self.send(401, headers={
                "WWW-Authenticate": f'Bearer realm="OAuth", resource_metadata="{self.origin}/.well-known/oauth-protected-resource/mcp"'
            })
        session = self.headers.get("Mcp-Session-Id")
        self.record({"rpc": method, "session": session, "version": self.headers.get("MCP-Protocol-Version"),
                     "accept": self.headers.get("Accept")})
        if method == "initialize":
            session = "qa-session-" + secrets.token_hex(4)
            with LOCK:
                STATE["sessions"].add(session)
            return self.send_json(200, {"jsonrpc": "2.0", "id": message.get("id"), "result": {
                "protocolVersion": "2025-06-18",
                "capabilities": {"tools": {"listChanged": False}},
                "serverInfo": {"name": "qa-docs", "version": "1.0"},
            }}, headers={"Mcp-Session-Id": session})
        with LOCK:
            known = session in STATE["sessions"]
        if not known:
            return self.send(404)
        if "id" not in message:
            return self.send(202)
        if method == "tools/list":
            return self.send_json(200, {"jsonrpc": "2.0", "id": message["id"], "result": {"tools": TOOLS}})
        if method == "tools/call":
            params = message.get("params", {})
            name = params.get("name")
            if name == "echo":
                result = {"content": [{"type": "text", "text": params.get("arguments", {}).get("text", "")}],
                          "structuredContent": {"length": len(params.get("arguments", {}).get("text", ""))}}
            elif name == "whoami":
                result = {"content": [{"type": "text", "text": "qa-user@example.test"}]}
            else:
                result = {"content": [{"type": "text", "text": f"Unknown tool {name}"}], "isError": True}
            # Answer as an event stream, with a progress notification first, as streaming servers do.
            reply = json.dumps({"jsonrpc": "2.0", "id": message["id"], "result": result})
            note = json.dumps({"jsonrpc": "2.0", "method": "notifications/progress",
                               "params": {"progressToken": 1, "progress": 1}})
            body = f"event: message\ndata: {note}\n\nevent: message\ndata: {reply}\n\n".encode()
            return self.send(200, body, content_type="text/event-stream")
        self.send_json(200, {"jsonrpc": "2.0", "id": message.get("id"),
                             "error": {"code": -32601, "message": f"Method not found: {method}"}})


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--port", type=int, default=0)
    arguments = parser.parse_args()
    server = ThreadingHTTPServer(("127.0.0.1", arguments.port), Handler)
    server.log_path = f"{arguments.output_dir}/requests.jsonl"
    with open(f"{arguments.output_dir}/port", "w") as port_file:
        port_file.write(str(server.server_port))
    server.serve_forever()


if __name__ == "__main__":
    main()
