# 휴대폰 원격 v2 설계

상태: 2026-10-24 설계와 구현(Mac·중계·Android). 프로토콜 계약은 [REMOTE_PROTOCOL](REMOTE_PROTOCOL.md) 11~17절이다.
화면 시안은 [remote-v2/mockups.html](remote-v2/mockups.html)과 같은 폴더의 PNG다.

## 0. 결론

- **연결 경로는 셋, 보안은 하나.** 휴대폰과 Mac 사이의 모든 연결은 같은 Noise IK 핸드셰이크와 암호화로 감싼다. 그 아래
  경로는 같은 Wi-Fi 직접 연결, Tailscale, Yardlet 중계 서버 가운데 먼저 닿는 것을 휴대폰이 고른다. 경로가 무엇이든 Mac의
  정적 공개 키로 상대를 확인하므로, 중계 서버와 같은 Wi-Fi의 다른 기기는 내용을 읽거나 바꿀 수 없다.
- **짝짓기는 QR 한 번.** QR에 Mac의 정적 공개 키, 5분짜리 일회용 비밀(256비트), 중계 주소와 방 ID, 직접 연결 주소가 들어간다.
  휴대폰은 자기 키 쌍을 만들어 첫 핸드셰이크에 비밀과 함께 보낸다. Mac은 휴대폰의 공개 키만 저장한다(지금의 토큰 해시보다
  강하다: Mac에 휴대폰의 비밀이 하나도 없다).
- **중계 서버는 상자 하나.** Cloudflare Workers + Durable Objects로 Mac마다 방 하나를 두고, Mac이 나가는 WebSocket으로 방을
  열면 휴대폰의 WebSocket과 이어 준다. 서버는 암호문만 넘기고 아무것도 저장하지 않는다. 계정도 없다. 방 ID는 Mac의 서명 키에서
  나오고(자기 증명), Mac은 그 키로 서명해 방을 연다. 사용자 한 명은 무료 요금제 안에 든다.
- **알림은 암호문만.** 휴대폰이 FCM 토큰을 Mac에 알려 두면, 휴대폰이 연결되어 있지 않을 때 Mac이 중계 서버를 거쳐 FCM 데이터
  메시지를 보낸다. 내용(작업 제목, 요청 요약)은 짝짓기 때 나눈 알림 키로 암호화되어 Google과 중계 서버는 읽지 못한다. FCM이
  없으면 지금처럼 "백그라운드 알림"(앞쪽 서비스)으로 받는다.
- **휴대폰에서 새로 하는 일:** 질문 카드 답하기, 계획 검토(승인·계속 계획), 새 작업 만들기(Mac의 새 작업 기본값으로). 설정·
  계정·파일·diff·터미널은 여전히 Mac에서 한다.
- **플랫폼은 Android 네이티브(Kotlin, Compose)를 잇는다.** iOS는 나중에 SwiftUI로 만들고 Mac의 `YardletRemote` 패키지(프로토콜
  타입, Noise)를 그대로 쓴다. 두 기준 앱도 플랫폼마다 네이티브 앱이다.
- **계정은 선택(2026-10-24 사용자 요청).** QR 없이 계정으로 로그인해 자기 Mac 목록에서 고르고, 새 휴대폰은 Mac이나 이미 연결된
  휴대폰이 확인 코드를 보고 승인한다(Signal·WhatsApp의 연결된 기기와 같다). 계정 서버는 Mac 목록만 알고 내용은 모른다(3.1).
- **두 앱보다 빠르고 넓게(같은 날 사용자 요청).** 마지막 목록과 대화를 휴대폰에 두고 먼저 그린 뒤 최신으로 바꾸고, 목표 시간을 정해
  잰다(5.1). 명령 출력과 diff, 제안된 작업 다루기, 고정·보관, 여러 Mac까지 휴대폰에서 한다(5절).
- **작업 중 잠자기·화면 잠금 막기(같은 날 사용자 결정).** 설정으로 켜고(기본 꺼짐), 작업이 일하는 동안만 화면 꺼짐까지 막는다.
  배터리 20% 아래와 과열이면 멈춘다. 덮개 닫힘은 관리자 권한이 들어 넣지 않는다(6.5).
- **Mac 없이 둘러보기와 APK 먼저(같은 날 사용자 결정).** 첫 화면의 "Explore without a Mac"을 누르면 휴대폰 안의 데모 Mac에 붙어 작업
  목록·대화·승인·질문·계획 검토·diff·새 작업·알림을 써 본다. 네트워크와 저장소를 쓰지 않는다(8절). 배포는 GitHub Releases APK와
  Obtainium을 먼저 하고, Play 비공개 테스트는 데모 모드와 Mac 공개 뒤의 실제 사용자로 천천히 채운다(12절).
- **v1 휴대폰은 깨지지 않는다.** v1 리스너(Tailscale 주소, 47615, 평문 JSON과 토큰)는 그대로 둔다. 이미 짝지은 v1 기기는 계속
  쓰고, 새 짝짓기는 v2 QR만 보인다. 새 앱은 v1을 말하지 않으므로 한 번 다시 짝짓는다.

## 1. 기준 대조

### 1.1 두 앱(2026-10-24, 공개 문서와 설치본 바이트)

| | Claude Code Remote Control(Claude 앱 Code 탭) | Codex Remote(ChatGPT 앱의 Codex) |
|---|---|---|
| 구조 | 로컬 CLI가 Anthropic으로 나가는 HTTPS만. 들어오는 포트 없음 | 호스트(데스크톱 앱)가 OpenAI의 중계 층에 등록, 휴대폰은 계정으로 들어옴 |
| 짝짓기 | 같은 claude.ai 계정. QR·세션 URL·세션 목록. 선택 사항으로 Trusted Devices | 호스트 설정 › Connections › Control this Mac에서 허용, QR로 휴대폰마다·호스트마다. 수동 코드(만료 있음)도 있음. 계정 MFA |
| 암호 | TLS. 대화 기록이 Anthropic 서버에 저장됨(문서에 명시) | 번들 CLI에 `Noise_hybridIK_X25519+MLKEM768_AESGCM_SHA256`. 휴대폰 연결 전체가 E2EE인지는 공개 자료로 확정 못 함 |
| 휴대폰에서 | 메시지, 중단, 권한 승인, `AskUserQuestion` 답, 계획 승인, 사진·파일 첨부, 서버 모드에서 새 세션 | 메시지(Queue·Steer), 중단, 승인(한 번·대화 동안·더 넓게), 질문·MCP 폼 답, Plan 모드, 새 로컬 작업(호스트·프로젝트·worktree·브랜치), diff 검토 |
| 알림 | 모바일 푸시(완료, 판단 필요; 설정 둘) | 완료·주의 필요 알림 |
| 끊김 | 대화형은 계속 재시도, 서버 모드는 약 10분 뒤 끝날 수 있음 | 호스트가 잠들거나 앱이 꺼지면 끊김 |
| 화면 관례 | Code 탭 목록, 원격 세션에 컴퓨터 아이콘과 녹색 점 | 목록 필터(All·Cloud·컴퓨터), Pinned·Today 구획. 승인 카드: 설명·명령, Approve 위·Always approve 아래, 아래 줄에 "Tell Codex what to do" 입력과 Deny |

