# Phone remote v2 design

Status: designed and implemented on 2026-10-24 (Mac, relay and Android). The protocol contract is
[REMOTE_PROTOCOL](REMOTE_PROTOCOL.md) sections 11 to 17. The screen mockups are
[remote-v2/mockups.html](remote-v2/mockups.html) and the PNG files in the same folder.

## 0. Conclusions

- **Three routes, one security layer.** Every connection between the phone and the Mac is wrapped in the same Noise IK
  handshake and encryption. Underneath, the phone picks whichever route reaches the Mac first: a direct connection on
  the same Wi-Fi, Tailscale or the Yardlet relay server. Whatever the route, the phone verifies the other end with the
  Mac's static public key, so the relay server and other devices on the same Wi-Fi cannot read or change the content.
- **Pairing is one QR scan.** The QR holds the Mac's static public key, a one-time secret that lasts 5 minutes (256
  bits), the relay address with its room ID and the direct connection addresses. The phone makes its own key pair and
  sends its public key with the secret in the first handshake. The Mac stores only the phone's public key (stronger than
  today's token hash: the Mac holds none of the phone's secrets).
- **The relay server is one box.** Cloudflare Workers + Durable Objects keep one room per Mac. When the Mac opens its
  room with an outgoing WebSocket, the relay joins it to the phone's WebSocket. The server only forwards ciphertext and
  stores nothing. It has no accounts either. The room ID comes from the Mac's signing key (self-certifying), and the Mac
  opens the room by signing with that key. One user fits within the free plan.
- **Notifications carry only ciphertext.** Once the phone has told the Mac its FCM token, the Mac sends FCM data
  messages through the relay server while the phone is not connected. The content (task title, request summary) is
  encrypted with a notification key shared at pairing, so Google and the relay server cannot read it. Without FCM, the
  phone gets them through "Background notifications" (a foreground service), as it does today.
