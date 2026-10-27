#!/usr/bin/env python3
"""Loopback-only page fixture for native browser panel retention and retry QA."""
import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import threading
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output-dir', required=True, type=Path)
parser.add_argument('--port', type=int, default=0)
args = parser.parse_args()
args.output_dir.mkdir(parents=True, exist_ok=True)
lock = threading.Lock()


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        with lock, (args.output_dir / 'requests.jsonl').open('a') as log:
            log.write(json.dumps({'path': self.path}) + '\n')
        if self.path == '/favicon.ico':
            self.send_response(204)
            self.end_headers()
            return
        if self.path.startswith('/slow'):
            time.sleep(5)
        title = 'Page B' if self.path.startswith('/second') else 'Page A'
        body = f'''<!doctype html><meta charset="utf-8"><title>{title}</title>
<style>body{{font:17px system-ui;margin:20px;background:#faf9f6;color:#30332f}}
input{{font:inherit;width:90%;padding:8px}}a{{display:block;margin:20px 0}}
section{{height:170px;border-top:1px solid #ccc}}</style>
<h1>{title}</h1><label>Page draft <input aria-label="Page draft" placeholder="Type a draft"></label>
<a href="/second">Go to Page B</a><a href="/">Go to Page A</a>'''
        body += ''.join(f'<section>Reading marker {i:02d}</section>' for i in range(1, 21))
        payload = body.encode()
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Cache-Control', 'no-store')
        self.send_header('Content-Length', str(len(payload)))
        self.end_headers()
        try:
            self.wfile.write(payload)
        except (BrokenPipeError, ConnectionResetError):
            pass  # The native Stop control intentionally cancels a slow request.

    def log_message(self, *args):
        pass


server = ThreadingHTTPServer(('127.0.0.1', args.port), Handler)
(args.output_dir / 'port').write_text(str(server.server_port))
print(f'http://127.0.0.1:{server.server_port}/', flush=True)
server.serve_forever()
