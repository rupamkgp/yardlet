# Yardlet Remote Protocol

Status: v1 and v2 contract. The Mac side (Yardlet) implements it in `Sources/YardletRemote` and
`Sources/NativeHarnessClient/Remote`; the phone apps implement the client side against this file; the relay
in `relay/` implements §14. The design is in [REMOTE_V2_DESIGN](REMOTE_V2_DESIGN.md).

A phone watches and drives the tasks running in Yardlet on the person's Mac: it lists projects and tasks
with the sidebar's attention states, reads a task's conversation (latest first, older on scroll, live while
it streams), sends a message to a task, answers a pending approval (allow once or deny), stops a running
turn, and marks a task read. Protocol v2 adds answering questions and plan reviews, starting a task, and
push notifications. Nothing else: no settings, accounts, files, diffs, terminals or connectors.

**Two versions.**

- **v1** (§1–§10): plain JSON over `ws://` on the Mac's Tailscale addresses only (port 47615), with a
  pairing code and a bearer device token. Kept for phones paired before v2; new pairings use v2.
- **v2** (§11–§16): the same JSON messages inside a Noise IK channel, over any path: the same network
  (port 47616 on every interface, found with Bonjour), Tailscale, or the Yardlet relay. The handshake
  authenticates both ends with their static keys, so `pair` and `hello` are not used. Everything in
  §2 and §4–§8 applies to v2 except where §11–§16 say otherwise.

## 1. Transport (v1)

- **WebSocket over TCP, no TLS** (`ws://`). Tailscale (WireGuard) already encrypts the link and
  authenticates both devices. The Mac never listens on its LAN or on all interfaces.
- **Port: `47615`** (fixed default).
- **Hosts.** Yardlet listens only on the Mac's Tailscale addresses: IPv4 in `100.64.0.0/10` and IPv6
  in `fd7a:115c:a1e0::/48`. The pairing QR names them, and the Mac's MagicDNS name when it can read
  one (`mac-name.tailnet-name.ts.net`). An IPv6 host goes in brackets: `ws://[fd7a:115c:a1e0::1]:47615/`.
- **Developer loopback.** With `YARDLET_REMOTE_LOOPBACK=1` in Yardlet's environment, or
  `defaults write <Yardlet's bundle identifier> Yardlet.remote.loopback -bool true`, Yardlet also listens on
  `127.0.0.1:47615` while the remote is on. The Android emulator reaches it as `ws://10.0.2.2:47615/`.
  Pairing is still required. The fixture server (§9) listens on loopback only.
- **Path:** the server ignores it; use `/`.
- **No `Origin` header.** A handshake that carries `Origin` (every browser sends one) is refused with HTTP 400. Native WebSocket clients (OkHttp, Ktor) do not send it unless told to.
- **Frames.** Text frames only, one UTF-8 JSON object per frame. A binary frame closes the connection
  (1003). A client frame larger than **65,536 bytes** closes the connection (1009). Server frames can be
  large (a page of conversation); accept frames up to 8 MiB.
- **Keepalive.** The server answers WebSocket ping frames. Clients send a `ping` message (§4.3) or a
  ping frame at least every 30 s; the server closes a connection that sent nothing for 75 s (4408).
- **Mac sleep.** Yardlet keeps the Mac from idle-sleeping only while a turn is working (not while it
  waits for an approval). When the Mac sleeps, the connection drops; reconnect with `hello` when it
  is reachable again.

## 2. Envelopes

Client → server, a request:

```json
{"id": "17", "type": "markRead", "taskId": "4C1F0E0A-2B7A-4E43-9E0B-6C5D8C0C3A11"}
```

- `id`: a string the client chooses, unique among its pending requests on this connection
  (≤ 64 characters). `type`: the message name. Other fields are the message's parameters.

Server → client, the response to one request (exactly one per request, in no guaranteed order
relative to events):

```json
{"re": "17", "ok": true}
{"re": "18", "ok": false, "error": {"code": "notFound", "message": "No task 4C1F…"}}
```

- `re`: the request's `id`. `ok`: whether it succeeded. On success the message's result fields sit
  beside `ok`; on failure `error.code` is one of §8 and `error.message` is an English diagnostic for
  logs, not for the UI.
- A frame whose `id` cannot be read (not JSON, not an object, `id` missing, not a string or longer
  than 64 characters) gets `{"re": "", "ok": false, "error": {"code": "badRequest", …}}`.

Server → client, an event (pushed, not a response):

```json
{"event": "tasksChanged", "seq": 42, "tasks": [], "removedTaskIds": []}
```

- `event`: the event name. `seq`: increases by one per event on this connection, starting at 1.
- Both sides ignore fields they do not know. A client ignores events it does not know. Optional fields
  may be absent; absent means null/false/empty.
- Times are integers: **milliseconds since the Unix epoch** (fields ending in `At`), durations in
  milliseconds (`…Ms`). They are the Mac's clock. The `pair`, `hello` and `snapshot` responses carry
  `serverTime`, the Mac's clock when it answered; a phone that keeps `serverTime − its own time at
  receipt` as an offset can show `lastActivityAt` and turn times without clock skew (never in the
  future).
- IDs (`taskId`, `requestId`, item `id`, `cursor`) are opaque strings. Compare them exactly.

## 3. Pairing and authentication

### 3.1 Pairing on the Mac

Settings › Remote › "Pair a phone" opens one pairing at a time. It shows a QR code and the same
secret as a short manual code. The pairing **expires after 5 minutes, after one successful use, or
after 5 wrong codes**, whichever comes first. Opening a new pairing cancels the previous one.

The QR code holds a URL:

```
yardlet-remote://pair?v=1&code=7KQ2M-X9D4T&port=47615&host=100.64.12.34&host=mac.tail1234.ts.net&host=fd7a:115c:a1e0::1234&name=MacBook%20Pro
```

- `v`: the protocol version (1). `code`: the pairing secret. `port`: the port. `host`: one or more,
  in the order to try (Tailscale IPv4, then the MagicDNS name, then Tailscale IPv6; `127.0.0.1` when
  the developer loopback is on). `name`: the Mac's name, for display. Values are percent-encoded.
- The manual code is the same secret: 10 characters of Crockford base32 shown as `XXXXX-XXXXX`.
  Accept it typed in any case, with or without the dash and spaces; read `O` as `0` and `I`/`L` as `1`.
  The Mac shows its Tailscale address beside the code for manual entry.

### 3.2 `pair` — exchange the secret for a device token

The first message of a connection from a new device.

```json
{"id": "1", "type": "pair", "protocolVersion": 1, "code": "7KQ2M-X9D4T", "deviceName": "Pixel 9"}
```

```json
{"re": "1", "ok": true, "deviceId": "B0D2…", "token": "q0Pj3w…43 chars…", "serverTime": 1792158000000,
 "server": {"name": "MacBook Pro", "app": "Yardlet", "appVersion": "1.0", "protocolVersion": 1}}
