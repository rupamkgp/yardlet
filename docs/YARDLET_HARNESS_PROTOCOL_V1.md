# Yardlet Harness Protocol v1

Status: implementation-proven contract candidate (`1.0`)

Yardlet Harness Protocol (YHP) is the process boundary between the independent Yardlet product and
any built-in or externally installed agent harness. It normalizes portable lifecycle and timeline
behavior into a Yardlet-owned shape without erasing provider-native features. Provider-native
features use declared, namespaced extensions and remain typed by their owning adapter.

The distributable schema, CLI runner, and sample live in
[`../SDK/YardletHarnessProtocolV1`](../SDK/YardletHarnessProtocolV1).

## Transport and negotiation

- The adapter is an executable supervised by Yardlet. stdin and stdout are UTF-8 JSONL; one complete
  JSON object occupies one line. stderr is diagnostic-only.
- The adapter must emit exactly one unversioned `hello` frame before any other output.
- `hello.manifest.protocolVersions` lists every exact version the adapter can decode. Yardlet selects
  the highest exact shared version and writes one `ready` frame.
- Major versions are incompatible. A minor version may only add optional fields, capabilities, event
  kinds, or methods. Neither side may assume an unadvertised minor fallback.
- Every request, response, and event after negotiation carries the selected version.
- JSON object key order is irrelevant. Dates are JSON numbers containing Unix seconds since
  `1970-01-01T00:00:00Z`. Binary provider evidence is base64.
- stdout belongs exclusively to protocol frames. Logging on stdout is a protocol violation.

Minimal hello:

```json
{"type":"hello","manifest":{"adapterID":"dev.example.agent","harness":"example","displayName":"Example Agent","protocolVersions":[{"major":1,"minor":0}],"capabilities":["runtime.discovery","session.close","session.create","timeline.streaming","turn.send"],"extensionNamespaces":["example.agent"]}}
```

Yardlet reply:

```json
{"type":"ready","version":{"major":1,"minor":0}}
```

## Manifest and capabilities

`adapterID`, `harness`, and `displayName` must be non-empty. Capability IDs and extension namespaces
contain at least two non-empty dot-separated components using letters, numbers, `_`, or `-`.

Every adapter must advertise:

- `runtime.discovery`
- `session.create`
- `session.close`
- `turn.send`
- `timeline.streaming`

Optional standard capabilities are:

- catalogs: `catalog.models`, `catalog.modes`
- lifecycle: `session.resume`, `session.import`
- turns: `turn.steer`, `turn.interrupt`
- structured surfaces: `permission.structured`, `timeline.reasoning`,
  `timeline.activities`, `timeline.plans`, `timeline.usage`, `timeline.subagents`
- rich input: `input.images`

Yardlet admits a standard method or rich event only when its capability was advertised. A harness
name never implies a capability.

## Request and response rules

Yardlet is the only side allowed to send `request` frames. The adapter may send only correlated
`response` frames and asynchronous `event` frames. Request IDs are non-empty strings and, once
written, cannot be reused for the life of one process connection, including after cancellation or
timeout. A late response therefore cannot satisfy a newer request. A response contains exactly one
of non-null `result` or `error`; errors use `{code, message, data?}`.

Portable methods:

| Method | Capability | Parameters | Result |
| --- | --- | --- | --- |
| `runtime.probe` | `runtime.discovery` | `{}` | harness, executable path, version, capabilities, fingerprint |
| `catalog.read` | models or modes | workspace path, refresh | typed model/mode/feature catalog |
| `session.create` | `session.create` | local UUID, config, initial rich blocks | session descriptor |
| `session.resume` | `session.resume` | local UUID, provider session ID, config | session descriptor |
| `session.import` | `session.import` | local UUID, provider handle ID, config | session descriptor |
| `session.send` | `turn.send` | local UUID, client message ID, rich blocks | `{accepted: true}` |
| `session.steer` | `turn.steer` | local UUID, expected turn ID, client message ID, rich blocks, clear-permissions flag | acknowledgement |
| `session.interrupt` | `turn.interrupt` | local UUID | acknowledgement |
| `permission.respond` | `permission.structured` | local UUID, request/action identity, allow/deny behavior, optional updated input/message/interrupt | acknowledgement |
| `session.close` | `session.close` | local UUID | acknowledgement |

Session config contains `workspacePath`, optional model/mode IDs, feature values, and namespaced
extension values. Content blocks are tagged `text`, `inline_data`, `file`, or `remote_url`; adapters
must reject unsupported blocks before provider dispatch instead of flattening them into text.

## Event contract

Each attached local session owns an independent event sequence. Its first event is sequence `0`,
must be `session.started`, and must repeat the exact local UUID. Sequence numbers then increase by
one with no gap or duplicate. A second `session.started` for the same attachment is invalid.

Canonical event kinds:

| Kind | Required payload | Capability gate |
| --- | --- | --- |
| `session.started` | session descriptor | baseline |
| `session.status_changed` | status | baseline |
| `turn.started` | matching turn ID and descriptor | baseline |
| `message.assistant_delta` | message ID and text | `timeline.streaming` |
| `message.reasoning_delta` | text | `timeline.reasoning` |
| `message.completed` | typed message | baseline |
| `tool.updated` | typed tool call | `timeline.activities` |
| `permission.requested` / `permission.resolved` | typed request/resolution | `permission.structured` |
| `plan.updated` | typed plan | `timeline.plans` |
| `usage.updated` | typed usage | `timeline.usage` |
| `subagent.updated` | typed subagent with matching parent session | `timeline.subagents` |
| `turn.completed` | turn ID and optional usage | baseline |
| `turn.failed` | typed failure | baseline |
| `turn.canceled` | reason and optional turn ID | baseline |
| `extension` | namespace, event name, payload | declared namespace |

`rawProviderEvent` may preserve provider evidence for diagnostics and future projection, but it never
widens permissions, capabilities, or execution authority.

## Extensions and provider fidelity

An extension method must begin with one namespace declared in the manifest. Extension values use a
fully qualified key beginning with that namespace. Undeclared methods, event namespaces, and values
fail closed.

The common protocol is deliberately not a lowest-common-denominator UI contract. Portable behavior
uses canonical methods/events; richer behavior stays lossless behind namespaced contracts. Yardlet's
built-in examples include `yardlet.provider` for generic provider options/actions and
`yardlet.codex` for lossless composer envelopes, live presentation snapshots, approvals and
answerable server requests, pagination, history/search, skills/plugins, complex responses,
fork/review, collaboration mode, and run location. External adapters own their own namespace.

### Live Codex presentation

`yardlet.codex` carries a session's live Codex timeline as extension events. `presentation.updated`
is a complete snapshot (thread, turns, items, approvals, server requests, answerable request IDs,
last applied sequence). A complete snapshot grows with the conversation, so an adapter that
advertises the capability `yardlet.codex.presentation.patches` can send the live timeline as
patches instead:

- The host opts in per session with `livePatches: true` on `yardlet.codex.presentation.read`. A host
  that does not, or an adapter that does not advertise the capability, keeps complete snapshots;
  an adapter that predates the field ignores it. Neither side assumes the other supports patches.
- After the opt-in, the adapter's next live update is a `presentation.updated` with a `revision`.
  Each later change is `presentation.patched` with `revision` and `baseRevision` (the previous
  update's revision). Revisions only increase for the life of the adapter process.
- A patch names turns and items by ID and carries only what changed: the thread's own fields when
  they changed, the complete turn order when a turn was added, removed, or moved, and per changed
  turn its own fields when they changed, its complete item order when an item was added, removed,
  or moved, and the added or changed items whole. Approvals and server requests are upserted
  whole or removed by ID; `activeTurnID`, `lastAppliedSequence`, and `answerableServerRequestIDs`
  are always complete. In a fields object the nested `turns` or `items` array is empty.
- A thread that appears, disappears, or changes ID, or a presentation with repeated turn IDs or
  repeated item IDs within a turn, is sent as a complete `presentation.updated` with a revision.
- A host applies a patch only to the presentation at its `baseRevision`. Otherwise it drops the
  patch, reads `yardlet.codex.presentation.read` with `livePatches: true` again, and drops further
  patches until the complete snapshot that read causes. Read responses never carry a revision and
  are never a patch base, because they are not ordered with the event stream.
- Yardlet's replay history keeps the newest complete snapshot and at most 64 patches after it;
  earlier snapshots and patches keep their sequence as `presentation.superseded`. Once more patches
  follow, the snapshot is superseded too, so a late subscriber meets only patches it cannot apply
  and reads a complete snapshot as above.

Extensions cannot:

- infer authority from a provider or harness name;
- bypass a canonical permission response;
- mutate another adapter's namespace;
- make malformed or unknown input executable by default.

## Process ownership and failure semantics

- Yardlet owns the launched adapter process tree and closes it on explicit stop, handshake failure,
  invalid frame direction, wrong version, malformed schema, invalid sequence, timeout, cancellation,
  or crash.
- Handshake and request deadlines are bounded. stderr retention and JSONL line size are bounded.
- A request cancellation releases its waiter; a connection-level violation terminates the process.
- Unknown or already-resolved permission/server-request identities fail before provider dispatch.
- Unsupported content and mismatched response variants fail closed and remain unresolved unless the
  provider contract explicitly says otherwise.
- Secrets never belong in manifests, extension payload examples, diagnostics, or conformance logs.

## Conformance

The baseline conformance runner requires a real external process to:

1. negotiate `1.0` and advertise the portable baseline plus resume and interrupt;
2. report a runtime matching the manifest;
3. round-trip a declared namespaced extension;
4. create and stream a fake session through a terminal turn;
5. start another turn and cancel it through interrupt;
6. close, resume the provider session under a new local UUID, stream another terminal turn, and close;
7. preserve contiguous per-session event identity and extension data;
8. exit after stdin closes, with bounded forced cleanup as fallback.

Yardlet's host additionally runs negative conformance for incompatible versions, missing
capabilities, bad directions, malformed payloads, duplicate IDs, wrong correlations, oversized
lines, timeouts, crashes, sequence gaps, undeclared extensions, and descendant cleanup.
