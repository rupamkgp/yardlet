# 작업마다 브라우저 세션 격리

상태: 구현(2026-10-24, 같은 날 디스크 프로필 경로를 고침: 7절. 2026-10-25 쿠키 복사가 쿠키 모양을 바꾸던 것을 고침: 8절. 2026-10-26 다른 브라우저에서 로그인 가져오기: 10절). 브라우저 호스트 계약은 [BROWSER_HOST](BROWSER_HOST.md)
3절 "프로필", 금고는 [BROWSER_VAULT_DESIGN](BROWSER_VAULT_DESIGN.md)에 있다.

## 1. 계기와 목표

사용자: "ai 브라우저는 자격증명같은 건 공유하면서도 쿠키,세션,로컬스토리지로 공유되는 현재 로그인계정 같은 값들을 각 세션별로 격리해야 원활한
작업이 되잖아 이것도 필요할듯".

전에는 모든 작업의 탭이 프로필 하나(`~/Library/Application Support/Yardlet/Browser/Default`)를 함께 썼다. 쿠키·저장소·캐시가 작업 사이에
섞였고, 두 작업이 같은 사이트에 다른 계정으로 로그인하면 서로 덮어썼다. 이제 금고의 자격 증명(비밀번호·TOTP·Yardlet 패스키)과 Touch ID
패스키는 모든 작업이 함께 쓰고, "지금 로그인 상태"(쿠키, localStorage, sessionStorage, IndexedDB, 캐시)는 작업마다 따로 둔다.

## 2. 두 앱과 다른 브라우저는 어떻게 하나

번들은 바이트로만 읽었다(실행하지 않음). Aside·Ego는 제작사 문서로 읽었다.

| 제품 | 작업마다 로그인 상태 | 근거 |
|---|---|---|
| Claude 앱 3.1623.3 | 설정 "Keep cookies"로 고른다: "Until quit"(기본, 비영속, 작업 폴더별), "Shared"(모든 세션 공유, `persist:launch-preview-cowork-shared`), "Per session"(세션마다 `persist:launch-preview-session-<세션 ID>`). 세션을 분기하면 부모의 쿠키를 복사한다(`seedForkedPreviewCookies`). 세션을 지우면 그 세션의 저장소를 지우고(`clearData`), 보관은 지우지 않는다. 에이전트와 사람은 같은 탭의 저장소를 쓴다 | `app.asar` `index.chunk-DylQWxwC.js`(`launchPreviewStorage: "none" \| "shared" \| "session"`), `ion-dist` 설정 문구 |
| Codex 앱 26.1016 | 없음. 로컬 내장 브라우저의 모든 스레드가 `persist:codex-browser-app` 하나를 쓴다. 스레드마다 다른 것은 탭 소유와 복원 정보뿐이고, 보관·삭제가 로그인 저장소를 지우지 않는다 | `main-JI9qDiXp.js`(`session.fromPartition(Vu("app"))`), `src-CSKkIr_z.js` |
| Aside | 작업은 기본 프로필을 함께 쓰고, "시크릿" 작업만 프로필 상태 없이 돈다. 금고(Aside Vault)가 자격 증명을 함께 쓴다 | 도움말 Run tasks |
| Claude 앱 3.6556.2(가져오기) | 기능 플래그 `desktop_ccd_chrome_import` 뒤에 "Chrome에서 로그인 가져오기"가 있다: Chrome·Edge·Brave·Chromium·Firefox의 프로필을 고르고 사이트(등록 도메인)를 골라 그 쿠키와 localStorage를 미리보기 저장소에 넣는다. 기존 쿠키는 지우지 않고 덮어쓰며, 가져온 사이트 목록과 지우기가 있다(10절) | `app.asar` `index.chunk-TCY6lWOp.js`(`runChromeImport`, `listChromeImportSites`) |
| ego(lite) | Space(작업)마다 BrowserContext 하나, 자기 쿠키와 저장소. 그러면서도 브라우저에 있는 로그인을 에이전트가 이어 받는다(옮기는 방법은 문서에 없음). 작업에 Profile을 지정할 수도 있다 | 문서 Space, 변경 기록 0.4.4.15 |

Yardlet은 Claude 앱의 "Per session"과 ego(lite)의 Space를 합친 모양이다: 작업마다 저장소를 두고, 새 작업은 로그인된 채로 시작하며, 자격 증명은
금고로 함께 쓴다.

## 3. 정한 것(사용자가 자리를 비운 동안 추천안으로)

| 질문 | 정한 것 | 이유 |
|---|---|---|
| 디스크 폴더인가 메모리인가 | 디스크 폴더(`Browser/Task-<키>`, `CefRequestContext`의 `cache_path`). Chromium은 root cache 바로 아래 폴더만 디스크 프로필로 연다 | 호스트는 탭이 없으면 60초 뒤 끝난다. 메모리 컨텍스트면 그때마다 로그인이 사라진다 |
| 새 작업은 빈 상태로 시작하나 | 기본 프로필의 쿠키를 복사해 시작한다. 하위 작업은 부모 작업의 쿠키로 시작한다 | 매번 다시 로그인하면 새 기기 알림·2단계 인증이 작업마다 생긴다. Claude 앱도 분기 때 부모 쿠키를 복사한다. localStorage·IndexedDB는 복사하지 않는다(그런 사이트는 금고가 다시 로그인한다) |
| 사람이 패널에서 로그인하면 | 그 작업에 남고, 그 사이트(등록 도메인)의 쿠키를 기본 프로필에도 복사한다. 이미 돌고 있는 다른 작업은 바뀌지 않는다 | 기본 프로필이 "사람이 지금 쓰는 계정"을 따라가야 새 작업이 그 계정으로 시작한다. 에이전트가 금고로 한 로그인은 그 작업에만 남는다 |
| 하위 작업은 물려받나 | 처음 열 때 부모의 쿠키를 복사한다. 그 뒤로는 따로다 | Claude 앱의 분기와 같다 |
| 새 작업 화면의 탭 | 새 작업 화면은 자기 프로필 키를 갖고, 그 탭이 넘어간 작업은 그 키를 이어 쓴다. 새 작업 화면은 새 키를 받는다 | 넘어간 탭의 페이지가 그대로이므로 저장소도 같아야 한다 |
| 보관·삭제 | 둘 다 그 작업의 폴더를 지운다. 호스트가 폴더를 열고 있지 않을 때(호스트가 끝날 때) 남은 작업에 속하지 않는 폴더를 지우고, Chromium이 `Local State`에 남긴 그 프로필의 기록도 지운다 | 지운 뒤 흔적이 남지 않게. Claude 앱은 삭제 때만 지운다 |
| 켜고 끄기 | 설정 › 일반 "쿠키 보관": "작업마다"(기본) / "모든 작업이 함께"(전과 같음) | Claude 앱의 "Keep cookies"와 같은 자리의 설정. "Until quit"은 호스트가 자주 끝나는 Yardlet에서 뜻이 달라 두지 않았다 |
| 다른 브라우저의 로그인(2026-10-26) | 사람이 브라우저 패널의 페이지 메뉴에서 고른 사이트의 쿠키를 기본 프로필과 그 작업의 프로필에 넣는다. 그 사이트에 있던 쿠키는 지운다 | 패스키가 다른 브라우저에만 있는 사이트를 Yardlet에서 쓰게. 이미 돌고 있는 다른 작업은 사람의 로그인 복사처럼 그대로 둔다(10절) |
| Touch ID 패스키 | 새 작업 프로필에 기본 프로필의 `webauthn.touchid.metadata_secret`를 넣는다 | Chromium은 Touch ID 패스키의 메타데이터를 프로필마다 이 키로 읽는다. 없으면 작업마다 패스키가 보이지 않는다 |

