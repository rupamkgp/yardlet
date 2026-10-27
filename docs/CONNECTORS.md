# 커넥터

이 문서는 Yardlet 커넥터의 현재 계약이다. 커넥터 도구를 하네스에 넣는 Yardlet MCP 서버와 주입 경로는
[AGENT_BROWSER_TOOLS](AGENT_BROWSER_TOOLS.md)에 있다. 아래에서 "절"은 이 문서의 절 이름이다.

## 1. 한눈에

- 커넥터는 외부 서비스가 운영하는 원격 MCP 서버(Streamable HTTP)다. Yardlet이 한 번 로그인해 자격 증명을 Keychain에
  두고, 그 서버의 도구를 Yardlet MCP 서버(`yardlet`)로 Claude Code·Codex·ACP 하네스에 제공한다. 예외로 Gmail·Google
  Calendar·Google Drive는 Yardlet이 앱 안에서 돌리는 서버다. Google 계정마다 한 번 로그인하고 공개 Google REST API를
  부른다("Google" 절). Apple 커넥터(App Store Connect, Mac의 캘린더·미리 알림·연락처, Xcode)도 앱 안의 서버다. App Store
  Connect는 사람의 API 키로 Apple의 REST API를 부르고, Mac 셋은 macOS가 허용한 뒤 Mac의 데이터를 쓰며, Xcode는 Xcode의
  `mcpbridge`를 거친다("Apple" 절).
- **모든 하네스와 계정이 같은 커넥터를 받는다.** Claude Code는 설정 폴더(`CLAUDE_CONFIG_DIR`)마다 claude.ai 커넥터와
  `claude mcp add` 항목이 따로라, Claude 계정을 여럿 쓰면 계정마다 연결이 다르다. Yardlet 커넥터는 프로세스마다
  넣으므로(Claude `--mcp-config`, Codex 스레드 `config`, ACP `mcpServers`) 어느 하네스·계정의 작업이든 같은 커넥터를 받는다.
  사용자 설정 파일에는 쓰지 않으므로 Yardlet을 지우면 흔적이 남지 않는다. Antigravity 작업에는 넣지 않는다.
- 토큰은 Yardlet 프로세스 밖으로 나가지 않는다. 하네스는 `yardlet-mcp`를 거쳐 호출하고, 원격 서버에 요청하는 것은
  Yardlet이다. 하네스 설정 파일에도 쓰지 않는다.
- 연결과 관리는 설정 → 커넥터에서, 작업마다 켜고 끄기와 다시 연결은 입력창 "+" → "커넥터"에서 한다("화면" 절).

## 2. 연결 방식

| 방식 | 언제 | 동작 |
|---|---|---|
| OAuth(동적 등록) | 서버가 401과 함께 로그인을 요구하고 동적 클라이언트 등록을 지원할 때 | 아래 순서 |
| OAuth(직접 만든 클라이언트) | 동적 등록이 없을 때(Slack, 사용자가 등록한 GitHub OAuth 앱) | 아래 순서에서 4단계 대신 사용자의 클라이언트 ID(와 secret), 고정 리디렉션 |
| GitHub 기기 코드 | GitHub, 빌드에 Yardlet GitHub OAuth 앱의 client ID가 있을 때 | "GitHub 로그인" 절 |
| 액세스 토큰 | 동적 등록이 없는 서버(GitHub 개인 액세스 토큰 등) | 붙여 넣은 값을 `Authorization: Bearer`로 보낸다 |
| 주소의 키 | 키를 쿼리로 받는 서버(Browserbase `browserbaseApiKey`) | 요청마다 주소에 붙인다. 저장된 주소·헤더에는 없다 |
| 인증 없음 | 서버가 401 없이 답할 때 | 그대로 연결한다 |
| Google 계정 | Gmail·Google Calendar·Google Drive | "Google" 절 |
| App Store Connect API 키 | App Store Connect | `.p8` 키 파일·키 ID·(팀 키는) 발급자 ID. "Apple" 절 |
| macOS 권한 | Apple Calendar·Apple Reminders·Apple Contacts | 켤 때 macOS가 한 번 묻는다. "Apple" 절 |
| 이 Mac의 앱 | Xcode | 로그인 없음. Xcode의 `mcpbridge`가 도구를 준다. "Apple" 절 |

OAuth 순서(MCP 인증 규약):

1. 토큰 없이 `initialize`를 보내 401을 받는다. `WWW-Authenticate: Bearer`의 `resource_metadata`와 `scope`를 읽는다.
   직접 만든 클라이언트가 있는 커넥터는 401을 기다리지 않고 먼저 로그인한다. `initialize`·`tools/list`는 누구에게나 답하고
   `tools/call`만 거절하는 서버가 있어서, 그대로 두면 "연결됨"이 되었다가 호출에서 실패하기 때문이다.
2. 보호 자원 메타데이터(RFC 9728): 헤더가 가리킨 주소, 없으면 `/.well-known/oauth-protected-resource<경로>`, 그다음 루트.
   메타데이터가 없는 서버(Atlassian)는 서버 origin을 인가 서버로 본다(2025-03-26 규약의 대체 경로).
3. 인가 서버 메타데이터(RFC 8414, OpenID): 발급자 경로가 있으면 경로 삽입형 두 개와 경로 뒤 OpenID, 없으면 루트 두 개.
   발급자 끝의 `/`(예: `https://accounts.google.com/`)는 경로가 아니다.
4. 클라이언트:
   - 동적 클라이언트 등록(RFC 7591): 로그인마다 `127.0.0.1`의 임의 포트 `/callback`을 redirect URI로 새로 등록한다. 서버가
     `none`을 받으면 공개 클라이언트, 아니면 `client_secret_post`·`client_secret_basic` 중 서버가 받는 것.
   - 직접 만든 클라이언트: 등록하지 않는다. redirect URI는 고정 `http://127.0.0.1:47823/callback`이다(서비스의 앱 설정에
     사용자가 넣는 값; Slack 앱과 웹 애플리케이션 유형 OAuth 클라이언트는 포트까지 정확히 맞아야 한다). secret이 없으면 PKCE
     공개 클라이언트(`none`, Slack의 PKCE 앱)다. 있으면 서버가 `client_secret_post`를 받거나 방법을 알리지 않을 때(GitHub) 폼으로,
     `client_secret_basic`만 받으면 Basic으로 보낸다.
5. 기본 브라우저에서 인가 코드 + PKCE S256, `state`, `resource`(RFC 8707), `scope`(커넥터의 scope, 없으면 헤더의 값, 없으면
   메타데이터의 `scopes_supported`), 디렉터리 항목의 추가 인가 인자로 인가 페이지를 연다. 사용자의 기존 브라우저 로그인을
   그대로 쓰고, Yardlet은 비밀번호를 보지 않는다.
6. 루프백 수신기가 첫 `GET /callback`을 받으면 "Yardlet에 연결되었습니다" 페이지를 돌려주고 Yardlet을 앞으로 가져온다.
   5분 안에 오지 않거나 사용자가 취소하면 끝난다. 인가 페이지의 취소(`error=access_denied`)는 Yardlet의 "취소"와 같아서
   오류로 남기지 않는다(`ConnectorOAuthError.declined`). `state`가 다르면 거부한다.
7. 토큰 요청으로 access·refresh 토큰을 받아 Keychain에 저장한 뒤 `initialize`·`tools/list`를 다시 보낸다.

직접 만든 클라이언트나 토큰이 있어야 하는 디렉터리 항목(Slack, Browserbase, 기기 코드 로그인이 없는 빌드의 GitHub)은 그것이
없으면 연결을 시작하지 않고 "직접 만든 OAuth 클라이언트나 액세스 토큰으로 연결하세요"를 보인다(요청 없음). 연결 해제는 토큰만
지우고 직접 만든 클라이언트는 남겨, 다시 연결하면 바로 로그인한다. 제거는 모두 지운다.

다시 연결(`ConnectorCenter.reconnect`)은 저장된 OAuth 로그인이 아직 되더라도 새로 로그인하고, 새 토큰을 저장할 때까지 저장된
토큰을 그대로 쓴다. 서버가 어디서 로그인할지는 토큰 없이 한 번 물어 받는다. 그래서 취소한 다시 연결은 연결·도구·설정 목록의
자리를 바꾸지 않는다. 다른 이유로 실패한 다시 연결(시간 초과, 다른 계정)이나 도구 다시 읽기도 연결과 도구를 그대로 두고, 그 행은
"연결됨"과 자리를 지킨 채 이유를 한 줄로 보인다("화면" 절). 붙여 넣은 토큰은 사용자만 바꿀 수 있으므로 다시 연결해도 그대로다.

토큰 갱신: 만료 1분 전이면 호출 전에 갱신한다. 서버가 401을 주면 한 번 갱신하고 다시 보낸다. 갱신은 한 번에 하나만 돌려
refresh 토큰을 교체하는 서버에서도 꼬이지 않게 한다(`ConnectorSession`).

- 갱신 전에 Keychain 항목을 다시 읽는다. 다른 Yardlet 사본(같은 번들 ID)이 이미 갱신해 만료가 같거나 늦은 토큰을 저장했으면,
  요청하지 않고 그것을 쓴다. 갱신 결과는 그것을 만든 값 위에만 저장한다(그사이 더 새 값이 들어왔거나 커넥터가 지워졌으면
  저장하지 않음).
- 거절(`invalid_grant`, 그 밖의 4xx: 모르는 클라이언트 등)이면 Keychain을 바로 한 번, 1초 뒤 한 번 더 읽는다. 다른 사본이 방금
  바꾼 토큰이 있으면 그것을 쓰고, 없을 때만 그 호출은 "다시 로그인하라"는 도구 오류가 된다. 커넥터는 "로그인 필요"가 된다.
- 일시적 실패(네트워크 없음·시간 초과 등 전송 오류, 5xx, 408, 429, `temporarily_unavailable`·`server_error`, 토큰이 없는 2xx)는
  1초·2초 뒤 다시 시도한다(모두 세 번). 끝내 안 되면 그 호출만 "지금은 갱신하지 못했다"는 도구 오류가 되고, 커넥터는 연결됨
  그대로다. 다음 호출이 다시 갱신한다. 잠자기 직후의 일시적 오류가 "로그인 필요"가 되지 않게 하려는 것이다.

MCP 세션: 서버가 준 `Mcp-Session-Id`와 협상한 `MCP-Protocol-Version`을 이후 요청에 붙인다. 서버가 세션을 잊으면(404)
한 번 다시 초기화한다. 응답은 JSON이나 짧은 event stream이며, stream 안의 알림은 건너뛰고 같은 `id`의 응답을 쓴다.

## 3. 디렉터리

디렉터리(`ConnectorPreset.all`)는 누구나 쓸 수 있는 원격 MCP 서버의 목록이다. 항목마다 로그인 방식을 정해 두며, 그 방식은
인증 없는 공개 요청(토큰 없는 `initialize`, 보호 자원 메타데이터, 인가 서버 메타데이터)과 서비스의 공개 문서로 확인한 것이다.
로그인, 동적 등록 POST, 토큰 요청으로 확인하지는 않는다. 등록 엔드포인트가 있어도 서비스가 클라이언트를 가려 받는지는 이
방법으로 알 수 없으므로, 공개 문서로 확인한 곳만 뺐다. 등록을 거절하는 서비스가 있으면 연결 오류에 서비스가 준 이유가 보인다.

| 로그인 | 서비스 |
|---|---|
| 동적 등록 OAuth | Linear, Notion, Atlassian, Sentry, Asana, ClickUp, monday.com, Todoist, Airtable, Miro, Dropbox, Intercom, Zapier, Granola, Fireflies, Gamma, GitLab, Supabase, Neon, Prisma Postgres, Netlify, Cloudflare, PostHog, Semgrep, Postman, Jam, Stripe, PayPal, Square, Mercury(읽기 전용), Webflow, Wix, Tavily |
| 인증 없음 | Exa, Hugging Face, Context7, DeepWiki, OpenAI Docs, Microsoft Learn, AWS Knowledge, Cloudflare Docs, Figma 데스크톱 앱 서버(`http://127.0.0.1:3845/mcp`, Dev Mode에서 켬). Exa·Hugging Face·Context7은 로그인하면 더 쓸 수 있지만 Yardlet은 묻지 않는다 |
| 직접 만든 OAuth 앱 | Slack("Slack" 절) |
| Google 계정 | Gmail, Google Calendar, Google Drive("Google" 절) |
| Apple | App Store Connect(API 키), Apple Calendar·Apple Reminders·Apple Contacts(macOS 권한), Xcode(이 Mac의 `mcpbridge`)("Apple" 절) |
| GitHub | GitHub(`https://api.githubcopilot.com/mcp/`): 기기 코드 로그인("GitHub 로그인" 절), 개인 액세스 토큰, 직접 만든 OAuth 앱 |
| 주소의 키 | Browserbase(`https://mcp.browserbase.com/mcp`, 키는 Keychain에) |

- 순서: 많이 쓰는 서비스(Linear, Notion, Slack, Google 셋, Mac 셋, GitHub, Browserbase, Atlassian, Sentry) → 일·계획 → 개발·운영
  (Xcode, App Store Connect 먼저) → 결제·사이트 → Figma 데스크톱 → 검색·문서. 항목의 기호(SF Symbol)는 서비스 아이콘을 받기 전과
  받지 못했을 때 쓴다("아이콘" 절).
- Xcode는 이 Mac에 `mcpbridge`가 있을 때만, App Store Connect는 빌드가 토큰에 서명할 수 있을 때만 목록에 보인다
  (`ConnectorCenter.isAvailable`).
- Asana는 동적 등록이 되는 `/mcp`를 쓴다. 새 주소(`/v2/mcp`)는 앱 등록이 필요하다.
- Mercury(`https://mcp.mercury.com/mcp`)는 읽기 전용이다. 디렉터리 항목의 범위가 `read offline_access`라서, 서버가 쓰기 범위를
  함께 알려도 Yardlet은 읽기와 갱신 토큰만 요청한다(docs.mercury.com/docs/connecting-mercury-mcp). 송금 요청·계좌 간 이체 요청·분류
  만들기와 고치기·거래 메모 도구는 그 범위가 없어 목록에 오지 않는다. 커넥터 추가 시트의 Mercury 줄 아래에 "읽기 전용"이 보인다.
  로그인은 "연결 방식" 절의 OAuth 순서 그대로다. Mercury는 공개 클라이언트 동적 등록과 PKCE `S256`을 받고, 보호 자원 메타데이터는
  루트(`/.well-known/oauth-protected-resource`)에만 둔다.
- 목록에 없는 서버는 커넥터 추가의 "다른 MCP 서버"에 주소로 더한다.

넣지 않은 것:

- 승인한 클라이언트만 받는 서버: Vercel, Canva, 원격 Figma(`mcp.figma.com`, 등록할 때 클라이언트 이름으로 승인된 클라이언트만
  받음). 다른 앱의 이름을 대는 우회는 하지 않는다.
- 등록 엔드포인트가 없어 클라이언트마다 앱 등록이 필요한 서버: Box, HubSpot, Asana `/v2/mcp`.
- Google 공식 MCP 서버(`gmailmcp`·`calendarmcp`·`drivemcp.googleapis.com`): Workspace Developer Preview가 필요하다. 대신 Yardlet이
  같은 도구 이름의 서버를 직접 돌린다("Google" 절).
- Google의 비공식 주소, 다른 회사가 띄운 Gmail·Drive 중계 서버, Slack·GitHub 토큰을 다른 앱에서 읽어 오기.
- 다른 회사가 만든 App Store Connect MCP 서버: API 키를 그 코드가 쥐게 된다. Yardlet이 Apple의 API를 직접 부른다("Apple" 절).
- Mac의 메모·메시지: macOS에 앱이 그 데이터를 읽는 공개 방법이 없다.
- Codex 런타임 플러그인(documents, spreadsheets, presentations, pdf, browser 등), computer-use, node_repl: 커넥터가 아니므로
  Codex에 그대로 둔다.

## 4. 하네스에 보이는 모습

- 서버 하나(`yardlet`)에 브라우저 도구, 작업 제안·세션·예약 도구, 커넥터 도구가 함께 있다([AGENT_BROWSER_TOOLS](AGENT_BROWSER_TOOLS.md)
  2절). 커넥터 도구 이름은 `<slug>_<서버의 도구 이름>`이다. slug는 커넥터 이름을 소문자 ASCII로 줄인 것(최대 20자, 겹치면 숫자를
  붙이고 `browser`는 쓰지 않음)이다. 그렇게 만든 이름이 Yardlet 자신의 도구 이름(`spawn_task` 등)과 같으면 그 커넥터 도구는
  목록에서 빠진다.
- 이름은 50자 이하다. Claude Code는 `mcp__yardlet__`를 붙이고 모델 API는 64자까지 받기 때문이다. 넘치면 앞부분과 원래 이름의
  FNV-1a 8자리를 쓴다. `[A-Za-z0-9_-]` 밖의 글자는 `_`가 된다.
- 제목은 `Linear: …`, 설명은 `[Linear] …`로 시작한다. `inputSchema`·`outputSchema`·`annotations`는 서버가 준 그대로다.
- 결과는 서버가 준 `content` 항목(텍스트, 이미지, 오디오, 리소스 링크 등), `structuredContent`, `isError`를 그대로 넘긴다.
  서버의 JSON-RPC 오류와 연결 실패는 `isError` 결과가 된다.
- 주입: 주입 경로가 있는 하네스에는 Yardlet MCP 서버를 늘 넣는다. 브라우저 도구가 꺼진 채 시작한 작업은 나머지 도구만 받고,
  브라우저 도구를 부르면 설정을 안내하는 오류가 된다.
- 도구 목록은 `connectors.json`에 두어 세션 시작 때 네트워크를 기다리지 않는다. 12시간이 지난 목록은 세션이 목록을
  요청할 때 백그라운드에서 다시 읽는다. 도구가 앱에 들어 있는 Google·Apple 서비스는 서버에 묻지 않고, Xcode는 그것만으로 Xcode가
  뜨지 않게 다시 읽지 않는다("Apple" 절).
- 이 작업에서 끈 커넥터의 호출은 바로 "이 작업에서 꺼짐" 도구 오류가 된다. 로그인이 필요한 커넥터의 호출은 "Yardlet 설정 →
  커넥터에서 다시 로그인하면 같은 도구가 다시 된다"는 오류다.
- 도구 줄: 대화의 도구 줄은 `yardlet` 서버 이름 대신 커넥터 이름과 아이콘을 보인다. Claude `mcp__yardlet__linear_create_issue`
  → "Linear: create issue", Codex `yardlet · linear_create_issue` → "Linear · create_issue". 이름표는 `ConnectorToolLabels`가
  지금 커넥터 목록에서 만든다. 지운 커넥터의 옛 줄은 원래 이름으로 보인다.

## 5. 실행 중인 작업의 도구 목록

커넥터를 연결·해제·다시 로그인하거나 작업에서 끄고 켜면, 실행 중인 작업도 바뀐 목록을 받는다. Claude Code 작업은 다음 턴부터,
다른 하네스의 작업은 다음에 시작하거나 재개할 때부터다.

- `yardlet-mcp`는 `initialize`에서 `tools.listChanged: true`를 알린다.
- 앱과 서버 사이의 소켓(연결 하나에 요청 하나와 답 하나)에 `tools/watch`가 있다.
  - `tools/list`의 답에는 앱이 계산한 `fingerprint`(정렬된 키의 JSON에 대한 FNV-1a와 도구 수)가 붙는다. 지문은 앱만 계산하므로,
    소켓을 건너온 목록을 다시 인코딩해 비교하다가 알림이 되풀이되는 일이 없다.
  - 서버는 클라이언트가 처음 목록을 받은 뒤 3초가 지나면, 클라이언트가 가진 목록의 지문으로 `tools/watch`를 보낸다. 3초는 Codex
    `mcpServerStatus/list`가 띄우는 확인용 프로세스가 그 전에 끝나게 하려는 것이다. 그러면 앱이 그 프로세스를 위해 연결을
    붙잡지 않는다.
  - 앱은 작업의 지금 목록이 그 지문과 다르고 작업이 턴 사이에 있으면 `{"changed": true}`를 답한다. 아니면 붙잡아 두었다가 60초 뒤
    `{"changed": false}`를 답하고, 서버는 다시 묻는다.
  - 서버는 바뀌었다는 답을 받으면 `notifications/tools/list_changed`를 보내고, 클라이언트가 목록을 다시 받을 때까지 묻지 않는다.
    그래서 다시 읽지 않는 클라이언트(Codex)는 한 번만 듣는다. 알림 사이는 2초 이상 둔다.
  - 앱에 닿지 못하거나 토큰이 거절되면(앞선 앱 실행의 토큰), 15초부터 두 배씩 5분까지 기다렸다가 다시 묻는다.
- 앱 안:
  - `ConnectorCenter.onToolsChanged`는 커넥터 목록이나 작업별 선택이 바뀔 때마다 `AgentToolBroker.toolsMayHaveChanged()`를 부른다.
  - 브로커는 300 ms 동안 몰린 변화를 모은 뒤, 감시 중인 작업마다 지금 목록의 지문을 다시 계산하고 다른 것에만 답한다.
  - 턴 중인 작업(`running`, `waitingForApproval`)에는 답하지 않는다. `AppModel`이 그 작업의 턴 끝(`ready`·`completed`·`failed`,
    오류 이벤트)을 `taskTurnEnded`로 알리면 그때 답한다. 이 작업에서 끈 커넥터의 호출은 그와 상관없이 바로 거절된다.
- 이름과 설명이 그대로인 도구는 바이트까지 같다. 목록은 같은 순서와 같은 변환으로 만들고, 지문이 같으면 알리지 않는다. 12시간마다
  다시 읽은 서버 목록이 같을 때도 알리지 않는다.
- **다시 로그인이 필요한 커넥터의 도구는 목록에 남긴다.** 한 번이라도 연결되어 도구를 읽은 커넥터(`toolsUpdatedAt`이 있음)만
  해당한다. 호출은 "로그인 필요" 오류가 되고, 다시 연결해도 목록이 바뀌지 않으므로 Codex를 포함한 모든 하네스에서 같은 도구가
  바로 다시 된다. 처음부터 연결되지 못한 것(Google 동의에서 뺀 서비스)은 목록에 없다. 사용자가 연결을 해제한 커넥터는 빠진다.
- 하네스별:
  - Claude Code: `listChanged`를 알린 서버의 알림을 받으면 `tools/list`를 다시 부르고, 다음 모델 요청부터 새 목록을 쓴다. 턴 중의
    변화는 턴이 끝난 뒤 알리므로 다음 턴부터다.
  - Codex: App Server는 이 알림을 로그로만 남긴다. `config/mcpServer/reload`와 이미 올라온 스레드의 `thread/resume`도 설정이 같은
    서버를 다시 띄우지 않는다. 그래서 다음에 다시 열 때(재개) 새 목록을 받는다. 스레드를 내렸다 다시 올리는 방법
    (`thread/unsubscribe`와 `thread/resume`)은 백그라운드 터미널을 잃을 수 있고 문서화되지 않은 동작이라 쓰지 않는다.
  - ACP 하네스: 알림은 가지만 하네스마다 따르는지는 확인하지 않았다. 화면은 "다음에 시작하거나 재개할 때"라고 말한다.
- 브라우저 도구 설정(켬·끔)은 작업을 시작할 때 정해진다.

## 6. 하네스 자체 서버

하네스가 스스로 싣는 MCP 서버와 Yardlet 커넥터가 같은 서비스를 가리킬 때, 모델이 같은 도구를 두 번 받지 않게 한다.

### 읽는 곳

작업을 주입할 때(`AppModel.configureAgentTools` → `AppModel.connectorScope(for:)`) 그 작업의 하네스가 스스로 싣는 원격 서버의 이름과
주소를 읽는다(`ConnectorCenter.scope(for:)` → `NativeMCPInventory.loadedRemoteServerEntries`). 주소는 소문자 scheme·host로 맞추고 기본
포트·끝 `/`·쿼리를 뺀다. 주소가 없는 stdio 서버(하네스가 싣는 Xcode `mcpbridge` 등)는 아래의 대신하기와 중복 제외 대상이 아니다.

- Claude Code: 작업 계정의 `.claude.json`(`CLAUDE_CONFIG_DIR`이 있으면 그 안, 없으면 `~/.claude.json`)의 사용자 서버, 작업 폴더(와
  작업 트리의 원래 폴더) 항목의 로컬 서버에서 `disabledMcpServers`를 뺀 것, 폴더 `.mcp.json` 중 승인된 것(`enabledMcpjsonServers`·
  `enableAllProjectMcpServers`: 프로젝트 항목, 폴더 `.claude/settings(.local).json`, 계정 `settings.json`).
- Codex: 작업 계정 홈의 `config.toml` `[mcp_servers.*]` 중 켜진 것.
- 다른 하네스: 없음.

하네스 설정을 읽은 결과는 메모리에만 두고, 파싱한 결과(이름·주소·프로그램 이름)만 파일 수정 시각별로 둔다. 파일 내용 자체와
헤더·환경 값·쿼리는 두지 않는다.

### Claude Code: Yardlet 커넥터가 대신한다

- 연결된 Yardlet 커넥터가 같은 주소의 하네스 서버를 대신한다. `ConnectorCenter.withYardletStandIns`가 작업을 시작하는 시점에
  연결됨인 커넥터(Google 같은 Yardlet 자체 서비스 제외)의 주소를 범위의 `yardletServedURLs`에 넣는다. 그 작업은 Yardlet 쪽 도구를
  받고, Claude 프로세스는 `--settings '{"deniedMcpServers":[…]}'`로 그 서버를 이 프로세스에서만 뺀다
  (`AgentToolServerLaunch.claudeSettings` → `ClaudeLaunchConfiguration.settings`). 계정 파일은 쓰지 않는다.
- 항목은 하네스 설정에 적힌 주소 그대로와 `주소?*`(쿼리가 붙은 경우) 둘이다. CLI는 `serverUrl`을 host는 대소문자 없이, 경로·쿼리는
  `*` glob으로 맞추므로 같은 host의 다른 경로(예: Linear `/mcp/readonly`)는 그대로 남는다.
- `deniedMcpServers`는 모든 설정 출처에서 합쳐지고 `--settings`는 그중 플래그 출처다. Claude Code의 `mcp_toggle`은 서버를 끌 때 그
  폴더의 `.claude.json` `disabledMcpServers`에 써서 사용자 설정을 바꾸므로 쓰지 않는다. `--strict-mcp-config`는 사용자 서버를 모두
  빼므로 쓰지 않는다.
- 이유: Claude Code는 MCP 로그인을 설정 폴더마다 따로 저장한다. 같은 서비스를 Claude 쪽에 등록해 두면 계정마다 로그인이 따로
  필요하고, 서버가 연결을 닫으면 다음 턴에야 다시 붙으며 그 턴 첫머리에 도구가 사라졌다고 모델에 알린다. Yardlet 커넥터는 로그인
  하나(Yardlet Keychain)로 모든 계정·폴더·하네스에 쓰이고, 서버가 연결을 닫아도 Yardlet이 MCP 세션을 다시 열어 하네스 쪽 도구 목록이
  흔들리지 않는다.
- Yardlet 커넥터가 연결 안 됨·로그인 필요이면 하네스 쪽을 쓴다(`.harnessHasIt`). 상태가 바뀌어도 이미 떠 있는 세션은 다음
  시작·재개부터 따른다(`--settings`는 시작 인자).
- 도구 이름이 바뀐다: `mcp__linear__save_issue` → `mcp__yardlet__linear_save_issue`. 옛 이름을 적은 권한 규칙이나 문서가 있으면
  새 이름에 맞춰야 한다.
- 작업별 스위치로 Yardlet 쪽을 끄면 그 작업에는 그 서비스가 없다(하네스 쪽도 빠져 있으므로). 사용자가 "이 작업에서 끔"을 고른
  뜻과 같다.

### Codex와 ACP 하네스

- 같은 주소의 Yardlet 커넥터는 그 작업의 목록에서 빠지고, 호출은 "하네스 자체 서버를 쓰라"는 오류가 된다. Codex에는 서버 하나를
  프로세스(스레드) 단위로 빼는 확인된 방법이 아직 없다.
- Codex 플러그인(ChatGPT 앱)은 주소가 없어 중복 제외 대상이 아니다. Codex 작업에서는 같은 서비스가 플러그인과 Yardlet 쪽에 둘 다
  보일 수 있다(플러그인은 Codex 설정에서 사용자가 끈다).

### claude.ai 계정 커넥터

- 설정 → 커넥터 "claude.ai 계정 커넥터 사용"(`Yardlet.claudeAIConnectors`, 기본 꺼짐). 꺼져 있으면 Yardlet이 띄우는 Claude Code
  프로세스 환경에 `ENABLE_CLAUDEAI_MCP_SERVERS=false`를 넣는다(`ClaudeProcessTransport.environment`). 켜면 넣지 않아 CLI 기본값
  (구독 계정이면 claude.ai 커넥터를 불러옴)이 된다. 계정 설정 파일에는 쓰지 않는다. 프로젝트·사용자 `claude mcp add` 서버에는
  영향이 없다.