```

- `token`: 32 random bytes, base64url without padding (43 characters). The Mac stores only its
  SHA-256, with the device name, when it was paired and when it was last seen. Keep the token in the
  phone's secure storage (Android Keystore-backed); it is the device's credential from now on.
- After a successful `pair` the connection is authenticated as that device; no `hello` is needed.
- `deviceName`: up to 64 characters, shown in the Mac's device list.
- Errors: `pairingUnavailable` (no pairing open: never opened, expired, used, cancelled, or closed by
  wrong codes), `pairingInvalid` (wrong code; the connection stays open for another try),
  `unsupportedVersion`, `badRequest`.

### 3.3 `hello` — authenticate a paired device

The first message of every later connection.

```json
{"id": "1", "type": "hello", "protocolVersion": 1, "token": "q0Pj3w…"}
```

```json
{"re": "1", "ok": true, "deviceId": "B0D2…", "serverTime": 1792158000000,
 "server": {"name": "MacBook Pro", "app": "Yardlet", "appVersion": "1.0", "protocolVersion": 1}}
```

- Errors, after which the server closes the connection: `invalidToken` (unknown or removed device;
  pair again), `unsupportedVersion`, `badRequest`.

### 3.4 Rules

- The first message must be `pair` or `hello`, within 10 s of connecting. Anything else gets
  `unauthenticated` and the connection closes (4401).
- A device removed in the Mac's Settings is disconnected at once: the server sends
  `{"event": "revoked"}` and closes (4403). Its token no longer works.
- Turning the remote off, or quitting Yardlet, sends `{"event": "closing", "reason": "disabled"}`
  (or `"quitting"`) and closes (4503).

## 4. Requests

### 4.1 `snapshot` — projects and tasks

```json
{"id": "2", "type": "snapshot"}
```

```json
{"re": "2", "ok": true, "serverTime": 1792158000000,
 "projects": [
   {"id": "6A1E…", "name": "Yardlet", "kind": "project"},
   {"id": "chats", "name": "Chats", "kind": "chats"}
 ],
 "tasks": [
   {"id": "4C1F…", "title": "Approve the index migration", "harness": "claude-code",
    "harnessName": "Claude Code", "projectId": "6A1E…", "attention": "waiting",
    "indicator": "awaitingApproval", "pendingRequest": "approval", "unread": false,
    "running": true, "pinned": false, "lastActivityAt": 1792158000000, "parentTaskId": "9E7D…"}
 ]}
```

After a client's first `snapshot`, the server pushes `tasksChanged` and `attention` events (§5) to it.
Call `snapshot` again after reconnecting.

**Project:** `id`; `name` (as the sidebar names it); `kind`: `project` (a Yardlet project), `folder`
(tasks of a folder outside any project) or `chats` (the sidebar's Chats, `id` `"chats"`, name in the
Mac's language). Listed in sidebar order. No folder paths are sent.

**Task** — the tasks the Mac's sidebar lists (not archived), most recently active first:

| field | |
|---|---|
| `id` | the Yardlet task ID |
| `title` | the sidebar title |
| `harness`, `harnessName` | e.g. `codex`/`Codex`, `claude-code`/`Claude Code`, `antigravity-cli` |
| `projectId` | the project it is listed under |
| `attention` | the sidebar's one attention state: `waiting` (an approval or a question waits for the person), `unread` (a finished result, failed included, not read yet), `active` (a turn or bash command is working), `idle` |
| `indicator` | the sidebar row's mark, absent when none: `awaitingApproval` (green dot), `needsInput` (orange dot), `failed` (red warning), `usageLimit` (gauge), `running` (gray dot), `unread` (blue dot) |
| `pendingRequest` | `approval` or `input` while `waiting` |
| `unread` | the task holds an unread result |
| `running` | a turn (or a Claude bash command) is running, waiting on a request included: `stopTurn` applies. `attention` `waiting` always comes with `running: true` |
| `pinned` | listed under Pinned in the sidebar |
| `lastActivityAt` | last activity |
| `parentTaskId` | the task it was started from (fork, subagent), when that task is in Yardlet; the sidebar nests it |

`attention` and `indicator` are the same definition the Mac's sidebar dots, menu bar menu and Dock
badge read (`TaskAttentionProjection`, `SidebarTaskIndicatorProjection`).

### 4.2 Conversation

#### `subscribeTask`

```json
{"id": "3", "type": "subscribeTask", "taskId": "4C1F…"}
```

```json
{"re": "3", "ok": true, "taskId": "4C1F…", "items": [ … ], "cursor": "t:…", "hasOlder": true}
```

- `items`: the latest page of the conversation (whole turns, at least one), oldest first (§6).
- `cursor`: names the start of what was sent; pass it to `loadOlder`. Absent when `hasOlder` is false.
- `hasOlder`: there is more before (loaded on the Mac, or still with the provider).
- Then the server pushes `conversation`, `conversationReset` and `conversationEnded` events for the
  task (§5.3) until `unsubscribeTask` or disconnect. Subscribing again to the same task starts over
  with a fresh page. Up to 8 tasks per connection (`tooManySubscriptions`).
- Subscribing reads the task's latest saved history the way opening the task on the Mac does (it
  never starts a model turn); what that read adds arrives as events.

#### `loadOlder`

```json
{"id": "4", "type": "loadOlder", "taskId": "4C1F…", "cursor": "t:…"}
```

```json
{"re": "4", "ok": true, "taskId": "4C1F…", "items": [ … ], "cursor": "t:…", "hasOlder": false}
```

- `items`: the whole turns just before `cursor`, oldest first; put them before the items you have.
  Later events can update them too.
- When the Mac must first ask the provider for earlier history, the response waits for it (up to
  about 15 s). `items` can then be empty with `hasOlder` still true: try again later.
- Errors: `notSubscribed`, `invalidCursor` (the conversation was reset since; subscribe again).

#### `unsubscribeTask`

```json
{"id": "5", "type": "unsubscribeTask", "taskId": "4C1F…"}
```

`{"re": "5", "ok": true}`. Unsubscribing a task that is not subscribed is fine.

### 4.3 `ping`

```json
{"id": "6", "type": "ping"}
```

```json
{"re": "6", "ok": true, "pong": true, "serverTime": 1792158000000}
```

### 4.4 Commands

Commands act through the same paths as the Mac's own controls. Every command is written to the Mac's
local audit log with its type, task ID, device and result — never the message text. `ok: true`
means the Mac accepted the command; what happens next arrives as events.

#### `sendMessage`

```json
{"id": "7", "type": "sendMessage", "taskId": "4C1F…", "text": "Run the migration tests again"}
```

- Sent as if typed in the task's composer on the Mac, with the task's current model, permission
  mode and account. An idle task starts a turn (resuming the provider session when needed); while a
  turn runs, the task's follow-up behavior applies (Codex steers or queues by the Mac's setting,
  Claude Code queues). A message that waits shows as a `queued` user item at the end of the
  conversation (§6.2) until the provider takes it; then that item is removed and the message
  appears as an ordinary `user` item in its turn.
- `text`: trimmed; 1–32,000 characters. Plain text only, no attachments.
- Errors: `emptyMessage`, `tooLarge`, `unsupportedCommand` (the first word is a slash command such as
  `/clear` or `/model` — commands stay on the Mac), `busy` (the Mac is editing a message in this task,
  switching its account, or another app holds the conversation), `notFound`.

#### `answerApproval`

```json
{"id": "8", "type": "answerApproval", "taskId": "4C1F…", "requestId": "toolu_01…", "answer": "allowOnce"}
```

- `answer`: `allowOnce` or `deny` — only answers the request's item lists in `options` (§6.5). Allow
  once is the narrowest allow the Mac's card offers (the same answer as the Mac notification's
  "Allow once"); deny is the card's plain deny. Answers that create standing rules ("Allow for
  session", "Always allow", provider options with a broader scope) and answers to questions and plan
  reviews stay on the Mac.
- Errors: `requestNotFound` (no longer waiting, answered elsewhere, or unknown), `notAllowed` (that
  answer is not offered for this request), `unavailable` (the task is not connected to its harness on
  the Mac), `notFound`.

#### `stopTurn`

```json
{"id": "9", "type": "stopTurn", "taskId": "4C1F…"}
```

- As the Mac's stop button: a running Claude bash command first, otherwise the turn. Queued
  follow-ups are held until resumed on the Mac (as on the Mac).
- Errors: `notRunning`, `notFound`.

#### `markRead`

```json
{"id": "10", "type": "markRead", "taskId": "4C1F…"}
```

Clears the task's unread result (idempotent). Errors: `notFound`.

## 5. Events

### 5.1 `tasksChanged`

```json
{"event": "tasksChanged", "seq": 3,
 "tasks": [ {"id": "4C1F…", "title": "…", "attention": "unread", "…": "…"} ],
 "removedTaskIds": ["77AB…"],
 "projects": [ {"id": "6A1E…", "name": "Yardlet", "kind": "project"} ]}