출처: [Claude Remote Control](https://code.claude.com/docs/en/remote-control), [Claude 모바일](https://code.claude.com/docs/en/mobile),
[Codex 원격 연결](https://learn.chatgpt.com/docs/remote-connections), [Codex 모바일](https://learn.chatgpt.com/docs/mobile),
[Codex Remote 글](https://developers.openai.com/blog/mastering-codex-remote-for-engineering). 설치본: Claude 3.1623.3
`app.asar`(`toggleRemoteControl`, 휴대폰에서 이 컴퓨터에 세션을 시작하도록 허용하는 안내), ChatGPT 26.1016.61520
(`codex-mobile-setup-dialog`: QR·수동 코드·새로 고침, CLI의 `remoteControl/pairing/start`·`manualPairingCode`). 앱은 실행하지 않았다.

**정리:** 두 앱 모두 휴대폰의 핵심을 작업 고르기·승인·질문·후속 메시지·중단·결과 보기로 잡고, 새 로컬 작업도 휴대폰에서 시작한다.
둘 다 회사 서버와 계정을 거친다. Yardlet은 계정과 서버가 없으므로 기기 키로 짝짓고, 중계는 암호문만 나르게 한다.

### 1.2 잘 알려진 원격·동기화 앱

| 앱 | 짝짓기와 신원 | 중계 | Yardlet이 가져온 것 |
|---|---|---|---|
| Syncthing | 기기 ID = 인증서 SHA-256. 로컬 발견(브로드캐스트) | 직접이 안 되면 중계, 기기 사이 TLS는 그대로라 중계가 못 읽음 | 경로와 무관한 끝단 인증, 로컬 발견 |
| KDE Connect | UDP 1716·mDNS 발견, TLS 위 짝짓기 승인, 인증서 고정 | 없음 | mDNS 발견, 고정된 상대 키 |
| Signal 기기 연결 | 새 기기의 임시 공개 키를 QR에 | 서버 mailbox에 암호문 | QR에 공개 키 |
| Tailscale | WireGuard(Noise IK 계열) | DERP가 암호문만 나르고 직접 경로로 옮김 | Noise IK, 중계 뒤 직접 경로로 올라가기 |
| Home Assistant Cloud | 계정 | TLS 암호문을 SNI로 넘기고 복호화는 집의 인스턴스 | 중계는 넘기기만 |
| Chrome Remote Desktop, Magic Wormhole | 짧은 코드 + SPAKE2(PAKE) | 직접 실패 시 중계 | 손으로 치는 짧은 코드에는 PAKE가 필요하다(다음 단계) |
| Happy(Claude Code 모바일 클라이언트) | QR에 CLI의 임시 NaCl 공개 키 | 서버가 암호화된 메시지를 저장 | 반면교사: 푸시 본문에 세션 제목이 평문으로 감. Yardlet은 푸시도 암호화 |

출처: [Syncthing](https://docs.syncthing.net/users/relaying.html), [KDE Connect 프로토콜](https://github.com/KDE/kdeconnect-meta/blob/master/protocol.md),
[Signal](https://signal.org/blog/a-synchronized-start-for-linked-devices/), [Tailscale DERP](https://tailscale.com/kb/1232/derp-servers),
[Nabu Casa](https://support.nabucasa.com/hc/en-us/articles/25619268678557-Remote-access-Deep-dive),
[Magic Wormhole](https://magic-wormhole.readthedocs.io/en/latest/welcome.html), [Happy](https://github.com/slopus/happy/blob/main/docs/encryption.md).

## 2. 연결

### 2.1 보안 채널: Noise IK

- 패턴 `Noise_IK_25519_ChaChaPoly_SHA256`, 프롤로그 `yardlet-remote/2`. 휴대폰이 시작하고(initiator) Mac이 받는다(responder).
  휴대폰은 QR로 Mac의 정적 공개 키를 이미 안다(`<- s`). 왕복 두 메시지로 끝나고, 첫 메시지부터 휴대폰의 공개 키가 암호화되어
  간다(중계는 어느 휴대폰인지도 모른다).
- 첫 메시지의 내용(payload)은 휴대폰 이름과, 짝짓기라면 QR의 일회용 비밀이다. 이 내용은 Mac의 정적 키와 휴대폰의 정적 키로
  만든 키로 암호화되므로 Mac만 읽고, 휴대폰 키의 주인만 만들 수 있다.
- 핸드셰이크 뒤의 메시지는 v1과 같은 JSON 요청·응답·이벤트다. Noise 메시지는 65,535바이트를 넘지 못하므로 큰 JSON(대화 한
  페이지는 수 MB)은 조각으로 나눈다(앞 1바이트가 "이어짐/끝").
- 모든 경로에서 같다: 같은 Wi-Fi의 `ws://`, Tailscale의 `ws://`, 중계의 `wss://`. TLS를 따로 두지 않는 까닭은 Noise가 끝단을
  인증하기 때문이다(인증서 관리가 없다). 중계 구간은 `wss://`라 한 겹 더 싸인다.
- 테스트 벡터: 공개 도메인인 cacophony 벡터의 `Noise_IK_25519_ChaChaPoly_SHA256`을 Mac과 휴대폰 검사가 같이 쓴다. 두 구현이
  같은 바이트를 내야 통과한다.
- 넣지 않은 것: Codex처럼 ML-KEM을 섞는 양자 내성 혼합 IK. CryptoKit에는 있지만 Android에 표준 구현이 없다. 중계 구간의
  "지금 모아 나중에 푸는" 위험을 줄이려면 다음 단계에서 `hybridIK`로 올릴 수 있게 프롤로그에 판 번호를 둔다.

### 2.2 같은 Wi-Fi 직접 연결

- Mac은 v2 리스너를 모든 인터페이스의 TCP 47616에 연다(쓰는 중이면 빈 포트). v1처럼 주소를 골라 묶을 까닭이 없다: 핸드셰이크를
  못 하는 상대는 아무것도 얻지 못한다(Syncthing의 22000과 같다).
- Bonjour로 `_yardlet._tcp`를 알린다. 인스턴스 이름과 TXT의 `id`는 Mac 공개 키에서 나온 16자 해시라 Mac 이름이 LAN에 보이지
  않는다. 휴대폰은 저장한 Mac 키로 같은 해시를 만들어 자기 Mac을 찾는다.
- macOS 15부터 Bonjour 광고는 로컬 네트워크 허용을 묻는다(TCP 수신만으로는 묻지 않는다, Apple TN3179). 원격을 켤 때 한 번 뜨고,
  거절하면 Bonjour 없이 마지막 주소와 중계로 연결한다. Info.plist에 `NSLocalNetworkUsageDescription`과 `NSBonjourServices`
  (`_yardlet._tcp`)를 넣는다.
- Mac은 핸드셰이크 응답에 지금의 직접 주소(LAN, Tailscale, MagicDNS 이름)를 넣는다. 휴대폰은 이것을 저장해 두었다가 Bonjour가
  안 되는 망(게스트 Wi-Fi의 기기 격리 등)에서도 먼저 시도한다.
- Android 17(targetSdk 37)부터는 LAN 소켓에 `ACCESS_LOCAL_NETWORK` 권한이 든다. 지금 targetSdk 36에서는 필요 없고, 37로 올릴 때
  권한 요청과 거절 시 중계로 넘어가는 길을 넣는다.

### 2.3 Tailscale

- Tailscale 주소도 Mac의 한 인터페이스라 v2 리스너가 그대로 받는다. 휴대폰은 VPN이 켜져 있을 때 저장된 Tailscale 주소를 직접 경로로
  시도한다. 따로 할 일이 없다.
- v1 리스너(Tailscale 주소만, 47615, 평문)는 v1 기기를 위해 남긴다.

### 2.4 Yardlet 중계 서버

**모양:** Cloudflare Worker 하나와 Durable Object 클래스 하나(`Room`). Mac마다 방이 하나다.

```
Mac ──wss /v1/rooms/<방>/host──▶ Room(DO) ◀──wss /v1/rooms/<방>/connect── 휴대폰
     (나가는 연결, 서명으로 방 열기)        (암호문만 넘김)
```

- **방 ID**는 Mac의 Ed25519 중계 키의 SHA-256 앞 20바이트를 base32로 쓴 32자다. 서버는 Mac이 보낸 공개 키에서 방 ID를 다시 계산하고,
  서버가 준 nonce에 대한 서명을 확인한 뒤에만 그 방의 Mac으로 받는다. 계정·등록·저장이 없다.
- **이어 주기:** 휴대폰이 `connect`로 들어오면 방이 연결 번호를 붙여 Mac에 알리고(`open`), 그 뒤 양쪽의 바이너리 프레임을 번호를
  붙이고 떼며 넘긴다. Mac은 연결마다 Noise 응답자를 하나씩 둔다. Mac이 없으면 휴대폰의 업그레이드 요청에 404를 준다.
- **하지 않는 것:** 내용 저장, 로그에 내용 쓰기, 휴대폰 인증(방 ID를 아는 누구나 들어올 수는 있지만 Mac의 핸드셰이크에서 끊긴다).
  방 하나에 휴대폰 연결 8개, 휴대폰 프레임 65,535바이트(Noise 메시지 하나), 인증 전 10초, 말 없는 연결 120초로 막는다.
- **잠자기:** Hibernation API로 받아, 오가는 메시지가 없으면 DO가 내려가도 연결은 남고 시간 요금이 붙지 않는다. Mac의 유지 ping은
  자동 응답(`ping`→`pong`)이라 DO를 깨우지 않는다.
- **서버가 보는 것:** 방 ID, 양쪽 IP 주소, 연결·끊김 시각, 프레임 크기와 간격, 알림을 보낼 때의 FCM 토큰(보내고 버림). 보지 못하는
  것: 작업 목록, 대화, 명령, 승인, 휴대폰의 공개 키.
- **비용(2026-10-24 Cloudflare 가격표):** 무료 요금제에서도 SQLite 저장 방식 DO를 쓸 수 있고 하루 요청 100,000회, 13,000 GB-s다.
  DO가 받는 WebSocket 메시지는 20개를 요청 1회로 센다. 사용자 한 명이 하루 두 시간 휴대폰을 열어 두면 대략 요청 수백 회, 수백
  GB-s라 무료 안이다. 사용자가 1,000명이면 유료 요금제(월 $5에 DO 요청 100만 회, 400,000 GB-s 포함)에 초과분 몇 달러로 본다.
  도메인은 없어도 된다(`*.workers.dev`).
- **배포는 이번에 하지 않는다.** 코드와 로컬 실행(`wrangler dev`, 로그인 불필요)·검사까지만 한다. Mac 빌드의 기본 중계 주소는
  비워 두고, 배포한 뒤 상수 하나를 넣는다. 그때까지는 개발용 설정 값으로만 중계를 쓴다.

### 2.5 휴대폰의 경로 고르기

1. 후보를 모은다: Bonjour로 찾은 주소, 마지막에 받은 직접 주소(Wi-Fi·이더넷이면 LAN, VPN이 켜져 있으면 Tailscale), 중계.
2. 직접 후보는 바로, 중계는 0.7초 뒤에 시작해 먼저 핸드셰이크를 마친 것을 쓰고 나머지는 닫는다(직접 시도는 3초 제한).
3. 중계로 붙어 있는 동안 망이 바뀌거나 Bonjour가 Mac을 찾으면 직접 연결을 다시 시도하고, 되면 옮긴다(목록·열린 대화는 다시
   받는다).
4. 화면에는 경로를 크게 보이지 않는다. Mac 시트에 "같은 Wi-Fi로 연결됨"·"Tailscale로 연결됨"·"Yardlet 서버를 거쳐 연결됨"
   한 줄만 둔다.

## 3. 짝짓기·제거·재연결

- **Mac:** 설정 › 원격 연결 › "휴대폰 연결"이 QR을 5분 보인다. 수동 코드는 없앴다: 계정이 없는 구조에서 손으로 치는 짧은 코드는
  PAKE(SPAKE2 등)가 있어야 안전하다. QR을 휴대폰 기본 카메라로 찍어도 앱이 열린다(`yardlet-remote://pair?v=2…`).
- **휴대폰:** QR을 읽으면 이 Mac 전용 X25519 키 쌍을 만들고(Mac마다 다른 키라 Mac끼리 휴대폰을 엮을 수 없다), 개인 키는 Android
  Keystore의 AES 키로 봉인해 DataStore에 둔다. 백업에서 뺀다.
- **확정:** Mac은 첫 메시지의 비밀이 맞으면 휴대폰 공개 키를 기기 목록에 넣고 응답한다. 응답이 휴대폰에 닿지 못해 다시 시도하면,
  같은 공개 키에 한해 같은 표의 남은 시간 안에서 같은 기기로 받는다.
- **제거:** Mac 설정에서 제거하면 열린 연결을 바로 끊고(`revoked`), 그 공개 키로는 다시 들어올 수 없다(`unknownDevice`). 알림
  토큰도 함께 지운다. 휴대폰의 "연결 해제"는 Mac에 알리고(`forgetDevice`) 자기 키를 지운다.
- **재연결:** 끊기면 지수 백오프(1초→30초, ±20%), 망이 바뀌면 바로. 매번 새 핸드셰이크를 한다(세션 재개 없음).
- **여러 Mac:** 휴대폰 앱은 Mac 여럿을 저장하고, 위쪽 Mac 이름을 눌러 바꾼다. 한 번에 하나에 연결한다.

### 3.1 계정(선택)

사용자(2026-10-24): "계정 느낌으로 하는 것도 가능한게 낫지않겠어?" QR 짝짓기는 그대로 두고, 계정으로 로그인하면 그 사람의 Mac이
보이고 새 휴대폰을 붙일 수 있게 한다. 종단 간 암호화는 지킨다.

- **계정이 하는 일은 둘뿐이다.** 찾기(이 계정에 등록된 Mac의 이름·방 ID·공개 키)와, 새 휴대폰을 기존 기기의 승인으로 붙이기.
  작업·대화·명령은 계정 서버에 가지 않는다(중계를 지나더라도 암호문이다). Signal·WhatsApp의 연결된 기기처럼 서버는 기기 목록만 알고,
  새 기기는 기존 기기가 승인한다.
- **흐름:**
  1. Mac: 설정 › 원격 연결 › "계정으로 로그인"(브라우저 로그인 창) 뒤 이 Mac을 계정에 올린다(이름, 방 ID, Mac 공개 키 둘). 방 주인임은
     중계 키 서명으로 증명한다.
  2. 새 휴대폰: "계정으로 로그인" → 계정의 Mac 목록 → Mac을 고르면 그 Mac과 Noise 핸드셰이크를 하며 연결 요청(`link`)을 보낸다.
  3. Mac은 그 휴대폰을 기다림으로 둔다. Mac 화면과 이미 연결된 휴대폰에 "Pixel 9가 연결하려 합니다 · 482 913"이 뜨고, 새 휴대폰에도
     같은 숫자가 보인다. 같으면 허용한다.
  4. 허용하면 그 연결이 바로 인증되어 목록을 받는다. 2분 안에 답이 없거나 거절하면 끊는다.
- **확인 숫자가 있는 까닭:** 계정 서버가 Mac 공개 키를 바꿔치기하면(서버 침해, 운영자) 휴대폰은 가짜 Mac과 이야기하게 된다. 숫자는
  양쪽이 각자 가진 두 공개 키로 계산하므로 바꿔치기가 있으면 두 화면의 숫자가 다르다. 그래서 계정 서버를 믿지 않아도 된다(KDE
  Connect의 확인 문자열, Signal 안전 번호와 같은 생각).
- **자리를 비웠을 때:** Mac 앞이 아니면 이미 연결된 휴대폰이 승인한다. 연결된 휴대폰이 없고 Mac 앞도 아니면 붙일 수 없다. 그것이 안전한
  쪽이다.
- **로그인 수단:** GitHub과 Google을 먼저 넣는다(OAuth 2.0 인가 코드와 PKCE, 앱은 브라우저 로그인 창 `ASWebAuthenticationSession`과
  Custom Tabs). 개발 도구 사용자에게 가장 흔하고 두 플랫폼 모두 같은 길로 된다. Sign in with Apple은 iOS 앱을 만들 때 넣는다(서비스
  ID·키·도메인 확인이 필요하고, App Store는 다른 소셜 로그인을 넣은 앱에 Apple 로그인도 요구하는 경우가 있다). 이메일 링크는 메일 발송
  서비스(발신 도메인, 대개 유료)가 있어야 해서 다음으로 둔다.
- **서버에 남는 것:** 계정 ID(로그인 제공자와 그 사용자 번호의 해시. 원래 번호와 이메일은 저장하지 않음), 표시 이름(GitHub 로그인 이름
  같은 것, 선택), 등록한 Mac(이름, 방 ID, Mac 공개 키 둘, 갱신 시각), 로그인 세션(토큰의 해시, 기기 이름, 시각), 2분짜리 일회용
  로그인 코드. 남지 않는 것: 작업, 대화, 명령, 휴대폰 공개 키, 알림 토큰. Mac에서 로그아웃하면 그 Mac은 목록에서 빠진다.
- **저장 위치:** 계정마다 Durable Object 하나(계정 ID가 이름, SQLite). 모든 사용자를 담은 표는 없다.
- **QR과의 관계:** QR은 계정 없이 쓰는 기본 길로 남는다. 계정은 Mac 앞에 없을 때 새 휴대폰을 붙이거나, 여러 Mac을 한 번에 찾을 때 쓴다.

## 4. 알림

- 휴대폰이 `registerPush`로 FCM 토큰을 보내면 Mac이 기기마다 32바이트 알림 키를 만들어 답한다. 토큰과 키는 Mac의 기기 목록에 있다.
- Mac은 기기가 연결되어 있지 않을 때만 보낸다: 기다림이 시작될 때(높은 우선순위), 작업이 끝나거나 실패했을 때, 기다림이 Mac에서
  풀렸을 때(알림 회수, 보통 우선순위). 휴대폰 앱은 화면에서 나가면 연결을 닫고 알림에 맡긴다("백그라운드 알림"을 켠 경우는 그대로
  연결해 둔다).
- 내용은 v1의 `attention` 이벤트와 같은 JSON을 ChaCha20-Poly1305(알림 키, 무작위 nonce)로 암호화한 것이다. FCM 데이터 메시지는
  4 KB까지라 요약은 120자로 둔다. Google과 중계는 토큰·크기·시각만 본다.
- 높은 우선순위 데이터 메시지는 보이는 알림으로 이어져야 우선순위가 낮아지지 않는다(FCM 문서). 기다림·완료는 늘 알림을 띄우고,
  회수만 보통 우선순위로 보낸다.
- 잠금 화면에는 "승인 요청이 있습니다"만 보이고(공개 버전), 잠금을 풀면 작업 제목과 요약을 보인다.
- FCM을 쓰려면 Firebase 프로젝트가 있어야 한다(무료). 프로젝트가 없는 빌드는 알림 등록을 하지 않고 "백그라운드 알림"만 쓴다.
  iOS는 APNs로 같은 모양을 쓴다(다음 단계).

## 5. 휴대폰에서 하는 일

| 일 | v1 | v2 | 근거 |
|---|---|---|---|
| 작업 목록·상태, 대화 읽기, 메시지, 중지, 읽음 | 함 | 함 | 두 앱 모두 |
| 승인: 한 번만 허용·거부 | 함 | 함 | 영구 규칙을 만드는 답은 여전히 Mac에서 |
| 질문 카드 답하기 | Mac에서 | **함** | 두 앱 모두 휴대폰에서 답한다. Mac 카드와 같은 길(`ConversationRequestFormInput`)로 보낸다. 비밀 답 질문과 MCP 폼은 Mac에서 |
| 계획 검토 | Mac에서 | **함**: 계획 승인, 계속 계획(이유 선택) | Mac 카드가 내는 두 답 그대로. 권한 모드를 바꾸는 답은 없다 |
| 새 작업 | 없음 | **함**: 프로젝트(또는 채팅)와 첫 메시지 | 두 앱 모두 휴대폰에서 새 로컬 작업을 연다. 하네스·모델·계정·worktree는 Mac 홈 입력창의 지금 값 그대로 |
| 명령 출력, 파일 변경(diff) | 없음 | **함**: 도구 줄을 누르면 그때 불러온다(`itemDetail`) | Codex 휴대폰은 diff를 보인다. 스트림에 늘 싣지 않고 누를 때만 받아 빠르기를 지킨다 |
| 제안된 작업 | 없음 | **함**: 시작, 여기서 하기, 닫기 | Mac 칩과 같은 세 동작 |
| 하위 작업 | 부모 링크 | 부모 아래 접어 보이고 바로 연다 | 사용자는 하위 작업을 여럿 동시에 돌린다 |
| 고정·보관 | 없음 | **함** | 목록 정리 |
| 여러 Mac, 계정 | 없음 | **함** | 3절, 3.1 |
| 이미지 첨부 | 없음 | 다음 | 두 앱 모두 있다. 사진 고르기·크기 줄이기·Mac 첨부 길이 함께 들어 따로 한다 |
| 새 작업의 하네스·모델 고르기, Steer·Queue 고르기 | 없음 | 다음 | 하네스마다 모델 목록이 달라 Mac 목록을 옮겨야 한다 |
| 브라우저 탭 넘겨받기 | 없음 | 다음(6.3) | Mac 쪽 "사람을 기다림" 신호가 브라우저 격리·금고 작업에 있다 |
| 설정, 커넥터, 파일 둘러보기, 터미널 | 없음 | 하지 않음 | Mac에서 |

### 5.1 빠르기

사용자(2026-10-24): "그 두 앱의 리모트는 느리고 기능도 좀 별로여서.. 훨씬 더 많은 일을 수행가능하면 좋을 듯". 두 앱은 회사 서버를
거쳐 한 번 더 돌고, 앱을 열 때마다 처음부터 받는다. Yardlet은 같은 Wi-Fi면 Mac에 바로 붙고, 휴대폰이 마지막 상태를 갖고 있다.

| 순간 | 목표 | 어떻게 |
|---|---|---|
| 앱을 열고 목록이 보이기 | 0.3초 안(저장해 둔 목록), 최신으로 1초 안(같은 Wi-Fi)·2초 안(중계) | 마지막 목록과 연 대화를 휴대폰에 두고 먼저 그림. 경로 경주(2.5) |
| 대화 열기 | 저장한 쪽 바로, 최신 0.5초 안 | 저장한 페이지를 먼저, 구독 응답으로 바꿈 |
| Mac에서 일어난 일이 휴대폰에 | 0.5초 안 | 서버 묶음 간격(목록 0.4초, 대화 0.2초), 바뀐 것만 보냄 |
| 망이 바뀐 뒤 다시 붙기 | 1.5초 안 | 망 변경 즉시 경로 경주 |
| 승인·메시지의 응답 | 0.3초 안(같은 Wi-Fi) | Mac이 받자마자 답하고 결과는 이벤트로 |

- **바뀐 것만:** 목록은 바뀐 작업만(`tasksChanged`), 대화는 바뀐 항목만(`conversation`) 보낸다. 다시 붙으면 저장해 둔 화면을 둔 채
  새 목록과 페이지로 바꾼다. 명령 출력과 diff는 누를 때만 받는다.
- **잰다:** Mac 검사는 루프백에서 핸드셰이크와 첫 목록까지의 시간을, 휴대폰 앱은 연결·첫 목록·대화 첫 페이지 시간을 기록한다.


## 6. 자리를 비운 동안 사람이 필요한 단계를 휴대폰에서 처리하기

휴대폰에서는 브라우저를 손으로 다루기, 지문, 다른 Mac 앱 조작, Yardlet 안의 복잡한 일이 어렵다. 다른 제품이 이것을 어떻게
나누는지 보고, Yardlet은 "휴대폰에서 끝낼 수 있는 일"과 "Mac 앞에서만 되는 일"을 정직하게 가른다.

### 6.1 다른 제품(2026-10-24, 공개 문서)

| 제품 | 사람이 필요한 단계 | 휴대폰에서 | 넘긴 동안 모델 |
|---|---|---|---|
| ChatGPT 에이전트(종료)와 지금의 cloud browser | 로그인에서 멈추고 "Take over browser", 끝나면 돌려주고 이어 감. 지금은 보안 로그인 폼이 값을 원격 브라우저에 바로 넣음 | cloud browser는 휴대폰에서도 넘겨받기 | 옛 에이전트는 넘긴 동안 스크린샷과 입력한 비밀을 찍지 않는다고 명시. 지금 문서에는 같은 보장이 따로 없음 |
| Browserbase Live View | 라이브 뷰 URL(iframe)로 클릭·입력·스크롤 | 모바일 키보드는 공식 지원하지 않고 자체 입력 칸을 권함 | 세션은 기본으로 녹화됨. URL은 만료 시간(최대 6시간) |
| Steel | WebRTC(H.264, 25fps) 라이브 세션, `interactive`로 입력, 로그인·CAPTCHA용 사람 개입 문서 | 브라우저에서 보임, 터치 완전 지원은 미확인 | 디버그 URL은 인증이 없어 링크를 가진 누구나 봄. 자격 증명 칸 흐리게 하기 옵션 |
| Claude Code Remote Control | 권한 요청·`AskUserQuestion`을 답할 때까지 열어 둠 | 휴대폰에서 답함, 푸시. 화면 넘겨받기는 없음 | — |
| Aside | 승인·질문 대기 표시, MFA·패스키·CAPTCHA는 사람이. 에이전트 탭을 골라 직접 쓰고, 10-23 Computer Use와 넘겨받기 추가 | Slack·Telegram에서 지시·승인 카드·`/stop`. 화면 스트리밍은 확인 안 됨 | 미확인 |
| ego(lite), ego.app | 작업 Space에 들어가 로그인·확인을 하고 이어 감 | ego.app은 iMessage·Dynamic Island 한 번 눌러 승인을 내세움(대기자 명단 단계) | 미확인 |
| Manus | SMS 코드·CAPTCHA·MFA에서 Take Over 알림 → 처리 → 돌려주기 | 휴대폰에서 직접 다 되는지는 문서에 없음 | 미확인 |
| 1Password for Claude, Steel Credentials | 비밀번호·코드를 모델을 거치지 않고 페이지에 직접 | — | 모델 문맥에 값이 들어가지 않음 |

Apple 쪽 사실: 멀리 있는 휴대폰으로 Mac의 Touch ID를 대신하는 공식 방법은 없다. Apple Watch 승인(`deviceOwnerAuthenticationWithWatch`,
`…WithCompanion`)은 가까이 있어야 한다. 근처 기기 패스키(QR)는 두 기기 모두 Bluetooth가 필요해 화면을 휴대폰으로 보내도 풀리지 않는다.

출처: [ChatGPT agent](https://help.openai.com/en/articles/11752874-chatgpt-agent),
[cloud browser](https://help.openai.com/en/articles/20001280-using-cloud-browser-in-chatgpt),
[Browserbase Live View](https://docs.browserbase.com/platform/browser/observability/session-live-view),
[Steel 라이브 세션](https://docs.steel.dev/overview/sessions-api/embed-sessions/live-sessions),
[Steel 사람 개입](https://docs.steel.dev/overview/sessions-api/human-in-the-loop),
[Claude 권한](https://code.claude.com/docs/en/permissions), [Aside 문제 해결](https://docs.aside.com/help/troubleshooting),
[Aside 변경 기록](https://docs.aside.com/changelog/components), [ego(lite)](https://lite.ego.app/document/en/docs/quick-start),
[Manus Take Over](https://help.manus.im/en/articles/11711218-how-can-i-take-over-manus-browser-or-vs-code),
[1Password for Claude](https://support.claude.com/en/articles/15936181-get-started-with-1password-for-claude),
[Apple Watch로 잠금 해제](https://support.apple.com/en-us/102442),
[LAPolicy](https://developer.apple.com/documentation/localauthentication/lapolicy). 금고 설계의 Aside·Ego 지도는
[BROWSER_VAULT_DESIGN](BROWSER_VAULT_DESIGN.md) 2절.

**정리:** 다들 (1) 하네스의 승인·질문은 휴대폰에서 바로, (2) 로그인은 비밀을 모델 밖으로 채우고, (3) 그래도 막히면 사람이
화면을 넘겨받았다가 돌려준다. 넘겨받은 동안 모델이 화면을 보지 않는다는 약속은 ChatGPT의 옛 에이전트만 명시했다.
지문·근처 기기 인증은 누구도 원격으로 풀지 않는다.

### 6.2 Yardlet의 처리

| 단계 | 먼저 | 막히면 휴대폰에서 | Mac 앞에서만 |
|---|---|---|---|
| 하네스의 승인·질문·계획 | — | 바로 답한다(5절) | 영구 규칙을 만드는 답, 비밀 답 질문, MCP 폼 |
| 브라우저 로그인·2단계 인증 | 금고가 비밀번호·TOTP·Yardlet 패스키를 값 없이 채움([BROWSER_VAULT_DESIGN](BROWSER_VAULT_DESIGN.md)) | 금고에 없거나 사이트가 막으면 탭 넘겨받기(6.3) | — |
| CAPTCHA, 본인 확인, 결제 확인, QR 로그인 | — | 탭 넘겨받기 | 휴대폰 카메라로 Mac 화면의 QR을 찍어야 하는 로그인 |
| 지문·패스키 | Yardlet 패스키는 사람 없이 | 금고 "매번 확인" 항목은 휴대폰 생체 인증으로도 확인(6.4) | Touch ID 전용 확인, iCloud 키체인·근처 기기 패스키, macOS 관리자 암호, 키체인 허용 창: 휴대폰에는 "Mac에서 처리해야 합니다"로 알린다 |
| 다른 Mac 앱 | 하네스의 컴퓨터 조작(Codex computer-use, Claude `--chrome`). "작업 중 화면 잠금 막기"를 켜면 화면이 잠기지 않는다(6.5) | 그 하네스의 승인에 답한다 | 그 설정이 꺼져 있고 화면이 잠긴 Mac의 화면 조작 |
| Yardlet 안의 복잡한 일 | — | 조율 작업(예: 고정한 채팅 작업)에 말로 맡긴다. 그 작업이 세션 도구([AGENT_BROWSER_TOOLS](AGENT_BROWSER_TOOLS.md): `create_task`, `send_message_to_task`, `read_task`)로 다른 작업을 만들고 묻고 정리한다 | 설정, 계정, 커넥터, 파일·diff 검토 |

- 휴대폰 앱은 자주 하는 일(기다리는 작업 보기, 승인, 질문 답, 메시지, 대화 읽기, 새 작업)만 잘 만든다. 고정한 작업은 목록 위에
  두어 조율 작업을 찾기 쉽게 한다. Mac 설정 화면을 휴대폰에 옮기지 않는다.
- "Mac에서 처리해야 합니다"는 v1의 `moreOnMac`과 같은 정직한 표시다. 무엇을 해야 하는지(예: "Mac에서 Touch ID 확인")를 한 줄로 보이고,
  휴대폰에서 할 수 있는 척하지 않는다.

### 6.3 브라우저 탭 넘겨받기(다음 단계 설계)

Yardlet 브라우저는 CEF 화면 밖 렌더링이고 탭마다 DevTools 프로토콜을 쥐고 있어(에이전트 도구가 이미 쓴다), 탭 하나의 화면과
입력만 휴대폰으로 보내기 쉽다. Mac 쪽에서 "사람을 기다림"을 만드는 일(에이전트가 사람을 부르는 도구, 금고의 "넘기고 기다리기")은
브라우저 격리·금고 작업이 맡고, 이 설계는 휴대폰 쪽(보기, 입력, 알림)과 프로토콜을 정한다.

- **신호:** 작업의 주의 상태가 `waiting`(`pendingRequest` `browser`)이 되고, 대화에 요청 항목(`requestKind` `browserHandoff`: 탭 ID,
  사이트, 이유 한 줄)이 생긴다. 알림은 "‘작업 제목’이 github.com에서 기다립니다". 사람이 직접 고른 탭도 같은 길로 넘겨받는다.
- **보기:** `watchTab {taskId, tabId}`에 Mac이 CDP `Page.startScreencast`로 받은 JPEG를 `tabFrame` 이벤트로 보낸다(휴대폰 폭에 맞춘
  최대 폭, 품질 60, 프레임마다 확인 응답으로 흐름 조절, 화면에 보일 때만). 한 장 50~100 KB, 초당 2~5장이라 중계로도 된다.
- **입력:** `tabInput`의 누르기(x, y), 글자(`Input.insertText`), 키(Enter, Backspace, Tab), 스크롤. 휴대폰 키보드는 화면 아래 입력
  칸으로 받는다(Browserbase도 자체 입력 칸을 권한다). 입력 대상이 비밀번호 칸이면 휴대폰 입력 칸도 가린다.
- **돌려주기:** `releaseTab {taskId, tabId, note?}`. 에이전트는 기다리던 도구 결과로 "사람이 탭에서 단계를 마쳤습니다"를 받고 이어 간다.
- **넘긴 동안:** 그 탭의 `browser_*` 도구는 "사람이 이 탭을 쓰는 중"으로 거절되고, 스크린샷·스냅샷을 주지 않는다(ChatGPT 옛 에이전트의
  약속과 같은 것을 코드로). 한 번에 한 기기만 입력한다.
- **화면의 비밀값:** 페이지가 그리는 그대로 간다. 비밀번호 칸은 브라우저가 가리고, 금고가 채운 칸의 덮개는 그대로 둔다. 휴대폰은
  프레임을 메모리에만 두고 `FLAG_SECURE`로 스크린샷과 최근 앱 미리보기를 막는다.
- **재인증:** 넘겨받기를 시작할 때 휴대폰 생체 인증을 한 번 묻는다(Claude Trusted Devices의 최근 인증과 같은 생각).

### 6.4 휴대폰 생체 인증으로 확인(다음 단계 설계)

- 짝지을 때 휴대폰이 Android Keystore에 "생체 인증 뒤에만 서명"하는 EC 키(`setUserAuthenticationRequired`, 강한 생체 인증)를 만들고
  공개 키를 Mac에 등록한다.
- 금고의 "매번 확인" 항목을 채울 때 Mac은 Touch ID 창과 함께 휴대폰에 확인 요청(사이트, 항목 이름, 작업 제목, 무작위 값)을 보낸다.
  휴대폰은 BiometricPrompt를 띄우고, 통과하면 그 키로 요청을 서명해 돌려준다. Mac은 서명을 확인한 뒤에만 채운다. 두 쪽 중 먼저 온
  확인이 쓰이고 2분이 지나면 거절한다.
- 휴대폰이 대신하는 것은 금고의 확인뿐이다. macOS 자체의 Touch ID·관리자 암호 창은 대신하지 못한다.

### 6.5 작업 중 잠자기·화면 잠금 막기

사용자(2026-10-24): "화면잠금이나 잠드는 걸 방지하는 방식을 요즘 개발자들이 다른 앱 써서 엄청 많이 쓰는걸로 알고있는디". 처음
추천("넣지 않기")을 바꾼다.

- **대조:** Amphetamine(무료, 화면 꺼짐·화면 보호기·덮개 닫힘 잠자기를 따로 막음), KeepingYouAwake(MIT, `caffeinate`를 감쌈), 에이전트
  전용 앱들(Claude Code·Codex 훅으로 에이전트가 일하는 동안만 막고 배터리 하한·발열에서 멈춤). 덮개를 닫은 채 돌리기는
  `sudo pmset -a disablesleep 1` 같은 관리자 권한이 들고, 되돌리기를 잊는 것이 주된 위험이다.
- **설정:** 설정 › 일반 "작업 중 화면 잠금 막기", 기본 꺼짐. 켜면 지금 유휴 잠자기를 막는 때(`AppModel.keepsMacAwake`: 작업이 일하는
  동안, 원격 휴대폰이 있으면 승인을 기다리는 동안까지)에 디스플레이 잠자기와 화면 보호기도 막는다. 화면이 꺼지지 않으니 잠금도 오지
  않는다. 일이 끝나면 바로 풀린다. Yardlet은 작업이 일하는 때를 이미 알므로 하네스 훅이 없다(2절 11: 하네스 설정에 쓰지 않는다).
- **멈추는 때:** 배터리로 돌고 남은 양이 20% 아래일 때. 나아지면 다시 막는다. 멈출 때 알림을 한 번 보내고 메뉴 막대 메뉴에 그 상태를 둔다.
  2026-10-24에는 Mac이 뜨거울 때(`thermalState` serious 이상)도 말없이 풀었으나, 일은 계속 돌아 식지 않고 화면만 잠겨 2026-10-26에 뺐다.
- **덮개 닫힘은 넣지 않는다.** 관리자 암호가 들고, Yardlet이 꺼지거나 지워진 뒤에도 시스템 설정이 남을 수 있다(2절 11). 외부
  디스플레이와 전원이 있으면 macOS가 덮개를 닫아도 깨어 있다(클램셸 모드).
- **위험은 기본값과 짧은 표시로 다룬다.** 실제로 막는 동안 메뉴 막대 항목의 메뉴 맨 위에 "화면 잠금을 막는 중" 한 줄을 둔다. 설정 옆
  설명 글은 두지 않는다.
- 이 설정이 꺼져 있고 화면이 잠겨 하네스의 화면 조작이 실패하면 그 실패를 휴대폰에 그대로 보인다. Mac 전체 화면을 넘겨받는 일은
  macOS 화면 공유가 할 일이라 Yardlet이 만들지 않는다.

### 6.6 이번 범위와 다음

| 이번(v2) | 다음 |
|---|---|
| 승인·질문·계획 답, 새 작업, 메시지(조율 작업 포함), 고정한 작업을 위로, 명령 출력·diff | 브라우저 탭 넘겨받기(6.3, 브라우저 격리·금고 작업의 "사람을 기다림" 신호와 함께) |
| 작업 중 잠자기·화면 잠금 막기(6.5) | 덮개 닫힘(넣지 않음) |
| 잠금 화면에는 알림의 공개 버전만 | 휴대폰 생체 인증으로 금고 확인(6.4), 넘겨받기 전 재인증 |
| Mac에서만 되는 요청은 그렇다고 보임(`moreOnMac`) | 무엇을 Mac에서 해야 하는지 한 줄 문구(Touch ID, iCloud 패스키, 시스템 창) |
| 기기 제거·휴대폰 쪽 연결 해제 | 앱 잠금(앱을 열 때 생체 인증) |

## 7. 플랫폼

- **추천과 진행: Android는 지금 앱(Kotlin, Jetpack Compose)을 잇는다.** 단위 검사 77개와 에뮬레이터 QA가 있고, 프로토콜 계층이
  화면과 나뉘어 있다. 새 연결은 `connection/`과 `protocol/` 아래 갈아 끼우고 화면을 다시 다듬는다.
- **iOS는 SwiftUI 네이티브로, Mac의 `YardletRemote` 패키지를 공유한다.** Noise, 프로토콜 타입, 짝짓기 URL 해석이 이미 Swift로
  있다. Kotlin Multiplatform이나 Compose Multiplatform은 Android 코드를 나눠 쓸 수 있지만, iOS 쪽 관례(시트, 알림, 생체 인증)를
  다시 맞춰야 하고 Swift로 있는 코드를 한 번 더 Kotlin으로 쓰게 된다. Flutter·React Native는 지금 앱을 버리고 새로 써야 한다.
- 두 플랫폼 사이의 약속은 이 문서와 REMOTE_PROTOCOL, 그리고 같은 테스트 벡터 파일이다.

## 8. 화면

시안: [remote-v2/mockups.html](remote-v2/mockups.html)(밝게·어둡게), PNG는 같은 폴더. 원칙: 두 앱의 휴대폰 관례, 꾸밈보다 읽기,
상태 점은 Mac 사이드바와 같은 뜻, 상자에 배지를 붙인 카드와 "01/02" 번호 표시는 쓰지 않는다.

- **연결 전:** 앱 아이콘, "Mac과 연결", 두 줄 안내(Mac에서 설정 › 원격 연결 › 휴대폰 연결), [QR 코드 스캔], 그 아래 보조 동작
  "Explore without a Mac". 직접 입력은 없앴다.
- **데모(Mac 없이 둘러보기):** 휴대폰 안의 데모 Mac이 요청에 답하고 이벤트를 보내므로 진짜 화면을 그대로 쓴다. 이름과 내용은 Mac 시연
  픽스처(`--ui-fixture=showcase`)와 같다: Jordan Park, 프로젝트 acme-web·payments-api·design-system, Codex·Claude Code·OpenCode 작업, PR
  #128. 각본으로 명령 승인, 여러 단계 질문, 계획 검토, diff, 제안 칩, 새 작업, 메시지를 해 볼 수 있다. 위에 "Demo"와 나가기가 늘 보이고,
  목록에서 뒤로 가도 나간다. 데모 중 앱을 떠나면 몇 초 뒤 "Demo"라고 적힌 요청 알림이 하나 온다. 소켓·Bonjour·중계·계정·FCM을 쓰지 않고,
  저장한 Mac·캐시·설정·키·알림 등록에 아무것도 쓰지 않으며, 나가면 들어오기 전 상태로 돌아간다.
- **작업(홈):** 위에 Mac 이름(누르면 Mac 시트)과 연결 상태 한 줄, 오른쪽 검색. "기다리는 작업"이 있으면 맨 위에 모아 요청 요약을
  둘째 줄로 보인다. 그 아래 프로젝트별 목록(Mac 사이드바 순서, 상태 점). 맨 아래 "새 작업" 입력 막대(Mac 홈처럼 입력이 아래).
- **대화:** 위에 뒤로, 제목, "하네스 · 프로젝트". 사람 말은 오른쪽 말풍선, 답은 전체 폭 글, 끝난 턴의 작업은 "N 동안 작업함 · 단계
  N개"로 접는다. 기다리는 요청은 대화 끝이 아니라 입력창 바로 위에 붙여 늘 보이게 한다(Claude Code의 권한 프롬프트가 입력창
  자리에 뜨는 것과 같다).
  - 승인: 도구 이름, 명령(고정폭, 세 줄, 누르면 다 보임), 설명, [거부] [한 번만 허용], "다른 선택지는 Mac에서".
  - 질문: 머리말, 질문, 선택지 줄(설명 포함, 여러 개 고르기는 체크), "직접 입력", 여러 질문이면 "1/3"과 [다음], 건너뛸 수 있으면
    [건너뛰기], 끝에 [보내기].
  - 계획: 계획 앞부분과 "전체 보기", [계속 계획] [계획 승인]. 계속 계획은 이유를 적을 수 있다.
- **새 작업 시트:** 프로젝트 고르기(목록), 입력, "Mac의 새 작업 설정으로 시작 · Claude Code" 한 줄, [시작]. 시작하면 그 작업 대화로
  간다.
- **Mac 시트:** 지금 Mac과 연결 경로 한 줄, 저장한 다른 Mac, "다른 Mac 연결", 알림(FCM이 없을 때 "백그라운드 알림"), 화면 모드,
  "이 Mac 연결 해제".
- **알림:** "승인 요청 · 작업 제목" / 요약 한 줄. 누르면 그 대화, 요청이 입력창 위에 있다.

## 9. v1 호환

- v1 리스너·`pair`·`hello`·토큰 기기는 그대로다. 새 요청(`answerQuestion`, `reviewPlan`, `createTask`, `registerPush`)은 v2
  연결에서만 받는다. v1 연결에 보내는 승인 항목은 v1이 아는 답만 남기고 나머지는 `moreOnMac`으로 바꾼다.
- Mac 설정은 v2 QR만 보인다. v1 기기는 목록에 "이전 앱"으로 보이고 제거할 수 있다.
- 새 Android 앱은 v1을 말하지 않는다. 그래서 새 앱은 새 Mac 빌드가 있어야 연결된다. 이미 깔린 v1 앱은 지금 Mac에서 계속 된다.

## 10. 보안 정리

| 위협 | 막는 법 | 남는 위험 |
|---|---|---|
| 중계 서버가 내용을 봄·바꿈 | Noise IK(끝단 키 고정), 중계는 암호문만 | 메타데이터(IP, 시각, 크기). 양자 컴퓨터로 나중에 푸는 일(2.1의 혼합 IK로 다음에) |
| 같은 Wi-Fi의 다른 기기 | 같은 Noise. Bonjour에는 Mac 이름 대신 키 해시 | Yardlet이 켜져 있다는 사실은 보인다 |
| 남이 방 ID를 알아냄 | 핸드셰이크에 Mac의 공개 키가 있어야 첫 메시지를 만든다. Mac 공개 키는 QR에만 | 연결 시도로 방을 귀찮게 할 수 있음(방당 8개 제한) |
| 중계 서버를 사칭한 방 가로채기 | 방 ID가 Mac 서명 키에서 나오고 서명을 확인 | 서버 운영자가 코드를 바꾸면 Mac을 막을 수는 있다(읽지는 못함) |
| QR을 남이 찍음 | 5분, 한 번, Mac이 짝지은 휴대폰 이름을 보임 | 5분 안에 먼저 찍으면 그 사람이 붙는다(Mac 목록에서 보이고 제거 가능) |
| 휴대폰 분실 | Mac에서 제거하면 바로 끊김, Android 화면 잠금, 잠금 화면 알림은 공개 버전만 | 잠금이 풀린 휴대폰을 잃으면 제거 전까지 조작 가능. 앱 잠금(생체 인증)은 다음 후보 |
| Mac의 키가 새어 나감 | 키는 키체인(앱 서명에만 열림) | 같은 사용자 권한의 악성 프로그램은 다른 Yardlet 자료처럼 위험 |
| 알림 내용 | 알림 키로 암호화, 키는 짝짓기 뒤 보안 채널로만 | Google·중계는 알림이 왔다는 사실과 시각을 앎 |
| 자격 증명·계정 토큰·환경 값 | 보내지 않는다(v1과 같음) | — |

## 11. Mac에 남는 것

- 켜 둔 동안: v2 리스너, Bonjour 광고, 중계로 나가는 연결 하나. 끄면 셋 다 바로 닫히고 중계 방은 메모리에서 사라진다.
- 늘 남는 것(Yardlet 자신의 자료): `~/.yardlet/remote/devices.json`(휴대폰 공개 키·이름·시각·알림 토큰과 키, v1 토큰 해시),
  `audit.log`(명령 종류·작업 ID, 본문 없음), 키체인 항목(Mac의 Noise 키와 중계 키, 계정에 로그인했으면 그 세션 토큰). 하네스·제공자
  계정·저장소에는 아무것도 쓰지 않는다.
- 잠자기·화면 잠금 막기는 프로세스가 쥔 전원 단언(assertion)이라 Yardlet이 끝나면 macOS가 거둔다. 시스템 설정(`pmset`)은 바꾸지 않는다.
- 로컬 네트워크 허용은 macOS가 기억한다(시스템 설정 › 개인정보 보호에서 끌 수 있다).

## 12. 배포에 필요한 설정

계정은 있다고 보고, 그 안에서 연결하고 설정할 것만 적는다. 로그인·결제·계정 설정은 사람이 직접 하고, 비밀 값은 명령 인자·문서·로그에
넣지 않는다(`wrangler secret put`의 입력, Gradle 사용자 속성).

- **중계:** Cloudflare에서 `wrangler login`과 `wrangler deploy`(`*.workers.dev` 하위 도메인, 도메인은 선택), 나온 주소를 Mac 빌드의 기본
  중계 주소와 Android `yardlet.relayUrl`에, `PUBLIC_URL`과 `AUTH_STATE_SECRET`. 2026-10-25 배포했다: 주소가 배포한 계정 이름을 담아
  저장소에 적지 않는다. 중계에는 `PUBLIC_URL`도 비밀로 두고, Mac 빌드는 `Packaging/RelayURL`(git 밖) 첫 줄을 Info.plist
  `YardletRelayURL`로 넣어 `RemoteControlService.builtInRelayURL`이 읽는다. Android `yardlet.relayUrl`은 Gradle 사용자 속성이다.
- **알림:** Firebase 프로젝트에 Android 앱(`com.zzunkie.yardlet.remote`)을 더해 그 값을 Android 빌드에, 서비스 계정 키를 중계의 비밀
  `FCM_SERVICE_ACCOUNT`·`FCM_PROJECT_ID`로.
- **계정:** 같은 Google Cloud 프로젝트의 OAuth 클라이언트(웹)와 GitHub OAuth App, 콜백은 `https://<중계>/v1/auth/<provider>/callback`.
  Sign in with Apple은 iOS 앱 때. 이메일 링크는 메일 발송 서비스를 고른 뒤.
- **배포 순서(2026-10-24 바뀜):** Play 계정은 2023-11-13 뒤에 만든 개인 계정이라 프로덕션 전에 비공개(closed)
  트랙에서 테스터 12명이 14일 연속 참여해야 하고(내부 트랙은 세지 않는다), 지인으로 채우기는 어렵다. 그래서 다음 순서로 한다.
  1. **GitHub Releases APK와 Obtainium을 먼저 낸다.** 릴리스마다 APK 두 개를 올린다: `play` 빌드(FCM 알림, Firebase 값을 넣어 빌드, 보통
     휴대폰용)와 파일 이름에 `-foss`를 붙인 `foss` 빌드(Google Play 서비스가 없는 휴대폰용). 둘은 앱 ID가 같고 아래 키로 서명하므로, 나중에
     다른 채널의 판을 지우지 않고 덮어 설치할 수 있다. Obtainium은 GitHub Releases를 그대로 읽으므로 따로 할 일이 없고, 두 APK 가운데
     하나를 고르게 한다. 앱 안에는 스스로 업데이트하는 기능을 넣지 않는다(Play 정책). 업데이트는 Obtainium이나 Play가 한다.
  2. **Play 비공개 테스트는 천천히 채운다.** 데모 모드로 Mac이 없는 사람도 실제로 써 볼 수 있으므로, Mac 공개 뒤의 실제 사용자에 더해
     공개 채널의 관심자도 받는다. 내부 트랙은 우리끼리 빠르게 확인하는 데만 쓴다. "앱 접근 권한" 안내는 데모 모드로 한다(14.5).
- **키 정책:** 앱 서명 키를 우리가 만들어 Play App Signing에 올리고, GitHub의 두 APK와 Play판이 같은 키를 쓴다. 업로드 키는 따로 두고, 두
  키 모두 오프라인에 백업한다. F-Droid는 소스에서 빌드해 자기 키로 서명하므로 재현 가능 빌드를 맞추지 않으면 다른 채널과 서명이 다르다.
  Android 개발자 인증은 2027년 전 세계 시행 전에 패키지 이름을 등록한다(한국은 아직 시작 전).
- **Play Console:** 앱, 비공개 테스트 트랙, 데이터 보안 양식과 개인정보처리방침(14절). iOS는 Apple 개발자 계정의 앱 ID와 APNs.

## 13. 구현 계획과 검증

| 갈래 | 내용 | 검증 |
|---|---|---|
| Mac(`YardletRemote`, `NativeHarnessClient/Remote`) | Noise, 보안 채널, 키(키체인), v2 리스너와 Bonjour, 중계 클라이언트, 알림 보내기, 새 요청, 설정 화면, 픽스처 서버 v2 | cacophony 벡터, 서버·종단 간 검사 넓히기, 설정 렌더 |
| 중계(`relay/`, TypeScript) | Worker + Room DO, 서명 확인, 이어 주기, FCM HTTP v1 | Vitest(workerd), `wrangler dev`로 Mac 픽스처와 이어 보기 |
| Android(다른 저장소) | Noise(BouncyCastle X25519, 플랫폼 ChaCha20-Poly1305), 경로 경주, Bonjour(NsdManager), 여러 Mac, 질문·계획·새 작업, 알림(FCM 선택), 화면, 데모 모드 | 같은 벡터, MockWebServer, 에뮬레이터에서 픽스처(직접)와 `wrangler dev`(중계), 데모는 비행기 모드에서 |

## 14. Play 공개에 필요한 사실(2026-10-24, 코드 기준)

Play 비공개 테스트 준비용이다. 아래 사실은 `relay/src`, Android `app/src`, Mac `Sources/YardletRemote`를 읽고 적었다. 정책 근거는 Play 도움말
[데이터 보안](https://support.google.com/googleplay/android-developer/answer/10787469),
[계정 삭제](https://support.google.com/googleplay/android-developer/answer/13327111),
[포그라운드 서비스](https://support.google.com/googleplay/android-developer/answer/13392821)와 Firebase의
[Play 데이터 공개 안내](https://firebase.google.com/docs/android/play-data-disclosure)다(모두 2026-10-24 확인).

### 14.1 무엇이 어디로 가고 무엇이 남는가

Play의 정의로 "수집"은 앱 밖으로 데이터를 보내는 것이다. 다만 종단 간 암호화로 보낸 사람과 받는 사람 말고는(개발자를 포함한 중간 누구도)
읽을 수 없는 데이터는 신고하지 않아도 되고, 기기 안에서만 다루는 데이터도 신고하지 않는다. 메모리에서만 잠깐 다루는 데이터는 양식에는 적되
스토어에는 "일시 처리"로 보인다.

| 데이터 | 어디로 | 개발자(중계)가 읽나 | 어디에 얼마나 남나 | 지우는 길 | 양식 판단 |
|---|---|---|---|---|---|
| 작업 목록, 대화, 메시지, 승인·질문·계획 답, 명령 출력, diff | 휴대폰 ↔ 사용자의 Mac | 못 읽음. 같은 Wi-Fi·Tailscale은 중계를 지나지 않고, 중계 경로는 Noise 암호문만 넘긴다 | 중계: 없음. 휴대폰: 마지막 목록과 연 대화를 앱 전용 `noBackupFilesDir`에 캐시(백업 안 됨) | 앱 삭제, "이 Mac 연결 해제" | 수집 아님(종단 간 암호화, 기기 안) |
| 알림 내용(작업 제목, 요청 한 줄, Mac 이름) | Mac → 중계 → FCM → 휴대폰 | 못 읽음. 짝짓기 뒤 Mac이 준 알림 키로 봉인(ChaCha20-Poly1305) | 중계: 없음. FCM: 전달될 때까지(TTL 1시간) | 자동 | 수집 아님(종단 간 암호화) |
| 휴대폰 공개 키, 기기 이름(`Settings.Global.DEVICE_NAME`, 없으면 모델명) | 휴대폰 → 사용자의 Mac(핸드셰이크, 암호화) | 못 읽음 | 사용자의 Mac `~/.yardlet/remote/devices.json`. 중계에는 없음 | Mac 설정에서 기기 제거, 앱의 "연결 해제" | 수집 아님. 단, 기기 이름에 사람 이름이 들어갈 수 있다(예: "OO의 Galaxy") |
| FCM 등록 토큰 | 휴대폰 → Mac(암호화) → 알림마다 Mac → 중계(TLS) → FCM | 읽음: 알림 하나를 보내는 동안 메모리에서만. 저장·로그하지 않는다(`fcm.ts`는 실패 상태 코드만 경고) | 사용자의 Mac 기기 목록. 중계에는 없음. FCM이 거절하면 Mac이 지움 | 앱 삭제·데이터 삭제(토큰 무효), Mac에서 기기 제거 | 기기 또는 기타 ID, 일시 처리, 앱 기능. FCM은 서비스 제공자라 공유 아님 |
| Firebase SDK가 보내는 것(`play` 빌드만) | 휴대폰 → Google | 우리 서버가 아님 | Firebase 안내: 설치 ID(FID), 앱 버전, Firebase 사용자 에이전트 | 앱 삭제·데이터 삭제 | 기기 또는 기타 ID(FID), 앱 정보(앱 버전). `foss` 빌드에는 없음 |
| IP 주소와 접속 시각 | 휴대폰·Mac → 중계(Cloudflare) | 우리 코드는 기록하지 않음(`wrangler.jsonc`에 Workers Logs가 꺼져 있음) | Cloudflare가 호스팅 제공자로 처리 | — | Play 양식에 IP 항목은 없고 위치 추정에 쓰지 않는다. 개인정보처리방침에는 적는다 |
| 방 상태(방 ID, 연결 번호, 인증 여부, 시각) | 중계 Durable Object | 읽음 | 열린 소켓에 붙은 첨부에만. 소켓이 닫히면 사라짐 | 자동 | 개인 데이터 아님 |
| 데모 모드의 작업·대화(샘플 데이터) | 어디로도 가지 않음. 앱 안의 데모 Mac이 메모리에서 답한다 | 해당 없음 | 메모리에만. 나가면 사라짐 | 자동 | 수집 아님(네트워크를 쓰지 않음) |
| 계정(켰을 때만, 14.2) | 앱 → 중계(https) | 읽음 | 계정 Durable Object(SQLite): 계정 ID(제공자 사용자 번호의 SHA-256 해시), 표시 이름(GitHub 로그인 이름, Google 프로필 이름), 로그인 토큰 해시와 기기 이름·만든·쓴 시각, Mac 목록(Mac 이름, 방 ID, 공개 키 둘, 갱신 시각), 2분짜리 일회용 코드. 원래 사용자 번호와 이메일은 저장하지 않는다 | `DELETE /v1/account`(전부), Mac 로그아웃(그 Mac 항목과 토큰), 앱 로그아웃(그 토큰). 90일 쓰지 않은 토큰은 다음에 쓰려 할 때 지운다(그 전까지 남음) | 개인 정보 › 이름(표시 이름)과 사용자 ID(계정 ID), 기기 이름. 계정 삭제 요건 적용 |

- **권한(병합된 release 매니페스트):** `play`는 `INTERNET`, `ACCESS_NETWORK_STATE`, `POST_NOTIFICATIONS`와 FCM 라이브러리가 넣는
  `WAKE_LOCK`·`com.google.android.c2dm.permission.RECEIVE`·`DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION`뿐이고 포그라운드 서비스가 없다. 앱이
  화면에서 사라지면 5초 뒤 연결을 닫고, 알림은 FCM으로 받고, 돌아오면 바로 다시 연결한다. `foss`는 FCM이 없어 "백그라운드 알림"(기본 꺼짐)용
  `ConnectionService`(connectedDevice)와 `FOREGROUND_SERVICE`·`FOREGROUND_SERVICE_CONNECTED_DEVICE`·`CHANGE_NETWORK_STATE`, 앱 안
  QR 스캐너용 `CAMERA`를 더 쓴다. 위치·연락처·사진·마이크는 쓰지 않는다.
- **넣지 않은 것:** 분석, 광고, 충돌 보고 SDK.
- **전송 중 암호화:** 예. 휴대폰과 Mac 사이는 모든 경로에서 Noise(같은 Wi-Fi·Tailscale의 `ws://`도 내용은 Noise), 중계는 `wss://`, 계정 API는
  `https://`, FCM과 Firebase는 Google의 HTTPS.

**양식 초안(계정을 뺀 첫 비공개 테스트, `play` 빌드):**

- 수집: 기기 또는 기타 ID(FCM 등록 토큰은 일시 처리, Firebase 설치 ID), 앱 정보와 성능 › 기타(앱 버전, Firebase SDK). 목적은 앱 기능(알림
  전달). 필수(알림을 쓰는 동안 앱 안에서 끌 수 없다). 공유 없음.
- 보안: 전송 중 암호화 예. 삭제 요청: 계정이 없고 우리가 남기는 데이터가 없다. 휴대폰의 데이터는 앱 삭제로, Mac의 기기 기록은 Mac 설정의
  제거로 지운다는 것을 개인정보처리방침에 적는다.
- 작업 내용·대화·알림 내용은 종단 간 암호화 예외로 신고하지 않는다. 예외가 좁으므로 개인정보처리방침에 이유(중계가 키를 갖지 않음)를 함께 적는다.

### 14.2 첫 비공개 테스트에 계정 기능을 넣을지: 빼기를 추천

- **이유 1, 삭제 요건:** 앱 안에서 계정을 만들 수 있으면(제3자 로그인도 해당할 가능성이 크다) 앱 안 계정 삭제 경로와 웹 삭제 링크가 둘 다
  있어야 한다. 중계에는 `DELETE /v1/account`가 있지만 Mac·Android 앱에는 로그아웃만 있고 삭제 버튼과 웹 안내가 없다.
- **이유 2, 신고와 설정이 는다:** 이름·사용자 ID·기기 이름 신고, Google OAuth 동의 화면과 GitHub OAuth App 등록, iOS에서는 Sign in with Apple.
- **이유 3, 테스트에 필요하지 않다:** Mac이 있는 테스터는 처음에 Mac 앞에서 Yardlet을 설치하므로 QR로 짝짓는 길이 자연스럽고, Mac이 없는
  테스터는 데모 모드를 쓰므로 계정이 필요 없다. 계정은 Mac 앞에 없을 때 새 휴대폰을 붙이는 편의 기능이다.
- **끄는 법:** 중계에 OAuth 비밀을 넣지 않는다. 그러면 중계의 `GET /v1/auth/providers`가 빈 목록을 주고, Mac 설정과 휴대폰(연결 전 화면,
  Mac 시트)은 계정 줄을 보이지 않는다(로그인해 있을 때만 로그아웃 줄이 남는다). 중계 주소(Mac 빌드의 기본값, Android `yardlet.relayUrl`)는
  그대로 두므로 밖에서 연결(중계 경로)은 그대로 된다. 두 앱은 설정 화면을 열 때마다 제공자를 다시 물어, 나중에 비밀을 넣으면 계정 줄이 나타난다.
- **나중에 켤 때 할 일:** Mac·Android 앱의 계정 삭제 버튼(`DELETE /v1/account`를 부름), 사이트의 웹 삭제 안내, 양식에 이름·사용자 ID 추가, 90일
  지난 토큰을 주기적으로 지우는 정리, iOS의 Sign in with Apple.

### 14.3 포그라운드 서비스(connectedDevice) 신고 문안

`play` 빌드에는 포그라운드 서비스가 없다(병합된 release 매니페스트로 확인). 그래서 첫 비공개 테스트의 Play Console에는
포그라운드 서비스 신고가 필요 없다. 서비스는 FCM이 없는 `foss` 빌드의 "백그라운드 알림"(기본 꺼짐)에만 남는다. 아래 문안은 나중에 `play`
빌드에 다시 넣게 될 때를 위한 참고다(Play Console은 영어로 적는다).

- **Use case:** Continuous data transfer to an external device (network connection).
- **Feature description:** "Background notifications is an optional setting, off by default. When the user turns it on, Yardlet
  Remote keeps an encrypted network connection open to the user's own Mac running the Yardlet app, which the user paired with the
  phone by scanning a QR code on the Mac. While the connection is open, the Mac sends approval requests, questions and finished-task
  updates from the coding agents running on it, and the phone shows them right away. A persistent notification shows which Mac is
  connected and lets the user turn the setting off."
- **User impact if deferred or interrupted:** "A coding agent on the user's Mac stops and waits until the user answers its request.
  If the connection is deferred or interrupted, the request does not reach the phone, and the agent on the Mac stays blocked until
  the user opens the app."
- **Video(이 순서로 한 번에 찍는다, 시스템 설정 화면이 아니라 앱 안 설정과 기기 사이 동작):** Mac의 Yardlet 설정 › 원격 연결에서 QR 표시 →
  휴대폰 앱으로 QR 찍기 → 휴대폰 앱의 Mac 시트에서 "백그라운드 알림" 켜기 → 알림 권한 허용 → 상시 알림("Mac에 연결됨") 확인 → 휴대폰 화면
  끄기 → Mac에서 에이전트가 명령 승인을 요청 → 휴대폰에 알림 → 눌러 "한 번만 허용" → Mac에서 명령이 이어지는 화면.

### 14.4 개인정보처리방침에 더할 "휴대폰 앱" 절 초안(영어, 사이트용)

사이트의 다른 절처럼 영어로 쓰고, Mac 앱 절들 뒤에 둔다.

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

계정 기능을 켜는 판에서는 다음 문단을 더한다: "If you sign in with GitHub or Google to find your Macs, the relay keeps a hashed account
identifier, your display name, your Macs' names and keys, and a hash of each sign-in token with the device name. You can delete your
account and this data in the app or at <web deletion link>."

### 14.5 "앱 접근 권한"(App access) 안내

Play Console의 앱 콘텐츠 › 앱 접근 권한은 "일부 기능이 제한됨"으로 두고, 로그인 정보 대신 데모 모드를 안내한다. 심사자와 Mac이 없는
테스터가 같은 길로 앱을 써 본다(Play Console은 영어로 적는다).

- **Instructions:** "Yardlet Remote controls the Yardlet app on the user's own Mac, so its full use needs a Mac paired by QR code.
  No account or sign-in is needed. To try every screen without a Mac, tap "Explore without a Mac" on the first screen. The demo runs
  entirely on the phone with sample data and no network: open tasks, read conversations, approve a command, answer a question,
  review a plan, open a file diff, start a new task, and leave the app to receive a demo notification. Tap "Exit demo" at the top to
  leave the demo."