- 켜면 같은 서비스가 claude.ai 쪽과 Yardlet 쪽에 두 번 보일 수 있다. claude.ai 커넥터는 로컬에 주소가 없어 중복 제외 대상이
  아니다. 화면 문구가 이를 말한다.

### 다른 곳에서 쓰는 서비스

- 설정 → 커넥터가 열릴 때 백그라운드에서 읽는다(`NativeMCPHome.all`): 기본 Claude 로그인, 저장된 Claude 계정, Session Switch 계정
  폴더(`~/Library/Application Support/Session Switch/accounts/*/.claude.json`), 기본·저장된 Codex 홈,
  `~/.gemini/antigravity/mcp_config.json`·`~/.gemini/config/mcp_config.json`. 읽기만 한다.
- 출처: 계정마다 `.claude.json`의 `claudeAiMcpEverConnected`("claude.ai · 계정", 계정은 그 폴더의 `oauthAccount`가 말하는 주소, 팀
  조직이면 "주소 (조직)"), Codex 홈의 플러그인("Codex 플러그인")과 ChatGPT 앱("Codex 앱": Codex가 남긴 캐시의 이름에서 설정이 끈
  앱을 빼고, 캐시에 없는 앱은 도구 이름 접두사로), 하네스 설정의 서버.
- 남기는 것: 서버 이름, 주소(쿼리·사용자 정보 없이), stdio 프로그램의 파일 이름과 npm 패키지 이름(범위 패키지이거나 "mcp"를 담은
  것만; 명령줄 키가 패키지로 잡히지 않게), 켜짐 여부, claude.ai 커넥터 이름, 계정 주소와 조직 이름, Codex 플러그인 ID. 헤더·환경
  값·쿼리·조직 ID·대화 기록은 남기지 않는다.
- 제안: 디렉터리와 같은 주소·같은 host·claude.ai 이름·Codex 플러그인 이름·stdio 패키지로 맞춘 서비스(`ConnectorPreset.isNamed`),
  디렉터리에 없는 https 원격 서버는 그 이름과 주소 그대로. 이미 연결한 것(Google 서비스는 그 API 주소로), `yardlet` 서버,
  claude.ai 전용 항목, 디렉터리에 없는 앱은 뺀다.
- 행마다 "Yardlet에서 연결": 한 번에 되는 서비스는 추가하고 연결, Google 서비스는 Google 페이지, Slack은 Slack 페이지, 키가 필요한
  것은 그 칸을 연다. "숨기기"(`Yardlet.connectorImportDismissed`)로 접는다.

### Antigravity

Antigravity 작업에는 커넥터를 넣지 않는다(`ConnectorTaskScope.carriesConnectors`). 브로커가 목록·호출에서 빼고, 입력창 목록과 설정
문구가 Antigravity는 지원하지 않는다고 말한다.

## 7. 화면