```

- `tasks`: the tasks that are new or changed, whole. `removedTaskIds`: tasks no longer listed
  (archived, deleted). `projects`: present only when the project list changed, then the whole list.
- Sent at most about twice a second.

### 5.2 `attention`

```json
{"event": "attention", "seq": 4, "taskId": "4C1F…", "title": "Approve the index migration",
 "projectName": "Yardlet", "harnessName": "Claude Code", "state": "waiting",
 "previousState": "active", "indicator": "awaitingApproval", "pendingRequest": "approval",
 "requestId": "toolu_01…", "summary": "Bash: Run the migration tests"}
```

- Sent when a listed task's `attention` changes, and again while `waiting` when a newer request
  starts waiting (`requestId` changes). Not sent for the tasks of the first snapshot, or for a task
  that is new and idle.
- Changes are read at most about twice a second, so a quick turn can go from `waiting` straight to
  `unread` without an `active` in between.
- `summary` (while `waiting`): one line about the request, at most 120 characters, safe for a lock
  screen — a question's first line, or the call and what it does (`Bash: Run the migration tests`;
  its description, else the first line of its command). Credentials are masked with `•••` (`Bearer …`,
  `TOKEN=…`, `--password …`, `user:password@` in URLs, long key-like strings). Never file contents or
  diffs. Absent when the Mac has nothing to say.
- The phone makes its own notifications from these; the Mac uses no push service. Suggested: notify
  on `waiting` (approval or question) and on `active` → `unread` (finished; `indicator` `failed` when
  it failed).

### 5.3 Conversation events

#### `conversation` — changes to a subscribed conversation

```json
{"event": "conversation", "seq": 5, "taskId": "4C1F…", "changes": [
  {"op": "remove", "id": "req:toolu_01…"},
  {"op": "upsert", "after": "i:5D0C…", "item": {"id": "i:91AA…", "kind": "assistant", "…": "…"}}
]}
```

Apply the changes in order to the loaded items:

- `remove`: drop the item with that `id`.
- `upsert`: if an item with `item.id` exists, replace it in place. Otherwise insert the item right
  after the item `after`; `after` absent or null means at the very start of the loaded items.

The server keeps, per subscription, exactly the items it has sent (every page, `loadOlder` pages
included) and describes each change against them. So `after` always names an item the phone holds
once it has applied, in order, everything this connection sent before: earlier responses (a
`loadOlder` page is put before the loaded items first), earlier events, and the changes before it in
the same event. Apply responses and events in the order they arrive. A phone that ever cannot find
`after` is out of step (it dropped something): it must not guess a place — it subscribes to the task
again, which sends a fresh page. After a `loadOlder` response, the changes the newer turns went
through meanwhile follow at once as a `conversation` event.

A streaming answer is the same item sent again with its text so far. Sent at most about five times a
second per task.

#### `conversationReset`

```json
{"event": "conversationReset", "seq": 6, "taskId": "4C1F…", "items": [ … ], "cursor": "t:…", "hasOlder": true}
```

Replace all loaded items: the Mac read the history again in a way changes cannot express. As a
fresh `subscribeTask` page; older cursors are invalid.

#### `conversationEnded`

```json
{"event": "conversationEnded", "seq": 7, "taskId": "4C1F…", "reason": "removed"}
```

The task was archived or deleted; its subscription ended.

### 5.4 `revoked`, `closing`

See §3.4.

## 6. Conversation items

The phone's projection of the Mac's one conversation model (`ConversationPresentation`, which the
Mac's `ConversationTimeline` draws for every harness), in the Mac's order. Each turn is: what was
sent (`user`), notices, the turn header (`turn`), the turn's error (`error`), its plan and work
(`plan`, `activity`, answered `approval`, commentary `assistant`; marked `inWork`), its answers
(`assistant` with role `answer`), and the requests still waiting (pending `approval`).

Every item has:

| field | |
|---|---|
| `id` | stable within the task; prefixes `turn:`, `i:`, `req:`, `plan:`, `outcome:`, `queued:` keep kinds apart |
| `turnId` | the turn it belongs to |
| `kind` | `turn`, `user`, `assistant`, `activity`, `approval`, `plan`, `error`, `notice` |
| `inWork` | true for the turn's work: hide it under the turn header while that turn's `foldsWork` is true, as the Mac folds a finished turn's work, unless the person opens it |

Unknown kinds: skip them. Text fields are capped (`truncated: true` when cut).

### 6.1 `turn`

```json
{"id": "turn:3F2A…", "turnId": "3F2A…", "kind": "turn", "status": "completed",
 "startedAt": 1792157900000, "completedAt": 1792157990000, "durationMs": 90000,
 "foldsWork": true, "workCount": 7}