## 4. 구조

- **CEF 브리지:** 요청 컨텍스트를 폴더 경로마다 하나 만들고(`cef_request_context_create_context`, 세션 쿠키도 저장), 그 폴더를 쓰는 브라우저와
  쿠키 복사가 있는 동안 둔다. 마지막이 끝나면 놓는다. 쿠키 복사는 원본의 쿠키를 모두 읽고(`visit_all_cookies`), 쿠키마다의 주소로 원본에 다시
  물어(`visit_url_cookies`, 파티션 없는 쿠키만 답함) 답에 든 쿠키만 대상에 넣는다(`set_cookie`, 호스트 전용 쿠키는 도메인을 비워 호스트 전용으로).
  끝나면 대상 저장소를 디스크에 반영한 뒤(`flush_store`) 알린다(8절). 브라우저는 모두 합쳐 16개(호스트 상한), 컨텍스트는 32개까지다.
- **호스트:** `open` 명령의 `profile`(`key`, `seedFrom`)을 받아 `<root cache>/Task-<key>`에서 탭을 연다. 키는 UUID 꼴만 받아 다른 폴더를 가리키지 못한다.
  Chromium이 디스크 프로필을 비동기로 읽으므로, 그 프로필이 준비된 뒤(`on_request_context_initialized`) 브라우저를 만든다. 폴더가 새로 생기면 Touch ID
  키를 넣고, 탭을 about:blank로 연 뒤 시작 쿠키를 복사하고 나서 요청한 주소를 연다(프로필을 기다리거나 복사하는 사이에 온 이동과 DevTools 메시지는 그 뒤로 미룬다).
  `copyCookies` 명령은 한 프로필의 한 사이트 쿠키를 다른 프로필로 옮긴다. `importCookies` 명령은 다른 브라우저에서 가져온 쿠키로 한 프로필의 고른
  사이트 쿠키를 바꾼다(10절).
- **Yardlet:** `BrowserTaskProfiles`가 작업의 키(작업 ID, 새 작업 화면에서 넘어온 작업은 그 화면의 키), 시작 쿠키의 출처(부모 작업의 폴더가 있으면
  그것, 없으면 기본 프로필), 설정, 정리를 맡는다. `BrowserHostClient`는 작업의 탭을 열 때마다 프로필을 붙이고, 탭이 다른 작업으로 옮겨 가면 알리고,
  호스트가 끝나면 정리를 부른다. 정리는 저장된 작업 목록을 다 읽은 뒤에만 한다. Chromium은 연 프로필을 모두 `Local State`(`profile.info_cache`,
  `profile.profiles_order`, `variations_google_groups`)에 적고 폴더가 없어져도 지우지 않으므로, 정리가 폴더 없는 `Task-` 이름도 거기서 지운다.
- **사람의 로그인:** 금고의 저장 제안이 쓰는 감시(사람이 입력한 비밀번호 칸이 있는 폼의 제출)가 알려 주면, 4초와 12초 뒤 그 사이트의 쿠키를
  기본 프로필로 복사한다. 금고가 꺼져 있어도 "작업마다"이면 감시는 돈다.

## 5. 비용과 한계

- **메모리(2026-10-24 QA, 7절의 고침 뒤 디스크 프로필, 창 없는 탭 8개, 같은 QA 페이지):** 작업마다 프로필이면 프로세스 트리 합 1,162 MiB(브라우저
  프로세스 232), 같은 탭을 기본 프로필 하나에 열면 1,113 MiB(브라우저 프로세스 197). 차이는 약 49 MiB, 프로필 하나에 6 MiB 안팎이고 대부분 브라우저
  프로세스(프로필마다의 서비스)다. 렌더러는 두 경우 모두 탭마다 하나(10개)였다. 고치기 전의 첫 측정(1,134 MiB)은 메모리 프로필로 잰 것이다.
  탭이 늘 때 크게 느는 것은 탭이 그리는 프레임 표면(헬퍼 하나의 footprint 86 → 504 MiB, 상주 메모리는 그대로)이고 격리와 관계없다.
- **상한:** 브라우저는 모두 합쳐 16개(호스트 상한, 작업마다 9개), 프로필 컨텍스트는 32개까지다. 브라우저 프로세스 하나가 맡는다.
- 새 작업은 쿠키만 받는다. localStorage·IndexedDB에 로그인 토큰을 두는 사이트는 새 작업에서 다시 로그인해야 한다(금고의 "항상" 항목이면 에이전트가 한다).
- 파티션 쿠키(CHIPS, 다른 사이트에 끼워진 페이지가 그 최상위 사이트 아래에만 두는 쿠키)는 옮기지 않는다. CEF의 쿠키 관리자는 파티션 키를 받지 않아,
  넣으면 모든 최상위 사이트가 받는 쿠키가 된다(8절). 새 작업에서 끼워진 위젯은 처음 보는 것처럼 시작한다.
- 옮긴 쿠키에는 그 쿠키를 심은 scheme과 포트 대신 복사가 쓴 주소의 것(Secure면 https:443, 아니면 http:80)이 남는다. CEF가 원래 값을 알려 주지
  않는다. CEF 154는 쿠키를 scheme에 묶지 않아(QA `schemeBoundCookies: false`) 보내는 데는 차이가 없다. Claude 앱의 복사도 같은 주소를 쓴다.
