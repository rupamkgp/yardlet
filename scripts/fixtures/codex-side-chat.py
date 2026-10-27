#!/usr/bin/env python3
"""Provider-free native fork fixture. Copy into a scratch directory before running."""
import copy
import json
from pathlib import Path
import sys
import threading
import time

if '--version' in sys.argv:
    print('codex-cli 0.152.1')
    sys.exit(0)

root = Path(__file__).resolve().parent
output_lock = threading.Lock()
state_lock = threading.RLock()
states = {'lifecycle-thread': {
    'id': 'lifecycle-thread', 'name': 'Main conversation', 'status': {'type': 'idle'},
    'turns': [{'id': 'context-turn', 'status': 'completed', 'itemsView': 'full', 'items': [
        {'id': 'context-user', 'type': 'userMessage', 'content': [{'type': 'text', 'text':
            'Keep the original conversation and its draft intact. Side chat should inherit this context.'}]},
        {'id': 'context-answer', 'type': 'agentMessage', 'phase': 'final_answer', 'text':
            '## Shared starting point\n\nThe main conversation keeps its own input, approvals, and execution.\n\nA side chat starts with this history and continues independently.'}]}]}}
active = {}
approvals = {}

def output(value):
    with output_lock:
        print(json.dumps(value, ensure_ascii=False), flush=True)

def record(method, params):
    with output_lock, (root / 'side-chat-events.jsonl').open('a') as log:
        log.write(json.dumps({'method': method, 'params': params, 'at': time.time()}, ensure_ascii=False) + '\n')

def response(request, value):
    output({'id': request['id'], 'result': value})

def notify(method, thread_id, **params):
    output({'method': method, 'params': {'threadId': thread_id, **params}})

def finish(thread_id, status='completed'):
    with state_lock:
        turn = active.pop(thread_id, None)
        if turn:
            turn['status'] = status
            states[thread_id]['status'] = {'type': 'idle'}
            notify('item/completed', thread_id, turnId=turn['id'], item=turn['items'][-1])
            notify('turn/completed', thread_id, turn=turn)

def stream(thread_id, turn, prompt):
    dense = (root / 'dense-stream').exists()
    for i in range(1, 2001 if dense else 25):
        time.sleep(0.02 if dense else 0.2)
        with state_lock:
            if active.get(thread_id) is not turn:
                return
            chunk = f'\n{thread_id}_{i}' if dense else f'\n\n{thread_id}: response fragment {i}.'
            turn['items'][-1]['text'] += chunk
            notify('item/agentMessage/delta', thread_id, turnId=turn['id'], itemId=turn['items'][-1]['id'], delta=chunk)
    if 'approval' in prompt.lower():
        request_id = f'approval-{thread_id}-{turn["id"]}'
        approvals[request_id] = thread_id
        output({'id': request_id, 'method': 'item/commandExecution/requestApproval', 'params': {
            'threadId': thread_id, 'turnId': turn['id'], 'itemId': 'inert-command',
            'command': 'printf side-chat-fixture', 'reason': 'Local fixture. No command will execute.'}})
    else:
        finish(thread_id)

for line in sys.stdin:
    request = json.loads(line)
    method = request.get('method')
    params = request.get('params', {})
    if method is None:
        thread_id = approvals.pop(request.get('id'), None)
        if thread_id:
            record('approval.response', {'threadId': thread_id, 'result': request.get('result')})
            finish(thread_id)
        continue
    record(method, params)
    if 'id' not in request:
        continue
    with state_lock:
        thread_id = params.get('threadId', 'lifecycle-thread')
        if method == 'initialize':
            response(request, {'platformOs': 'macos'})
        elif method in ('thread/resume', 'thread/read', 'thread/start'):
            response(request, {'thread': states[thread_id], 'model': 'fixture-codex', 'reasoningEffort': 'medium'})
        elif method == 'thread/fork':
            failure = root / 'fork-fail-once'
            if failure.exists():
                failure.unlink()
                time.sleep(3)
                output({'id': request['id'], 'error': {'code': -32000,
                    'message': 'Local fixture: side chat could not be opened. Retry is available.'}})
                continue
            child_id = f'side-thread-{len(states)}'
            child = copy.deepcopy(states[thread_id])
            child.update(id=child_id, name='Side conversation', forkedFromId=thread_id, status={'type': 'idle'})
            for turn in child['turns']:
                if turn['status'] == 'inProgress':
                    turn['status'] = 'interrupted'
            states[child_id] = child
            response(request, {'thread': child})
        elif method == 'turn/start':
            number = len(states[thread_id]['turns']) + 1
            prompt = '\n'.join(item.get('text', '') for item in params.get('input', []))
            turn = {'id': f'{thread_id}-turn-{number}', 'status': 'inProgress', 'itemsView': 'full', 'items': [
                {'id': f'user-{number}', 'type': 'userMessage', 'content': params.get('input', [])},
                {'id': f'answer-{number}', 'type': 'agentMessage', 'phase': 'final_answer',
                 'text': f'## {thread_id}\n\nThe inherited starting point is available in this thread.'}]}
            active[thread_id] = turn
            states[thread_id]['turns'].append(turn)
            response(request, {'turn': {**turn, 'items': []}})
            notify('turn/started', thread_id, turn={**turn, 'items': []})
            notify('item/completed', thread_id, turnId=turn['id'], item=turn['items'][0])
            notify('item/started', thread_id, turnId=turn['id'], item=turn['items'][-1])
            threading.Thread(target=stream, args=(thread_id, turn, prompt), daemon=True).start()
        elif method == 'turn/interrupt':
            finish(thread_id, 'interrupted')
            response(request, {})
        elif method == 'model/list':
            response(request, {'data': [
                {'id': 'fixture-codex', 'model': 'fixture-codex', 'displayName': 'Codex Fixture',
                 'defaultReasoningEffort': 'medium', 'isDefault': True, 'hidden': False,
                 'supportedReasoningEfforts': [{'reasoningEffort': e} for e in ['low', 'medium', 'high']]},
                {'id': 'fixture-fast', 'model': 'fixture-fast', 'displayName': 'Codex Fast Fixture',
                 'defaultReasoningEffort': 'low', 'isDefault': False, 'hidden': False,
                 'supportedReasoningEfforts': [{'reasoningEffort': e} for e in ['low', 'high']]}
            ]})
        elif method == 'config/read':
            response(request, {'config': {}})
        else:
            response(request, {'data': []})