```

- `status`: `running`, `completed`, `interrupted`, `failed`, `unknown`.
- `durationMs`: the work time ("Worked for 1m 30s") when known; `approximate: true` when read from
  the items' own times. `foldsWork`: the Mac folds this turn's `inWork` items. `workCount`: how many.
- While running: `progress` `thinking` (no visible output yet) or `reconnecting` with `progressText`
  (the provider retrying its stream, in its words).

### 6.2 `user`

```json
{"id": "i:5D0C…", "turnId": "3F2A…", "kind": "user", "text": "Run the migration tests", "imageCount": 1}
```

- `queued: true`: a message waiting in the task's follow-up queue (sent from the phone or the Mac
  while a turn ran), not yet taken by the provider. Queued items sit at the end of the last turn, `id`
  `queued:…`; `queueFailed: true` when sending it failed (it waits on the Mac). When the provider
  takes the message, the queued item is removed and the message appears as an ordinary `user` item
  (another `id`) in the turn that reads it.
- `text` ≤ 16,000 characters. `imageCount`: attached images (not sent). `scheduled: true`: a Codex
  automation sent it on its schedule. `shell: true`: a Claude Code bash command (`text` is the
  command). `diffCommentCount`: diff comments attached on the Mac (their text is not sent).

### 6.3 `assistant`

```json
{"id": "i:91AA…", "turnId": "3F2A…", "kind": "assistant", "role": "answer",
 "text": "All **12** migration tests pass.", "streaming": true}
```

- `text`: Markdown (CommonMark + GFM tables), ≤ 32,000 characters. `role`: `answer` (the turn's
  answer), `commentary` (a working note during the turn; `inWork`), `proposedPlan` (a plan the agent
  proposes, Markdown). `streaming: true` while it is still being written.

### 6.4 `activity` — one tool, command or step, as one line

```json
{"id": "i:CE01…", "turnId": "3F2A…", "kind": "activity", "inWork": true, "activity": "command",
 "title": "Ran swift test --filter Migration", "status": "completed", "exitCode": 0}
```

- `activity`: `command`, `fileChange`, `tool`, `subagent`, `reasoning`, `taskSuggestion`, `other`.
- `title` (≤ 300 characters): the line the Mac shows, in the provider app's words and the Mac's
  language ("Read Parser.swift", "Edited Package.swift", "Searched TODO", "Thinking").
- `detail` (≤ 500 characters, optional): the command when the title does not show it whole, a
  reasoning summary, an error message, a suggested task's summary.
- `status`: `running`, `completed`, `failed`, `stopped`.
- Optional: `exitCode` (a command that exited), `additions`/`deletions` (a file change's lines),
  `approved: true` (allowed through an approval).
- No command output, file contents or diffs are sent.

### 6.5 `approval` — a request

```json
{"id": "req:toolu_01…", "turnId": "3F2A…", "kind": "approval", "requestId": "toolu_01…",
 "requestKind": "approval", "status": "pending", "title": "Bash",
 "command": "swift test --filter Migration", "detail": "Run the migration tests",
 "options": ["allowOnce", "deny"], "moreOnMac": true}
```

- `requestId`: what `answerApproval` names. `requestKind`: `approval`, `question` (the agent asks
  the person), `planReview` (a plan to approve), `form` (a Codex input form).
- `status`: `pending`, `allowed`, `denied`, `answered`, `expired`, `rejected`. A pending request sits
  at its turn's end; once answered it moves into the turn's work (`inWork`) where it happened.
- `title`, `detail` (≤ 1,000), `command` (≤ 2,000): what the Mac's card shows. `text`: a plan review's
  plan (Markdown, ≤ 8,000). `questions`: a question's texts (each ≤ 500).
- `options` (pending only): what the phone may answer — `allowOnce`, `deny`, both, or none.
- `moreOnMac: true`: the Mac's card offers answers the phone does not (for example "Allow for
  session", a question form, a plan review). Show that more is on the Mac.

### 6.6 `plan`

```json
{"id": "plan:3F2A…", "turnId": "3F2A…", "kind": "plan", "inWork": true,
 "explanation": "Fix the failing tests first.",
 "steps": [{"text": "Read the failing test", "status": "completed"},
           {"text": "Fix the migration", "status": "inProgress"}]}
```

- A step plan or to-do list. `status`: `pending`, `inProgress`, `completed`. Up to 50 steps, each
  ≤ 500 characters.

### 6.7 `error`

```json
{"id": "outcome:3F2A…", "turnId": "3F2A…", "kind": "error", "errorKind": "usageLimit",
 "title": "You've hit your limit", "message": "Resets at 4pm", "resetsAt": 1792170000000}
```

- The turn's error (`errorKind` `error`, with `recoverable`) or the plan limit that stopped it
  (`errorKind` `usageLimit`, with `resetsAt` when known). `message` ≤ 2,000 characters. An error the
  turn went on past is in the work (`inWork`).

### 6.8 `notice`

```json
{"id": "i:7AB0…", "turnId": "3F2A…", "kind": "notice", "text": "Context compacted"}
```

The provider's notices beside the turn (a model reroute, a warning) and context compaction.

## 7. Limits

- Client frame ≤ 65,536 bytes (1009 close). `sendMessage.text` ≤ 32,000 characters.
- Requests: a burst of 30, then 10 per second per connection. Commands (`sendMessage`,
  `answerApproval`, `stopTurn`, `markRead`): a burst of 10, then one per 3 s. Over the limit a request
  gets `rateLimited` and is dropped; 20 in a row closes the connection (4429).
- At most 8 connections at once; more are closed (4503). At most 8 subscriptions per connection.
- Pairing: 5 wrong codes close the open pairing.

## 8. Error codes

| code | meaning |
|---|---|
| `badRequest` | not JSON, not an object, or a missing or wrong field |
| `unknownType` | a `type` the server does not know |
| `unsupportedVersion` | `protocolVersion` is not 1 |
| `unauthenticated` | the first message was not `pair` or `hello` |
| `invalidToken` | the token names no paired device |
| `pairingUnavailable` | no pairing is open (expired, used, cancelled, or closed by wrong codes) |
| `pairingInvalid` | wrong pairing code |
| `notFound` | no listed task with that ID |
| `notSubscribed` | `loadOlder` for a task not subscribed |
| `invalidCursor` | the cursor no longer names a place in the conversation |
| `tooManySubscriptions` | more than 8 subscribed tasks |
| `requestNotFound` | the request is not waiting any more |
| `notAllowed` | that answer is not offered for the request |
| `unavailable` | the task is not connected to its harness on the Mac |
| `notRunning` | nothing to stop |
| `emptyMessage` | `sendMessage.text` is empty |
| `tooLarge` | `sendMessage.text` is too long |
| `unsupportedCommand` | a slash command |
| `busy` | the task cannot take it now (editing, switching account, held by another app) |
| `rateLimited` | over the rate limit |
| `internal` | anything else |
| `unknownDevice` | v2 handshake: the phone's key is not paired, or the device was removed (§13.1) |
| `linkUnavailable` | v2 handshake: a link request to a Mac not signed in to an account (§12.1) |

Close codes: 1000 normal, 1003 binary frame, 1009 frame too large, 4401 unauthenticated or invalid
token, 4403 device removed, 4408 idle or no `hello` in time, 4426 unsupported version, 4429 rate
limited, 4503 remote off, Yardlet quitting, or too many connections.

## 9. Fixture server

A loopback server with the same protocol and realistic fixture tasks, for developing the client
without a Mac running Yardlet's real tasks:

```sh
swift run --build-system native yardlet-remote-fixture            # ws://127.0.0.1:47615/
swift run --build-system native yardlet-remote-fixture --port 47700 --single-use-pairing
```

- Android emulator: `ws://10.0.2.2:47615/`. It binds `127.0.0.1` only.
- Pairing code `ABCDE-12345` (reusable unless `--single-use-pairing`, which also expires it after
  5 minutes like the Mac). Or skip pairing: `hello` with token `yardlet-fixture-token`.