- **설정 → 커넥터:** 한 문단 소개(모든 하네스·계정, Antigravity 제외) → "내 커넥터"와 "커넥터 추가"(비어 있으면 빈 상태 안에 하나만)
  → "다른 곳에서 쓰는 서비스" → "한 번에 설정"(Google·Slack) → claude.ai 계정 커넥터 스위치.
  - 내 커넥터: 연결됨 먼저, 그다음 진행 중, 로그인 필요, 오류(빨간 이유 줄). 상태는 점과 한 단어(`ConnectorSettingsState`), 할 일
    버튼은 하나(다시 연결·연결·설정…·다시 시도·취소)다. 목록 아래 한 줄이 바뀐 내용이 언제 작업에 닿는지 말한다("실행 중인 작업의
    도구 목록" 절).
  - 행의 `…`: 도구 목록 다시 읽기, 다시 로그인, 연결 해제, 제거. 액세스 토큰·직접 만든 OAuth 클라이언트로 연결은 그 서비스가 받는
    경우(디렉터리의 토큰·클라이언트 서비스, 또는 디렉터리 밖 서버)에만 있다. Google 서비스는 연결 해제 대신 "Google 계정과
    서비스…"가 Google 페이지를 연다. App Store Connect는 "App Store Connect 키…"가 키 페이지를, Mac 셋은 "개인정보 보호 및 보안
    열기…"가 시스템 설정의 그 패널을 연다. 도구가 앱에 들어 있는 Google·Apple 서비스에는 도구 목록 다시 읽기가 없다(Xcode는 있다).
  - 연결된 커넥터는 다시 로그인하거나 도구를 다시 읽는 동안에도 자리를 지킨다. 그 시도가 실패해도 "연결됨"으로 남고, 이유는 회색
    한 줄(`ConnectorSettingsState.note`, 다 보이지 않으면 도움말)이다. Codex 앱과 Claude 앱도 이때 행을 그대로 둔다. Google 페이지의
    계정 행과 Slack 페이지도 같다.
- **커넥터 추가 시트(`ConnectorAddSheet`):** 맨 위 서비스 검색(이름이나 ID, 대소문자 무시; "Gmail"·"Calendar"·"Drive"도 Google 줄을
  찾음) → "한 번에 연결"(동적 등록·인증 없음 서비스와 Mac 셋·Xcode, 누르면 추가하고 연결) → "키나 토큰 붙여 넣기"(GitHub·Browserbase는
  행 안에 칸과 "GitHub에서 토큰 만들기"·"API 키 찾기", App Store Connect는 "설정…"이 자기 페이지를 연다) → "직접 만든 OAuth 앱
  필요"(기본 접힘) → "다른 MCP 서버"(URL로 추가, 로그인 정보는 접힌 선택 칸). 검색이 한 곳도 못 찾으면 안내 한 줄과 URL로 추가만
  남는다.
  - 빌드에 Google 앱이 들어 있으면 Google 줄이 "한 번에 연결" 맨 위에 오고, "직접 만든 OAuth 앱 필요" 아래에는 Slack만 남는다.
    없으면 그 아래에 Google과 Slack이 있고, Google 안내가 claude.ai 스위치를 대안으로 말한다.
  - 빌드에 GitHub client ID가 있으면 GitHub가 "한 번에 연결"로 옮겨 "GitHub로 로그인"을 보인다.
- **한 번에 설정 페이지(`GoogleSetupPage`, `SlackSetupPage`):** 머리에 "n단계 중 m단계 완료"/"모두 완료", 단계마다 번호 동그라미(누르면
  완료 표시를 켜고 끔)·제목·한 줄 설명·콘솔 페이지 단추·복사 단추. 클라이언트 단계의 칸은 입력하는 대로 확인한다(빨간 이유 한 줄,
  맞으면 초록 체크). 콘솔 단계는 그 페이지를 열었거나 손으로 표시하면 완료, 앱을 저장하면 모두 완료, 계정이 연결되면 마지막 단계가
  완료다. 연 단계는 `Yardlet.connectorSetup.opened`(단계 이름만)에 남는다.
  - 칸 확인: Google client ID `<숫자>-<영숫자>.apps.googleusercontent.com`(보안 비밀을 넣으면 "이것은 보안 비밀입니다"), 보안 비밀은
    16자 이상·공백 없음·client ID가 아님, Slack client ID `숫자.숫자`, Slack secret(선택)은 16진수 32자.
- **입력창 "+" 메뉴(`ComposerPlusMenu`, `ComposerMenuList`):** 파일 또는 사진 추가(이미지를 못 받는 하네스는 "파일 추가") · 폴더 추가 |
  슬래시 명령 ▸ · 커넥터 ▸(다시 연결이 필요한 수를 힌트로). 하위 목록은 같은 팝오버에서 "‹ 커넥터"처럼 제목과 뒤로를 둔다. 키:
  ↑↓ 강조, Return·Space 선택, → 목록 열기, ← 뒤로, Escape 닫기(한 번에). 키보드로 열면 첫 행이 강조된다.
- **커넥터 목록(`ComposerConnectorsMenu`):** 커넥터 관리·커넥터 추가 | Yardlet 커넥터(스위치 행 먼저, 로그인이 필요한 행은 "로그인 필요"와 "다시
  연결"/"연결") | "하네스 자체 서버" 제목 아래 하네스가 스스로 불러온 서버(읽기 전용, 상태 한 단어). Yardlet 커넥터가 대신하는
  서버는 "Yardlet 커넥터 사용"(회색, 다시 연결 수에 세지 않음, `ComposerConnectorList.Row.State.yardletStandsIn`)이다. 이 작업에서
  끈 것이 있을 때만 끈 커넥터가 언제 빠지는지 한 줄로 말한다. 오른쪽 세션 레일의 커넥터 카드도 같은 환경
  (`ComposerConnectorEnvironment`)을 쓴다.
  - 작업별 스위치: 끄면 `connectors.json`의 `offInTasks`에 작업별로 남고(Yardlet 재시작 뒤에도), 커넥터를 지우면 그 선택도 지운다.
  - 하네스 자체 서버 행은 읽기 전용이다. 끄려면 하네스 설정 파일을 바꿔야 하기 때문이다("하네스 자체 서버" 절).
  - 다시 연결은 처음부터 로그인하되, 새 로그인을 저장할 때까지 이전 로그인을 쓴다("연결 방식" 절). 클라이언트·토큰이 필요한
    항목은 입력창에서 누르면 설정을 연다.

사람이 할 일(서비스별):

- 동적 등록 OAuth: 커넥터 추가 → "한 번에 연결"에서 그 서비스의 "연결"(또는 "다른 곳에서 쓰는 서비스"의 "Yardlet에서 연결") →
  브라우저에서 로그인·허용.
- 인증 없음: 같은 곳의 "연결". Figma는 먼저 Figma 데스크톱 앱 → Dev Mode에서 MCP 서버를 켠다.
- 키·토큰: "키나 토큰 붙여 넣기"의 "연결" → 서비스에서 토큰이나 키를 만들어 붙여 넣기.
- Google: "Google" 절, Apple(App Store Connect, Mac 셋, Xcode): "Apple" 절, Slack: "Slack" 절, GitHub: "GitHub 로그인" 절.
- 그다음 실행 중인 Claude Code 작업은 다음 턴부터, 다른 하네스의 작업은 다음에 시작하거나 재개하면 도구가 보인다.

## 8. 저장

- `~/.yardlet/connectors.json`: 이름, slug, 서버 주소, 인증 방식, 상태, 도구 목록과 읽은 시각(`toolsUpdatedAt`), 디렉터리 ID
  (`presetID`), 직접 만든 OAuth 클라이언트 ID(`oauthClientID`, 비밀 아님), scope, 추가 인가 인자, 키 쿼리 이름(`tokenQueryParameter`),
  서버 아이콘(`serverIcons`), 작업별로 끈 커넥터(`offInTasks`: 작업 ID → 커넥터 ID). Google 서비스는 `localService`·`account`(주소)·
  `googleAccountID`, 파일 맨 위에 사용자가 저장한 Google 앱의 `googleOAuthClientID`(비밀 아님). Apple 서비스는 `localService`, App
  Store Connect는 `account`(키 ID)도 둔다. 서버 주소는 Mac 셋이 그 데이터를 가진 Mac 앱(`/System/Applications/Calendar.app` 등),
  Xcode가 찾은 `mcpbridge`의 경로다. 비밀은 쓰지 않는다. 예전 파일은 그대로
  읽힌다(새 필드는 없으면 비어 있음).
- Keychain: generic password, service `<번들 ID>.connectors`, account 커넥터 UUID(Google은 계정 로그인의 ID), 값은 JSON(종류
  `oauth`·`token`·`client`·`signingKey`, access·refresh 토큰, 만료, client ID·secret, 토큰 엔드포인트와 인증 방식, resource;
  `signingKey`는 App Store Connect의 키 ID·발급자 ID·PEM). `client`는 로그인 전이나 연결 해제 뒤 직접 만든 클라이언트만 남긴 것이다.
  사용자가 저장한 Google 앱의 ID·secret은 같은 service의 고정 account(`GoogleOAuth.appCredentialID`) 항목 하나다. 빌드에 든 Google
  앱은 Keychain에 쓰지 않는다.
- ad-hoc 빌드도 identifier 기반 designated requirement라서 업데이트 뒤에도 키체인 허용 창이 뜨지 않는다. QA 번들은 번들 ID가 달라
  항목이 섞이지 않는다.
- Keychain 호출은 메인 스레드 밖에서 한다. 키체인이 시스템 창을 기다리는 동안 화면이 멈추지 않게 하려는 것이다.
- 연결 해제는 토큰을 지운다(직접 만든 클라이언트는 남김). 제거는 Keychain 항목을 지운다. 서버에 토큰 폐기(RFC 7009)를 요청하지는
  않는다. macOS가 Mac 셋에 준 권한은 제거해도 남는다("Apple" 절).
- 아이콘 캐시는 `~/Library/Caches/<번들 ID>/ConnectorIcons/`에 있다("아이콘" 절).

## 9. Google

Gmail·Google Calendar·Google Drive는 원격 MCP 서버가 아니라 Yardlet이 앱 안에서 돌리는 서버다. 하네스는 다른 커넥터와 같이
`yardlet` MCP 서버(`yardlet-mcp` → 소켓 → 앱)로 받으므로, 토큰이 Yardlet 밖으로 나가지 않고 주입·작업별 스위치·Antigravity 제외도
같다. 도구 이름과 인자는 Google 공식 MCP 서버(claude.ai의 Google 커넥터가 쓰는 것)를 따랐다. Google Drive 커넥터는 Docs·Sheets·Slides
파일 안의 구조를 읽고 고치는 도구도 준다(아래 "도구").

### Google 앱

- **빌드에 든 앱:** `scripts/build-app.sh`가 환경의 `YARDLET_GOOGLE_CLIENT_ID`·`YARDLET_GOOGLE_CLIENT_SECRET`, 없으면
  `Packaging/GoogleOAuthClient.json`(Google이 내려주는 `{"installed": {...}}` 모양이나 `{"client_id", "client_secret"}`, 예시는
  `Packaging/GoogleOAuthClient.example.json`)을 읽어 번들의 Info.plist에 `YardletGoogleOAuthClientID`·`YardletGoogleOAuthClientSecret`을
  넣는다. 파일은 `.gitignore`에 있고, 값은 로그에 찍지 않는다(넣었는지만). 데스크톱 클라이언트의 secret은 설치형 앱 안에 들어가므로
  Google도 비밀로 보지 않지만, 저장소에는 넣지 않는다. 다른 사람이 자기 클라이언트로 빌드할 수 있게 하려는 것이다.
- `GoogleOAuth.BuiltInApp.from(info:)`가 Info.plist에서 읽고(공백 정리, ID가 없으면 없음), `ConnectorCenter.Environment.googleBuiltInApp`
  으로 들어간다. `swift run`이나 검사처럼 Info.plist가 없으면 없음이다.
- **로그인에 쓰는 앱:** 사용자가 저장한 앱(Keychain `appCredentialID`)이 있으면 그것, 없으면 빌드에 든 앱, 둘 다 없으면 없음
  (`noApp`). `canSignInWithGoogle`이 로그인·계정 추가·연결 단추를 켠다. 계정의 자격 증명에는 로그인한 클라이언트가 남으므로, 앱을
  바꿔도 이미 로그인한 계정은 자기 클라이언트로 계속 갱신한다(옛 클라이언트를 Google Cloud에서 지우면 "로그인 필요").
- **Google 페이지:** 빌드에 든 앱이 있고 사용자 앱이 없으면 단계는 "Google 계정마다 로그인" 하나와 서비스 체크·"Google로 로그인"이다.
  그 아래에 확인 전 앱의 경고 안내와 "직접 만든 Google OAuth 앱 쓰기…" 링크가 있고, 링크를 누르면 일곱 단계("직접 만든 Google 앱")가
  열린다. 사용자 앱을 저장하면 그 앱이 쓰이고, 제거하면 다시 빌드에 든 앱이다. 앱이 저장되면 단계는 한 줄("Google OAuth 앱이
  키체인에 저장됨 · client ID", 설정 단계·변경…)로 접힌다.
- **Google의 정책(공식 문서):** 민감·제한 범위를 요청하는 앱은 Google 확인을 받기 전까지 계정마다 첫 로그인에 "확인되지 않은 앱"
  화면을 보이고, 새 사용자 100명으로 제한된다. 게시 상태가 "테스트"인 외부 앱의 refresh 토큰은 7일 뒤 만료된다. "프로덕션
  단계"에는 고정 만료가 없고, 대신 사용자가 접근을 취소했을 때, 6개월 동안 쓰지 않았을 때, Gmail 범위가 든 토큰은 비밀번호를
  바꿨을 때, 한 계정·한 클라이언트에 refresh 토큰이 100개를 넘을 때(가장 오래된 것부터) 무효가 된다.

### 계정과 서비스

- Google 서비스는 `LocalConnectorService`의 `gmail`·`googleCalendar`(`google-calendar`)·`googleDrive`(`google-drive`) 셋이다
  (`LocalConnectorService.google`, `isGoogle`; 나머지는 Apple 서비스, "Apple" 절). 디렉터리 항목은 `SignIn.googleAccount`, 주소는
  `https://gmail.googleapis.com/gmail/v1/`·`https://www.googleapis.com/calendar/v3/`·`…/drive/v3/`이다.
- **계정 하나, 서비스마다 커넥터 하나:** Google 계정의 서비스는 각자 `ConnectorRecord`(작업별 스위치·도구 줄·다시 연결이 서비스마다)이고
  로그인은 하나를 나눠 쓴다: `ConnectorRecord.googleAccountID`(그 계정 로그인의 Keychain 항목), `credentialID = googleAccountID ?? id`.
  계정의 첫 서비스는 자기 ID 아래에 둔다. `ConnectorCenter.googleAccounts`가 `credentialID`로 묶는다.
- **로그인 한 번:** 고정 루프백 `127.0.0.1:47823/callback` → 기본 브라우저로 `accounts.google.com/o/oauth2/v2/auth`. 그 계정에서 켠
  서비스의 범위를 모두(디렉터리 순서) 한 번에 요청하고 `include_granted_scopes=true`, `access_type=offline`, 새 계정은
  `prompt=select_account consent`, 다시 로그인은 `prompt=consent`와 `login_hint=주소`, PKCE S256, `state`를 보낸다(`resource`는 보내지
  않음). 토큰은 `oauth2.googleapis.com/token`에 secret을 폼으로 보내 받는다. refresh 토큰이 없으면 실패로 말한다.
- **계정 주소:** Gmail 프로필의 `emailAddress`, 없으면 기본 캘린더(`users/me/calendarList/primary`의 `id`), 없으면 Drive `about`의
  `user.emailAddress`로 정한다(범위를 더 요청하지 않음). 이미 있는 주소면 그 계정에 합친다(이미 있는 서비스는 새 행을 버림).
  새 로그인은 따로 된 세션으로 주소를 읽은 뒤에야 저장한다. 그래서 다시 연결에 다른 계정이 오면 그 로그인은 저장하지 않고 이유만
  두며, 계정의 이전 로그인·상태·도구는 그대로다(연결된 계정이면 "연결됨"과 이유 한 줄). 첫 로그인을 사용자가 Yardlet이나 Google
  페이지에서 취소하면 그 행을 지우고, 다시 연결을 취소하면 아무것도 바뀌지 않는다. 그 밖의 실패는 이유와 함께 남긴다.
- **일부만 허용:** 세분화 동의에서 한 서비스를 빼면 그 서비스만 "로그인 필요"와 "Google이 Google Drive 접근을 허용하지 않았습니다"
  같은 이유이고 도구가 빠진다. 아무것도 허용하지 않으면 로그인이 아니다.
- **켜고 끄기:** 켜기는 로그인이 이미 그 범위를 가지면 바로 연결, 아니면 그 계정만 다시 동의한다(점진적 인가). 끄기는 그 서비스의
  커넥터를 지우고, 로그인은 다른 서비스가 쓰는 동안 남긴다(첫 서비스를 꺼도). 마지막 서비스와 함께 Keychain 항목이 지워진다.
  Google에서 범위를 취소하지는 않는다(사용자가 Google 계정의 "서드파티 액세스"에서 취소).
- **이름:** 첫 계정의 slug는 `gmail`·`calendar`·`drive`, 그 이름이 이미 있으면 주소 앞부분을 붙인다(`gmail_<앞부분>`). 도구 제목·설명은
  `Gmail · 주소: …`, `[Gmail · 주소] …`. 도구 목록은 앱에 들어 있어 서버에 묻지 않는다.
- **갱신(`GoogleAPISession`):** 만료 1분 전이면 호출 전에, 401이면 한 번 갱신하고 다시 보낸다. 갱신은 계정마다 한 번에 하나다.
  Google이 refresh를 `invalid_grant`로 거절하면(접근 취소, 6개월 미사용, 비밀번호 변경, 테스트 상태 7일) 그 계정은 "로그인 필요"가 되고
  설정·입력창에 "다시 연결"이 보이며, 호출은 "다시 로그인하라"는 도구 오류다. 네트워크 실패는 그 호출의 오류일 뿐 상태를 바꾸지 않는다.
- **다시 연결·제거:** Google 서비스의 다시 연결은 계정 전체를 다시 로그인한다. 제거는 그 서비스만, "이 Google 계정 제거"는 계정
  전체다. Google에 토큰 폐기는 요청하지 않는다.
- Google 계정 행: 주소, 서비스 칩 셋(켜짐/꺼짐과 상태), 필요할 때 다시 연결·`…`. 아래에 "Yardlet이 Google에 요청하는 범위"(범위와
  분류)가 있다.

### 범위

| 서비스 | 범위 | 분류 | 왜 |
|---|---|---|---|
| Gmail | `gmail.modify` | 제한 | 읽기·임시보관·보내기·라벨. 라벨 바꾸기(`threads.modify`·`messages.modify`)는 `mail.google.com`과 `gmail.modify`만 받는다. 영구 삭제는 없다 |
| Calendar | `calendar.calendarlist.readonly` | 민감 | `list_calendars`(calendarList.list) |
| Calendar | `calendar.events` | 민감 | 모든 캘린더의 일정 읽기·만들기·바꾸기·지우기·답하기 |
| Calendar | `calendar.events.freebusy` | 민감 | `suggest_time`(freeBusy.query) |
| Drive | `drive.readonly` | 제한 | 모든 파일 읽기·내보내기, Docs·Sheets·Slides 안의 구조 읽기 |
| Drive | `drive.file` | 비민감 | 만들기·복사, Yardlet이 만든 파일만 바꾸기(Docs·Sheets·Slides 고치기 포함) |

- 범위는 앞에 `https://www.googleapis.com/auth/`가 붙는다. 전체 `drive`·`calendar`·`https://mail.google.com/`은 요청하지 않는다.
  그래서 Yardlet은 사람이 가진 다른 Drive 파일을 바꾸거나 지울 수 없고, Drive 도구에 지우기는 없다.
- **Docs·Sheets·Slides도 Drive의 두 범위로 부른다.** 읽는 메서드(Docs `documents.get`, Sheets `spreadsheets.get`·
  `spreadsheets.values.get`, Slides `presentations.get`·`presentations.pages.get`·`presentations.pages.getThumbnail`)는 `drive.readonly`를,
  고치는 메서드(Docs `documents.batchUpdate`, Sheets `spreadsheets.values.update`·`spreadsheets.batchUpdate`, Slides
  `presentations.batchUpdate`)는 `drive.file`을 받는다(메서드마다 "Authorization scopes"). 그래서 `documents`·`spreadsheets`·
  `presentations` 범위(민감)는 요청하지 않고, 이 도구들 때문에 동의 화면의 범위가 늘지 않는다.
- **고칠 수 있는 Docs·Sheets·Slides:** `drive.file`은 앱으로 만들었거나 앱으로 연 파일, Google Picker나 앱의 파일 선택기로 앱에
  공유한 파일에만 닿는다. Yardlet에는 Picker가 없으므로 고칠 수 있는 것은 Yardlet이 만들거나 복사한 파일이다. 다른 파일은 Google의
  403("The caller does not have permission")이 그대로 도구 오류가 된다. 그런 파일은 `copy_file`로 사본을 만들어 고친다.
- **API 켜기:** 범위와 따로, OAuth 클라이언트가 속한 Cloud 프로젝트에서 Docs API(`docs.googleapis.com`)·Sheets API
  (`sheets.googleapis.com`)·Slides API(`slides.googleapis.com`)가 켜져 있어야 한다. 꺼져 있으면 Google의 403("… API has not been used
  in project … before or it is disabled")이 그 도구의 오류가 된다. API를 켜도 범위와 동의 화면은 바뀌지 않는다. "직접 만든 Google
  앱"의 API 단계는 여섯 API를 한 페이지에서 켠다(`ConnectorSetupAssistant.googleAPIs`).
- 출처: 제한 범위 목록 support.google.com/cloud/answer/13464325, Gmail 범위 developers.google.com/workspace/gmail/api/auth/scopes,
  Drive 범위 developers.google.com/workspace/drive/api/guides/api-specific-auth, Calendar 범위 developers.google.com/workspace/calendar/api/auth
  (분류 열이 없다; 제한 목록에 없고 Cloud 콘솔이 민감으로 표시한다), Docs·Sheets·Slides 메서드
  developers.google.com/workspace/docs/api/reference/rest/v1/documents, …/sheets/api/reference/rest/v4/spreadsheets,
  …/slides/api/reference/rest/v1/presentations, 그 범위의 분류 …/docs/api/auth, …/sheets/api/scopes, …/slides/api/scopes.

### 도구

Gmail(`GmailToolCatalog`, `GmailToolRunner`, Gmail API v1):

| 도구 | Gmail API | 하는 일 |
|---|---|---|
| `search_threads` | `GET users/me/threads?q&maxResults&pageToken&includeSpamTrash` + 스레드마다 `threads/{id}?format=metadata` | Gmail 검색 문법, 한 쪽 1–50(기본 20). 스레드 ID, 메시지 수, 최근 10개의 보낸 사람·받는 사람·날짜·제목·snippet·라벨·안 읽음. 본문 없음. 스레드 조회는 5개씩 동시 |
| `get_thread` | `GET users/me/threads/{id}?format=full` 또는 `metadata` | `messageFormat`: `PLAIN_TEXT`(기본: 본문 텍스트·첨부 이름), `FULL_CONTENT`(+HTML), `MINIMAL`, `METADATA_ONLY` |
| `get_message` | `GET users/me/messages/{id}` | 같은 형식 |
| `list_labels` | `GET users/me/labels` | id·name·type |
| `create_draft` | `POST users/me/drafts` | to·cc·bcc·subject·body·htmlBody·replyToMessageId. 답장이면 그 스레드, `In-Reply-To`·`References`, "Re:" 제목, 받는 사람이 없으면 Reply-To·From |
| `send_draft` | `POST users/me/drafts/send` | 임시보관 ID |
| `send_message` | `POST users/me/messages/send` | create_draft와 같은 칸, 받는 사람 필수 |
| `modify_labels` | `POST users/me/threads/{id}/modify` 또는 `messages/{id}/modify` | `threadId`나 `messageId` 하나 + `addLabelIds`·`removeLabelIds`. INBOX 제거 = 보관, UNREAD 제거·추가 = 읽음·안 읽음 |

- 본문: 파트의 charset(EUC-KR 등)대로 디코드, HTML만 있으면 텍스트로, 메시지당 40,000자. 보내는 메일은 UTF-8 base64 본문, 비ASCII
  제목·표시 이름은 RFC 2047, HTML은 텍스트 파트와 함께 `multipart/alternative`. 주소에 줄바꿈·쉼표가 있으면 보내기 전에 거절한다
  (헤더 주입). From은 Gmail이 채운다.
- 라벨은 claude.ai 쪽의 다섯 도구 대신 `modify_labels` 하나다.

Calendar(`GoogleCalendarToolRunner`, Calendar API v3):

| 도구 | API | 메모 |
|---|---|---|
| `list_calendars` | `GET users/me/calendarList` | id·이름(사용자가 바꾼 이름 먼저)·시간대·권한·primary |
| `list_events` | `GET calendars/{id}/events` | `singleEvents=true`, 기본 지금부터 7일, `orderBy` startTime·updated(startTimeDesc는 그 쪽을 뒤집음), `q`=fullText, `eventTypes`, 최대 250 |
| `search_events` | `GET calendars/primary/events?q=` | 앞뒤 1년, 시작 순. Google MCP는 의미 검색이지만 공개 API는 단어 검색이다 |
| `get_event` | `GET calendars/{id}/events/{id}` | |
| `suggest_time` | `POST freeBusy` | 계정(`primary`)과 참석자의 바쁜 시간을 합치고, 근무 시간·주말 제외 안에서 15분 단위로, 한 시간 간격, 기본 5개. 볼 수 없는 캘린더는 `unavailableCalendars` |
| `create_event` | `POST calendars/{id}/events` | 시간대·종일(끝 날 포함)·참석자·Meet(`conferenceDataVersion=1`)·반복·알림·바쁨/한가함·공개 범위, `sendUpdates` 기본 all |
| `update_event` | `PATCH …/events/{id}` | 바꾼 칸만. 시작만 옮기면 길이 유지, 참석자는 이메일로 더하고 빼기(그때 먼저 GET) |
| `delete_event` | `DELETE …/events/{id}` | |
| `respond_to_event` | GET 뒤 `PATCH attendees` | 계정 자신의 참석자 항목만 바꾼다. 초대받지 않은 일정은 오류 |

- 시간: 오프셋 없는 시각(`2026-04-30T10:00:00`)은 인자 `timeZone`, 없으면 이 Mac의 시간대로 읽고, Google에는 오프셋과 `timeZone`을
  함께 보낸다. 인자 이름은 Google MCP의 것(`calendarId`·`startTime`·`attendeeEmails`·`addGoogleMeetUrl`·`notificationLevel` 등)이다.

Drive(`GoogleDriveToolRunner`, Drive API v3, `supportsAllDrives`):

| 도구 | API | 메모 |
|---|---|---|
| `search_files` | `GET files?q=` | Google MCP의 질의 용어를 Drive 말로: `title`→`name`, `parentId = 'x'`→`'x' in parents`, `owner = 'x'`→`'x' in owners`, `!=`는 `not`. 연산자 없는 말은 `fullText contains`. 휴지통 제외 |
| `list_recent_files` | `GET files?orderBy=` | recency·lastModified(`modifiedTime desc`)·lastModifiedByMe |
| `get_file_metadata` | `GET files/{id}` | Google MCP 이름(`title`·`fileSize`·`owner`·`parentId`·`viewUrl`) |
| `get_file_permissions` | `GET files/{id}/permissions` | |
| `read_file_content` | 내보내기·`alt=media` | Docs는 Markdown(안 되면 텍스트), Sheets는 첫 시트 CSV, Slides는 텍스트, 텍스트 파일은 그대로, 100,000자에서 자름, `includeComments`면 댓글 스레드. PDF·Office·이미지는 "download_file_content를 쓰라"는 오류(Google MCP는 읽어 주지만 공개 API에는 없다) |
| `download_file_content` | 내보내기·`alt=media`·revisions | base64, 5 MB까지(크기를 먼저 보고 거절) |
| `create_file` | multipart 올리기 또는 메타데이터만 | 텍스트·CSV·Office는 Google 형식으로 바꿈(`disableConversionToGoogleType`), 내용 없으면 빈 Docs/Sheets/Slides/폴더 |
| `copy_file` | `POST files/{id}/copy` | |
| `update_file` | `PATCH` (multipart) | Yardlet 추가 도구: 이름·설명·폴더·내용. `drive.file`이라 Yardlet이 만들거나 복사한 파일만 바뀌고, 다른 파일은 Google의 403 문구가 그대로 오류가 된다 |

Docs·Sheets·Slides(`GoogleEditorsToolCatalog`, `GoogleEditorsToolRunner`, Docs API v1·Sheets API v4·Slides API v1):

- **Drive 커넥터의 도구다.** 범위가 Drive와 같고 파일이 Drive 파일이라 서비스 행·칩·로그인·작업별 스위치가 따로 없다. Drive
  커넥터는 위 아홉과 이 열두, 모두 21개(`drive_*`)를 준다. 첫 계정은 `drive_read_doc`, 다음 계정은 `drive_<앞부분>_read_doc`이다.
- **이름과 인자:** Google 공식 Docs·Sheets·Slides MCP 서버(`docsmcp`·`sheetsmcp`·`slidesmcp.googleapis.com`)의 도구 이름과 인자 이름
  (`documentId`·`requests`·`writeControl`·`spreadsheetId`·`range`·`values`·`formulas`·`sheetId`·`presentationId`·`pageId`·`fields`·
  `commentsIncluded`·`thumbnailProperties`)을 따랐다. 나눠 읽기 인자와 `valueRenderOption`은 Yardlet이 더한 것이다.

| 도구 | API | 메모 |
|---|---|---|
| `read_doc` | `GET documents/{id}?includeTabsContent=true` | 문단마다 시작·끝 색인(UTF-16), 글, 스타일(`HEADING_1`…; 보통 글은 생략), 목록(`listId`·`nestingLevel`), 웹 링크. 표는 칸마다 글과 그 글의 색인. 이미지·각주 표시 같은 개체는 색인 하나마다 U+FFFC라 글 길이가 색인 길이와 같다. 탭이 여럿이면 `tabs` 목록과 `tabId`로 고르기(하위 탭 포함). `revisionId`, `commentsIncluded`면 Drive 댓글 |
| `update_doc` | `POST documents/{id}:batchUpdate` | 요청 목록 그대로(`insertText`·`deleteContentRange`·`replaceAllText`·`updateParagraphStyle`·`createParagraphBullets`·`insertTable` 등), 전부 아니면 아무것도. `writeControl`(`requiredRevisionId`, `writeMode: SUGGEST`)도 그대로 |
| `get_spreadsheet` | `GET spreadsheets/{id}` | 기본은 필드 마스크로 제목·로캘·시간대·시트마다 ID·이름·크기·고정 행/열·숨김·종류, 이름 있는 범위. `fields`나 `includeGridData`면 Sheets API의 JSON 그대로(100,000자를 넘으면 범위를 좁히라는 오류) |
| `get_values` | `GET spreadsheets/{id}/values/{range}` | 행 단위. `valueRenderOption` `FORMATTED_VALUE`(기본)·`UNFORMATTED_VALUE`·`FORMULA`(수식 읽기) |
| `update_values` | `PUT …/values/{range}?valueInputOption=RAW` | 값 그대로: 숫자는 숫자, `=`로 시작하는 글도 글. null은 그 칸을 두고, `""`는 비운다 |
| `update_formulas` | `PUT …/values/{range}?valueInputOption=USER_ENTERED` | 수식과 사람이 입력하듯 읽힐 값 |
| `insert_dimension` | `POST spreadsheets/{id}:batchUpdate`(`insertDimension`) | 빈 행·열 넣기(0부터, 끝은 포함 안 함) |
| `update_spreadsheet` | `POST spreadsheets/{id}:batchUpdate` | 요청 목록 그대로(`addSheet`·`deleteSheet`·`updateSheetProperties`·`repeatCell`·`mergeCells`·`sortRange` 등). 답의 `replies`(새 시트 ID 등) |
| `read_presentation` | `GET presentations/{id}?fields=…` | 슬라이드마다 ID·순서·레이아웃 이름·건너뜀, 요소마다 ID·종류(shape·table·image·group·sheetsChart·wordArt…)·자리 표시자(`TITLE`·`BODY`)·글, 표는 칸 글, 발표자 노트와 그 개체 ID. `fields`면 Slides API의 JSON 그대로 |
| `read_slide_page` | `GET presentations/{id}/pages/{pageId}` | 한 쪽(슬라이드·레이아웃·마스터)의 요소에 크기·위치(`size`·`transform`)까지 |
| `read_slide_page_thumbnail` | `GET …/pages/{pageId}/thumbnail` | PNG, `thumbnailProperties.thumbnailSize`(SMALL·MEDIUM·LARGE, 기본 MEDIUM). 크기와 주소, 그리고 PNG 자체를 이미지 내용으로(5 MB까지). 그림 주소는 Google이 계정용으로 서명한 30분짜리라 Google 토큰을 붙이지 않고 받는다 |
| `update_presentation` | `POST presentations/{id}:batchUpdate` | 요청 목록 그대로(`createSlide`·`insertText`·`deleteText`·`replaceAllText`·`createShape`·`updateTextStyle`·`deleteObject` 등), `writeControl` |

- **나눠 읽기:** 답이 100,000자(`read_file_content`와 같은 한도)를 넘지 않게 자른다. 문서는 요소 단위로 자르고 `nextStartIndex`를
  준다(`startIndex`로 다시 부름; 표는 행 단위로 이어지고, 처음이 아니면 `firstRow`). 시트는 행 단위로 `rowsReturned`와, Google이
  돌려준 범위에서 계산한 `nextRange`를 준다(예: `Data!A1:D3000`에서 1,850행을 주면 `Data!A1851:D3000`). 슬라이드는 장 단위로
  `nextStartSlide`를 준다(`startSlide`로 다시 부름).
- **ID:** 링크(`…/document/d/<ID>/edit`)를 넣어도 ID만 쓴다. 요청 전에 인자를 확인한다(빈 `requests`, 칸이 배열이 아닌 행, 시작
  이상인 끝, 틀린 `valueRenderOption`은 요청 없이 오류).
- 고치는 도구가 닿는 파일과 켜야 하는 API는 "범위"에 있다.

- 설명은 하는 일만 260자 아래다. 주석은 읽기 `readOnlyHint: true`·`openWorldHint: false`, 보내기와 쓰기는 `openWorldHint: true`,
  `modify_labels`·`delete_event`·`update_file`과 `insert_dimension`을 뺀 Docs·Sheets·Slides 쓰기는 `destructiveHint: true`다.
- 본문·요청·응답을 로그에 쓰지 않는다. 오류는 Google의 `error.message`와 HTTP 상태만 보인다("Gmail: Requested entity was not found.
  (HTTP 404)").

### 하네스가 묻기

- 묻는 도구는 하네스의 승인 설정을 따른다. Yardlet은 승인 규칙을 따로 두지 않고, 쓰기 도구에 주석(`destructiveHint` 등)을 단다.
- Claude Code: 커넥터 도구는 `--allowedTools`에 없으므로 CLI가 작업의 권한 모드대로 묻는다. 쓰기 도구(Gmail `send_draft`·
  `send_message`·`modify_labels`, Calendar `create_event`·`update_event`·`delete_event`·`respond_to_event`, Drive `create_file`·
  `copy_file`·`update_file`·`update_doc`·`update_values`·`update_formulas`·`insert_dimension`·`update_spreadsheet`·
  `update_presentation`; `LocalConnectorService.approvalRequiredTools`)의 요청 카드는 Yardlet 문구이고 "항상 허용"이 없다
  (`GmailToolApproval`, `GoogleToolApproval`): 메일은 받는 사람·참조·숨은 참조·제목·본문 앞 1,200자, 라벨은 스레드·추가·제거·
  보관/읽음/안 읽음, 일정은 제목·일시·초대·Meet·Google이 메일을 보내는지, Drive는 제목·유형·폴더·내용 앞 600자. Docs·Sheets·Slides는
  "Claude가 {주소}의 Drive 문서를(스프레드시트를, 프레젠테이션을) 바꾸도록 허용할까요?" 아래 파일 ID, 범위, 바꿀 것("insertText ×2,
  updateParagraphStyle"), 넣는 글이나 칸 값 앞 600자이고, 행·열 넣기는 "행 2개를 넣습니다."처럼 수를 말한다. 나머지는 CLI의 보통
  카드다. 권한 우회 모드에서는 묻지 않는다(하네스 그대로).
- Codex: Yardlet 서버의 도구에 `approval_mode`를 넣지 않는다. 묻는지는 작업의 승인 설정과 도구 주석으로 Codex가 정한다.
- ACP: 그 하네스의 MCP 승인 그대로.

### 직접 만든 Google 앱

빌드에 Google 앱이 없거나 자기 앱을 쓰려는 사람은 Google Cloud에 OAuth 앱을 하나 만든다. 설정 → 커넥터 → "한 번에 설정"의 Google이
아래 단계를 차례로 연다.

1. **새 프로젝트**(console.cloud.google.com/projectcreate)에서 프로젝트 만들기.
2. **API 켜기**: 한 페이지(`flows/enableapi?apiid=gmail.googleapis.com,calendar-json.googleapis.com,drive.googleapis.com,docs.googleapis.com,sheets.googleapis.com,slides.googleapis.com`)에서
   여섯 API를 켠다. 뒤의 셋은 Drive 커넥터의 Docs·Sheets·Slides 도구가 쓴다.
3. **Google 인증 플랫폼**: 앱 이름(복사 버튼), 지원 이메일, 대상, 연락처. 개인 Gmail 계정을 쓰려면 대상은 **외부**다. 한 Workspace
   조직의 계정만 쓰고 프로젝트가 그 조직 안에 있으면 **내부**도 된다(확인 화면과 100명 한도가 없음).
4. **대상** → 앱 게시 → "프로덕션 단계"(외부일 때). "테스트"로 두면 7일마다 다시 로그인해야 한다.
5. **데이터 액세스** → 범위 추가 또는 삭제 → 수동으로 범위 추가에 범위 여섯(복사 버튼)을 붙여 넣고 업데이트·저장.
6. **클라이언트 만들기**: 유형 데스크톱 앱 → client ID와 보안 비밀을 Yardlet 칸에 붙여 넣고(형식 확인) **저장**. 웹 애플리케이션으로
   만든다면 승인된 리디렉션 URI에 `http://127.0.0.1:47823/callback`을 넣는다.
7. 서비스를 고르고 **Google로 로그인** → 계정 선택 → "확인되지 않은 앱"에서 고급 → 이동 → 서비스 허용. 두 번째 계정은 **다른 Google
   계정 추가**. 계정마다 서비스 칩으로 켜고 끈다.

Workspace 관리 콘솔에서 확인되지 않은 서드파티 앱의 Gmail 접근을 막아 두었다면 로그인이 거절된다. 그때는 관리 콘솔(보안 → API 제어)
에서 이 앱의 client ID를 신뢰 목록에 넣거나, 그 조직 전용으로 내부 앱을 쓴다.

### 없는 것

- Gmail: 첨부 내려받기·첨부해 보내기, 휴지통·스팸, 라벨 만들기·고치기, 임시보관 목록·수정·삭제.
- Drive: PDF·Office·이미지 본문 읽기(내려받아 따로 읽어야 함), 파일 지우기, 공유 바꾸기.
- Docs·Sheets·Slides: Yardlet이 만들거나 복사하지 않은 파일을 그 자리에서 고치기. 그러려면 `documents`·`spreadsheets`·`presentations`
  범위(민감)나 전체 `drive`(제한)를 더 요청하거나, 사람이 파일을 고르는 Google Picker 화면이 있어야 한다. 지금은 사본을 고친다.
- Calendar: `search_events`는 의미 검색이 아니라 단어 검색이다. 시간대는 이 Mac의 것이다(캘린더 설정의 시간대를 읽으려면 범위가 더
  필요).

## 10. Apple

App Store Connect, Mac의 캘린더·미리 알림·연락처, Xcode도 원격 MCP 서버가 아니라 Yardlet이 앱 안에서 돌리는 서버다
(`LocalConnectorService`의 `appStoreConnect`·`appleCalendar`·`appleReminders`·`appleContacts`·`xcode`). Google처럼 `yardlet` MCP 서버
하나로 모든 하네스·계정의 작업에 들어가고, 작업별 스위치·도구 줄 이름표·Antigravity 제외가 다른 커넥터와 같다.

### 구조

| 커넥터 | 디렉터리 로그인 방식 | 무엇을 부르나 | 도구 이름 |
|---|---|---|---|
| App Store Connect | `appStoreConnectKey`(API 키) | Apple의 App Store Connect API(`https://api.appstoreconnect.apple.com/`, JSON:API) | `app_store_connect_*`, 키를 둘 넣으면 두 번째는 `app_store_connect2_*` |
| Apple Calendar | `macPermission`(macOS 권한) | EventKit(`EKEventStore`)의 캘린더 | `apple_calendar_*` |
| Apple Reminders | `macPermission` | EventKit의 미리 알림 | `apple_reminders_*` |
| Apple Contacts | `macPermission` | Contacts(`CNContactStore`) | `apple_contacts_*` |
| Xcode | `localApp`(이 Mac의 앱) | Xcode의 MCP 서버(Xcode 26.3부터), stdio 다리 `mcpbridge`를 거쳐 | `xcode_<Xcode의 도구 이름>`(`xcode_BuildProject`) |

- App Store Connect와 Mac 셋의 도구는 앱에 들어 있어 서버에 묻지 않는다. Xcode의 도구는 Xcode 서버가 주는 목록 그대로이고, 연결할
  때 읽어 `connectors.json`에 둔다. 도구 설명은 260자 아래다.
- 아이콘: Mac 셋과 Xcode는 macOS가 그 앱에 주는 아이콘(네트워크 없음), App Store Connect는 Apple 개발자 사이트의 아이콘("아이콘" 절).

### App Store Connect

- Apple의 공식 API를 Yardlet이 사람의 API 키로 직접 부른다. 다른 회사의 MCP 서버를 거치지 않는다.
- **키 종류**(Apple "Creating API Keys for App Store Connect API"): 팀 키는 Account Holder·Admin만 만들고, 만들 때 역할을 고르며 모든
  앱에 닿는다. 개인 키는 그 사용자의 권한을 따르고 인증서·프로필, 판매·재무, 공증(`notaryTool`)에 쓸 수 없다. `.p8` 파일은 한 번만
  내려받을 수 있다.
- **토큰**(Apple "Generating Tokens for API Requests"): 머리 `alg: ES256`·`kid`(키 ID)·`typ: JWT`, 본문 `aud: appstoreconnect-v1`·`iat`·
  `exp`, 팀 키는 `iss`(발급자 ID), 개인 키는 `sub: "user"`이고 `iss`가 없다. Apple의 수명 한도가 20분이라 15분짜리로 만들고 끝나기
  1분 전에 새로 만든다. 서명은 P-256의 R‖S(64바이트)다. 엔진에는 계약(`ES256Signing`)만 있고 CryptoKit 구현(`MacES256Signer`)은
  macOS 층에 있다. 서명할 수 없는 빌드에는 디렉터리에 App Store Connect가 없다.
- **거절:** 401이면 새 토큰으로 한 번 더 보낸다. 또 401이면 키가 취소됐거나 ID가 틀린 것이라 커넥터는 "로그인 필요"가 되고, 행의 할
  일은 키를 다시 넣는 페이지를 여는 "설정…"이다.
- **키 저장:** 페이지에서 고른 `.p8` 파일을 "연결"을 누를 때 읽어 키인지 확인한 뒤 Keychain에 둔다("저장" 절의 `signingKey`).
  `connectors.json`에는 키 ID만 있다. 키 값은 화면·로그·모델·일반 파일에 없다. 앱 목록을 한 번(`GET /v1/apps?limit=1`) 읽어 키를
  확인하고, 되면 페이지 안의 한 줄로 그 `.p8` 파일을 휴지통으로 옮길지 묻는다(휴지통으로 옮기기·파일 그대로 두기). 시트 위에
  대화상자를 겹치지 않는다. 키 ID는 파일 이름(`AuthKey_<키 ID>.p8`)에서 채운다. 같은 키 ID를 다시 넣으면 그 키를 바꾼다.
- **도구 14개**(읽기 9, 쓰기 5, `AppStoreConnectToolCatalog`, `AppStoreConnectToolRunner`):

| 도구 | API | 메모 |
|---|---|---|
| `list_apps` | `GET /v1/apps` | 이름·번들 ID·SKU·기본 언어, `bundleId`·`name` 거르기 |
| `list_builds` | `GET /v1/builds?filter[app]` + `include=preReleaseVersion,buildBetaDetail` | 최근 올린 것 먼저. `version`(마케팅 버전)·`buildNumber`·처리 상태·만료·TestFlight 내부/외부 상태 |
| `list_beta_groups` | `GET /v1/betaGroups?filter[app]` | 내부·외부, 공개 링크 |
| `list_beta_testers` | `GET /v1/betaTesters?filter[betaGroups]` 또는 `filter[apps]` | 이름·이메일·초대 방식·상태 |
| `list_beta_feedback` | `GET /v1/apps/{id}/betaFeedbackScreenshotSubmissions`·`…CrashSubmissions` | 둘을 합쳐 최신순, 기기·빌드·댓글·스크린샷 주소 |
| `get_beta_crash_log` | `GET /v1/betaFeedbackCrashSubmissions/{id}/crashLog` | `logText` 100,000자까지 |
| `list_customer_reviews` | `GET /v1/apps/{id}/customerReviews?include=response` | 별점·국가·답글 여부 거르기, 최신·오래된·높은·낮은 순 |
| `list_app_store_versions` | `GET /v1/apps/{id}/appStoreVersions?include=build` | `appVersionState`(심사 중·거절·배포 준비…)·출시 방식·빌드 |
| `list_review_submissions` | `GET /v1/reviewSubmissions?filter[app]` | 제출 상태와 든 버전 |
| `add_beta_tester` | `POST /v1/betaTesters`(새 이메일, Apple이 초대 메일을 보냄) 또는 `POST /v1/betaGroups/{id}/relationships/betaTesters` | 묻는 도구 |
| `remove_beta_tester` | `DELETE /v1/betaGroups/{id}/relationships/betaTesters` | 묻는 도구, destructive |
| `add_build_to_group` | `POST /v1/betaGroups/{id}/relationships/builds` | 묻는 도구. 외부 그룹은 베타 심사 승인 뒤에 받는다 |
| `reply_to_review` | `POST /v1/customerReviewResponses` | 묻는 도구. 이전 답글이 있으면 바꾼다 |
| `submit_for_review` | 버전 읽기 → 그 앱·플랫폼의 아직 안 보낸 제출(`READY_FOR_REVIEW`) 또는 새 `POST /v1/reviewSubmissions` → `POST /v1/reviewSubmissionItems` → `PATCH …{submitted: true}` | 묻는 도구. App Store Connect에서 시작해 둔 제출이 이미 그 버전을 가지면(409) 그대로 보낸다 |

- 답은 리소스의 ID와 속성으로 펴고, 다음 쪽은 Apple의 `links.next`에서 꺼낸 `cursor`를 `nextCursor`로 준다. 오류는 Apple의
  `errors[].detail`과 HTTP 상태("App Store Connect: There is no resource of type 'apps' with id '404' (HTTP 404)")이고, 경로에 넣을 수
  없는 ID는 요청 전에 거절한다. 엔드포인트는 Apple의 App Store Connect API OpenAPI 명세(4.5.1)를 따랐다.
- **키의 역할**(Apple "Role permissions", developer.apple.com/support/roles): 심사 제출·외부 TestFlight 그룹과 빌드 배포는 Account
  Holder·Admin·App Manager, 리뷰 답글은 Account Holder·Admin·Customer Support만 된다. 그래서 다섯 쓰기 도구가 모두 되는 하나의 역할은
  Admin이다. App Manager 키로는 `reply_to_review`만 Apple의 403 문구로 실패한다.

### Mac의 캘린더·미리 알림·연락처

- iCloud는 이 데이터의 OAuth API를 열어 두지 않아, Mac이 동기화해 둔 것을 쓴다(`MacDataStoring`, `MacEventKitStore`,
  `MacDataToolRunner`). 캘린더는 Calendar 앱에 있는 iCloud와 다른 계정의 캘린더다. 캘린더·미리 알림은 EventKit(macOS 14부터의
  `requestFullAccessToEvents`·`requestFullAccessToReminders`), 연락처는 Contacts다.
- **권한:** 셋은 따로 켠다. 켤 때(연결) 권한이 정해지지 않았으면 macOS가 한 번 묻고, 이미 허용됐으면 묻지 않는다. 거절했거나 기기
  정책이 막으면 묻지 않고 "macOS가 Yardlet의 캘린더 사용을 허용하지 않았습니다. 시스템 설정 → 개인정보 보호 및 보안 → 캘린더에서
  Yardlet을 켠 뒤 다시 시도하세요."가 이유로 보인다. 도구 호출은 권한을 읽기만 하고 묻지 않는다. 나중에 권한을 끄면 호출이 같은 안내를 돌려준다.
- Info.plist에 사용 설명이 없는 빌드(`swift run`)는 묻지 않는다. macOS는 설명 없이 묻는 앱을 끝내기 때문이다.
- **도구:**
  - Apple Calendar: `list_calendars`, `list_events`(기본 지금부터 7일, 모든 캘린더 또는 하나, 단어 거르기, 4년까지), `search_events`
    (앞뒤 1년), `get_event`, `create_event`·`update_event`·`delete_event`(묻는 도구). 인자 이름은 Google Calendar의 것(`summary`·
    `startTime`·`endTime`·`allDay`·`timeZone`·`calendarId`·`location`·`description`)에 `url`·`alertMinutes`·`span`(반복 일정의
    `thisEvent`·`futureEvents`)을 더했다. EventKit은 참석자를 초대하거나 초대에 답할 수 없어 그 인자와 `respond_to_event`·
    `suggest_time`이 없다. 반복 일정의 한 번은 `<일정 ID>@<원래 시작 UTC>`로 가리킨다. 오프셋 없는 시각은 인자 `timeZone`, 없으면 Mac
    시간대로 읽는다(`CalendarTime`).
  - Apple Reminders: `list_reminder_lists`, `list_reminders`(기본 안 끝난 것, 목록·마감 범위·단어), `create_reminder`(날짜만 또는 날짜와
    시각, 우선순위 none·low·medium·high = EventKit 0·9·5·1), `complete_reminder`(되돌리기는 `completed: false`). 뒤 둘이 묻는 도구다.
  - Apple Contacts: `search_contacts`(이름·이메일·전화번호; `@`가 있으면 이메일, 숫자가 4개 이상이면 전화번호), `get_contact`. 읽기만
    한다. 연락처의 메모는 읽지 않는다(따로 entitlement가 필요하다).
- EventKit 호출은 메인 스레드 밖에서 하고, 저장소는 잠금 하나로 한 번에 하나씩 다룬다.
- **앱 묶음:** Info.plist에 `NSCalendarsFullAccessUsageDescription`·`NSRemindersFullAccessUsageDescription`·`NSContactsUsageDescription`
  (영어), `ko.lproj/InfoPlist.strings`에 한국어. `Packaging/Entitlements/Yardlet.entitlements`에 하드닝 런타임의
  `com.apple.security.personal-information.calendars`(미리 알림 포함)·`com.apple.security.personal-information.addressbook`. Yardlet이
  띄운 명령이 이 데이터를 쓸 때도 macOS는 Yardlet의 이름으로 묻는다. `DeveloperIDSigningTests`가 entitlement마다 두 언어의 사용
  설명이 있는지 본다.

### Xcode

- Apple의 MCP 서버(Xcode 26.3부터)는 stdio 다리 `mcpbridge`가 열린 Xcode의 도구 서비스에 잇는다. Yardlet은 `mcpbridge`를 자기 자식
  프로세스로 띄우고 JSON-RPC를 주고받는다(`XcodeBridge`, `MCPStdioClient`). 그래서 Xcode가 접근을 묻는 상대는 하네스마다가 아니라
  Yardlet 하나다.
- **찾기(`XcodeBridge.locate`):** `DEVELOPER_DIR`, `/var/db/xcode_select_link`가 가리키는 폴더, `/Applications/Xcode.app`·`Xcode-beta.app`
  순으로 `Contents/Developer/usr/bin/mcpbridge`를 본다. 경로만 읽는다. 개발 도구가 없는 Mac에서 `xcrun`·`xcode-select`를 실행하면
  설치 창이 뜨기 때문이다.
- **다리를 띄우는 때:** 사람이 "연결"(도구 목록 읽기)이나 "도구 목록 다시 읽기"를 누를 때와 Xcode 도구를 부를 때뿐이다. 앱이나
  작업을 시작할 때는 띄우지 않고(도구 목록은 `connectors.json`에 둔 것), 12시간마다 다시 읽지도 않는다. 그것만으로 Xcode가 뜨지 않게
  하려는 것이다. 한 번 띄운 다리는 Yardlet이 끝나거나 커넥터를 지울 때까지 두고, 다리가 끝나면 다음 호출이 한 번 다시 띄운다.
  Yardlet이 끝나면 표준 입력이 닫혀 다리도 끝난다.
- **클라이언트:** 줄 단위 JSON-RPC, 요청 ID로 답을 맞춰 동시 호출, 서버의 `ping`에는 답하고 그 밖의 서버 요청은 거절, 취소한 호출은
  `notifications/cancelled`. 줄은 줄바꿈 바이트로만 나눈다(JSON 문자열 안의 U+2028에서 끊지 않게). 빌드·검사가 몇 분 걸리므로 호출에
  따로 시간 제한을 두지 않고 하네스의 도구 시간 제한을 따른다. 다리가 끝나며 표준 오류에 남긴 마지막 줄이 오류가 된다("Xcode MCP
  access is disabled; turn it on in Xcode Settings > Intelligence > Model Context Protocol…", "No running Xcode found and could not launch
  one automatically.").
- **조건 안내:** 커넥터 추가 타일은 Xcode에서 프로젝트를 열어 두어야 한다고 말하고, 설정 행은 "Xcode 27.1 · 프로젝트를 연 동안"처럼
  버전과 조건을 보인다. 실패하면 그 이유와 "Xcode에서 프로젝트를 열고, Xcode 설정 → Intelligence에서 다른 에이전트가 Xcode 도구를
  쓰도록 허용하세요."가 보인다.
- **가져오기 제안:** 하네스 설정에 `xcrun mcpbridge`가 있으면 "다른 곳에서 쓰는 서비스"에 Xcode가 보인다(`packages: ["mcpbridge"]`).
  하네스가 스스로 싣는 stdio Xcode 서버는 주소가 없어 "하네스 자체 서버" 절의 대신하기와 중복 제외 대상이 아니다. 그래서 한 작업이
  하네스 쪽 Xcode와 Yardlet 쪽 Xcode를 함께 받을 수 있다.

### 하네스가 묻기

- 묻는 도구(`LocalConnectorService.approvalRequiredTools`): App Store Connect `add_beta_tester`·`remove_beta_tester`·
  `add_build_to_group`·`reply_to_review`·`submit_for_review`, Apple Calendar `create_event`·`update_event`·`delete_event`, Apple Reminders
  `create_reminder`·`complete_reminder`. Apple Contacts는 읽기만 한다. Xcode에는 Yardlet이 정한 묻는 도구가 없다.
- Claude Code: Google과 같이 커넥터 도구가 허용 목록에 없어 부를 때마다 묻는다. 위 쓰기의 요청 카드는 Yardlet 문구이고 "항상 허용"이
  없다(`AppleToolApproval`): 테스터 초대(Apple이 초대 메일을 보낸다는 말)·빼기, 빌드 배포(그룹의 테스터가 설치할 수 있다는 말), 리뷰
  답글(App Store에 보이고 이전 답글을 바꾼다는 말과 답글 앞 1,200자), 심사 제출, 이 Mac의 캘린더 일정 만들기·바꾸기·지우기, 미리 알림
  추가·완료와 되돌리기. Xcode 도구는 CLI의 보통 카드다.
- Codex: 주석을 따른다. 쓰기는 모두 `readOnlyHint: false`·`openWorldHint: true`(계정 서버로 동기화되거나 공개되므로), 일정 지우기와
  테스터 빼기는 `destructiveHint: true`다. Xcode 도구는 Xcode 서버가 준 주석 그대로다.
- ACP: 그 하네스의 MCP 승인 그대로.

### 끄기와 지우기

- 작업별 스위치로 그 작업에서 끄고, 설정 행 `…` → 제거로 지운다. 제거는 레코드와 Keychain 항목(App Store Connect 키)을 지우고
  Xcode의 `mcpbridge`를 끝낸다. 하네스 설정 파일에는 아무것도 쓰지 않는다.
- macOS 권한(시스템 설정 → 개인정보 보호 및 보안의 Yardlet 허용)은 Google 범위처럼 제거해도 남는다. Yardlet은 권한을 되돌리지
  않으므로 사람이 시스템 설정에서 끈다(행 `…` → "개인정보 보호 및 보안 열기…").

### 사람이 할 일

- **App Store Connect**(팀 키, 역할 Admin 권장):
  1. appstoreconnect.apple.com → 사용자 및 액세스 → 통합 → App Store Connect API → 팀 키 → "API 키 생성"(또는 +). Account Holder·
     Admin에게만 보인다.
  2. 이름(예: "Yardlet"), 액세스는 **Admin**(리뷰 답글이 필요 없으면 App Manager). 생성.
  3. 새 키 줄의 "API 키 다운로드"(한 번만 된다) → `AuthKey_<키 ID>.p8`이 다운로드 폴더에 생긴다. 키 목록 위의 발급자 ID를 복사한다.
  4. Yardlet 설정 → 커넥터 → 커넥터 추가 → "키나 토큰 붙여 넣기"의 App Store Connect "설정…" → 팀 키 → ".p8 파일 고르기…"(키 ID는
     파일 이름에서 채워진다) → 발급자 ID 붙여 넣기 → "연결" → 키 파일을 휴지통으로 옮길지 고른다.
  - 개인 키라면 1~2 대신 App Store Connect의 내 프로필 → 개인 API 키 → "API 키 생성"(권한이 없으면 Admin이 "개인 API 키 생성" 권한을
    줘야 한다). 4에서 "개인 키"를 고르고 발급자 ID는 넣지 않는다.
- **Mac의 캘린더·미리 알림·연락처:** 커넥터 추가 → "한 번에 연결"의 Apple Calendar(또는 Apple Reminders·Apple Contacts) "연결" →
  macOS 창에서 "허용"(셋 각각 한 번). 나중에 끄려면 시스템 설정 → 개인정보 보호 및 보안 → 캘린더(미리 알림·연락처)에서 Yardlet을 끈다.
- **Xcode:** Xcode → Settings → Intelligence → Model Context Protocol에서 외부 에이전트가 Xcode 도구를 쓰도록 켠다. 프로젝트를 연다.
  커넥터 추가 → "한 번에 연결"의 Xcode "연결" → Xcode가 Yardlet의 접근을 물으면 허용.
- 그다음 Claude Code 작업은 다음 턴부터, 다른 하네스의 작업은 다음에 시작하거나 재개할 때 도구가 보인다("실행 중인 작업의 도구
  목록" 절).

### 없는 것

- App Store Connect: 인증서·프로필·판매 보고서·공증, 메타데이터·스크린샷 편집, 단계적 출시, 베타 심사 제출, 크래시 로그 밖의 진단.
- Mac: 일정의 첨부·참석자·반복 규칙 만들기, 미리 알림 고치기·지우기, 연락처 쓰기와 메모 읽기, 메모·메시지 앱의 데이터.
- Xcode: 하네스가 스스로 싣는 stdio Xcode 서버를 Yardlet 쪽이 대신하지 않는다(위 "Xcode").

## 11. Slack

Slack MCP 서버(`https://mcp.slack.com/mcp`)는 동적 등록이 없고, Slack Marketplace에 게시된 앱과 그 워크스페이스의 내부 앱만 받는다.
그래서 Google처럼 빌드에 앱을 넣을 수 없고, 워크스페이스마다 Yardlet 매니페스트로 앱을 하나 만든다.

- **매니페스트(`SlackAppManifest`):** 이름 "Yardlet", `oauth_config.redirect_urls` = `http://127.0.0.1:47823/callback`,
  `oauth_config.scopes.user` = 서버가 알리는 user scope 30개(봇 범위 없음; 데스크톱 redirect는 봇 범위를 못 받는다),
  `oauth_config.pkce_enabled: true`, `settings.is_mcp_enabled: true`. MCP를 켜는 것이 매니페스트에 들어가므로 따로 켜는 단계가 없다.
- **PKCE를 켠 이유:** Slack은 redirect가 HTTPS여야 하고, 루프백 http redirect는 PKCE를 켠 앱의 데스크톱 redirect로만 받는다. PKCE
  앱은 토큰 교환에 secret을 보내지 않으므로 사람이 복사하는 값은 client ID 하나다. Slack은 PKCE를 켜면 다시 끌 수 없고, PKCE 앱의
  refresh 토큰은 30일 뒤 만료된다(쓰는 동안 갱신으로 이어짐; 30일 넘게 안 쓰면 다시 로그인). PKCE를 끈 기존 앱은 secret 칸(접힘)에
  넣으면 `client_secret_post`로 간다.
- **만들기 링크:** `https://api.slack.com/apps?new_app=1&manifest_json=<JSON>`. JSON을 정렬된 키로 압축하고 RFC 3986 비예약 문자 밖을
  모두 퍼센트 인코딩한다(`&`·`=`·`+`·`#`·`/`·`:`·따옴표·괄호).

사람이 할 일:

1. 설정 → 커넥터 → "한 번에 설정"의 Slack → **Slack에서 만들기**(매니페스트가 채워진 Slack 페이지) → 워크스페이스 고르기 → Next →
   만들기와 설치.
2. 새 앱의 Basic Information → App Credentials → **Client ID** 복사 → Yardlet 칸에 붙여 넣기(형식 `숫자.숫자` 확인).
3. **Slack에 로그인** → 브라우저에서 Yardlet 허용(워크스페이스가 관리자 승인을 요구하면 승인 요청).

## 12. GitHub 로그인

GitHub의 원격 MCP 서버(`https://api.githubcopilot.com/mcp/`)는 동적 등록이 없어, 등록된 OAuth 앱이 있는 호스트만 로그인 단추를 쓸 수
있다. Yardlet은 GitHub OAuth 앱의 기기 코드 방식(device flow)으로 로그인한다.

- **앱:** GitHub OAuth 앱(Redirect URI `http://127.0.0.1/callback`, **Enable Device Flow** 켬)의 client ID를 `Packaging/Info.plist`의
  `YardletGitHubOAuthClientID`에 둔다. client ID는 공개 값이고 기기 코드 방식은 secret이 필요 없어 빌드에 비밀이 없다. 자기 앱으로
  빌드하려면 이 값을 바꾼다.
- **흐름(`GitHubDeviceSignIn`):** `POST github.com/login/device/code`(`client_id`, `scope=repo read:org workflow`, `Accept: application/json`)
  → 코드(`WDJB-MJHT` 모양)를 클립보드와 커넥터 행에 보이고 기본 브라우저로 `github.com/login/device`를 연다 → `interval`초마다
  `POST github.com/login/oauth/access_token`(`grant_type=urn:ietf:params:oauth:grant-type:device_code`). `authorization_pending`은 계속,
  `slow_down`은 간격을 GitHub가 준 값으로 바꾼다. `access_denied`(GitHub 페이지의 취소)는 Yardlet의 취소처럼 조용히 끝내고,
  `expired_token`·`device_flow_disabled`는 이유와 함께 끝낸다. 코드 만료(15분)는 Yardlet 쪽에서도 끝낸다.
- **토큰:** OAuth 앱 사용자 토큰은 만료·갱신 토큰이 없어 access 토큰만 Keychain에 둔다. GitHub에서 앱을 취소하면 서버가 거절하고
  커넥터는 "로그인 필요"가 된다.
- **언제 쓰나:** GitHub 항목이고, 빌드에 client ID가 있고, 붙여 넣은 토큰도 직접 만든 OAuth 클라이언트도 없을 때(`signsInOnGitHub`).
  이미 토큰으로 연결한 커넥터는 그대로다(바꾸려면 제거 뒤 다시 추가). 기다리는 동안 행에 "GitHub 페이지에 이 코드를 붙여 넣으세요:
  …"와 복사 단추가 있다.
- 기기 코드 로그인이 없는 빌드에서는 "키나 토큰 붙여 넣기"의 GitHub에 개인 액세스 토큰을 넣거나, 추가한 뒤 행의 `…` → "직접 만든
  OAuth 클라이언트로 연결…"에 GitHub OAuth 앱(콜백 `http://127.0.0.1:47823/callback`)을 넣는다.

## 13. 아이콘

- **순서(`ConnectorIconSources`):** 그 커넥터 MCP 서버가 `initialize`의 `serverInfo.icons`로 준 아이콘(서버 주소와 같은 등록 도메인의
  `https`, 또는 `data:image/`; light 화면은 light → 테마 없음 → dark, dark 화면은 반대, 각 테마에서 가장 큰 것) → 디렉터리 항목의
  `iconURL`(그 서비스 자신의 사이트) → 기호/첫 글자. 다른 회사의 파비콘 서비스와 서버와 다른 사이트의 아이콘은 쓰지 않는다. 앱에
  서비스 로고를 넣지 않는다.
- **서버 아이콘 저장:** 연결할 때와 12시간 지난 도구 목록을 다시 읽을 때 `record.serverIcons`에 둔다. 하네스 자체 서버는 주소가 없을
  수 있으므로 이름으로 디렉터리 항목을 찾아(`ConnectorPreset.preset(forServerNamed:)`) 그 아이콘을 쓴다.
- **디렉터리 아이콘(`ConnectorPreset.iconAddresses`):** 각 서비스 홈페이지의 `<link rel=icon|apple-touch-icon>`과 루트의
  `apple-touch-icon.png`·`favicon.ico` 중, 그 서비스 도메인에 있고 32 px 이상인 것이다. 홈페이지가 직접 연결한 그 회사 정적 호스트와
  사이트가 돌려보내는 곳은 그대로 따른다. Google 서비스는 Google 자신의 `www.gstatic.com/images/branding/product/` 그림, App Store
  Connect는 Apple 개발자 사이트(`developer.apple.com/assets/elements/icons/app-store-connect/`)의 그림이다. 쓸 만한 아이콘이 없는
  곳(16 px뿐이거나 다른 회사 호스트에만 있는 곳)은 기호로 남는다.
- **이 Mac의 앱:** Apple Calendar·Apple Reminders·Apple Contacts·Xcode의 디렉터리 아이콘은 그 앱의 `file://` 주소
  (`/System/Applications/Calendar.app` 등, `/Applications/Xcode.app`)이고, `ConnectorIconStore`가 macOS가 그 앱에 주는 아이콘
  (`NSWorkspace.icon(forFile:)`)을 그린다. 네트워크에 가지 않고, 앱이 없으면 기호다.
- **받기·캐시(`ConnectorIconStore`):** 쿠키·URL 캐시·자격 증명 저장소 없는 ephemeral `URLSession`으로 `https`만, 15초, 1 MB까지,
  `NSImage`가 읽는 그림(PNG·ICO·SVG·JPEG)만 받는다. `~/Library/Caches/<번들 ID>/ConnectorIcons/<FNV-1a 64>`에 두고 다음 실행부터
  디스크에서 읽는다. 실패하면 표시를 두고 하루 동안 다시 묻지 않는다. 캐시를 지우면 다시 받는다(설정 파일에는 아무것도 쓰지 않는다).
  검사 프로세스의 앱 저장소는 네트워크에 가지 않는다.
- **그리기(`ConnectorIcon`):** 20 pt 이상은 옅은 상자에 상자의 2/3 크기 그림, 도구 줄(16 pt)은 그림만. 받기 전·실패 때는 기호나 첫 글자.

## 14. 보안과 한계

- 같은 사용자의 다른 프로세스가 `yardlet-mcp`의 작업 토큰을 얻으면 커넥터 도구도 부를 수 있다. 브라우저 도구와 같은
  경계다([AGENT_BROWSER_TOOLS](AGENT_BROWSER_TOOLS.md) 6절).
- 도구 승인은 하네스 몫이다. Yardlet은 따로 묻지 않는다. Claude Code의 Google·Apple 쓰기 요청 카드만 Yardlet 문구로 보이고 "항상
  허용"을 뺀다("Google" 절, "Apple" 절).
- 커넥터로 읽은 내용은 그 작업의 하네스를 거쳐 그 제공자에게 간다. Mac의 캘린더·미리 알림·연락처와 App Store Connect의 데이터도
  같다. Yardlet은 서비스에서 받은 본문·요청·응답을 로그에 쓰지 않는다.
- App Store Connect API 키는 Keychain에만 있고, Yardlet이 그 키로 15분짜리 토큰을 만들어 Apple에 보낸다. 에이전트가 그 키로 할 수
  있는 일의 범위는 키의 종류와 역할이 정한다("Apple" 절).
- Browserbase 키는 Browserbase가 정한 대로 요청 주소에 실린다(서버 로그에 남을 수 있음). Yardlet의 파일·화면·오류 문구에는 없다.
- 지원하지 않는 것: 옛 HTTP+SSE 전송(2024-11-05), Client ID Metadata Document(Yardlet에 https 문서 주소가 없음), resources·prompts,
  서버가 stream 안에서 보내는 요청(elicitation, sampling, roots), 진행 알림 표시, 도구별 막기, 커넥터 서버(원격 MCP)가 스스로 보내는
  `notifications/tools/list_changed`(서버 목록은 연결할 때와 12시간마다 다시 읽는다).
- 사용자가 더하는 stdio 커넥터(Yardlet이 `npx` 같은 프로세스를 띄우고 비밀을 환경으로 넘기는 것)는 없다. 원격 서버가 있는 서비스는
  원격이 더 단순하고, stdio는 Yardlet이 서드파티 프로세스의 수명·업데이트·샌드박스를 맡게 된다. 같은 브로커 뒤의 stdio 클라이언트
  (`MCPStdioClient`)는 Xcode에 든 Apple의 `mcpbridge` 하나만 띄우고, 비밀을 넘기지 않는다("Apple" 절).
- 루프백 수신기, Keychain, 브라우저 열기, SHA-256, App Store Connect의 ES256 서명(CryptoKit), EventKit·Contacts, 시스템 설정의
  개인정보 패널 주소는 macOS 플랫폼 층이다. Windows는 같은 규약으로 Credential Manager와 루프백 수신기를 따로 만들어야 하고, Mac
  데이터와 Xcode 커넥터는 없다.

## 15. 코드 위치

| 위치 | 내용 | 층 |
|---|---|---|
| `Sources/NativeHarnessClient/Connectors/ConnectorModels.swift` | 레코드, 자격 증명(`client`·`signingKey` 종류 포함), 저장소 규약, 이름 규칙(`ConnectorToolNaming`), 앱 안의 서비스(`LocalConnectorService`: Google 셋과 Apple 다섯) | 엔진 |
| `Sources/NativeHarnessClient/Connectors/ConnectorDirectory.swift` | 디렉터리(`ConnectorPreset`), 가져오기 제안, 작업 상태(`ConnectorTaskState`·`ConnectorTaskScope`), 도구 줄 이름표 | 엔진 |
| `Sources/NativeHarnessClient/Connectors/NativeMCPConfigs.swift` | 하네스 자체 설정 읽기(Claude `.claude.json`·`.mcp.json`, Codex `config.toml`, Antigravity `mcp_config.json`), 작업이 스스로 싣는 서버 | 엔진 |
| `Sources/NativeHarnessClient/Connectors/MCPHTTPClient.swift` | Streamable HTTP 클라이언트, `WWW-Authenticate` 해석, event stream, 주소의 키 | 엔진 |
| `Sources/NativeHarnessClient/Connectors/ConnectorOAuth.swift` | 발견, 동적 등록, 직접 만든 클라이언트, 인가 URL, 토큰 교환·갱신, PKCE | 엔진 |
| `Sources/NativeHarnessClient/Connectors/ConnectorCenter.swift` | 커넥터 목록·연결·로그인, 작업별 스위치, 하네스 서버 대신하기(`withYardletStandIns`), 도구 목록과 호출, 세션별 토큰 갱신(`ConnectorSession`), Google 앱·계정·로그인, Apple 서비스 더하기·연결(`isAvailable`, `addLocal`, `addAppStoreConnectKey`), 목록 바뀜 알림(`onToolsChanged`) | 엔진 |
| `Sources/NativeHarnessClient/Connectors/GoogleOAuth.swift` | Google 엔드포인트, 빌드에 든 앱(`BuiltInApp`), Google 앱 Keychain 항목 ID, 인가 인자, 범위 확인, `GoogleAPISession` | 엔진 |
| `Sources/NativeHarnessClient/Connectors/GmailToolCatalog.swift`, `GmailAPI.swift`, `GmailToolRunner.swift` | Gmail 도구 정의·주석·묻는 도구, REST 호출·메시지 읽기(charset·HTML→텍스트)·MIME 만들기, 도구별 요청·응답 | 엔진 |
| `Sources/NativeHarnessClient/Connectors/GoogleREST.swift` | Calendar·Drive REST 클라이언트(JSON, 내려받기, multipart 올리기), 인자 읽기(`GoogleToolArguments`), 스키마 조각(`GoogleToolSchema`) | 엔진 |
| `Sources/NativeHarnessClient/Connectors/GoogleCalendarToolCatalog.swift`, `GoogleCalendarToolRunner.swift` | Calendar 도구·범위·묻는 도구, Calendar API v3 요청·응답, `CalendarTime`(시간대·빈 시간) | 엔진 |
| `Sources/NativeHarnessClient/Connectors/GoogleDriveToolCatalog.swift`, `GoogleDriveToolRunner.swift` | Drive 도구·범위·묻는 도구, Drive API v3 요청·응답(내보내기·multipart), `DriveQuery` | 엔진 |
| `Sources/NativeHarnessClient/Connectors/GoogleEditorsToolCatalog.swift`, `GoogleEditorsToolRunner.swift` | Drive 커넥터의 Docs·Sheets·Slides 도구·묻는 도구·켜야 하는 API, Docs·Sheets·Slides API 요청·응답, 나눠 읽기 | 엔진 |
| `Sources/NativeHarnessClient/Connectors/AppStoreConnectAPI.swift`, `AppStoreConnectToolCatalog.swift`, `AppStoreConnectToolRunner.swift` | `.p8` 키와 ES256 토큰(`ES256Signing` 계약), 키 세션(401 뒤 새 토큰), JSON:API 요청, 도구 14개와 묻는 도구 | 엔진 |
| `Sources/NativeHarnessClient/Connectors/MacDataStore.swift`, `MacDataToolCatalog.swift`, `MacDataToolRunner.swift` | Mac 데이터 저장소 계약(`MacDataStoring`)·권한 상태·오류 문구, 캘린더·미리 알림·연락처 도구와 실행 | 엔진 |
| `Sources/NativeHarnessClient/Connectors/MCPStdioClient.swift`, `XcodeBridge.swift` | stdio MCP 클라이언트(요청 ID 맞추기, 취소, 표준 오류의 이유), 자식 프로세스 채널, `mcpbridge` 찾기·Xcode 버전 | 엔진 |
| `Sources/NativeHarnessClient/Connectors/SlackAppManifest.swift` | Slack 앱 매니페스트와 만들기 링크 | 엔진 |
| `Sources/NativeHarnessClient/Connectors/GitHubDeviceSignIn.swift` | GitHub 기기 코드 로그인, Info.plist의 client ID | 엔진 |
| `Sources/NativeHarnessClient/Connectors/ConnectorIcons.swift` | `MCPServerIcon`(`serverInfo.icons`), 아이콘 출처 순서(`ConnectorIconSources`), 자기 사이트 확인(`ConnectorIconSite`), 디렉터리 아이콘 주소 | 엔진 |
| `Sources/NativeHarnessClient/AgentTools/AgentToolBroker.swift` | `tools/list`와 커넥터 호출 경로, 작업별 범위, 주입 조건, `tools/watch` | 엔진 |
| `Sources/NativeHarnessClient/AgentTools/AgentToolInjection.swift` | 주입 문서, `deniedMcpServers` 설정, `ClaudeAIConnectorPreference` | 엔진 |
| `Sources/NativeHarnessClient/AgentTools/GmailToolApproval.swift`, `GoogleToolApproval.swift`, `AppleToolApproval.swift` | Claude Code 요청 카드의 Gmail·Calendar·Drive(Docs·Sheets·Slides 포함) 쓰기 문구, App Store Connect·Mac 캘린더·미리 알림 쓰기 문구 | 엔진 |
| `Sources/YardletAgentTools/MCPServer.swift` | `listChanged: true`, 클라이언트가 받은 목록(`MCPToolListing`), 목록 감시와 `notifications/tools/list_changed`(`watchToolList`) | 엔진 |
| `Sources/NativeHarnessClient/Adapters/Claude/ClaudeProcessTransport.swift` | `ENABLE_CLAUDEAI_MCP_SERVERS=false` | 엔진 |
| `Sources/NativeHarnessClient/Presentation/ConnectorSetupAssistant.swift` | "한 번에 설정" 단계 상태·콘솔 링크·복사 값·칸 확인 | 표현 |
| `Sources/NativeHarnessClient/Platform/macOS/Connectors/` | Keychain 저장소, 루프백 수신기(Network.framework, 고정 포트 선택), 브라우저 열기, SHA-256, 아이콘 받기·캐시(`ConnectorIconStore`, 이 Mac의 앱 아이콘 포함), EventKit·Contacts 구현(`MacEventKitStore`, 사용 설명이 없으면 묻지 않음, 시스템 설정의 개인정보 패널 주소), CryptoKit ES256(`MacES256Signer`) | macOS |
| `Sources/NativeHarnessClient/Views/AppShell/ConnectorSettingsView.swift` | 설정 → 커넥터, 상태 한 단어(`ConnectorSettingsState`), "한 번에 설정" 카드 | 화면 |
| `Sources/NativeHarnessClient/Views/AppShell/ConnectorAddSheet.swift` | "커넥터 추가" 시트, 서비스별 단계와 링크(`ConnectorSetupGuide`) | 화면 |
| `Sources/NativeHarnessClient/Views/AppShell/GoogleSetupPage.swift`, `SlackSetupPage.swift`, `ConnectorSetupAssistantViews.swift` | Google·Slack 설정 도우미(단계 행, 복사 버튼, 확인되는 칸, 계정별 서비스 칩) | 화면 |
| `Sources/NativeHarnessClient/Views/AppShell/AppStoreConnectSetupPage.swift` | App Store Connect 페이지(단계, 키 종류, `.p8` 고르기, ID 칸, 키 목록, 휴지통 질문) | 화면 |
| `Sources/NativeHarnessClient/Views/Composer/ComposerPlusMenu.swift` | 입력창 "+" 메뉴 행·키(`ComposerMenuList`), "+" 순서(`ComposerPlusMenu`), 커넥터 목록(`ComposerConnectorsMenu`) | 화면 |
| `Sources/NativeHarnessClient/Views/Composer/ComposerConnectorsMenu.swift`, `Presentation/Composer/ComposerConnectorList.swift` | 커넥터 환경, `ConnectorIcon`, 세션 레일 행, 목록 상태 | 화면 |

검사:

| 위치 | 내용 |
|---|---|
| `Tests/NativeHarnessClientTests/ConnectorTests.swift` | 가짜 인가·MCP 서버로 전 과정, 이름, 브로커, 루프백, 갱신(일시적 실패 재시도, refresh 토큰 교체, 다른 사본의 갱신), Keychain(opt-in `NHC_KEYCHAIN_LIVE=1`) |
| `Tests/NativeHarnessClientTests/ConnectorDirectoryTests.swift` | 디렉터리, 실제 메타데이터 모양의 발견, 직접 만든 클라이언트·공개 클라이언트·주소의 키, 작업별 스위치, 중복 제외와 Claude 하네스 서버 대신하기(`--settings`), 설정 파싱(가짜 값), 가져오기, claude.ai 환경, 주입 문서, 도구 줄 |
| `Tests/NativeHarnessClientTests/ConnectorLiveToolsTests.swift` | 가짜 MCP 클라이언트로 `list_changed`와 목록 갱신, 소켓을 거친 `tools/watch`, 실제 `ConnectorCenter`의 작업별 변화, 다시 읽는 클라이언트와 읽지 않는 클라이언트, 턴 끝 알림, 하네스별 문구 |
| `Tests/NativeHarnessClientTests/GmailConnectorTests.swift`, `GoogleCalendarDriveConnectorTests.swift`, `GoogleBuiltInAppTests.swift` | 가짜 Google(`FakeGoogle`, `FakeGoogleWorkspace`)로 로그인·범위·계정·도구마다 요청·묻기, 빌드에 든 앱 |
| `Tests/NativeHarnessClientTests/AppleConnectorTests.swift` | 가짜 App Store Connect(요청마다 토큰 서명 확인)·가짜 Mac 저장소·가짜 `mcpbridge`로 전 과정: 팀 키·개인 키 토큰, 키는 Keychain에만, 도구마다 요청과 답, 거절된 키, 쓰기만 묻기와 카드 문구, Mac 권한과 캘린더·미리 알림·연락처, Xcode 찾기·연결·다시 띄우기·지우기, 실제 셸 프로세스의 stdio |
| `Tests/NativeHarnessClientTests/GitHubDeviceSignInTests.swift` | 기기 코드 요청·대기·거절·만료, MCP에 bearer로 보냄 |
| `Tests/NativeHarnessClientTests/ConnectorSetupAssistantTests.swift` | Slack 매니페스트와 링크 인코딩, Google·Slack 단계 상태, 칸 확인, 이름만 읽은 제안 |
| `Tests/NativeHarnessClientTests/ConnectorIconTests.swift` | 아이콘 순서·테마·출처 제한, 받기·캐시·실패 대기(opt-in `YARDLET_CONNECTOR_ICONS_LIVE=1`은 실제 서비스 사이트에서 받아 그림) |
| `Tests/NativeHarnessClientTests/ConnectorsRenderingTests.swift`, `ConnectorsEasyQARenderingTests.swift`, `PlusConnectorsQARenderingTests.swift`, `GmailSetupRenderingTests.swift`, `AppleConnectorsRenderingTests.swift` | 설정·추가 시트·도우미·입력창 목록·App Store Connect 페이지를 `.build/` 아래에 라이트·다크로 그림. Apple 연결 흐름은 화면 밖 투명 창에서 접근성 누르기로 돈다 |

## 16. QA(모델 턴 없이)

`scripts/connector-qa/`:

- `mock-connector-server.py`: 127.0.0.1의 인가 서버 + MCP 서버. 등록한 redirect URI, PKCE 검증, resource, bearer 토큰, MCP 세션을
  실제 서버처럼 확인하고, 인가를 바로 승인해 되돌려 보낸다. `tools/call`은 진행 알림을 앞에 둔 event stream으로 답한다.
- `run-check.sh <QA 앱> <출력 폴더>`: 모의 서버를 띄우고, QA 번들을 임시 홈·설정 fixture(`connectors`)로 띄워
  `YARDLET_CONNECTOR_QA_ADD`로 커넥터를 추가·연결하게 한다. `YARDLET_CONNECTOR_QA_FOLLOW_SIGN_IN=1`은 브라우저 대신 URLSession이 인가
  URL의 리디렉션을 따라가게 하고, `YARDLET_CONNECTOR_QA_MEMORY_CREDENTIALS=1`은 로그인 키체인이 없는 임시 홈에서 자격 증명을 메모리에
  둔다. 그다음 `drive-mcp.py`로 `yardlet-mcp`를 하네스처럼 띄워 목록과 호출을 확인한다. `run-check.sh finish …`는 앱을 끝내고
  `YARDLET_CONNECTOR_QA_REMOVE_ALL=1`로 다시 띄워 커넥터를 지운 뒤 서버를 멈춘다.
- `drive-codex.py`: 빈 임시 `CODEX_HOME`의 Codex app-server에 ephemeral `thread/start`의 `config`로 서버를 넣고
  `mcpServerStatus/list`와 `mcpServer/tool/call`을 보낸다.

실제 서비스 로그인과 모델 턴은 이 QA에 들어 있지 않다. 단위 검사는 가짜 인가·MCP·Google 서버와 실제 메타데이터 모양을 쓰고,
렌더 검사는 화면 없이 그린다.
