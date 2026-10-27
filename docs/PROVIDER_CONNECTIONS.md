# Harness, model provider and account connections (2026-09-15)

The need: see the remaining usage of several accounts, choose the account directly, and use a structure that is not
limited to ChatGPT. Harness connections are kept apart from model provider authentication, and each harness is
connected only through the paths it actually supports. No arbitrary model proxy and no OAuth token conversion or
copying are added.

The latest screen flow and design decisions follow [ACCOUNT_SELECTION_UX.md](ACCOUNT_SELECTION_UX.md).

## What the user does

- In **Settings › Accounts → Add account** (the sidebar's **Connections** opens this section), the user connects a
  separate account, or points to an existing CLI account folder in the advanced settings. Existing sign-ins appear in
  the same list, and the name and folder are optional. A new folder is created empty, and the harness's official
  sign-in and provider setup opens. The CLI keeps owning secret values.
- In **Choose account** next to the project and harness of a new task, the user chooses after seeing the remaining
  limits and reset times. The choice is kept with the draft, and the account binding is fixed just before submission.
- Resuming, forking and side chats of a task use the saved account environment together with the native session ID.
  Changing the default account for new tasks does not change the account of existing tasks.
- Claude Code can switch, from **Choose account** in the task menu, only to an account that uses the same conversation
  history folder (2026-10-06). It is allowed only when the `projects` of the two account folders point, through links,
  to the same real folder, so the session ID and history location stay the same and no file is moved or copied. Session
  Switch account folders have this structure (`projects` and the like link to `~/.claude`, and only the sign-in is kept
  per account). If the CLI of the target account does not confirm the sign-in in `auth status`, the switch does not
  happen. It does not switch during a turn in progress or while waiting for approval, and after the switch it
  reconnects with the same session ID.
- When usage is not published, it is shown as not available. Short-term and long-term limits are shown separately,
  not combined, and a limit without a number is not turned into 0.

## Support boundaries

| Harness | Model supply path | Extra account environment | Remaining limits | Changing the account of an existing task |
|---|---|---|---|---|
| Codex | The default OpenAI service or a provider set in the CLI | CODEX_HOME | primary/secondary of the account the App Server publishes | Choose the environment in a new task |
| Claude Code | The default Anthropic service or a provider set in the CLI | CLAUDE_CONFIG_DIR | 5-hour, weekly and per-model weekly limits from the CLI `get_usage` control request | Choose among accounts that share the same history folder |
| Pi | A separate model provider | PI_CODING_AGENT_DIR, provider choice | Not shown when the CLI does not publish it | Choose the environment in a new task |
| OpenCode | A separate model provider | Per-account XDG data/config/state/cache | The existing CLI lookup boundary | Choose the environment in a new task |
| Hermes Agent | A separate model provider | HERMES_HOME | No safe structured lookup | Choose the environment in a new task |
| Other harnesses | The default or external provider settings that the CLI owns | Keep the existing connection | Only public lookups verified before | No extra paths are made up |

The Gemini CLI entry was removed in an earlier installed build, and it is separate from choosing a Google model
provider in other harnesses such as Pi. Gajae Code and Oh My Pi (including Deep Agents Code) were dropped from the
default list on 2026-10-23. The Gajae records in the evidence section below stay as the evidence of that time.

For OpenCode, Yardlet hosts the provider and authentication method choice of the official `auth login`. For Pi, it
looks up the provider that the user specifies or that is set in Pi's own settings.json. Without a setting, it does not
assume ChatGPT as the default provider. The default Pi connection and adding a new Pi account choose the provider
first. Pi's authentication method choice screen is also recognized as waiting for input.
Pi's explicit provider sign-in keeps the existing
`auth check --provider … --json --no-refresh` completion detection and the guard against cancellation and late replies.

## Storage and process contract

`~/.yardlet/provider-connections.json` stores only the name, harness, provider ID, account folder and selector. Tokens
and API keys are never read or copied. The file uses atomic write and 0600 permissions, and a failed read never
overwrites the original file. A new account folder is 0700.

`account-snapshots.json` in the same folder (2026-10-08) holds the latest lookup results, so the account list shows
them as soon as it opens. For each connection ID (`native:<harness>` for the default sign-in) it keeps only whether the
account is signed in (`signedIn`/`signedOut`), the account name, organization and plan line that the CLI reported, the
limit rows (name, used ratio, display text, reset time and kind of evidence) and the lookup time. It keeps no tokens,
credentials, account folder paths, CLI output or per-task token usage. It uses atomic write and 0600; when it cannot
be read, it starts empty and the next lookup writes it anew. When a lookup confirms sign-in or sign-out, the entry is
rewritten, and when action is needed (a missing folder and the like), it is removed. When a lookup cannot finish
(time-out, error), the screen keeps the last sign-in value but marks it "Couldn't refresh", and when there is no
runtime, it shows that state as is. A sign-in remembered from the last run is not a candidate for automatically
replacing the default account of new tasks (`replaceSignedOutDefaultSelection`). Only what this run confirmed is used.
The account chip in the new task composer uses the account name remembered with a signed-in state in the same file. So
the name stays visible while the next run checks again. This name is for display only and has nothing to do with
binding, selection or credentials. Before the check, with no remembered name, it shows "Checking account…". (The
`account-labels.json` that a branch kept separately was folded into this file at merge and is not created.)

Reading and checking have one owner, `ProviderConnectionStore` (2026-10-08, B5). It holds the values of the default
sign-ins and saved accounts, `AccountReadingStatus` and the checking indicator, and the account screen
(`AccountCenterModel`) handles only the sign-in console. A check starts only through
`check(defaultsOf:savedOf:connectionIDs:policy:checkUsage:runtimeSelections:)`.
- If a check of the same account (`native:<harness>` for the default sign-in, the connection ID for a saved account,
  the per-account-home list for GJC) is already running, no new CLI process starts; it waits for that check.
- There is one freshness rule: a value that a check in this run confirmed as "current" within the last minute is not
  checked again when the list opens (`ifStale`). Values remembered from the last run and "Couldn't refresh" values are
  always checked again. The refresh button (`refresh`) checks again even when the value is fresh, but joins a check
  that is running.
- After the sign-in console ends or the runtime changes (`restart`), the answers of checks started before are
  discarded and a new check runs. Only the answers of checks or reads started later (Codex account notifications, the
  Pi sign-in check) stay on screen.
- The Codex default sign-in is read in the same environment as the app's Codex tasks (`CodexEnvironmentManager`). The
  Codex account notification monitor runs on a single App Server, only while the account screen is open.

SQLite's nullable `connection_binding` preserves `SessionRecord.connection`. A null value in past tasks keeps the
existing native/yardlet scope meaning. Importing native history does not treat tasks with a different provider ID,
scope or account binding as the same task. If a registered folder has disappeared or a GJC account is gone, it does not
fall back to the default account.

A separate environment does not receive the parent process's model API keys, OAuth overrides or model routing
overrides. HOME and the general development tool environment are kept. A provider adapter can be configured in the
harness's own settings, but Yardlet does not guarantee an arbitrary provider connection for an arbitrary engine.
Existing tasks are not moved to another account folder, and native conversations are not duplicated.

GJC lookup runs only the public `accounts list --json` automatically. Pressing **Refresh usage** runs the CLI-owned
`accounts check --json` and then reads the list again. It never opens the auth DB or credential payload directly, and
it does not pass API-key/env rows off as OAuth multi-accounts.
Switching accounts rechecks the binding and task state, closes that handle and resumes with the same provider session
ID. Other tasks' handles and drafts stay. A closed ACP transport is not reused.

## Verification

- Full `swift test`: 669 tests, 660 passed, 9 opt-in live tests excluded, 0 failures.
- With three Codex account folders (including spaces in the path), creation, restart, resume with the same ID, fork and
  keeping the original native home were verified through subprocess + YHP + AppModel + SQLite. It is a fixture without
  authentication.
- With GJC's public inventory and a real ACP subprocess fixture, switching A→B→A, keeping another B task connected, the
  same session ID, keeping the draft, refusing a deleted account and keeping the permission/abort policy were verified.
  No model prompt was sent.
- On the real installed Codex 0.153.4 and Claude Code 2.1.270, empty separate account environments were read with
  `login status`/`auth status`, and they were confirmed not to inherit the existing account.
- Real OAuth sign-ins of the user's three accounts, paid model turns and really exhausting each account's limits were
  not done. Each CLI performs the user's sign-in.
- In a native UI fixture, comparing the limits of three accounts, choosing the default account of a new task and the
  popover's choice of another account taking effect were verified.

Evidence: the accounts CLI, account-inventory and root flags in the official Gajae Code v0.16.0 source; the docs and
CLI source of the installed Pi 0.84.1; the official OpenAI App Server account docs.
Reproduction logs are in `.build/provider-connections-*.log`, and the fixture is in `scripts/fixtures/codex-session-home.py`
(`gjc-account-selection.py` for Gajae was deleted together with Gajae Code on 2026-10-23).

## Claude plan limit lookup (2026-10-06)

When a Claude account is signed in, Yardlet runs the official CLI in that account's environment with
`-p --input-format stream-json --output-format stream-json --verbose --strict-mcp-config` and sends only the
`initialize` and `get_usage` control requests. It looks up usage with Claude Code's own sign-in, there are no model
requests and no conversation history writes, and Yardlet does not handle tokens. It is the same method that Session
Switch 0.5.0 uses. Because the CLI treats the usage endpoint as nonessential traffic,
`CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` is removed for this lookup only. It runs in an empty temporary folder, which
is deleted at the end. The response's `limits` rows (`session` for 5 hours, `weekly` for the week, per-model weekly when
`scope.model` is present) come first; without them, `five_hour`, `seven_day` and `model_scoped` are read. An unknown
group is not shown as a limit. `rate_limits_available: false` (API keys and the like) or a failed lookup shows "Claude
Code did not report plan limits for this login." and is not turned into 0.