- **New on the phone:** answering question cards, plan review (approve or keep planning) and creating a new task (with
  the Mac's new-task defaults). Settings, accounts, files, diffs and the terminal are still handled on the Mac.
- **The platform stays native Android (Kotlin, Compose).** iOS comes later in SwiftUI and uses the Mac's `YardletRemote`
  package (protocol types, Noise) as is. The two reference apps are also native apps on each platform.
- **Accounts are optional (requested 2026-10-24).** Without a QR code, the person signs in with an account and picks
  from their own list of Macs. The Mac or a phone already connected checks a confirmation code and approves the new
  phone (like linked devices in Signal and WhatsApp). The account server knows only the list of Macs, not the content
  (section 3.1).
- **Faster and broader than the two apps (requested the same day).** The phone keeps the last list and conversations,
  draws them first and then replaces them with the latest, and target times are set and measured (section 5.1). The
  phone also covers command output, diffs, suggested tasks, pinning, archiving and several Macs (section 5).
- **Preventing sleep and screen lock while a task works (decided the same day).** A setting turns it on (off by
  default), and only while a task works does it also keep the display from turning off. It stops below 20% battery and
  when the Mac overheats. Lid-closed operation is left out because it needs administrator rights (section 6.5).
- **Exploring without a Mac, and the APK first (decided the same day).** Tapping "Explore without a Mac" on the first
  screen attaches the app to a demo Mac inside the phone, where the person can try the task list, conversations,
  approvals, questions, plan review, diffs, a new task and notifications. It uses no network and no storage (section 8).
  Distribution starts with a GitHub Releases APK and Obtainium. The Play closed test fills up slowly through demo mode
  and real users after the Mac release (section 12).
- **v1 phones do not break.** The v1 listener (Tailscale addresses, 47615, plain JSON and a token) stays. v1 devices
  already paired keep working, and new pairing shows only the v2 QR. The new app does not speak v1, so it pairs again
  once.

## 1. Comparison with reference products

### 1.1 The two apps (2026-10-24, public docs and installed app bytes)

| | Claude Code Remote Control (Code tab in the Claude app) | Codex Remote (Codex in the ChatGPT app) |
|---|---|---|
| Structure | The local CLI makes only outgoing HTTPS connections to Anthropic. No incoming port | The host (desktop app) registers with OpenAI's relay layer; the phone comes in through the account |
| Pairing | The same claude.ai account. QR, session URL or session list. Trusted Devices as an option | Allowed in the host's Settings › Connections › Control this Mac, by QR per phone and per host. A manual code (with expiry) too. Account MFA |
| Encryption | TLS. Conversation history is stored on Anthropic's servers (stated in the docs) | `Noise_hybridIK_X25519+MLKEM768_AESGCM_SHA256` in the bundled CLI. Public sources do not confirm whether the whole phone connection is E2EE |
| On the phone | Messages, interrupt, permission approval, `AskUserQuestion` answers, plan approval, photo and file attachments, new sessions in server mode | Messages (Queue and Steer), interrupt, approvals (once, for the conversation or broader), answers to questions and MCP forms, Plan mode, new local tasks (host, project, worktree and branch), diff review |
| Notifications | Mobile push (when finished or when a decision is needed; two settings) | Notifications when a task finishes or needs attention |
| Disconnects | Interactive mode keeps retrying; server mode may end after about 10 minutes | Drops when the host sleeps or the app quits |
| UI conventions | Code tab list; remote sessions get a computer icon and a green dot | List filter (All, Cloud, computer), Pinned and Today sections. Approval card: description and command, Approve above and Always approve below, and a "Tell Codex what to do" field with Deny on the bottom line |

Sources: [Claude Remote Control](https://code.claude.com/docs/en/remote-control), [Claude
mobile](https://code.claude.com/docs/en/mobile), [Codex remote
connections](https://learn.chatgpt.com/docs/remote-connections), [Codex mobile](https://learn.chatgpt.com/docs/mobile),
[Codex Remote post](https://developers.openai.com/blog/mastering-codex-remote-for-engineering). Installed apps: Claude
3.1623.3 `app.asar` (`toggleRemoteControl`, the text that allows starting sessions on this computer from a phone),
ChatGPT 26.1016.61520 (`codex-mobile-setup-dialog`: QR, manual code and refresh; the CLI's `remoteControl/pairing/start`
and `manualPairingCode`). The apps were not run.

**Summary:** Both apps treat picking a task, approvals, questions, follow-up messages, interrupting and viewing results
as the core of the phone, and both start new local tasks from the phone too. Both go through the company's servers and
accounts. Yardlet has no accounts or servers, so it pairs with device keys and has the relay carry only ciphertext.

### 1.2 Well-known remote and sync apps

| App | Pairing and identity | Relay | What Yardlet took |
|---|---|---|---|
| Syncthing | Device ID = certificate SHA-256. Local discovery (broadcast) | Relay when direct fails; TLS between devices stays, so the relay cannot read | End-to-end authentication regardless of route, local discovery |
| KDE Connect | UDP 1716 and mDNS discovery, pairing approval over TLS, certificate pinning | None | mDNS discovery, pinned peer key |
| Signal device linking | The new device's ephemeral public key in the QR | Ciphertext in a server mailbox | Public key in the QR |
| Tailscale | WireGuard (Noise IK family) | DERP carries only ciphertext and moves to a direct path | Noise IK, upgrading from the relay to a direct path |
| Home Assistant Cloud | Account | Forwards TLS ciphertext by SNI; the instance at home decrypts | The relay only forwards |
| Chrome Remote Desktop, Magic Wormhole | Short code + SPAKE2 (PAKE) | Relay when direct fails | A short code typed by hand needs a PAKE (next step) |
| Happy (Claude Code mobile client) | The CLI's ephemeral NaCl public key in the QR | The server stores encrypted messages | A lesson in what not to do: the session title goes in plain text in the push body. Yardlet encrypts pushes too |

Sources: [Syncthing](https://docs.syncthing.net/users/relaying.html), [KDE Connect
protocol](https://github.com/KDE/kdeconnect-meta/blob/master/protocol.md),
[Signal](https://signal.org/blog/a-synchronized-start-for-linked-devices/), [Tailscale
DERP](https://tailscale.com/kb/1232/derp-servers), [Nabu
Casa](https://support.nabucasa.com/hc/en-us/articles/25619268678557-Remote-access-Deep-dive), [Magic
Wormhole](https://magic-wormhole.readthedocs.io/en/latest/welcome.html),
[Happy](https://github.com/slopus/happy/blob/main/docs/encryption.md).

## 2. Connection

### 2.1 Secure channel: Noise IK

- Pattern `Noise_IK_25519_ChaChaPoly_SHA256`, prologue `yardlet-remote/2`. The phone starts (initiator) and the Mac
  answers (responder). The phone already knows the Mac's static public key from the QR (`<- s`). The handshake takes two
  messages, one round trip, and the phone's public key travels encrypted from the first message on (the relay does not
  even know which phone it is).
- The first message's payload is the phone's name and, when pairing, the one-time secret from the QR. It is encrypted
  with a key made from the Mac's static key and the phone's static key, so only the Mac can read it and only the owner
  of the phone's key can make it.
- Messages after the handshake are the same JSON requests, responses and events as in v1. A Noise message cannot exceed
  65,535 bytes, so large JSON (one page of conversation can be several MB) is split into fragments (the first byte says
  "continues" or "end").
- It is the same on every route: `ws://` on the same Wi-Fi, `ws://` over Tailscale, `wss://` through the relay. There is
  no separate TLS because Noise authenticates both ends (no certificates to manage). The relay leg is `wss://`, so it
  gets one more layer.
- Test vectors: the Mac and phone tests share the `Noise_IK_25519_ChaChaPoly_SHA256` vectors from the public-domain
  cacophony set. Both implementations must produce the same bytes to pass.
- Left out: a quantum-resistant hybrid IK that mixes in ML-KEM, as Codex does. CryptoKit has it, but Android has no
  standard implementation. To reduce the "harvest now, decrypt later" risk on the relay leg, the prologue carries a
  version number so that a later step can move up to `hybridIK`.

### 2.2 Direct connection on the same Wi-Fi

- The Mac opens the v2 listener on TCP 47616 on every interface (a free port if that one is in use). There is no reason
  to bind to chosen addresses as v1 does: a peer that cannot complete the handshake gets nothing (like Syncthing's
  22000).
- The Mac advertises `_yardlet._tcp` over Bonjour. The instance name and the TXT `id` are a 16-character hash derived
  from the Mac's public key, so the Mac's name is not visible on the LAN. The phone makes the same hash from the Mac key
  it saved and finds its Mac that way.
- From macOS 15, advertising over Bonjour asks for local network permission (only listening on TCP does not ask; Apple
  TN3179). The prompt appears once when the remote is turned on; if the person declines, the phone connects through the
  last address and the relay without Bonjour. Info.plist gets `NSLocalNetworkUsageDescription` and `NSBonjourServices`
  (`_yardlet._tcp`).
- The Mac puts its current direct addresses (LAN, Tailscale, MagicDNS name) in the handshake response. The phone saves
  them and tries them first, even on networks where Bonjour does not work (such as device isolation on guest Wi-Fi).
- From Android 17 (targetSdk 37), LAN sockets need the `ACCESS_LOCAL_NETWORK` permission. The current targetSdk 36 does
  not need it; moving to 37 adds the permission request and a fallback to the relay when it is denied.

### 2.3 Tailscale

- A Tailscale address is also one of the Mac's interfaces, so the v2 listener accepts it as is. When the VPN is on, the
  phone tries the saved Tailscale address as a direct route. Nothing else is needed.
- The v1 listener (Tailscale addresses only, 47615, plain text) stays for v1 devices.

### 2.4 Yardlet relay server

**Shape:** one Cloudflare Worker and one Durable Object class (`Room`). Each Mac has one room.

```
Mac ──wss /v1/rooms/<room>/host──▶ Room(DO) ◀──wss /v1/rooms/<room>/connect── phone
     (outgoing, opens the room by signing)    (forwards ciphertext only)
```

- The **room ID** is 32 characters: the first 20 bytes of the SHA-256 of the Mac's Ed25519 relay key, written in base32.
  The server recomputes the room ID from the public key the Mac sends, and accepts the connection as that room's Mac
  only after verifying its signature over a nonce the server gave. There are no accounts, registration or storage.
- **Joining:** when a phone comes in through `connect`, the room gives it a connection number and tells the Mac
  (`open`). After that it forwards binary frames both ways, adding and removing the number. The Mac keeps one Noise
  responder per connection. If the Mac is not there, the room answers the phone's upgrade request with 404.
- **What it does not do:** store content, write content to logs or authenticate phones (anyone who knows the room ID can
  come in, but the Mac's handshake cuts them off). Limits: 8 phone connections per room, 65,535 bytes per phone frame
  (one Noise message), 10 seconds before authentication and 120 seconds for a silent connection.
- **Sleeping:** sockets are accepted through the Hibernation API, so when no messages pass, the DO can be evicted while
  the connections stay, and no duration charge accrues. The Mac's keepalive ping gets an automatic response
  (`ping`→`pong`), so it does not wake the DO.
- **What the server sees:** the room ID, both sides' IP addresses, connect and disconnect times, frame sizes and
  intervals, and the FCM token while sending a notification (dropped after sending). What it cannot see: the task list,
  conversations, commands, approvals and the phone's public key.
- **Cost (Cloudflare price list, 2026-10-24):** the free plan also allows SQLite-backed DOs, with 100,000 requests and
  13,000 GB-s per day. Every 20 WebSocket messages a DO receives count as one request. A user who keeps the phone open
  two hours a day makes roughly a few hundred requests and a few hundred GB-s, within the free plan. 1,000 users would
  need the paid plan ($5 a month, including 1 million DO requests and 400,000 GB-s) plus a few dollars of overage. No
  domain is needed (`*.workers.dev`).
- **Deployment is not part of this step.** It goes only as far as the code, running it locally (`wrangler dev`, no
  sign-in needed) and tests. The Mac build's default relay address stays empty, and one constant goes in after
  deployment. Until then the relay is used only through a development setting.

### 2.5 How the phone picks a route

1. Gather candidates: addresses found through Bonjour, the last direct addresses received (LAN on Wi-Fi or Ethernet,
   Tailscale when the VPN is on) and the relay.
2. Start the direct candidates at once and the relay after 0.7 seconds; use whichever finishes the handshake first and
   close the rest (direct attempts time out after 3 seconds).
3. While connected through the relay, if the network changes or Bonjour finds the Mac, try a direct connection again and
   move to it if it works (the list and the open conversation are fetched again).
4. The screen does not make much of the route. The Mac sheet has just one line: "Connected over the same Wi-Fi",
   "Connected over Tailscale" or "Connected through the Yardlet server".

## 3. Pairing, removal and reconnection

- **Mac:** Settings › Remote › "Pair a phone" shows the QR for 5 minutes. The manual code is gone: without accounts, a
  short code typed by hand is safe only with a PAKE (such as SPAKE2). Scanning the QR with the phone's built-in camera
  also opens the app (`yardlet-remote://pair?v=2…`).
- **Phone:** after reading the QR, it makes an X25519 key pair for this Mac only (a different key for each Mac, so Macs
  cannot link the phone across each other) and keeps the private key in DataStore, sealed with an AES key in the Android
  Keystore. It is excluded from backups.
- **Confirming:** if the secret in the first message matches, the Mac adds the phone's public key to its device list and
  responds. If the response does not reach the phone and the phone tries again, the Mac accepts it as the same device,
  for the same public key only and within the time left on the same ticket.
- **Removal:** removing the phone in the Mac's settings closes its open connections at once (`revoked`), and that public
  key cannot come back in (`unknownDevice`). Its notification token is deleted too. "Disconnect" on the phone tells the
  Mac (`forgetDevice`) and deletes the phone's own key.
- **Reconnection:** after a drop, exponential backoff (1 second→30 seconds, ±20%), or at once when the network changes.
  Every reconnection is a new handshake (no session resumption).
- **Several Macs:** the phone app saves several Macs, and the person switches by tapping the Mac name at the top. It
  connects to one at a time.

### 3.1 Accounts (optional)

Decision (2026-10-24): an account-based way to connect should also be possible. QR pairing stays, and signing in with an
account shows that person's Macs and lets them add a new phone. End-to-end encryption is kept.

- **An account does only two things.** Discovery (the names, room IDs and public keys of the Macs registered to this
  account), and adding a new phone with approval from an existing device. Tasks, conversations and commands never go to
  the account server (even when they pass the relay, they are ciphertext). As with linked devices in Signal and
  WhatsApp, the server knows only the device list, and existing devices approve new ones.
- **Flow:**
  1. Mac: Settings › Remote › "Sign in with an account" (a browser sign-in window), then this Mac is registered to the
     account (name, room ID, the Mac's two public keys). The Mac proves it owns the room with a relay key signature.
  2. New phone: "Sign in with an account" → the account's list of Macs → picking a Mac runs a Noise handshake with that
     Mac and sends a link request (`link`).
  3. The Mac puts that phone on hold. The Mac's screen and the phones already connected show "Pixel 9 wants to connect ·
     482 913", and the new phone shows the same number. If they match, the person allows it.
  4. Once allowed, that connection is authenticated at once and receives the list. With no answer within 2 minutes, or a
     refusal, the Mac drops it.
- **Why there is a confirmation number:** if the account server swapped the Mac's public key (a server breach, or the
  operator), the phone would talk to a fake Mac. Each side computes the number from the two public keys it holds, so a
  swap makes the numbers on the two screens differ. That way the account server does not need to be trusted (the same
  idea as KDE Connect's verification string and Signal's safety number).
- **When away:** if the person is not at the Mac, a phone already connected approves. With no connected phone and nobody
  at the Mac, a new phone cannot be added. That is the safe side.
- **Sign-in methods:** GitHub and Google come first (OAuth 2.0 authorization code with PKCE; the apps use browser
  sign-in windows, `ASWebAuthenticationSession` and Custom Tabs). They are the most common among developer-tool users
  and work the same way on both platforms. Sign in with Apple comes with the iOS app (it needs a service ID, a key and
  domain verification, and the App Store sometimes requires Sign in with Apple in apps that offer other social sign-in).
  Email links need a mail sending service (a sending domain, usually paid), so they come later.
- **What stays on the server:** the account ID (a hash of the sign-in provider and the user number there; the original
  number and the email are not stored), a display name (such as the GitHub login name; optional), registered Macs (name,
  room ID, the Mac's two public keys, update time), sign-in sessions (a hash of the token, device name, times) and
  one-time sign-in codes that last 2 minutes. What does not stay: tasks, conversations, commands, phones' public keys
  and notification tokens. Signing out on a Mac removes that Mac from the list.
- **Where it is stored:** one Durable Object per account (named by the account ID, SQLite). There is no table of all
  users.
- **Relation to the QR:** the QR remains the default way, with no account. An account is for adding a new phone when the
  person is not at the Mac, or for finding several Macs at once.

## 4. Notifications

- When the phone sends its FCM token with `registerPush`, the Mac makes a 32-byte notification key for that device and
  returns it. The token and the key live in the Mac's device list.
- The Mac sends one only while the device is not connected, at three moments: a wait starts (high priority); a task
  finishes or fails; a wait is resolved on the Mac (the notification is withdrawn, normal priority). When the phone app
  leaves the screen, it closes the connection and relies on notifications (with "Background notifications" on, it stays
  connected).
- The content is the same JSON as v1's `attention` event, encrypted with ChaCha20-Poly1305 (the notification key, a
  random nonce). FCM data messages are limited to 4 KB, so the summary is capped at 120 characters. Google and the relay
  see only the token, the size and the time.
- A high-priority data message must lead to a visible notification, or its priority gets lowered (FCM docs). Waits and
  completions always show a notification; only withdrawals go at normal priority.
- The lock screen shows only "There is an approval request" (the public version); after unlocking, the task title and
  summary appear.
- FCM needs a Firebase project (free). A build without a project does not register for notifications and uses only
  "Background notifications". iOS uses the same shape with APNs (next step).

## 5. What the phone does

| Action | v1 | v2 | Basis |
|---|---|---|---|
| Task list and status, reading conversations, messages, stop, mark read | Yes | Yes | Both apps |
| Approval: allow once or deny | Yes | Yes | Answers that create a permanent rule still stay on the Mac |
| Answering question cards | On the Mac | **Yes** | Both apps answer on the phone. Sent through the same path as the Mac card (`ConversationRequestFormInput`). Questions with secret answers and MCP forms stay on the Mac |
| Plan review | On the Mac | **Yes**: Approve plan, Keep planning (with an optional reason) | The same two answers the Mac card gives. No answer that changes the permission mode |
| New task | No | **Yes**: project (or chat) and first message | Both apps open new local tasks from the phone. Harness, model, account and worktree are the current values in the Mac home composer |
| Command output, file changes (diff) | No | **Yes**: loaded when the tool line is tapped (`itemDetail`) | Codex on the phone shows diffs. Fetched only on tap instead of always riding the stream, to keep things fast |
| Suggested tasks | No | **Yes**: Start, Do it here, Dismiss | The same three actions as the Mac chip |
| Child tasks | Parent link | Shown collapsed under the parent and opened directly | Users run several child tasks at once |
| Pin and archive | No | **Yes** | Keeping the list tidy |
| Several Macs, accounts | No | **Yes** | Sections 3 and 3.1 |
| Image attachments | No | Next | Both apps have it. It needs photo picking, resizing and the Mac's attachment path together, so it is done separately |
| Choosing the harness and model for a new task, choosing Steer or Queue | No | Next | Each harness has a different model list, so the Mac's lists have to be carried over |
| Taking over a browser tab | No | Next (section 6.3) | The Mac-side "waiting for the person" signal belongs to the browser isolation and vault work |
| Settings, connectors, browsing files, terminal | No | Not done | On the Mac |

### 5.1 Speed

The goal (2026-10-24): the remotes in the two apps are slow and limited, so Yardlet's should do much more. The two apps
take an extra trip through the company's servers and fetch everything from scratch each time the app opens. On the same
Wi-Fi, Yardlet connects straight to the Mac, and the phone keeps the last state.

| Moment | Target | How |
|---|---|---|
| Opening the app until the list shows | Within 0.3 s (saved list); up to date within 1 s (same Wi-Fi) or 2 s (relay) | Keep the last list and opened conversations on the phone and draw them first. Route race (section 2.5) |
| Opening a conversation | Saved copy at once, up to date within 0.5 s | Saved page first, replaced by the subscription response |
| Something on the Mac reaching the phone | Within 0.5 s | Server batching interval (list 0.4 s, conversation 0.2 s), sends only changes |
| Reconnecting after a network change | Within 1.5 s | Route race as soon as the network changes |
| Response to an approval or a message | Within 0.3 s (same Wi-Fi) | The Mac answers as soon as it receives, and the result comes as an event |

- **Only changes:** the list sends only changed tasks (`tasksChanged`), and the conversation only changed items
  (`conversation`). On reconnecting, the saved screen stays up while the new list and page replace it. Command output
  and diffs are fetched only on tap.
- **Measuring:** the Mac tests record the time to the handshake and to the first list over loopback, and the phone app
  records the time to connect, to the first list and to the first conversation page.


## 6. Handling steps that need the person from the phone while they are away

From a phone it is hard to work a browser by hand, use a fingerprint, operate other Mac apps or do complex work inside
Yardlet. After looking at how other products split this, Yardlet honestly separates "what can be finished on the phone"
from "what works only at the Mac".

### 6.1 Other products (2026-10-24, public docs)

| Product | Steps that need the person | On the phone | The model during takeover |
|---|---|---|---|
| ChatGPT agent (discontinued) and today's cloud browser | Stops at sign-in for "Take over browser", then gets the browser back and continues. Now a secure sign-in form puts the values straight into the remote browser | The cloud browser can be taken over from the phone too | The old agent stated that it takes no screenshots and records no typed secrets during takeover. Today's docs give no such guarantee |
| Browserbase Live View | Click, type and scroll through a live view URL (iframe) | No official mobile keyboard support; recommends your own input field | Sessions are recorded by default. The URL expires (6 hours at most) |
| Steel | WebRTC (H.264, 25fps) live sessions, input with `interactive`, human-in-the-loop docs for sign-in and CAPTCHA | Shows in a browser; full touch support not confirmed | The debug URL has no authentication, so anyone with the link can watch. Option to blur credential fields |
| Claude Code Remote Control | Keeps permission requests and `AskUserQuestion` open until answered | Answered on the phone, with push. No screen takeover | — |
| Aside | Shows waits for approvals and questions; the person handles MFA, passkeys and CAPTCHA. The person picks an agent tab and uses it directly; Computer Use and takeover added on 10-23 | Instructions, approval cards and `/stop` in Slack and Telegram. Screen streaming not confirmed | Not confirmed |
| ego(lite), ego.app | The person enters the task's Space, signs in or confirms, and it continues | ego.app advertises one-tap approval in iMessage and the Dynamic Island (waitlist stage) | Not confirmed |
| Manus | Take Over notification at SMS codes, CAPTCHA and MFA → the person handles it → hands back | The docs do not say whether all of it works directly on the phone | Not confirmed |
| 1Password for Claude, Steel Credentials | Passwords and codes go straight into the page without passing through the model | — | Values never enter the model's context |

Facts on the Apple side: there is no official way for a distant phone to stand in for the Mac's Touch ID. Apple Watch
approval (`deviceOwnerAuthenticationWithWatch`, `…WithCompanion`) requires the watch to be nearby. A passkey from a
nearby device (QR) needs Bluetooth on both devices, so sending the screen to the phone does not unlock it.

Sources: [ChatGPT agent](https://help.openai.com/en/articles/11752874-chatgpt-agent), [cloud
browser](https://help.openai.com/en/articles/20001280-using-cloud-browser-in-chatgpt), [Browserbase Live
View](https://docs.browserbase.com/platform/browser/observability/session-live-view), [Steel live
sessions](https://docs.steel.dev/overview/sessions-api/embed-sessions/live-sessions), [Steel
human-in-the-loop](https://docs.steel.dev/overview/sessions-api/human-in-the-loop), [Claude
permissions](https://code.claude.com/docs/en/permissions), [Aside
troubleshooting](https://docs.aside.com/help/troubleshooting), [Aside
changelog](https://docs.aside.com/changelog/components), [ego(lite)](https://lite.ego.app/document/en/docs/quick-start),
[Manus Take Over](https://help.manus.im/en/articles/11711218-how-can-i-take-over-manus-browser-or-vs-code), [1Password
for Claude](https://support.claude.com/en/articles/15936181-get-started-with-1password-for-claude), [Unlock with Apple
Watch](https://support.apple.com/en-us/102442),
[LAPolicy](https://developer.apple.com/documentation/localauthentication/lapolicy). The vault design's map of Aside and
Ego is in [BROWSER_VAULT_DESIGN](BROWSER_VAULT_DESIGN.md) section 2.

**Summary:** Everyone (1) answers the harness's approvals and questions directly on the phone, (2) fills sign-in secrets
outside the model and (3), when still stuck, lets the person take over the screen and then hand it back. Only ChatGPT's
old agent stated a promise that the model does not see the screen during takeover. Nobody unlocks fingerprint or
nearby-device authentication remotely.

### 6.2 How Yardlet handles it

| Step | First | If stuck, from the phone | Only at the Mac |
|---|---|---|---|
| Harness approvals, questions and plans | — | Answer directly (section 5) | Answers that create a permanent rule, questions with secret answers, MCP forms |
| Browser sign-in and two-step verification | The vault fills passwords, TOTP and Yardlet passkeys without exposing the values ([BROWSER_VAULT_DESIGN](BROWSER_VAULT_DESIGN.md)) | If the vault does not have it or the site blocks it, take over the tab (section 6.3) | — |
| CAPTCHA, identity checks, payment confirmation, QR sign-in | — | Take over the tab | Sign-in that needs the phone's camera to scan a QR on the Mac's screen |
| Fingerprint and passkeys | Yardlet passkeys without the person | Vault items set to "Every time" can also be confirmed with phone biometrics (section 6.4) | Touch ID-only confirmation, iCloud Keychain and nearby-device passkeys, the macOS administrator password, keychain access prompts: the phone says "This must be handled on the Mac" |
| Other Mac apps | The harness's computer control (Codex computer-use, Claude `--chrome`). With "Keep the screen unlocked while tasks work" on, the screen does not lock (section 6.5) | Answer that harness's approvals | Screen control on a Mac whose screen is locked with that setting off |
| Complex work inside Yardlet | — | Hand it in words to a coordinating task (for example a pinned chat task). That task uses the session tools ([AGENT_BROWSER_TOOLS](AGENT_BROWSER_TOOLS.md): `create_task`, `send_message_to_task`, `read_task`) to create, ask and tidy up other tasks | Settings, accounts, connectors, reviewing files and diffs |

- The phone app does only the frequent things, and does them well (seeing waiting tasks, approvals, answering questions,
  messages, reading conversations, new tasks). Pinned tasks sit at the top of the list so the coordinating task is easy
  to find. The Mac's settings screens are not brought to the phone.
- "This must be handled on the Mac" is an honest marker, like v1's `moreOnMac`. It shows in one line what needs doing
  (for example "Confirm with Touch ID on the Mac") and does not pretend the phone can do it.

### 6.3 Taking over a browser tab (design for the next step)

Yardlet's browser uses CEF off-screen rendering and holds the DevTools protocol for each tab (the agent tools already
use it), so it is easy to send just one tab's screen and input to the phone. Creating the "waiting for the person" state
on the Mac side (a tool for the agent to call the person, the vault's "hand over and wait") belongs to the browser
isolation and vault work; this design sets the phone side (viewing, input, notifications) and the protocol.

- **Signal:** the task's attention state becomes `waiting` (`pendingRequest` `browser`), and a request item appears in
  the conversation (`requestKind` `browserHandoff`: tab ID, site, a one-line reason). The notification reads "‘Task
  title’ is waiting on github.com". A tab the person picks directly is taken over the same way.
- **Viewing:** on `watchTab {taskId, tabId}`, the Mac sends the JPEGs it gets from CDP `Page.startScreencast` as
  `tabFrame` events (maximum width fitted to the phone, quality 60, flow control by acknowledging each frame, only while
  on screen). At 50 to 100 KB per frame and 2 to 5 frames per second, it works through the relay too.
- **Input:** `tabInput` carries taps (x, y), text (`Input.insertText`), keys (Enter, Backspace, Tab) and scrolling. The
  phone keyboard types into an input field at the bottom of the screen (Browserbase also recommends its own input
  field). When the target is a password field, the phone's input field is masked too.
- **Handing back:** `releaseTab {taskId, tabId, note?}`. The agent gets "The person finished the step in the tab" as the
  result of the tool it was waiting on, and continues.
- **During takeover:** `browser_*` tools on that tab are refused with "The person is using this tab", and they give no
  screenshots or snapshots (the same promise as ChatGPT's old agent, in code). Only one device types at a time.
- **Secrets on screen:** frames go exactly as the page draws them. The browser masks password fields, and the cover over
  fields the vault filled stays. The phone keeps frames only in memory and blocks screenshots and the recent apps
  preview with `FLAG_SECURE`.
- **Re-authentication:** starting a takeover asks once for phone biometrics (the same idea as recent authentication in
  Claude Trusted Devices).

### 6.4 Confirming with phone biometrics (design for the next step)

- At pairing, the phone makes an EC key in the Android Keystore that "signs only after biometric authentication"
  (`setUserAuthenticationRequired`, strong biometrics) and registers the public key with the Mac.
- When filling a vault item set to "Every time", the Mac shows the Touch ID prompt and also sends the phone a
  confirmation request (site, item name, task title, a random value). The phone shows BiometricPrompt and, if it passes,
  signs the request with that key and returns it. The Mac fills only after verifying the signature. Whichever
  confirmation arrives first is used, and after 2 minutes the request is refused.
- The phone stands in only for the vault's confirmation. It cannot stand in for macOS's own Touch ID or administrator
  password prompts.

### 6.5 Preventing sleep and screen lock while a task works

Decision (2026-10-24): many developers already use separate apps to keep the Mac from sleeping or locking its screen, so
this replaces the first recommendation ("leave it out").

- **Comparison:** Amphetamine (free; blocks display sleep, the screen saver and lid-closed sleep separately),
  KeepingYouAwake (MIT; wraps `caffeinate`) and agent-specific apps (they block only while the agent works, through
  Claude Code and Codex hooks, and stop at a battery floor or when hot). Running with the lid closed needs administrator
  rights, as in `sudo pmset -a disablesleep 1`, and the main risk is forgetting to undo it.
- **Setting:** Settings › General "Keep the screen unlocked while tasks work", off by default. When it is on, whenever
  Yardlet already prevents idle sleep (`AppModel.keepsMacAwake`: while a task works, and also while it waits for an
  approval when there is a remote phone), it also prevents display sleep and the screen saver. With the screen staying
  on, the lock never comes. It is released as soon as the work ends. Yardlet already knows when a task is working, so
  there is no harness hook (a product principle: Yardlet writes nothing to harness settings).
- **When it stops:** on battery with less than 20% left. It blocks again once that improves. When it stops, it sends one
  notification and shows the state in the menu bar menu. On 2026-10-24 it also released silently when the Mac was hot
  (`thermalState` serious or above), but the work kept running, so the Mac did not cool down and only the screen locked;
  that was removed on 2026-10-26.
- **Lid-closed operation is left out.** It needs the administrator password, and the system setting can remain after
  Yardlet quits or is deleted (a product principle: Yardlet leaves nothing behind once removed). With an external
  display and power, macOS stays awake with the lid closed (clamshell mode).
- **The risk is handled with the default and a short indicator.** While it is actually blocking, the top of the menu bar
  item's menu shows one line, "Keeping the screen unlocked". There is no explanatory text next to the setting.
- If this setting is off and the harness's screen control fails because the screen is locked, the phone shows that
  failure as it is. Taking over the whole Mac screen is a job for macOS Screen Sharing, so Yardlet does not build it.

### 6.6 This scope and what comes next

| This time (v2) | Next |
|---|---|
| Answering approvals, questions and plans; new tasks; messages (including to the coordinating task); pinned tasks at the top; command output and diffs | Taking over a browser tab (section 6.3, together with the "waiting for the person" signal from the browser isolation and vault work) |
| Preventing sleep and screen lock while a task works (section 6.5) | Lid closed (left out) |
| Only the public version of notifications on the lock screen | Vault confirmation with phone biometrics (section 6.4), re-authentication before takeover |
| Requests that only work on the Mac say so (`moreOnMac`) | A one-line message on what to do on the Mac (Touch ID, iCloud passkey, system prompt) |
| Device removal and disconnecting from the phone side | App lock (biometrics when opening the app) |

## 7. Platforms

- **Recommendation and progress: Android continues the current app (Kotlin, Jetpack Compose).** It has 77 unit tests and
  emulator QA, and its protocol layer is separate from the UI. The new connection is swapped in under `connection/` and
  `protocol/`, and the screens are refined again.
- **iOS is native SwiftUI and shares the Mac's `YardletRemote` package.** Noise, the protocol types and pairing URL
  parsing already exist in Swift. Kotlin Multiplatform or Compose Multiplatform would share the Android code, but the
  iOS conventions (sheets, notifications, biometrics) would have to be matched again, and code that exists in Swift
  would be written once more in Kotlin. Flutter or React Native would mean throwing away the current app and writing a
  new one.
- The contract between the two platforms is this document, REMOTE_PROTOCOL and the shared test vector file.

## 8. UI

Mockups: [remote-v2/mockups.html](remote-v2/mockups.html) (light and dark), with the PNGs in the same folder.
Principles: the two apps' phone conventions, reading over decoration, status dots that mean the same as in the Mac
sidebar, and no boxed cards with badges or "01/02" number labels.

- **Before connecting:** the app icon, "Connect to your Mac", two lines of guidance (on the Mac, Settings › Remote ›
  Pair a phone), [Scan QR code], and below it the secondary action "Explore without a Mac". Manual entry is gone.
- **Demo (Explore without a Mac):** a demo Mac inside the phone answers requests and sends events, so the real screens
  are used as they are. Names and content match the Mac's showcase fixture (`--ui-fixture=showcase`): Jordan Park; the
  projects acme-web, payments-api and design-system; tasks in Codex, Claude Code and OpenCode; PR #128. A script lets
  the person try a command approval, a multi-step question, plan review, a diff, suggestion chips, a new task and
  messages. "Demo" and a way out always show at the top, and going back from the list also leaves. Leaving the app
  during the demo brings one request notification marked "Demo" a few seconds later. It uses no sockets, Bonjour, relay,
  accounts or FCM, writes nothing to saved Macs, the cache, settings, keys or notification registration, and leaving
  puts everything back as it was before entering.
- **Tasks (home):** at the top, the Mac name (tap for the Mac sheet) and one line of connection state, with search on
  the right. If there are tasks "Waiting for you", they are gathered at the top with the request summary as their second
  line. Below that, lists per project (in the Mac sidebar's order, with status dots). At the bottom, a "New task" input
  bar (input at the bottom, like the Mac home).
- **Conversation:** at the top, back, the title and "harness · project". The person's messages are bubbles on the right,
  answers are full-width text, and the work of a finished turn collapses into "Worked for N · N steps". A waiting
  request sits right above the composer, not at the end of the conversation, so it is always visible (like Claude Code's
  permission prompt, which appears in place of the composer).
  - Approval: tool name, command (monospace, three lines, tap to see all), description, [Deny] [Allow once], "More
    choices are on your Mac".
  - Question: header, question, option rows (with descriptions; check marks for multiple choice), "Your own answer",
    "1/3" and [Next] when there are several questions, [Skip] when skippable, and [Send] at the end.
  - Plan: the start of the plan and "Show all", [Keep planning] [Approve plan]. Keep planning lets the person write a
    reason.
- **New task sheet:** project picker (list), input, one line "Starts with your Mac's new-task settings · Claude Code",
  [Start]. Starting goes to that task's conversation.
- **Mac sheet:** the current Mac with one line for the connection route, other saved Macs, "Add another Mac",
  Notifications ("Background notifications" when there is no FCM), Appearance and "Disconnect this Mac".
- **Notifications:** "Approval requested · task title" / a one-line summary. Tapping opens that conversation, with the
  request above the composer.

## 9. v1 compatibility

- The v1 listener, `pair`, `hello` and token devices stay as they are. The new requests (`answerQuestion`, `reviewPlan`,
  `createTask`, `registerPush`) are accepted only on v2 connections. Approval items sent on a v1 connection keep only
  the answers v1 knows, and the rest become `moreOnMac`.
- The Mac's settings show only the v2 QR. v1 devices appear in the list as "Earlier app" and can be removed.
- The new Android app does not speak v1, so it needs a new Mac build to connect. A v1 app already installed keeps
  working with the current Mac.

## 10. Security summary

| Threat | Defense | Remaining risk |
|---|---|---|
| The relay server reads or changes content | Noise IK (end keys pinned), the relay carries only ciphertext | Metadata (IP, time, size). Decryption later by a quantum computer (next, with the hybrid IK in section 2.1) |
| Other devices on the same Wi-Fi | The same Noise. Bonjour carries a key hash instead of the Mac name | They can see that Yardlet is on |
| Someone learns the room ID | Making the first handshake message needs the Mac's public key, which is only in the QR | They can pester the room with connection attempts (limit of 8 per room) |
| Room hijacking by impersonation at the relay server | The room ID comes from the Mac's signing key, and the signature is verified | A server operator who changes the code can block the Mac (but cannot read anything) |
| Someone else scans the QR | 5 minutes, one use, and the Mac shows the paired phone's name | Whoever scans first within the 5 minutes gets in (visible in the Mac's list and removable) |
| Lost phone | Removing it on the Mac cuts it off at once, Android screen lock, only the public version of notifications on the lock screen | Someone with a lost, unlocked phone can operate it until it is removed. App lock (biometrics) is a candidate for next |
| The Mac's keys leak | Keys are in the keychain (open only to the app's signature) | Malware running with the same user's rights is a risk, as it is for other Yardlet data |
| Notification content | Encrypted with the notification key, which travels only over the secure channel after pairing | Google and the relay know that a notification came and when |
| Credentials, account tokens, environment values | Not sent (same as v1) | — |

## 11. What stays on the Mac

- While it is on: the v2 listener, the Bonjour advertisement and one outgoing connection to the relay. Turning it off
  closes all three at once, and the relay room disappears from memory.
- What always stays (Yardlet's own data): `~/.yardlet/remote/devices.json` (phones' public keys, names, times,
  notification tokens and keys, v1 token hashes), `audit.log` (command kinds and task IDs, no content) and keychain
  items (the Mac's Noise key and relay key, and the session token if signed in to an account). Nothing is written to
  harnesses, provider accounts or repositories.
- Preventing sleep and screen lock is a power assertion held by the process, so macOS releases it when Yardlet quits.
  System settings (`pmset`) are not changed.
- macOS remembers the local network permission (it can be turned off in System Settings › Privacy & Security).

## 12. Settings needed for distribution

This assumes the accounts exist and lists only what to connect and set up in them. Sign-in, payment and account settings
are done by the person, and secret values never go in command arguments, docs or logs (they go through the input of
`wrangler secret put` and Gradle user properties).

- **Relay:** on Cloudflare, `wrangler login` and `wrangler deploy` (a `*.workers.dev` subdomain; a domain is optional);
  the resulting address goes into the Mac build's default relay address and into Android's `yardlet.relayUrl`; then
  `PUBLIC_URL` and `AUTH_STATE_SECRET`. Deployed on 2026-10-25: the address contains the name of the account that
  deployed it, so it is not written in the repository. The relay keeps `PUBLIC_URL` as a secret too, and the Mac build
  puts the first line of `Packaging/RelayURL` (outside git) into Info.plist as `YardletRelayURL`, which
  `RemoteControlService.builtInRelayURL` reads. Android's `yardlet.relayUrl` is a Gradle user property.
- **Notifications:** add the Android app (`com.zzunkie.yardlet.remote`) to a Firebase project and put its values in the
  Android build; the service account key goes into the relay's secrets `FCM_SERVICE_ACCOUNT` and `FCM_PROJECT_ID`.
- **Accounts:** an OAuth client (web) in the same Google Cloud project and a GitHub OAuth App, with the callback
  `https://<relay>/v1/auth/<provider>/callback`. Sign in with Apple comes with the iOS app. Email links come after a
  mail sending service is chosen.
- **Release order (changed 2026-10-24):** the Play account is a personal account created after 2023-11-13, so before
  production 12 testers must take part in a closed track for 14 days in a row (the internal track does not count), and
  filling that with acquaintances is hard. So the order is:
  1. **Ship the GitHub Releases APK and Obtainium first.** Each release uploads two APKs: the `play` build (FCM
     notifications, built with the Firebase values, for ordinary phones) and the `foss` build, with `-foss` in its file
     name (for phones without Google Play services). Both have the same app ID and are signed with the key below, so a
     build from one channel can later be installed over another channel's build without uninstalling it. Obtainium reads
     GitHub Releases directly, so nothing else is needed, and it lets the person pick one of the two APKs. The app has
     no self-update feature (Play policy). Updates come from Obtainium or Play.
  2. **Fill the Play closed test slowly.** Demo mode lets people without a Mac really try the app, so besides real users
     after the Mac release, it also takes interested people from public channels. The internal track is only for quick
     checks among ourselves. The "App access" instructions use demo mode (section 14.5).
- **Key policy:** we create the app signing key and upload it to Play App Signing, and the two APKs on GitHub and the
  Play build use the same key. The upload key is kept separate, and both keys are backed up offline. F-Droid builds from
  source and signs with its own key, so unless reproducible builds match, its signature differs from the other channels.
  For Android developer verification, the package name is registered before worldwide enforcement in 2027 (it has not
  started in Korea yet).
- **Play Console:** the app, the closed test track, the Data safety form and the privacy policy (section 14). For iOS,
  the app ID and APNs in the Apple developer account.

## 13. Implementation plan and verification

| Track | Contents | Verification |
|---|---|---|
| Mac (`YardletRemote`, `NativeHarnessClient/Remote`) | Noise, secure channel, keys (keychain), v2 listener and Bonjour, relay client, sending notifications, new requests, settings screen, fixture server v2 | cacophony vectors, broader server and end-to-end tests, settings render |
| Relay (`relay/`, TypeScript) | Worker + Room DO, signature verification, joining, FCM HTTP v1 | Vitest (workerd), joining with the Mac fixture through `wrangler dev` |
| Android (separate repository) | Noise (BouncyCastle X25519, the platform's ChaCha20-Poly1305), route race, Bonjour (NsdManager), several Macs, questions, plans and new tasks, notifications (FCM optional), screens, demo mode | The same vectors, MockWebServer, the fixture (direct) and `wrangler dev` (relay) on the emulator, the demo in airplane mode |

## 14. Facts needed for the Play release (2026-10-24, from the code)

This is for preparing the Play closed test. The facts below were written down after reading `relay/src`, Android
`app/src` and Mac `Sources/YardletRemote`. The policy basis is the Play help pages [Data
safety](https://support.google.com/googleplay/android-developer/answer/10787469), [Account
deletion](https://support.google.com/googleplay/android-developer/answer/13327111) and [Foreground
services](https://support.google.com/googleplay/android-developer/answer/13392821), and Firebase's [Play data disclosure
guide](https://firebase.google.com/docs/android/play-data-disclosure) (all checked 2026-10-24).

### 14.1 What goes where and what stays

By Play's definition, "collection" means sending data out of the app. But data that is end-to-end encrypted so that no
one other than the sender and the recipient can read it (nobody in between, the developer included) need not be
declared, and neither does data handled only on the device. Data handled only briefly in memory goes on the form, but
the store shows it as "processed ephemerally".

| Data | Where it goes | Does the developer (relay) read it | Where it stays and for how long | How it is deleted | Form verdict |
|---|---|---|---|---|---|
| Task list, conversations, messages, answers to approvals, questions and plans, command output, diffs | Phone ↔ the user's Mac | No. Same Wi-Fi and Tailscale do not pass through the relay, and the relay route forwards only Noise ciphertext | Relay: nothing. Phone: the last list and opened conversations, cached in the app-only `noBackupFilesDir` (not backed up) | Uninstalling the app, "Disconnect this Mac" | Not collection (end-to-end encrypted, on device) |
| Notification content (task title, one-line request, Mac name) | Mac → relay → FCM → phone | No. Sealed with the notification key the Mac gave after pairing (ChaCha20-Poly1305) | Relay: nothing. FCM: until delivered (TTL 1 hour) | Automatic | Not collection (end-to-end encrypted) |
| Phone public key, device name (`Settings.Global.DEVICE_NAME`, or the model name if there is none) | Phone → the user's Mac (handshake, encrypted) | No | The user's Mac, `~/.yardlet/remote/devices.json`. Nothing on the relay | Removing the device in the Mac's settings, "Disconnect" in the app | Not collection. But the device name can contain a person's name (for example "Alex's Galaxy") |
| FCM registration token | Phone → Mac (encrypted) → for each notification, Mac → relay (TLS) → FCM | Yes: only in memory while sending one notification. Not stored or logged (`fcm.ts` warns only with the failure status code) | The user's Mac device list. Nothing on the relay. The Mac deletes it if FCM rejects it | Uninstalling the app or clearing its data (invalidates the token), removing the device on the Mac | Device or other IDs, processed ephemerally, App functionality. FCM is a service provider, so this is not sharing |
| What the Firebase SDK sends (`play` build only) | Phone → Google | Not our server | Per Firebase's guide: installation ID (FID), app version, Firebase user agent | Uninstalling the app or clearing its data | Device or other IDs (FID), App info (app version). Not in the `foss` build |
| IP addresses and connection times | Phone and Mac → relay (Cloudflare) | Our code does not record them (Workers Logs is off in `wrangler.jsonc`) | Cloudflare processes them as the hosting provider | — | The Play form has no IP item, and they are not used to estimate location. The privacy policy mentions them |
| Room state (room ID, connection number, whether authenticated, times) | Relay Durable Object | Yes | Only in attachments on open sockets. Gone when the socket closes | Automatic | Not personal data |
| Demo mode tasks and conversations (sample data) | Go nowhere. The demo Mac inside the app answers from memory | Not applicable | In memory only. Gone on leaving | Automatic | Not collection (no network use) |
| Accounts (only when turned on, section 14.2) | App → relay (https) | Yes | Account Durable Object (SQLite): account ID (SHA-256 hash of the provider's user number), display name (GitHub login name, Google profile name), sign-in token hashes with device name and created and last-used times, list of Macs (Mac name, room ID, two public keys, update time), one-time codes that last 2 minutes. The original user number and email are not stored | `DELETE /v1/account` (everything), signing out on the Mac (that Mac's entry and token), signing out in the app (that token). A token unused for 90 days is deleted the next time someone tries to use it (it stays until then) | Personal info › Name (display name) and User IDs (account ID), device name. The account deletion requirement applies |

- **Permissions (merged release manifest):** `play` has only `INTERNET`, `ACCESS_NETWORK_STATE`, `POST_NOTIFICATIONS`
  and, added by the FCM library, `WAKE_LOCK`, `com.google.android.c2dm.permission.RECEIVE` and
  `DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION`, with no foreground service. When the app leaves the screen it closes the
  connection after 5 seconds, notifications arrive through FCM, and it reconnects at once when the app comes back.
  `foss` has no FCM, so it also uses `ConnectionService` (connectedDevice) for "Background notifications" (off by
  default), with `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_CONNECTED_DEVICE` and `CHANGE_NETWORK_STATE`, and `CAMERA`
  for the in-app QR scanner. Location, contacts, photos and the microphone are not used.
- **Left out:** analytics, advertising and crash-reporting SDKs.
- **Encryption in transit:** yes. Between the phone and the Mac, Noise on every route (on the same Wi-Fi and Tailscale,
  the content of `ws://` is Noise too); the relay uses `wss://`, the account API `https://`, and FCM and Firebase use
  Google's HTTPS.

**Draft form (first closed test without accounts, `play` build):**

- Collected: Device or other IDs (the FCM registration token, processed ephemerally; the Firebase installation ID), App
  info and performance › Other (app version, Firebase SDK). Purpose: App functionality (delivering notifications).
  Required (it cannot be turned off in the app while notifications are used). Not shared.
- Security: encrypted in transit, yes. Deletion requests: there is no account and we keep no data. The privacy policy
  states that data on the phone is deleted by uninstalling the app, and the device record on the Mac by removing it in
  the Mac's settings.
- Task content, conversations and notification content are not declared, under the end-to-end encryption exception. The
  exception is narrow, so the privacy policy also gives the reason (the relay holds no keys).

### 14.2 Whether the first closed test includes accounts: leave them out (recommended)

- **Reason 1, the deletion requirement:** if an account can be created in the app (third-party sign-in likely counts),
  there must be both an in-app account deletion path and a web deletion link. The relay has `DELETE /v1/account`, but
  the Mac and Android apps have only sign-out, with no delete button and no web instructions.
- **Reason 2, more declarations and setup:** declaring name, user ID and device name, the Google OAuth consent screen
  and GitHub OAuth App registration, and Sign in with Apple on iOS.
- **Reason 3, the test does not need them:** testers with a Mac first install Yardlet at the Mac, so pairing by QR is
  the natural way, and testers without a Mac use demo mode, so they need no account. Accounts are a convenience for
  adding a new phone when the person is not at the Mac.
- **How to turn them off:** do not put the OAuth secrets in the relay. Then the relay's `GET /v1/auth/providers` returns
  an empty list, and the Mac's settings and the phone (the before-connecting screen, the Mac sheet) show no account row
  (a sign-out row stays only while signed in). The relay address (the Mac build's default, Android's `yardlet.relayUrl`)
  stays, so connecting from outside (the relay route) keeps working. Both apps ask for the providers again each time the
  settings screen opens, so the account row appears once the secrets are added later.
- **What to do when turning them on later:** an account delete button in the Mac and Android apps (calling
  `DELETE /v1/account`), web deletion instructions on the site, adding name and user ID to the form, a periodic cleanup
  that deletes tokens past 90 days and Sign in with Apple on iOS.

### 14.3 Foreground service (connectedDevice) declaration text

The `play` build has no foreground service (verified in the merged release manifest). So the first closed test needs no
foreground service declaration in the Play Console. The service remains only for "Background notifications" (off by
default) in the `foss` build, which has no FCM. The text below is for reference, in case the service goes back into the
`play` build later (the Play Console is filled in in English).

- **Use case:** Continuous data transfer to an external device (network connection).
- **Feature description:** "Background notifications is an optional setting, off by default. When the user turns it on,
  Yardlet Remote keeps an encrypted network connection open to the user's own Mac running the Yardlet app, which the
  user paired with the phone by scanning a QR code on the Mac. While the connection is open, the Mac sends approval
  requests, questions and finished-task updates from the coding agents running on it, and the phone shows them right
  away. A persistent notification shows which Mac is connected and lets the user turn the setting off."
- **User impact if deferred or interrupted:** "A coding agent on the user's Mac stops and waits until the user answers
  its request. If the connection is deferred or interrupted, the request does not reach the phone, and the agent on the
  Mac stays blocked until the user opens the app."
- **Video (recorded in one take, in this order, showing the in-app settings and what happens between the devices, not
  system settings screens):** show the QR in Yardlet's Settings › Remote on the Mac → scan the QR with the phone app →
  turn on "Background notifications" in the phone app's Mac sheet → allow the notification permission → check the
  persistent notification ("Connected to your Mac") → turn off the phone's screen → an agent on the Mac asks to approve
  a command → a notification on the phone → tap it and choose "Allow once" → the screen where the command continues on
  the Mac.

### 14.4 Draft "Phone app" section for the privacy policy (English, for the website)

It is written in English like the site's other sections and goes after the Mac app sections.

> **Yardlet Remote (the phone app)**
>
> Yardlet Remote lets you follow and answer the tasks running in Yardlet on your own Mac. Apart from the demo below, it works only with
> a Mac you pair it with by scanning a QR code on that Mac.
>
> - **What travels between your phone and your Mac.** Task lists, conversations, messages, answers, command output and file
>   changes go only between your phone and your Mac. They are end-to-end encrypted (Noise protocol) on every route. On the same
>   Wi-Fi or over Tailscale they go directly. When you are away, they pass through the Yardlet relay, which forwards encrypted data
>   it cannot read and does not store.
> - **Notifications.** If your phone uses Google Play services, your Mac can send you notifications through the relay and Firebase
>   Cloud Messaging (FCM). The notification text is encrypted with a key only your phone and your Mac hold. The relay handles your
>   phone's FCM registration token only while sending a notification and does not keep it. Google's Firebase SDK in the app sends
>   Google a Firebase installation ID and the app's version to deliver notifications. The build for phones without Google Play
>   services (on GitHub and F-Droid) has no Firebase; it keeps a connection to your Mac open in the background only if you turn on
>   Background notifications.
> - **Explore without a Mac.** The demo on the first screen runs entirely on your phone with sample data. It uses no network and
>   saves nothing; leaving it removes it from memory.
> - **The relay.** The relay runs on Cloudflare. It does not keep logs of your connections; Cloudflare processes connection
>   information such as IP addresses to deliver traffic.
> - **On your devices.** Your phone keeps its keys for each paired Mac (protected by the Android Keystore) and a copy of the last task
>   list and conversations it showed you, excluded from backups. Your Mac keeps your phone's public key, its name and when it last
>   connected. "Disconnect this Mac" in the app deletes the phone's keys and copies for that Mac and its record on the Mac; removing
>   the phone in Yardlet's settings on the Mac deletes the record there. Uninstalling the app deletes everything on the phone.
> - **No analytics or ads.** The app contains no analytics, advertising or crash-reporting code.

A build with accounts turned on adds this paragraph: "If you sign in with GitHub or Google to find your Macs, the relay
keeps a hashed account identifier, your display name, your Macs' names and keys, and a hash of each sign-in token with
the device name. You can delete your account and this data in the app or at <web deletion link>."

### 14.5 "App access" instructions

In the Play Console, App content › App access is set to "All or some functionality in my app is restricted", and the
instructions point to demo mode instead of sign-in details. Reviewers and testers without a Mac try the app the same way
(the Play Console is filled in in English).

- **Instructions:** "Yardlet Remote controls the Yardlet app on the user's own Mac, so its full use needs a Mac paired
  by QR code. No account or sign-in is needed. To try every screen without a Mac, tap "Explore without a Mac" on the
  first screen. The demo runs entirely on the phone with sample data and no network: open tasks, read conversations,
  approve a command, answer a question, review a plan, open a file diff, start a new task, and leave the app to receive
  a demo notification. Tap "Exit demo" at the top to leave the demo."