- 사람의 로그인 감지는 비밀번호를 입력한 경우뿐이다. "Google로 로그인" 같은 팝업·OAuth 로그인은 기본 프로필로 옮기지 않는다.
- 보관한 작업을 되살리면 그 작업의 브라우저는 기본 프로필의 쿠키로 다시 시작한다.
- 설정을 바꿔도 이미 열린 탭은 그대로다. 그 뒤에 여는 탭부터 따른다.

## 6. QA

`run-check.sh … --ui-fixture-browser-check-only=isolation`(`BrowserHostIsolationQA`)이 실제 CEF 호스트에서 확인한다: 새 작업이 기본 프로필의 쿠키로
시작하는지, 두 작업이 같은 사이트에서 쿠키·localStorage를 따로 갖는지, 작업의 로그인이 기본 프로필에 새지 않는지, 하위 작업이 부모의 쿠키로
시작하는지, 사람의 로그인 복사가 뒤에 시작한 작업에만 가는지, Touch ID 키가 새 프로필에 들어가는지, 호스트가 끝났다 다시 떠도 작업의 쿠키(세션
쿠키 포함)와 localStorage가 남고 시작 쿠키를 다시 받지 않는지, "모든 작업이 함께"로 바꾸면 기본 프로필을 쓰는지, 남지 않은 작업의 폴더와 그
`Local State` 기록을 지우는지. 쿠키가 Chromium이 저장한 모양대로 옮겨지는지(8절): QA 서버의 두 사이트 로그인 확인(`/cookie-check`, 콘솔 127.0.0.1과 계정 사이트 localhost)이 기본
프로필과 새 작업에서 모두 `ok`인지, DevTools로 기본 프로필에 심은 Google 모양의 쿠키(`accounts.example.com`의 호스트 전용 쿠키와 `__Host-` 쿠키,
`.example.com`의 Secure·비Secure 쿠키, 다른 최상위 사이트 아래의 파티션 쿠키)가 새 작업에 같은 도메인·Secure로 들어가고 파티션 쿠키는 최상위 쿠키가
되지 않는지, 작업에서 다시 로그인한 쿠키를 기본 프로필로 옮기면 계정 사이트가 같은 이름을 한 번씩 새 값으로 받는지(기본 프로필과 그 뒤 작업 모두).
`--ui-fixture-isolation-cookies`를 더하면 이 확인만 돈다.
확인마다 새 작업을 쓰고 읽을 값을 먼저 정하므로(쿠키 확인은 앞선 실행의 같은 이름 쿠키를 먼저 지운다), 앞선 QA가 같은 QA 홈에 남긴 상태와 상관없다. 단계마다 프로세스
트리의 메모리를 잰다(`--ui-fixture-isolation-shared`를 더하면 같은 탭을 기본 프로필 하나에 열어 잰다).
2026-10-24 결과(7절의 고침 뒤): 새 QA 홈에서 9개 모두 통과, 전체 확인과 격리 확인을 먼저 돌린 QA 홈에서도 9개 모두 통과, 금고 QA 30개 통과,
전체 `run-check.sh`의 "profile keeps cookies across host restarts" 통과.

## 7. 고침: 작업 프로필이 메모리에 있었다(2026-10-24)

- **증상:** 이 기능을 합친 뒤 전체 QA의 "profile keeps cookies across host restarts"가 `cookies ""`로 실패했다. 패널의
  탭이 작업(`…F401`)의 프로필을 쓰기 때문이다.
- **원인:** CEF 154(Chrome 부트스트랩)는 요청 컨텍스트의 `cache_path`가 root cache와 같거나 그 바로 아래일 때만 디스크 프로필을 열고, 그 밖이면
  "Cannot create profile at path"를 남기고 메모리(OffTheRecord) 프로필을 쓴다. 처음 구현의 `Browser/Tasks/<키>`는 한 단계 더 깊어 모든 작업
  프로필이 메모리에 있었다. 한 호스트 안에서는 격리와 시작 쿠키 복사가 그대로 되어 격리 QA 8개가 통과했지만, 호스트가 끝나면 작업의 로그인이
  모두 사라졌다(폴더에는 Yardlet이 쓴 `Preferences`만 있었다). 5절의 첫 메모리 측정도 메모리 프로필로 잰 것이었다.
- **고친 것:** 폴더를 `Browser/Task-<키>`로 옮겼다(호스트 `TaskProfiles`, 앱 `BrowserTaskProfiles`, 저장 파일 `Browser/TaskProfiles.json`). 디스크
  프로필은 비동기로 읽히고 `create_browser_sync`는 읽히기 전의 컨텍스트에서 브라우저를 만들지 못하므로(NULL을 돌려줌), 브리지가 컨텍스트마다
  `on_request_context_initialized`를 받은 뒤 브라우저를 만들고, 호스트는 그 사이의 탭을 시작 쿠키를 복사하는 탭처럼 다룬다. Chromium이 디스크
  프로필마다 `Local State`에 남기는 기록(프로필 하나에 약 400바이트, 폴더를 지워도 남음)은 정리 때 지운다. 격리 QA에 호스트 재시작과 `Local State`
  확인을 더했다.
- **옛 `Browser/Tasks` 폴더:** 이 기능은 설치본에 나간 적이 없어(main에 없음, 이 Mac 설치본의 `Browser`에 `Tasks` 없음) 옮기거나 지우는 코드는
  넣지 않았다. `integration` 개발 빌드를 쓴 홈에는 쓰이지 않는 `Browser/Tasks`가 남을 수 있고, 지워도 된다.

## 8. 고침: 복사가 쿠키 모양을 바꿨다(2026-10-25)