- It prints its QR URL. Its device list is kept in memory and is gone when it stops.
- Fixture tasks (projects Yardlet, Website and Chats):
  - "Approve the index migration" (Claude Code) waits on a Bash approval (`allowOnce`, `deny`,
    `moreOnMac`; `running: true`, so `stopTurn` applies and expires the request). Allow once: the
    command runs, an answer streams, the turn completes and the task turns unread. Deny: the turn
    ends with a short answer. About 30 s after the turn ends a new approval arrives, so it can be
    tried again.
  - "Build the release bundle" (Codex) streams an answer word by word with a running command;
    `stopTurn` interrupts it; it starts streaming again 30 s after it stops or finishes.
  - A message sent to a running task waits as a `queued` item and is taken when the turn ends, which
    starts a reply turn.
  - "Summarize the crash reports" (Codex) is finished and unread with 30 turns, for `loadOlder`.
  - "Fix the footer links" (Claude Code) is idle; `sendMessage` (to it or any idle task) starts a turn
    that reads and edits files, streams an answer and completes.
  - "Pick the release name" (Claude Code) waits on a question (no phone options, `moreOnMac`;
    `stopTurn` expires it, and the question comes back 30 s later).
  - "Plan the weekend trip" (a chat) has a to-do plan; "Check the footer on mobile" is nested under
    "Fix the footer links"; "Regenerate the screenshots" failed.

## 10. Revisions

Still protocol version 1: every revision only adds optional fields or states a rule.

- 2026-10-16, after the first Android client build:
  - §5.3: `after` always names an item the phone holds once it has applied what came before in order;
    a phone that cannot find it subscribes again. A `loadOlder` page is followed by the changes its
    newer turns went through meanwhile.
  - §6.2: `queued` (and `queueFailed`) user items for messages waiting in a task's follow-up queue.
  - §4.1: `running` is true while a turn waits on a request (`waiting` implies `running`); the fixture's
    waiting tasks now say so and `stopTurn` expires their request.
  - §5.2: `summary` on `attention` events while `waiting` (≤ 120 characters, secrets masked).
  - §2, §3.2, §3.3, §4.1: `serverTime` on the `pair`, `hello` and `snapshot` responses, for clock skew.
- 2026-10-24: protocol v2 (§11–§16) beside v1. v1 is unchanged on the wire; a v1 connection never sees
  the v2 answers in `options` (§15.12).

## 11. v2 transport

### 11.1 Paths

Every v2 connection is a WebSocket that carries **binary frames only**, one Noise message per frame
(§13). A text frame closes the connection (1003); a frame over 65,535 bytes closes it (1009). The same
handshake and encryption run on every path:

| path | phone connects to | notes |
|---|---|---|
| direct (same network, Tailscale, the emulator) | `ws://<host>:<port>/` | The Mac listens on every interface, port **47616** by default (another free port when 47616 is taken; Bonjour and §13.3 name the real one). No `Origin` header (HTTP 400, as v1). |
| relay | `wss://<relay>/v1/rooms/<room>/connect` | §14. The relay forwards frames and cannot read them. |

No TLS on direct paths: the Noise handshake authenticates the Mac by its static key, whatever the path.

### 11.2 Keys and names

| key | kind | where |
|---|---|---|
| Mac static key | X25519 | The Mac's Keychain. Its public key is in the pairing QR (`k`). |
| Mac relay key | Ed25519 | The Mac's Keychain. Opens the Mac's room on the relay (§14.2). |
| Phone static key | X25519, one per paired Mac | The phone's secure storage (Android: sealed with a Keystore key, no backup). The Mac stores its public key. |
| Push key | 32 random bytes, one per device | Made by the Mac on `registerPush` (§15.6), kept in the Mac's device list and the phone's secure storage. |

- **Room:** `base32(SHA-256(relay public key)[0..<20])`, RFC 4648 alphabet in lowercase, no padding:
  32 characters `[a-z2-7]`.
- **Mac discovery id:** the first 8 bytes of `SHA-256("yardlet-mdns/2" ‖ Mac static public key)` as
  16 lowercase hex characters.
- **Push key id:** the first 8 bytes of `SHA-256(push key)` as 16 lowercase hex characters.
- Binary values in JSON and URLs are **base64url without padding** (a 32-byte key is 43 characters).

### 11.3 Discovery on the same network

The Mac advertises Bonjour service `_yardlet._tcp` on its v2 port while the remote is on: instance name
`Yardlet-<discovery id>`, TXT `v=2` and `id=<discovery id>`. The Mac's name is not advertised. A phone
computes the discovery id from the Mac static key it stored and connects to the service with that id.
Bonjour can be refused (macOS asks for Local Network access once; guest networks drop multicast), so a
phone also keeps the direct addresses of §13.3.

### 11.4 Choosing a path (phone)

1. Candidates: addresses Bonjour resolved for the Mac, the direct addresses last received (§13.3; the
   private-range ones when on Wi-Fi or Ethernet, Tailscale ones when a VPN is up), then the relay.
2. Start the direct candidates at once (3 s each to finish the handshake) and the relay 0.7 s later;
   the first handshake that completes wins and the others are closed.
3. While on the relay, try direct again when the network changes or Bonjour finds the Mac; when one
   completes, move to it (send `snapshot` and subscribe again) and close the relay connection.

## 12. v2 pairing

Settings › Remote › "Pair a phone" shows a QR code holding:

```
yardlet-remote://pair?v=2&k=<Mac static public key>&s=<secret>&n=MacBook%20Pro&h=192.168.1.20:47616&h=100.64.12.34:47616&r=wss://relay.example.test&i=<room>
```

- `v=2`. `k`: the Mac static public key. `s`: the pairing secret, 32 random bytes. `n`: the Mac's name.
  `h`: zero or more direct addresses `host:port` in the order to try (an IPv6 host in brackets). `r` and
  `i`: the relay's base URL and the Mac's room, present when the Mac uses a relay. Values are
  percent-encoded; unknown parameters are ignored.
