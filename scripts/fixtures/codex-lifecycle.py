#!/usr/bin/env python3
"""Local JSON-RPC fixture: stream, await an inert approval, then exit unexpectedly.
Copy into a temporary directory before use. No provider, network, or shell command is invoked.
"""
import json
import os
from pathlib import Path
import sys
import threading
import time

if '--version' in sys.argv:
    print('codex-cli 0.152.1')
    sys.exit(0)

root = Path(__file__).resolve().parent
state_path = root / 'lifecycle-state.json'
log_path = root / 'lifecycle-events.jsonl'
lock = threading.Lock()
thread_id = 'lifecycle-thread'

def send(value):
    with lock:
        print(json.dumps(value, ensure_ascii=False), flush=True)

def note(method):
    with log_path.open('a') as log:
        log.write(json.dumps({'method': method}) + '\n')

def notify(method, **params):
    send({'method': method, 'params': {'threadId': thread_id, **params}})

def response(request, result):
    send({'id': request['id'], 'result': result})

def save():
    state_path.write_text(json.dumps(state, ensure_ascii=False))

def answer_item(number):
    return {'id': f'answer-{number}', 'type': 'agentMessage', 'phase': 'final_answer',
            'text': f'## Earlier response {number}\n\n' + '\n\n'.join(
                f'Paragraph {i}: keep this reading position while the next response grows. 한글 👩🏽‍💻'
                for i in range(1, 6))}

state = json.loads(state_path.read_text()) if state_path.exists() else {
    'id': thread_id, 'name': 'Codex connection recovery', 'status': {'type': 'idle'},
    'turns': [{'id': f'turn-{i}', 'status': 'completed', 'itemsView': 'full', 'items': [
        {'id': f'user-{i}', 'type': 'userMessage', 'content': [{'type': 'text', 'text': f'Request {i}'}]},
        answer_item(i)]} for i in range(1, 9)]}
active = None

def stream_until_approval():
    global active
    for number in range(1, 61):
        if active is None:
            return
        chunk = f'\n\nStream paragraph {number}: the local fixture preserves earlier reading positions.'
        active['items'][-1]['text'] += chunk
        notify('item/agentMessage/delta', turnId=active['id'], itemId='live-answer', delta=chunk)
        time.sleep(0.25)
    send({'id': 'fixture-approval', 'method': 'item/commandExecution/requestApproval', 'params': {
        'threadId': thread_id, 'turnId': active['id'], 'itemId': 'fixture-command',
        'command': 'printf lifecycle-fixture', 'reason': 'Local fixture only. No command will execute.'}})
    note('approval.waiting')

for line in sys.stdin:
    request = json.loads(line)
    method = request.get('method')
    if method is None:
        if request.get('id') == 'fixture-approval':
            note('approval.response')
            # Flush several final frames immediately before exit to exercise stdout draining.
            for number in range(1, 6):
                chunk = f'\n\nFinal buffered fragment {number}.'
                active['items'][-1]['text'] += chunk
                notify('item/agentMessage/delta', turnId=active['id'], itemId='live-answer', delta=chunk)
            active['status'] = 'failed'
            active['error'] = {'message': 'Local fixture disconnected after approval.'}
            state['status'] = {'type': 'idle'}
            save()
            os._exit(17)
        continue
    note(method)
    if 'id' not in request:
        continue
    if method == 'initialize':
        response(request, {'platformOs': 'macos'})
    elif method in ('thread/start', 'thread/resume', 'thread/read'):
        response(request, {'thread': state})
    elif method == 'turn/start':
        active = {'id': f'turn-{len(state["turns"]) + 1}', 'status': 'inProgress', 'itemsView': 'full', 'items': [
            {'id': 'live-user', 'type': 'userMessage', 'content': request.get('params', {}).get('input', [])},
            {'id': 'live-answer', 'type': 'agentMessage', 'phase': 'final_answer', 'text': '## Connection recovery review'}]}
        state['turns'].append(active)
        # A turn begins before its items. Historical snapshot items are interpreted as
        # completed, so do not include the pending answer in the initial snapshot.
        started = {**active, 'items': []}
        response(request, {'turn': started})
        notify('turn/started', turn=started)
        notify('item/completed', turnId=active['id'], item=active['items'][0])
        notify('item/started', turnId=active['id'], item=active['items'][-1])
        threading.Thread(target=stream_until_approval, daemon=True).start()
    elif method == 'turn/interrupt':
        if active:
            active['status'] = 'interrupted'
            notify('turn/completed', turn=active)
            active = None
        response(request, {})
    elif method == 'config/read':
        response(request, {'config': {}})
    else:
        response(request, {'data': []})