- **증상:** 사용자가 Google 계정에 로그인한 작업의 패널에서 Google Cloud 콘솔(`console.cloud.google.com/auth/…`)과 OAuth 동의
  주소(`accounts.google.com/o/oauth2/v2/auth?…prompt=select_account`)를 열면 매번 `accounts.google.com/CookieMismatch`("쿠키 설정에 문제가 있음을
  발견했습니다")로 넘어갔다. 같은 탭에서 Search Console은 열렸다. 그 단계는 다른 브라우저에서 했다.
- **원인:** 복사가 쿠키를 넣을 때 원본의 도메인 값을 그대로 넘겼다. Chromium은 호스트 전용 쿠키의 도메인을 점 없이(`accounts.google.com`) 저장하는데,
  CEF의 `set_cookie`는 도메인이 비어 있어야 호스트 전용 쿠키를 만들고 무엇이든 주면 도메인 쿠키(`.accounts.google.com`, 하위 도메인에도 감)를
  만든다(`cef_types.h`의 `cef_cookie_t.domain` 설명). 그래서 호스트 전용 쿠키는 모두 도메인 쿠키가 됐고, 도메인 속성이 없어야 하는 `__Host-` 쿠키는
  Chromium이 거절해 빠졌다. 또 쿠키를 모두 읽는 `visit_all_cookies`는 파티션 쿠키도 돌려주는데 CEF의 쿠키 구조체에는 파티션 키가 없어, 파티션
  쿠키가 파티션 없는 쿠키로 들어갔다.
- **Google에서 일어난 일(설치본 기록, 값은 보지 않음):** 그 작업의 프로필이 생긴 00:37에 기본 프로필에서 복사하며 `accounts.google.com`의
  호스트 전용 로그인 쿠키 3개가 `.accounts.google.com`이 되고 `__Host-` 쿠키 3개가 빠졌다. 17:20에 그 패널에서 Google이 새 로그인 쿠키(호스트 전용
  2개, `__Host-` 3개)를 심자, 그 뒤 `accounts.google.com`에는 같은 이름의 쿠키가 두 벌(00:37 복사본, 17:20 원본)씩 갔다. Google 계정 사이트를 거치는
  흐름(콘솔의 로그인 확인, OAuth 동의)은 이것을 `CookieMismatch`로 돌려보냈다. Search Console은 `.google.com` 도메인 쿠키로 열려(그 쿠키는 그대로
  복사됨) 되었다고 본다(추정). 같은 17:20에 사람의 로그인 복사가 기본 프로필에도 두 벌을 만들어(기본 프로필의 호스트 전용 원본은 10-23, 복사본은
  17:20), 그 뒤에 만드는 작업도 같은 상태로 시작한다. 16:49 업데이트 재시작은 계기가 아니다: 폴더가 새로 생기지 않았고(쿠키 DB 생성 00:37, 별칭
  없음), 다시 복사한 쿠키가 없으며(복사본은 모두 00:37), Google 쿠키는 모두 영속 쿠키다.
- **설치본의 다른 사실:** 쿠키 DB는 Chromium 154의 스키마 24(`top_frame_site_key`, `source_scheme`, `source_port`, `source_type` 등)다. 복사로 생긴
  쿠키는 `source_type` 3(API로 넣은 쿠키)으로 남아 원본(1: HTTP 응답, 2: 스크립트)과 구별된다. 기본 프로필에서 복사한 작업은 호스트
  전용 쿠키 0개, `__Host-` 쿠키 0개였고, 기본 프로필의 파티션 쿠키 7개가 모두 파티션 없이 들어 있었다. 기본 프로필에는 다른 사이트에서도 호스트
  전용 원본과 도메인 복사본이 같은 이름으로 함께 있고(Google 3, 다른 사이트 3), 원본이 호스트 전용인 것으로 보이는 도메인 복사본이 45개 있다.
  `Preferences`의 쿠키 설정(`profile.cookie_controls_mode`, 서드파티 차단, 쿠키 예외)은 기본 프로필과 작업 프로필 모두 적혀 있지 않아 Chrome
  기본값이고, `chromium.log`에는 쿠키 줄이 없다.
- **서드파티 쿠키·사용자 에이전트는 원인이 아니다(QA):** 다른 사이트 프레임에서 `SameSite=None; Secure` 쿠키와 파티션 쿠키가 모두 저장·읽히고
  `hasStorageAccess()`가 true다(Chrome의 일반 프로필 기본과 같음). 사이트가 받는 것은 `Chrome/154.0.0.0` 사용자 에이전트와 `Sec-CH-UA: "Not A(Brand";v="99",
  "Chromium";v="154"`이다(Chrome의 "Google Chrome" 브랜드 대신 Chromium. Search Console이 같은 탭에서 된 것과 맞음).
- **고친 것:** `YardletCEFBridge.c`의 쿠키 복사. 호스트 전용 쿠키는 도메인을 비우고 주소의 호스트로만 넣는다(Claude 앱의 복사와 같은 방법). 원본의
  쿠키를 모두 읽은 뒤 쿠키마다의 주소로 원본에 다시 물어(`visit_url_cookies`, CEF가 파티션 없는 쿠키만 돌려줌) 답에 든 쿠키만 넣는다. 파티션 쿠키는
  옮기지 않는다(5절). 쿠키 300개(호스트 150곳, Chromium의 사이트당 상한으로 약 186개가 남음)를 가진 기본 프로필에서 새 작업이 페이지를 열기까지
  0.21초였다(임시 측정, 커밋하지 않음).
- **두 앱(번들 바이트, 실행하지 않음):** Claude 앱 3.1623.3은 세션을 분기할 때 `cookies.get({})`로 읽어 `cookies.set`으로 넣으며 호스트 전용 쿠키는
  `domain`을 뺀다(`bgi`: `...e.hostOnly?{}:{domain:e.domain}`, 주소는 `secure`면 https 아니면 http). 파티션 키는 다루지 않는다. Codex 앱 26.1016은 모든
  스레드가 저장소 하나(`persist:codex-browser-app`)라 프로필 사이 복사가 없다. 두 앱 모두 서드파티 쿠키 정책을 바꾸는 스위치·설정을 찾지 못했다.
- **이미 바뀐 쿠키(한 번 정리, `BrowserCookieCopyRepair`):** 고친 복사는 이미 저장된 복사본을 고치지 않으므로, Yardlet이 브라우저 호스트를 처음
  띄우기 직전에 한 번 정리한다(호스트가 쿠키 DB를 열고 있으면 할 수 없다). 기본 프로필과 `Task-<UUID>` 프로필의 `Cookies`에서, 복사로 생긴
  도메인 쿠키(`source_type` 3, `.호스트`) 가운데 사이트가 직접 만든(`source_type` 1·2) 같은 이름·경로·파티션의 호스트 전용 쿠키와 두 벌인 것만
  지운다. 고치기 전 복사는 등록 도메인의 호스트 전용 쿠키를 만든 적이 없어, 그 두 벌의 호스트 전용 쪽은 언제나 사이트의 것이다. 사이트 자신의
  두 벌, 짝 없는 복사본, 고친 복사가 옮긴 사이트의 두 벌(둘 다 복사본)은 남는다. 지울 것이 있는 DB만 먼저 `Cookies`와 `-journal`·`-wal`을
  `~/.Trash/Yardlet cookie backup <날짜 시각>/<프로필>/`에 복사하고, 백업이 실패한 프로필은 그대로 둔다. 한 트랜잭션으로 지운다. 모두 끝나면
  root cache에 `CookieCopyRepair.json`(실행 시각과 프로필별 지운 개수만)을 남겨 다시 돌지 않는다. 호스트가 잡고 있거나(`SingletonLock`의 PID가 살아
  있음), 읽을 수 없거나(롤백이 필요한 저널 등), 백업·삭제가 실패하면 기록을 남기지 않아 다음 시작에 다시 한다. 휴지통은 `NSHomeDirectory()`의
  것이다(FileManager의 휴지통은 QA가 준 홈을 따르지 않아, 첫 QA에서 백업이 사람의 휴지통에 갔다). 그 사이트들에 다시 로그인해야 할 수 있다.
- **QA:** 6절의 쿠키 확인. 고치기 전 빌드(QA만 더함)에서 새 작업의 두 사이트 확인은 `CookieMismatch`(`__Host-qa_signin` 빠짐, 파티션
  쿠키가 최상위 사이트로 샘), 새 작업의 `qa_signin`은 `.accounts.example.com`, 다시 로그인을 옮긴 기본 프로필의 `qa_signin`은 두 벌(A, B)이었다. 고친
  빌드에서 4개 모두 통과하고, 격리 QA 전체 13개가 통과했다. 한 번 정리는 `BrowserCookieCopyRepairTests`(임시 폴더의 DB)와 QA 홈에서 앱을 다섯 번
  띄워 확인했다: 빈 홈에서 기록만 남음, 두 벌을 심고 기록을 지우면 그 두 벌만 지우고 QA 홈의 휴지통에 백업, 기록이 있으면 다시 돌지 않음.

## 9. 고침: 정리한 뒤에도 두 벌이 다시 퍼졌다(2026-10-26)

- **증상:** 사용자가 한 작업에서 Sentry에 Google로 로그인하자 다시 `/CookieMismatch`였다. 8절의 한 번 정리(10-26 03:48 KST,
  기본 프로필 3개·작업 둘 5개)가 끝난 뒤였다.
- **원인:** 8절의 고친 복사는 쿠키 모양을 지켰지만 두 가지를 하지 않았다. (1) 보내는 프로필에 예전 복사가 만든 도메인 쿠키
  (`.accounts.google.com`의 `LSID`·`ACCOUNT_CHOOSER`·`OTZ`, `source_type` 3)가 사이트의 호스트 전용 쿠키 옆에 있으면 둘 다 옮겼다.
  (2) 받는 프로필에 다른 모양의 같은 쿠키가 있어도 지우지 않고 더했다. 한 번 정리는 짝이 있는 프로필에서만 지웠으므로, 짝 없이
  도메인 쿠키만 남은 프로필에서 다시 로그인이 옮겨지면 기본 프로필에 두 벌이 생겼고(10-26 14:17), 그 뒤 만든 작업이 두 벌로 시작했다.
  10-26 14시 기준 기본 프로필, ERP 작업, 오픈소스 작업(40F6679B)에 두 벌이 있었다.
- **고침:** 복사(`set_copied_cookies`)가 보내는 쪽에서 같은 호스트·이름·경로의 호스트 전용 쿠키가 있는 도메인 쿠키를 빼고, 쿠키마다
  받는 쪽의 다른 모양(호스트 전용이면 도메인 쿠키, 도메인 쿠키면 호스트 전용)을 먼저 지운다. CEF에는 정확히 하나를 지우는 호출이 없어서,
  같은 이름·도메인·경로의 쿠키를 이미 만료된 채로 쓴다. Chromium은 그 쿠키 하나만 지운다(`cookie_monster.cc`
  `DELETE_COOKIE_EXPIRED_OVERWRITE`, 154.0.8037.58 원본). 한 번 정리는 2회차(`CookieCopyRepair.json`의 `round` 2)로 다시 한 번 돈다.
- **QA:** 6절 마지막 단계에 기본 프로필과 작업 F 양쪽에 예전 복사의 도메인 쿠키(`.accounts.example.com` `qa_signin=OLD`)를 심었다.
  기본 프로필과 뒤에 만든 작업 G가 `qa_signin`을 `B` 하나만 보내 격리 QA 13개가 통과했다. 비밀번호 QA 22개도 통과했다.
- **3회차(같은 날):** 2회차는 22:57 KST에 ERP 작업과 Mobi CS 작업에서 3개씩 지웠지만, 기본 프로필 6쌍과 작업 둘(5쌍, 3쌍)을 남겼다.
  남은 쌍은 호스트 전용 쪽도 복사본(`source_type` 3)이었다. 정리 전의 두 벌이 프로필 사이를 오가며 양쪽 모두 복사본이 된 것이다. 예전 복사는
  호스트 전용 쿠키를 만들지 않았으므로 쌍의 호스트 전용 쪽은 출처가 무엇이든 사이트의 모양이다. 그래서 3회차는 호스트 전용 쿠키와 짝인
  복사된 도메인 쿠키를 모두 지운다. 사이트가 직접 둘 다 만든 쌍(예: `search.google.com`의 `_ga`)은 남긴다.

## 10. 다른 브라우저에서 로그인 가져오기(2026-10-26, 2026-10-27 브라우저 넓힘)

- **계기:** 패스키로만 로그인되는 사이트는 패스키가 다른 브라우저(iCloud 키체인, Whale, Chrome)에만
  있어 Yardlet 브라우저에서 로그인할 수 없다. 그 브라우저의 로그인 쿠키를 가져오면 Yardlet에서 그 사이트에 들어갈 수 있고, 그 사이트 설정에서
  Yardlet 패스키를 하나 더 등록하면 그 뒤로는 Yardlet만으로 된다. [BROWSER_VAULT_DESIGN](BROWSER_VAULT_DESIGN.md)의 "Aside와 Ego 비교"에서 미뤄 둔 ④다.
- **사람이 하는 것:** 브라우저 패널의 페이지에서 오른쪽 클릭 → "다른 브라우저에서 로그인 가져오기…" → 브라우저·프로필 고르기 → 사이트 체크(지금
  페이지의 사이트는 맨 위에 체크된 채) → 가져오기 → macOS의 키체인 허용 창("Yardlet이 키체인의 'Whale Safe Storage'를 사용하려고 합니다")에서
  허용. 끝나면 패널이 "Whale에서 … 로그인을 가져왔습니다"를 보이고, 페이지가 그 사이트면 다시 읽는다.
- **찾는 브라우저(2026-10-27 넓힘):** `~/Library/Application Support`에서 Chromium 계열 Whale, Chrome, Edge, Brave, Arc, Comet, Vivaldi, Opera,
  Opera GX, Yandex, Helium, Chromium과 Firefox 계열 Firefox, Zen, Floorp, LibreWolf, Waterfox 순서로 찾는다. 폴더·키체인 이름과 근거는 아래 표.
  이 Mac에 쿠키 DB가 있는 프로필만 보이고, 시트는 그 브라우저 앱이 있으면 앱 번들의 아이콘을, 없으면 지구본 기호를 붙인다
  (`NSWorkspace.urlForApplication(withBundleIdentifier:)`, 앱을 실행하지 않음).
  - Chromium 계열: `Local State`(`profile.info_cache`의 이름, `profiles_order`, `last_used`가 먼저)에서 프로필을 읽고, 쿠키 DB(`<프로필>/Network/Cookies`,
    없으면 `<프로필>/Cookies`: Whale·Comet은 뒤쪽)가 있는 프로필만 보인다. Opera처럼 브라우저 폴더 자체가 첫 프로필이면(폴더 바로 아래 쿠키 DB) 그것도
    브라우저 이름만으로 보인다. 키체인 항목은 서비스 이름만으로 찾는다(브라우저마다 한 항목이고, 계정 이름은 브라우저마다 달라 확인하지 못한 것이 있다).
  - Firefox 계열: `profiles.ini`의 `[Profile…]` 절(`Name`, `Path`, `IsRelative=1`이면 브라우저 폴더 아래)에서 `cookies.sqlite`가 있는 프로필만 보인다.
    그 설치가 쓰는 프로필(`[Install…]`의 `Default`)이 먼저, 다음이 `Default=1`, 나머지는 파일 순서다. 키체인은 쓰지 않는다.
- **macOS 27의 브라우저 폴더 보호(2026-10-27 확인):** macOS 27의 `/usr/libexec/sandboxd`에 들어 있는 규칙(`defaultRules-3`)이 Chrome(`Google/Chrome`),
  Brave(`BraveSoftware/Brave-Browser`), Edge(`Microsoft Edge`), Firefox(`Firefox`) 폴더를 그 브라우저 자신의 팀 ID·서명 ID와 Safari의 가져오기 서비스
  (`com.apple.Safari.BrowserDataImportingService`, Chrome·Firefox만)에게만 연다. 다른 앱이 읽으면 허용 창 없이 `Operation not permitted`가 난다(이 작업의
  셸에서 Chrome 폴더 목록을 읽어 보고 `sandboxd` 로그 "TCC denied kTCCServiceSystemPolicyAppDataDetailed for com.google.Chrome"로 확인, Apple 개발자 포럼
  847030의 DTS 답 "intentional change"). 같은 보고에서 전체 디스크 접근을 받은 앱은 읽힌다. 그래서 목록 파일(`Local State`, `profiles.ini`)이 있는데
  읽히지 않는 브라우저는 목록에 넣지 않고, 시트 아래에 "Chrome의 데이터는 macOS가 전체 디스크 접근 권한이 있는 앱에만 열어 주어 목록에 없습니다"로
  이름만 적는다. 권한을 묻는 창이나 설정 단추는 두지 않았다. `NativeMessagingHosts`와 Chrome의 `ChromeFeatureState`·`Crashpad`는 규칙에서 빠져 있다.
  Whale·Arc·Comet·Vivaldi·Opera·Yandex·Helium과 Firefox 밖의 Gecko 브라우저 폴더는 규칙에 없다. Yardlet(서명된 앱)이 읽을 때도 허용 창 없이 거절되는지는
  사용자 화면에 창이 뜰 수 있어 시험하지 않았다(포럼과 Claude Code 이슈 81453의 보고는 둘 다 "창 없이 거절").
- **Safari는 넣지 않았다:** Safari의 쿠키(`~/Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies`)는 macOS가 "전체 디스크
  접근"을 받은 앱에만 열어 준다. 그 권한은 다른 앱의 데이터 전부에 미치므로 이 기능 하나를 위해 Yardlet에 달라고 하지 않는다.
- **사이트 목록:** 쿠키 DB 사본에서 `host_key`와 마지막 사용 시각만 읽는다(값은 읽지 않음). 파티션 쿠키(`top_frame_site_key`가 빈 값이 아닌 것)와
  만료된 쿠키는 세지 않는다. 호스트를 등록 도메인(Public Suffix List, 금고와 같은 목록)으로 묶고, IP 주소와 `localhost`는 그대로 둔다. 최근 쓴 순서다.
- **복호화(Chromium macOS):** 키체인 비밀번호에서 PBKDF2-HMAC-SHA1(salt "saltysalt", 1003회, 16바이트)로 AES-128 키를 만들고, `v10` 접두사 뒤를
  AES-128-CBC(IV는 공백 16개, PKCS#7)로 푼다. `meta` 버전이 24 이상이면 푼 값 앞 32바이트가 `host_key`의 SHA-256이어야 하고(다르면 그 쿠키는 뺀다),
  그 뒤가 값이다. 하나도 풀리지 않으면 키가 그 프로필의 것이 아니라고 보고 아무것도 넣지 않는다. 암호화되지 않은 `value`도 받는다.
- **Firefox 읽기(2026-10-27):** `cookies.sqlite`(WAL 모드라 최근 쿠키는 `-wal`에 있다)를 같은 방법으로 복사해 `moz_cookies`를 평문으로 읽는다.
  Firefox 158 소스 `netwerk/cookie/CookiePersistentStorage.cpp`(스키마 17) 기준으로 바꾼다: `host`의 앞 점은 도메인 쿠키, `isSecure`·`isHttpOnly`는
  그대로, `expiry`는 스키마 16부터 1970년 기준 **밀리초**(그전은 초, `PRAGMA user_version`으로 가름)라 Chromium의 1601년 기준 마이크로초로 바꾼다.
  SameSite는 `nsICookie`의 0 None·1 Lax·2 Strict·256 미지정을 CEF의 1·2·3·0으로 옮기고, Secure가 아닌 None은 Chromium이 받지 않아 미지정으로 둔다
  (스키마 15 전의 `rawSameSite` None·`sameSite` Lax도 미지정). 우선순위는 없어 보통이다. `originAttributes`가 빈 값인 쿠키만 받는다: `partitionKey`
  (파티션), `userContextId`(컨테이너), `privateBrowsingId`가 붙은 것은 다른 정체성이라 넣지 않는다. Firefox는 세션 쿠키를 파일에 두지 않아 브라우저를
  닫으면 끝나는 로그인은 가져올 수 없다. `lastAccessed`(1970년 기준 마이크로초)는 사이트 순서에만 쓴다.
- **넣기:** 앱이 고른 사이트(와 그 하위 도메인)의 쿠키를 `importCookies` 명령으로 호스트에 보낸다. 호스트는 대상 프로필의 그 사이트 쿠키를 모두
  지우고(`visit_all_cookies`의 삭제 표시, 파티션 쿠키 포함), 8·9절의 넣기 경로(`set_copied_cookies`)로 넣는다: 호스트 전용 쿠키는 도메인을 비워
  호스트 전용으로, Secure·HttpOnly·SameSite·우선순위·만료(Chromium의 1601년 기준 마이크로초 그대로)를 지키고, 같은 호스트·이름·경로의 호스트 전용
  쿠키가 있는 도메인 쿠키는 빼며, 쿠키마다 받는 쪽의 다른 모양을 지운다. 9절 3회차와 같이 짝이면 호스트 전용 쪽이 남는다. 그 뒤 저장소를 디스크에
  반영하고(`flush_store`) 답한다. 대상은 기본
  프로필과 패널 작업의 프로필이다. 작업 프로필 폴더가 아직 없으면 건드리지 않는다(첫 탭이 열릴 때 기본 프로필에서 받는다). "모든 작업이 함께"이면
  기본 프로필 하나다.
- **지우고 넣는 이유:** 다른 브라우저의 로그인과 Yardlet에 있던 같은 사이트 쿠키가 섞이면 두 세션의 쿠키가 한 사이트에 간다. Google 계정 사이트는
  그런 상태를 `/CookieMismatch`로 막았다(8·9절). Claude 앱의 가져오기는 지우지 않고 덮어쓴다.
- **보안:** Chromium 계열의 키체인은 가져오기를 누른 그때 한 번 읽고(`SecItemCopyMatching`, 서비스 이름만, 백그라운드 스레드), 비밀번호와 키는
  메모리에서만 쓰고 0으로 지운다. Firefox 계열은 키체인을 읽지 않는다.
  쿠키 DB는 브라우저가 쓰는 중일 수 있어 `-journal`·`-wal`과 함께 `$TMPDIR`의 개인 폴더(0700)에 복사해 읽기 전용으로 열고, 쓰는 도중의 사본이라
  열리지 않으면 0.3초 뒤 다시 복사한다(세 번). 사본은 읽은 뒤 바로 지운다(값이 암호화된 채라도 휴지통으로 보내지 않는다). 원본은 열지 않는다.
  쿠키 값은 앱과 호스트 사이 파이프로만 가고, 화면·로그·모델·파일에 남지 않는다(호스트의 명령 기록은 명령 이름만 적는다). 에이전트 도구는 없다.
- **한계:** localStorage·IndexedDB에 로그인을 두는 사이트는 따라오지 않는다(Claude 앱은 localStorage도 옮긴다). Chromium은 넣는 쿠키의 만료를
  넣은 때부터 최대 400일로 줄인다(원본 근거, QA로 재지 않음). 가져온 쿠키는 그 브라우저의 세션을 함께 쓰는 것이라, 사이트에 따라 한쪽에서
  로그아웃하면 다른 쪽도 끊긴다. 이미 돌고 있는 다른 작업은 바뀌지 않는다.
- **QA:** `run-check.sh … --ui-fixture-browser-check-only=import`(`BrowserHostLoginImportQA`). QA 홈의 Application Support에 가짜 Whale 폴더(프로필 둘,
  시험 비밀번호로 암호화한 쿠키: `accounts.example.com`의 호스트 전용·`__Host-` 쿠키, `.example.com`의 Secure·비Secure 쿠키, 파티션 쿠키, 만료된 쿠키,
  `localhost` 쿠키, 고르지 않을 `www.other.test` 쿠키)를 만들고, 키체인 대신 그 비밀번호를 넘긴다. 기본 프로필에는 예전 복사의 도메인 쿠키와 사이트의
  다른 쿠키를, 패널 작업에는 그 작업의 로그인을 먼저 심는다. 2026-10-27 결과(ad-hoc 디버그 번들, 새 QA 홈): 9개 모두 통과. 사이트 목록은
  `example.com`·`localhost`·`other.test`(파티션·만료 쿠키만 있는 사이트 없음), 페이지 메뉴에 항목이 있고 시트가 `localhost`를 체크한 채 열림(그림
  `import-sheet.png`), 기본 프로필·패널 작업·뒤에 만든 작업 모두 `accounts.example.com`에 `qa_signin`·`__Host-qa_signin`·`qa_session`을 가져온 값 하나씩
  보내고 이전의 `OLD`·`Y`·`T`와 `qa_leftover`가 없음, 저장 모양은 `__Host-qa_signin accounts.example.com Secure HttpOnly Lax`, `qa_plain .example.com
  비Secure Lax 세션`, `qa_session .example.com Secure HttpOnly None`, `qa_signin accounts.example.com Secure HttpOnly None`, `keep.test`는 그대로이고
  `other.test`는 들어오지 않음, 패널 페이지가 다시 읽혀 `qa_local`을 봄, 앱·호스트 로그에 값 없음. 남은 프로세스·충돌 보고서 없음.
  **2026-10-27 넓힘:** 같은 QA 홈에 가짜 Firefox 폴더(`profiles.ini`의 프로필 둘, 설치가 쓰는 것과 `Default=1`이 다름, 스키마 17의 `cookies.sqlite`를
  WAL에 둔 채: `accounts.example.net`의 호스트 전용 Strict, `.example.net`의 SameSite 미지정·Secure None·비Secure None, 같은 이름의 컨테이너 쿠키,
  파티션 쿠키, 만료된 쿠키)와 `Local State`를 읽을 수 없게 둔 가짜 Chrome 폴더를 더했다. Whale 다음에 Firefox를 키체인 없이 가져온다. 결과(ad-hoc
  디버그 번들, `$TMPDIR/browser-host-qa/import-more-browsers/`): 밝은 화면 `run-import`·어두운 화면 `run-import-dark` 모두 13개 통과. 프로필 순서
  `Whale · Work`, `Whale · Person 1`, `Firefox · default-release`, `Firefox · old`와 읽지 못한 브라우저 `Chrome`, Firefox 사이트는 WAL까지 읽어
  `example.net`, 기본 프로필의 Firefox 쿠키 저장 모양 `qa_ff_signin accounts.example.net Secure HttpOnly Strict`, `qa_ff_session .example.net Secure
  HttpOnly (미지정)`, `qa_ff_cross .example.net Secure HttpOnly None`, `qa_ff_plain .example.net 비Secure (미지정)`(모두 만료 있음), 패널 작업은 같은 네
  값을 보내고 컨테이너 값은 없음, 패널 알림 "Firefox에서 example.net 로그인을 가져왔습니다.", 앱·호스트 로그에 값 없음, 남은 프로세스·충돌 보고서
  없음. 시트 그림(`import-sheet.png`)에 Whale 설치본의 아이콘과 Chrome 안내 줄이 보인다. 지구본 기호는 메뉴를 열어야 보여 그리지 않았다.

### 지원 브라우저와 근거(2026-10-27)

폴더는 `~/Library/Application Support/` 아래, 키체인은 서비스(괄호는 같은 자리에서 본 계정)다. "배포본"은 그 회사 서버에서 받은 dmg·tar.xz·pkg를
읽기 전용으로 붙이거나 설치 없이 풀어 Info.plist와 바이트만 읽은 것이고(앱은 실행하지 않음), "설치본"은 이 Mac의 앱 번들이다. Chromium 계열의
바이트 근거는 Chromium의 쿠키 키 소금 `saltysalt` 바로 뒤에 놓이는 서비스·계정 상수, 또는 `chrome_paths` 옆의 기본 폴더 값이다. 여러 브라우저가
다른 브라우저의 가져오기 표를 품고 있어(Brave 소스, Comet·Dia·Vivaldi·Yandex·Opera 바이트) 교차 확인에 썼다.

| 브라우저 | 폴더 | 키체인 | 번들 ID | 근거 |
|---|---|---|---|---|
| Whale | `Naver/Whale` | Whale Safe Storage (Whale) | `com.naver.Whale` | 설치본 5.39.412.57 바이트, 이 Mac의 폴더(`<프로필>/Cookies`) |
| Chrome | `Google/Chrome` | Chrome Safe Storage (Chrome) | `com.google.Chrome` | 설치본 155.0.8059.86 바이트, Chromium 소스. macOS 27 보호 |
| Edge | `Microsoft Edge` | Microsoft Edge Safe Storage (Microsoft Edge) | `com.microsoft.edgemac` | 배포본 pkg 156.0.4314.42 바이트, 폴더는 `sandboxd` 규칙과 Dia·Yandex 표. macOS 27 보호 |
| Brave | `BraveSoftware/Brave-Browser` | Brave Safe Storage | `com.brave.Browser` | 배포본 156.1.98.60 `CrProductDirName`, brave-core `keychain_password_mac.mm` 기본값. macOS 27 보호 |
| Arc | `Arc/User Data` | Arc Safe Storage | `company.thebrowser.Browser` | 배포본 1.170.0 ArcCore 바이트(`%s Safe Storage`와 arc→Arc), Comet·Vivaldi·Opera 표, 이 Mac의 `Arc/User Data/Local State` |
| Comet | `Comet` | Comet Safe Storage | `ai.perplexity.comet` | 배포본 155.0.8059.148 바이트, 이 Mac의 `Comet/Local State`·`Default/Cookies` |
| Vivaldi | `Vivaldi` | Vivaldi Safe Storage (Vivaldi) | `com.vivaldi.Vivaldi` | 배포본 8.2.4133.94 바이트, 폴더는 Dia 표와 Vivaldi 포럼 |
| Opera | `com.operasoftware.Opera`(폴더 자체가 첫 프로필) | Opera Safe Storage (Opera) | `com.operasoftware.Opera` | 배포본 138.0.6044.24 바이트, 폴더는 Dia·Yandex 표, 첫 프로필 자리는 Opera 포럼 운영진 답 |
| Opera GX | `com.operasoftware.OperaGX` | Opera Safe Storage (Opera) | `com.operasoftware.OperaGX` | 배포본 138.0.6044.45 바이트(GX 빌드도 같은 상수, `com.operasoftware.OperaGX` 9회), Dia·Yandex 표. Vivaldi 표만 "Opera GX Safe Storage"라 적어 GX 자신의 바이트를 따랐다 |
| Yandex | `Yandex/YandexBrowser` | Yandex Safe Storage (Yandex) | `ru.yandex.desktop.yandex-browser` | 배포본 26.8.3.1016 바이트, Brave 소스. 쿠키가 `v10`으로 암호화되는지는 확인 못 함(아니면 "풀지 못했습니다"로 끝남) |
| Helium | `net.imput.helium` | Helium Storage Key (Helium) | `net.imput.helium` | 배포본 0.20.1.1 바이트, helium-macos 패치 `change-keychain-name`·`change-product-dir-name` |
| Chromium | `Chromium` | Chromium Safe Storage (Chromium) | `org.chromium.Chromium` | Chromium 소스 `keychain_password_mac.mm`·`chrome_paths_mac.mm`·`BRANDING` |
| Firefox | `Firefox` | 없음 | `org.mozilla.firefox` | 배포본 158.0.1 `application.ini`(`Name=Firefox`), Gecko `nsXREDirProvider::AppendProfilePath`(macOS는 `Profile`, 없으면 `Name`). macOS 27 보호 |
| Zen | `zen` | 없음 | `app.zen-browser.zen` | 배포본 1.23.4b `Profile=zen` |
| Floorp | `Floorp` | 없음 | `app.floorp.Floorp` | 배포본 12.20.2 `Profile=Floorp` |
| LibreWolf | `librewolf` | 없음 | `net.librewolf.librewolf` | 배포본 158.0.1-2 `Profile=librewolf` |
| Waterfox | `Waterfox` | 없음 | `net.waterfox.waterfox` | 배포본 6.7.6 `Profile=Waterfox` |

넣지 않은 것: **Dia**(배포본 1.54.2 `company.thebrowser.dia`의 ArcCore에 `%s Safe Storage` 형식만 있고 자기 폴더·서비스 문자열이 없다. Comet의 표가
"Dia Safe Storage"라 적지만 폴더는 확인하지 못했다), **ChatGPT Atlas**(OpenAI 도움말 "ChatGPT Atlas retirement": 은퇴해 업데이트가 끝났고 쿠키는
새 브라우저에서 다시 로그인하라고 안내한다. 참고로 1.2026.189.1 번들의 내장 Chromium은 `com.openai.atlas.web`, "ChatGPT Safe Storage"/"ChatGPT"),
**Sidekick**(2025-08-03 서비스 종료, 팀은 Perplexity로), **Thorium**(Thorium-MacOS 릴리스가 M144(2026-06)부터 macOS 파일 없이 나오고 마지막
M138은 2026-02, Homebrew cask도 비활성), **Safari**(위).