- A pairing **expires after 5 minutes**, closes after 5 handshakes with a wrong secret, and opening a new
  one cancels it. It is spent by its first successful use, except that the **same phone key** may use it
  again until it expires (a phone that lost the Mac's answer simply pairs again).
- A phone key is a device: pairing again with a new key adds a new device. A phone that pairs a Mac again
  sends `forgetDevice` with its old key first, if it still can.
- There is no manual code in v2: a short code typed by hand needs a PAKE to be safe without accounts.
  The QR also opens the app from the phone's camera (the `yardlet-remote` scheme).

### 12.1 Linking through an account

A phone signed in to the person's account (§14.4) learns the account's Macs (name, room, keys) without a QR
code and asks one to link:

- Message 1's payload carries `"link": true` instead of `pair`. Message 2 answers
  `{"ok": false, "pending": true, "code": "482913", "server": {…}}` when the Mac takes the request, and the
  connection stays open but unauthenticated: the phone may only send `ping`.
- **Code:** the first 4 bytes of `SHA-256("yardlet-link/1" ‖ Mac static public key ‖ phone static public key)`
  as a big-endian unsigned integer, modulo 1,000,000, written with 6 digits (shown `482 913`). Both sides
  compute it from the keys they hold, so a server that handed the phone another Mac key shows mismatched codes.
  The phone shows the code it computed itself; when message 2's `code` differs, it stops (the Mac it reached
  holds other keys).
- A v2 phone that connects while a request waits gets the `linkRequest` event too.
- The Mac shows the request (name, platform, code) in Settings and to its connected v2 phones (event
  `linkRequest`, §15.11). The first approval or refusal wins. Approved: the Mac sends the encrypted event
  `{"event": "linked", "deviceId": "…"}` and the connection is authenticated as that new device from then on.
  Refused: `{"event": "linkRefused"}` and close 4403. No answer in 120 s: `linkRefused` and close 4408.
- Errors in message 2: `linkUnavailable` (the Mac is not signed in to an account; 4401), `busy` (another link
  request is pending; 4503).

## 13. v2 handshake and messages

### 13.1 Handshake

`Noise_IK_25519_ChaChaPoly_SHA256` (Noise revision 34), prologue the 16 ASCII bytes `yardlet-remote/2`.
The phone is the initiator and knows the Mac static public key (`<- s`):

```
-> e, es, s, ss   + payload   (phone → Mac, one binary frame)
<- e, ee, se      + payload   (Mac → phone, one binary frame)
```

Message 1's payload (UTF-8 JSON):

```json
{"v": 2, "name": "Pixel 9", "platform": "android", "appVersion": "0.2.0"}
{"v": 2, "name": "Pixel 9", "platform": "android", "appVersion": "0.2.0", "pair": "<secret>"}
```

- `name` ≤ 64 characters, shown in the Mac's device list (updated on every connection). `pair`: the QR's
  secret, when pairing.

Message 2's payload:

```json
{"ok": true, "deviceId": "B0D2…", "serverTime": 1792158000000, "paired": true,
 "server": {"name": "MacBook Pro", "app": "Yardlet", "appVersion": "1.0", "protocolVersion": 2},
 "direct": ["192.168.1.20:47616", "100.64.12.34:47616", "mac.example-tailnet.ts.net:47616"],
 "relay": {"url": "wss://relay.example.test", "room": "<room>"}}
```

```json
{"ok": false, "error": {"code": "unknownDevice", "message": "…"}}
```

- `paired: true` only on the connection that paired. `direct`: the Mac's addresses now, to try next time.
  `relay`: absent when the Mac uses none; a phone replaces what it stored with it.
- Errors, after which the Mac closes: `unknownDevice` (the phone key is not paired, or was removed:
  4403), `pairingUnavailable` and `pairingInvalid` (4401), `unsupportedVersion` (4426), `badRequest`
  (4401).
- A message 1 the Mac cannot read (another Mac key, a damaged frame) is closed with 4401 and no
  message 2. The phone sends message 1 within 10 s of the WebSocket opening; each side gives the
  other 10 s.
- After message 2 both sides `Split()`: the phone sends with the first cipher and receives with the
  second; the Mac the other way round. The connection is authenticated as `deviceId`; `pair` and
  `hello` get `badRequest`.

### 13.2 Messages

Requests, responses and events are the JSON objects of §2, §4, §5 and §15. Each is sent as one or
more Noise transport messages:

- UTF-8 bytes of the JSON, cut into chunks of at most 65,518 bytes. Each chunk's plaintext is one flag
  byte (`0x01` the last chunk, `0x00` more follow) and the chunk; encrypted with the sender's cipher,
  empty associated data, one transport message per binary frame (≤ 65,535 bytes).
- The receiver decrypts in order and joins the chunks. A message that fails to decrypt closes the
  connection (4401). A message from the phone over 65,536 bytes closes it (1009); the Mac's messages can
  be up to 8 MiB.
- Nonces start at 0 in each direction and grow by one per message (Noise).

### 13.3 Keepalive and closing

- The phone sends `ping` (§4.3) at least every 25 s. The Mac closes a connection that sent nothing for
  75 s (4408). WebSocket ping frames do not reach the Mac over the relay.
- Close codes are those of §8, plus: 4401 handshake or decryption failed, 4403 device unknown or
  removed, 4404 the Mac is not on the relay (§14.3), 4409 the Mac reconnected to the relay.
- The Mac sends `revoked` and `closing` (§3.4) as encrypted events before closing, as in v1.

## 14. Relay

### 14.1 Endpoints

| request | who | |
|---|---|---|
| `GET /v1/health` | anyone | `200 ok` |
| `GET /v1/rooms/<room>/host` (WebSocket) | the Mac | §14.2 |
| `GET /v1/rooms/<room>/connect` (WebSocket) | a phone | §14.3. `404` when no Mac holds the room, `429` when the room has 8 phones, `400` for a malformed room |

One room per Mac. The relay keeps a room only in memory while its Mac is connected; it stores nothing
and logs no frame contents. What it sees: rooms, IP addresses, when sockets open and close, frame sizes
and times, and a push's FCM token while sending it.

### 14.2 The Mac's socket

1. The relay sends `{"t": "challenge", "nonce": "<32 random bytes>"}` as soon as it accepts.
2. The Mac answers `{"t": "auth", "key": "<relay public key>", "sig": "<signature>"}`: an Ed25519
   signature of the UTF-8 bytes of `yardlet-relay-host/1\n<room>\n<nonce>`.
3. The relay checks that the room is the key's room (§11.2) and the signature, then sends
   `{"t": "ready"}`. Otherwise it closes with 4401; no `auth` within 10 s closes with 4408.
4. A newer authenticated socket for the same room replaces the older one: the older socket and every
   phone of the room are closed with 4409.
5. `{"t": "open", "c": 7}` tells the Mac a phone connected as connection 7 (numbers grow per room);
   `{"t": "closed", "c": 7, "code": 1006}` that it left. The Mac sends `{"t": "close", "c": 7,
   "code": 4403}` to close a phone's socket with that code; that phone gets no `closed` back. A close code the
   relay may not use closes with 1000.
6. Data both ways is binary frames: a 4-byte big-endian connection number, then the phone's frame.
7. The Mac sends the text `ping` every 30 s and the relay answers `pong` without waking the room. The
   Mac reconnects when no `pong` came for 90 s.
8. Push, at most 60 a minute per room:

   ```json
   {"t": "push", "id": "p3", "to": "<FCM registration token>", "urgent": true, "collapse": "<≤ 64 chars>", "ttl": 3600,
    "data": {"v": "1", "k": "<push key id>", "y": "<sealed payload>"}}
   ```

   The relay sends `data` as an FCM HTTP v1 data message (`android.priority` HIGH when `urgent`, else
   NORMAL; `collapse_key`; `ttl`) and answers `{"t": "pushed", "id": "p3", "ok": true}` or
   `{"t": "pushed", "id": "p3", "ok": false, "error": "unregistered"}`. Errors: `unregistered` (the
   token is gone: forget it), `invalid`, `rateLimited`, `unavailable`, `notConfigured` (the relay has
   no FCM credentials).

### 14.3 A phone's socket

Binary frames only (a text frame closes it, 1003), each at most 65,535 bytes (1009). The relay closes a
phone socket that sent nothing for 120 s (4408), and every phone socket of a room whose Mac left (4404).

### 14.4 Accounts

Optional (the QR stays the way to pair without one). The account only lists the person's Macs and lets a new
phone ask one of them to link (§12.1); it never carries tasks or conversations.

| request | | answer |
|---|---|---|
| `GET /v1/auth/providers` | | `{"providers": ["github", "google"]}`: the ones the relay is configured for. Empty (or no answer): apps show no sign-in at all, and the relay still carries connections |
| `GET /v1/auth/<provider>/start?redirect_uri=yardlet-remote://auth&code_challenge=<S256>&state=<client state>` | opened in the system's browser sign-in sheet | `302` to the provider |
| `GET /v1/auth/<provider>/callback?code=…&state=…` | the provider returns here | `302` to `yardlet-remote://auth?code=<one-time code>&state=<client state>`, or `?error=<reason>&state=…` |
| `POST /v1/auth/token` `{"code", "codeVerifier", "deviceName"}` | the app, once | `{"token": "<account>.<secret>", "account": {"id", "provider", "name"}}` |
| `GET /v1/account` | `Authorization: Bearer <token>` | `{"id", "provider", "name", "macs": [{"room", "macKey", "relayKey", "name", "updatedAt"}]}` |
| `PUT /v1/account/macs/<room>` `{"macKey", "relayKey", "name", "sig"}` | the Mac | `{"ok": true}` |
| `DELETE /v1/account/macs/<room>` | the Mac or a phone | `204` |
| `POST /v1/auth/logout` | | `204`: this token stops working |
| `DELETE /v1/account` | | `204`: the account, its Macs and every token are deleted |

- `redirect_uri` is exactly `yardlet-remote://auth`. `code_challenge` is base64url `SHA-256(code verifier)`
  (PKCE S256, the only method; `code_challenge_method` may be sent and must then be `S256`); `state` is the app's own (≤ 128 characters) and comes back unchanged. The relay signs its own
  provider `state` (HMAC-SHA256, 10 minutes) so the flow needs no storage until the account is known.
- **Account id:** `base32(SHA-256("yardlet-account/1\n" + provider + "\n" + subject)[0..<20])`, 32 characters,
  where `subject` is the provider's stable user number (GitHub user id, Google `sub`). The subject itself and
  the e-mail address are not stored. `name`: the GitHub login or the Google profile's name, for display.
- **Registering a Mac:** `sig` is an Ed25519 signature by the Mac relay key over the UTF-8 bytes of
  `yardlet-account-mac/1\n<account id>\n<room>\n<macKey>\n<name>`; the room must be the relay key's (§11.2).
  At most 20 Macs per account. Registering again updates the entry.
- **Tokens:** `<account id>.<32 random bytes>`; the relay keeps the secret's SHA-256, the device name and
  times. A token unused for 90 days stops working. The one-time code has the same shape (so the relay finds the
  account without a table of all accounts), lasts 2 minutes and is spent by the first exchange, right or wrong.
- **Callback failures:** a provider `state` that is forged or expired gets `400` and no redirect (the app's
  `state` inside it cannot be trusted); a provider that fails or refuses redirects with
  `?error=providerFailed` or the provider's own error (`access_denied`). Names (`name`, `deviceName`) are cut to
  64 characters.
- **Storage:** one Durable Object per account, named by the account id. Nothing else about accounts is kept.
- Errors are JSON `{"error": "…"}`: `unauthorized` (401), `badRequest` (400), `notConfigured` (501: no such
  provider), `invalidSignature` (403), `tooMany` (409), `providerFailed` (502).
- Provider credentials are the relay's secrets: `GITHUB_CLIENT_ID`, `GITHUB_CLIENT_SECRET`, `GOOGLE_CLIENT_ID`,
  `GOOGLE_CLIENT_SECRET`, `AUTH_STATE_SECRET`, and `PUBLIC_URL` (the relay's own https base, for callbacks).

## 15. v2 requests and fields

### 15.1 Snapshot

- `newTask: {"harness": "claude-code", "harnessName": "Claude Code"}`: what a task started from the phone
  runs on, the Mac's new-task composer as it is now (harness, its model and account, worktree or not).
  Absent when the Mac cannot start a task.
- Projects carry `canCreateTask: true` where `createTask` may start one (projects with a folder, and
  Chats).
- A waiting task carries `pendingSummary` (the newest request's line, as the `attention` event's `summary`)
  and `pendingKind` (`approval`, `question`, `planReview`, `form`), so a list says what waits without opening
  the task. v1 phones ignore them.
- `newTask` comes only with `snapshot`; a phone about to start a task asks for a `snapshot` again when it
  needs the Mac's current choice.

### 15.2 Approval items

- `questionSteps` on a pending question (`requestKind` `question`, or `form` for a Codex question form):

  ```json
  [{"id": "q1", "header": "Name", "text": "Which release name?",
    "options": [{"label": "Juniper", "description": "Short and easy to say"}, {"label": "Larch"}],
    "multiple": false, "custom": true, "skippable": false}]
  ```

  `id` is what `answerQuestion` names. `multiple`: more than one option may be picked. `custom`: the
  person may answer in their own words (with the options, or instead when there are none). `skippable`:
  the question may be left out.
- `options` may also hold `answer` (the phone may answer the questions), `approvePlan` and
  `keepPlanning` (a plan review). A question whose answer is secret, and an MCP form, stay on the Mac
  (`moreOnMac`).

### 15.3 `answerQuestion`

```json
{"id": "11", "type": "answerQuestion", "taskId": "4C1F…", "requestId": "toolu_02…",
 "answers": [{"questionId": "q1", "options": ["Juniper"]}, {"questionId": "q2", "text": "Ship on Friday"},
             {"questionId": "q3", "skipped": true}]}
```

- One entry per step: `options` are labels of that step (one unless `multiple`), `text` only where
  `custom` (≤ 4,000 characters), `skipped` only where `skippable`. Sent the way the Mac's card sends
  the same answers.
- Errors: `notFound`, `requestNotFound`, `notAllowed` (`answer` not offered, a label the step does not
  have, a step missing), `tooLarge`, `unavailable`.

### 15.4 `reviewPlan`

```json
{"id": "12", "type": "reviewPlan", "taskId": "4C1F…", "requestId": "toolu_03…", "decision": "approve"}
{"id": "13", "type": "reviewPlan", "taskId": "4C1F…", "requestId": "toolu_03…", "decision": "keepPlanning",
 "reason": "Split the migration first"}
```

The Mac card's two answers: approve the plan, or keep planning with an optional reason (≤ 4,000
characters). Errors as §15.3.

### 15.5 `createTask`

```json
{"id": "14", "type": "createTask", "projectId": "6A1E…", "text": "Add a dark mode toggle"}
```

```json
{"re": "14", "ok": true, "taskId": "9D02…"}
```

- Starts a task as the Mac's new-task composer would with that project (or Chats) chosen and the text
  typed: its harness, model, account and worktree setting as they are now on the Mac. The new task is listed
  (a `tasksChanged` event) before this response arrives, so the phone can subscribe to it at once.
- A command (§7). Errors: `notFound` (no such project, or it cannot take tasks), `emptyMessage`,
  `tooLarge`, `unsupportedCommand`, `unavailable` (no harness, or the project's folder is gone), `busy`,
  `internal` (the task did not start; `message` says why).

### 15.6 Push and devices

```json
{"id": "15", "type": "registerPush", "provider": "fcm", "token": "<FCM registration token>"}
```

```json
{"re": "15", "ok": true, "pushKey": "<32 bytes>", "pushKeyId": "<16 hex>"}
```

- Registering again (a new token) keeps the push key. `{"type": "unregisterPush"}` stops pushes.
- `{"type": "forgetDevice"}`: the phone unpairs itself; the Mac answers `ok`, removes the device and
  closes (4403).

### 15.8 `itemDetail`

```json
{"id": "18", "type": "itemDetail", "taskId": "4C1F…", "itemId": "i:CE01…"}
```

```json
{"re": "18", "ok": true, "taskId": "4C1F…", "itemId": "i:CE01…", "output": "…", "outputTruncated": true,
 "diffs": [{"path": "Sources/App.swift", "patch": "@@ -1,3 +1,4 @@\n…", "additions": 4, "deletions": 2}]}
```

- `activity` items with more to show carry `hasDetail: true`; only those are worth asking about.
- What a command, tool or file-change line holds beyond its title, fetched when the person opens it:
  `output`, the last 64,000 characters of a command's or tool's output (`outputTruncated` when cut); `diffs`,
  one unified diff per file (each ≤ 100,000 characters, `truncated` when cut; at most 50 files). Fields are
  absent when the Mac holds nothing for them. Sent only on request, over the encrypted channel, never in pushes.
- Errors: `notFound` (no such task or item), `unavailable` (the Mac holds nothing more for the item).

### 15.9 Suggested tasks

`activity` items with `activity` `taskSuggestion` carry `suggestionId`, `suggestionState` (`open`, `starting`,
`started`, `failed`, `dismissed`, `sentHere`), `startedTaskId` once started, and in `options` the actions the
phone may take: `start`, `here` (do it in this task), `dismiss`.

```json
{"id": "19", "type": "actOnSuggestion", "taskId": "4C1F…", "suggestionId": "task_1a2b3c4d", "action": "start"}
```

As the chip's buttons on the Mac. A command. Errors: `notFound`, `notAllowed` (the action is
not offered now).

### 15.10 Pinning and archiving

```json
{"id": "20", "type": "setPinned", "taskId": "4C1F…", "pinned": true}
{"id": "21", "type": "archiveTask", "taskId": "4C1F…"}
```

As the sidebar's Pin and Archive. Commands. An archived task leaves the list (`removedTaskIds`). Errors:
`notFound`, `busy` (the Mac cannot archive it now, for example while it runs).

### 15.11 Link requests

- Event to connected v2 phones while a link request (§12.1) waits:
  `{"event": "linkRequest", "requestId": "…", "name": "Pixel 9", "platform": "android", "code": "482913",
  "expiresAt": 1792158120000}`, and `{"event": "linkResolved", "requestId": "…", "approved": true}` once answered
  anywhere or expired.
- `{"type": "answerLink", "requestId": "…", "approve": true}`: approve or refuse it. A command. Errors:
  `requestNotFound`.

### 15.12 On v1 connections

The requests of §15.3–§15.11 get `unknownType`. Approval items sent to a v1 connection keep only `allowOnce` and
`deny` in `options` and set `moreOnMac` when they dropped another answer.

## 16. Push notifications

The Mac pushes to a device that registered (§15.6) and **has no open v2 connection**, for these
`attention` changes (§5.2): a task starts waiting or waits on a newer request (urgent); a task becomes
unread after `active` or `waiting` (finished or failed; urgent); a task stops waiting without becoming
unread (withdraw a notification; not urgent).

`data.y` is `nonce (12 random bytes) ‖ ciphertext ‖ tag (16 bytes)`, base64url: ChaCha20-Poly1305 with the
device's push key, associated data the UTF-8 bytes of `yardlet-push/1`, over the UTF-8 JSON

```json
{"event": "attention", "taskId": "4C1F…", "title": "Approve the index migration", "projectName": "Yardlet",
 "harnessName": "Claude Code", "state": "waiting", "previousState": "active", "indicator": "awaitingApproval",
 "pendingRequest": "approval", "requestId": "toolu_01…", "summary": "Bash: Run the migration tests",
 "macName": "MacBook Pro", "sentAt": 1792158000000}
```

- A waiting link request (§15.11) is pushed too, urgent:
  `{"event": "linkRequest", "requestId", "name", "platform", "code", "expiresAt", "macName", "sentAt"}`.
- `data.k` is the push key id, so a phone paired with several Macs knows which key opens it. `collapse` is
  the first 16 hex characters of `SHA-256(taskId)`; `ttl` 3,600 s. FCM data messages hold at most 4 KB,
  so titles are cut to 200 characters.
- The phone shows the notification itself, from the decrypted event, as it does for live `attention`
  events; on the lock screen only a public version ("Approval requested").

## 17. v2 fixture and test vectors

- `yardlet-remote-fixture --v2` also listens for v2 on `127.0.0.1:47616` with a fixed fixture Mac key and
  prints the v2 pairing URL (its secret is fixed too, and can be used again unless `--single-use-pairing`).
  The URL names `10.0.2.2:47616` (the Android emulator) and `127.0.0.1:47616`, or the `--host HOST:PORT`
  given. `--relay ws://127.0.0.1:8787` also opens the fixture's room on a local relay (`relay/`,
  `npx wrangler dev --local --port 8787`, no sign-in); `--relay-public ws://10.0.2.2:8787` is the relay address
  phones are told. `--approve-links` approves a link request (§12.1) three seconds after it arrives.
- The fixture's v2 tasks add a plan review, an answerable question, a suggested task, lines with details,
  and taking `createTask`, `setPinned` and `archiveTask`.
- Test vectors both implementations check (`Tests/NativeHarnessClientTests/Fixtures/RemoteNoiseVectors.json`,
  copied byte for byte into the phone app's tests): the public-domain cacophony vector for
  `Noise_IK_25519_ChaChaPoly_SHA256`, and a Yardlet vector with this protocol's prologue, a pairing
  payload, message 2's payload and a chunked transport message.
