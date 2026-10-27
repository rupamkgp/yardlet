# 창 안 브라우저 (macOS 브라우저 호스트)

작성: 2026-09-28. Windows 설계는 [WINDOWS_BROWSER_HOST](WINDOWS_BROWSER_HOST.md)다. 이 문서는 macOS 제품 구현의 운영 문서다.

## 1. 한눈에

- 작업(세션)마다 브라우저 탭이 최대 9개다(2026-10-22 전에는 하나). 브라우저 탭 하나하나가 오른쪽 패널의 탭이고(2026-10-23, 그 전에는
  패널 탭 "브라우저" 하나 안의 탭 줄), 패널이 보이는 브라우저 탭이 앞 탭이다. 에이전트는 CDP로 같은 탭들을 조종하며, `tabId`를 주지 않으면
  앞 탭을 쓴다(3절 "탭", 6절).
- Chromium(CEF)은 Yardlet 밖의 **브라우저 호스트 프로세스**에서 돈다. Yardlet 실행 파일에는 CEF가 없다. 호스트는 창 없이
  그리고(off-screen rendering), 프레임을 IOSurface로 Yardlet에 넘기며, Yardlet 패널이 입력을 호스트로 보낸다.
- 호스트가 끝나면 Chromium의 모든 프로세스와 메모리가 사라진다(Chromium의 사본 정리 Helper만 수십 ms 더 남아 임시 사본을 지운다,
  3절 "종료"). 작업의 탭은 그 작업을 보관·삭제할 때까지 남고(Codex 앱이
  스레드를 보관할 때 브라우저 페이지를 정리하는 것과 같다), 열린 탭이 하나도 없게 된 뒤 60초 지나면 호스트가 끝난다.
- VoiceOver와 접근성 앱은 패널 안의 페이지를 요소 단위로 읽고 조작한다. 페이지의 접근성 트리는 누가 물을 때만 켠다(5절).
- CEF 없이 빌드한 Yardlet(`swift build`, `swift run`, `swift test`)에서는 브라우저 패널이 기존 WebKit 미리보기로 대체된다.

## 2. 구조

```text
Yardlet.app
├── Contents/MacOS/Yardlet                                패널·전송·수명 관리 (CEF 없음)
└── Contents/Frameworks/Yardlet Browser Host.app          CEF의 main bundle, LSUIElement
    ├── Contents/MacOS/Yardlet Browser Host               Swift + CEF C API, NSApplication 하위 클래스
    └── Contents/Frameworks/
        ├── Chromium Embedded Framework.framework         Versions/A 구조, 로캘 en·ko만
        └── Yardlet Helper{, (Alerts), (GPU), (Plugin), (Renderer)}.app   LSUIElement, 샌드박스
```

| 층 | 위치 | 내용 |
|---|---|---|
| 엔진(플랫폼 공통, Foundation만) | `Sources/NativeHarnessClient/BrowserHost/` | `BrowserHostProtocol`(명령·이벤트), `BrowserHostFraming`, `BrowserHostClient`(수명·탭·보임), `BrowserTab`, `BrowserDevToolsClient`(CDP), `BrowserURLPolicy`, `BrowserAccessibilityTree`(접근성 트리), `BrowserFrameSurfaceCache`(받은 프레임 표면을 언제까지 쥐는지) |
| macOS 층 | `Sources/NativeHarnessClient/Platform/macOS/BrowserHost/` | `CEFBrowserHostProcess`(프로세스·파이프·IOSurface 수신), `MacBrowserHost`(앱의 클라이언트 하나), `BrowserHostView`(층·입력·IME·끌어 놓기·메뉴), `BrowserSecureInput`(비밀번호 칸의 보안 입력·입력 소스 제한), `BrowserHostPane`(SwiftUI 패널), `BrowserKeyCodes`, `BrowserAccessibilityBridge`·`BrowserAccessibilityElement`(VoiceOver) |
| Mach 교환 | `Sources/YardletSurfacePort/` | bootstrap check-in/look-up, IOSurface 포트 송수신, audit token 검사(C) |
| CEF 접근성 가공 | `Sources/YardletCEFAccessibility/` | `CEFAccessibilityReducer`: CEF 접근성 값 → 계약의 작은 모양. Foundation만이라 CEF 없이도 검사한다 |
| 호스트 | `Sources/YardletBrowserHost/`, `Sources/YardletCEFBridge/`, `Sources/YardletCEFHelper/` | CEF 초기화와 처리기, 프레임 복사, 명령 처리, 접근성 전달(`AccessibilityForwarder`), 렌더러의 비밀번호 칸 알림(`FocusedField.c`). `YARDLET_CEF_DIR`가 있을 때만 컴파일 |

전송은 호스트 표준 입력(명령)과 표준 출력(이벤트)의 4바이트 길이 + JSON이다. JSON은 Swift Codable 기본형
`{"<case>": {<필드>}}`이고 `BrowserHostProtocolTests`가 모양을 고정한다. 호스트는 시작하자마자 표준 출력을 표준 오류로
돌려 Chromium이 찍는 글자가 이벤트 흐름을 깨지 못하게 한다. Yardlet이 죽어 표준 입력이 끝나면 호스트도 끝난다.
Yardlet은 이벤트의 틀 나누기와 JSON 해석을 파이프의 직렬 큐에서 하고, 메인 스레드에는 해석한 이벤트만 순서대로 넘긴다.

**프레임 표시는 메인 스레드를 거치지 않는다(2026-10-22).** 같은 파이프 큐가 프레임 이벤트의 IOSurface를 Mach 포트에서
꺼내(`BrowserSurfaceReceiver`), 그 탭을 보여 주는 패널의 층(`BrowserFrameDisplay`, 패널 뷰의 `contentLayer`)에 명시적
`CATransaction`으로 바로 넣는다. 어느 패널이 어느 탭을 보여 주는지는 `BrowserFrameRouter`(잠금 하나)가 들고, 패널이 탭을
붙이고 뗄 때 메인 스레드가 바꾼다(`MacBrowserHost.showFrames(of:in:)`·`stopShowingFrames`). 메인 스레드는 여전히 프레임
이벤트를 받지만(에이전트 도구의 관찰자 등), 이미 화면에 놓인 것이라 메인이 바쁜 동안 같은 탭의 더 새 프레임이 앞 것을
대신한다(`BrowserMainThreadEvents`: 탭마다 한 차례에 프레임 하나, 다른 이벤트 순서는 그대로). 팝업 층(`<select>` 목록)과
아직 화면에 없는 프레임만 메인 스레드가 놓는다. 그 전에는 프레임마다 메인 스레드 차례를 기다려 SwiftUI 창 갱신(흐르는
작업이 있으면 창마다 초당 28번, 한 번 약 17 ms) 뒤에 줄을 섰다. 입력은 AppKit이 메인 스레드로 주므로 여전히 메인을 거친다.

**세션 레일의 미리보기(2026-10-22).** 라우터는 탭마다 패널 하나에 더해 미리보기 하나
(`setPreview`)를 들고, 같은 파이프 큐에서 같은 프레임을 그 층에도 넣는다(`route`). 미리보기 층은 크기를 바꾸지 않고 `contentsGravity`로
프레임을 맞춘다(`BrowserFrameDisplay(sizesLayer: false)`, `BrowserFramePreviewView`). 늦게 붙은 미리보기가 바로 보이도록 라우터가 탭의 마지막
프레임을 들고(`latestFrame`), 호스트의 `hidden`·`closed`에 놓는다 — 숨겨진 탭의 표면을 라우터가 붙잡지 않는다. 미리보기는 엔진에 탭을 보이게
하지 않는다: 에이전트가 쓰는 동안(`agentVisibleWindow`) 그리는 프레임만 그리고, 그 뒤에는 마지막 프레임이 미리보기 층에 남는다(카드는 턴이
끝나면 사라진다). 어느 탭을 미리 보일지는 에이전트가 쓴 탭(`BrowserHostClient.onAgentActivity` → `BrowserAgentUse`)이고, 턴 끝·탭 닫힘
(`onTabClosed`)·호스트 종료에 지운다.

호스트는 CEF 공유 텍스처(`on_accelerated_paint`, IOSurface)를 받는다(`.ready`의 `acceleratedPaint: true`). 통계 줄의
`copies`는 CPU 복사가 아니라 그 텍스처를 호스트의 IOSurface 고리로 옮기는 Metal blit(GPU)이다. CEF 계약상 그 텍스처는 풀에서
오고 콜백이 끝나면 풀로 돌아가므로("cannot be cached and cannot be accessed outside of this callback") 넘기기 전에 복사해야 한다.

## 3. 결정

| 항목 | 결정 |
|---|---|
| 호스트 수명 | 세션 탭은 패널이 닫히거나 에이전트가 멈춰도 닫지 않고, 작업을 보관·삭제해 그 작업의 탭을 닫을 때까지 둔다(Codex 앱은 `thread/archived`에서 브라우저 대화를 정리하고, 보이지 않는 페이지는 백그라운드 절전만 한다). 보이지 않는 탭은 엔진에 숨김으로 알려 그리기를 멈춘다. 마지막 탭이 닫히면 60초(`idleGrace`) 뒤 호스트를 끝낸다. 패널을 다시 열면 같은 탭(페이지 상태 그대로)이 보인다. 호스트가 죽은 뒤면 작업의 탭들이 마지막으로 보인 주소(`rememberedTabs(forSession:)`, 순서와 앞 탭 포함)로 함께 다시 열리고(`restoreTabs`), 에이전트 도구도 같은 탭들을 다시 연다. 그것도 없으면 작업에 저장된 주소(탭이 여럿이면 그 목록, `BrowserPreviewPreferences.tabs`·`selectedTab` — 앱을 다시 켠 뒤)로 연다. 작업의 탭들을 닫으면(`closeTabs(forSession:)`) 주소를 잊는다. 2026-10-22 전에는 패널 없이 5분(`agentKeepAlive`) + 60초 뒤 탭을 닫아, 에이전트가 연 페이지가 사용자가 패널을 열기 전에 빈 탭이 됐다 |
| 종료 | 2026-10-24. 입력 끝(Yardlet이 끝남)·`shutdown` 명령·SIGTERM 모두 CEF가 권하는 순서로 끝난다: 열린 브라우저를 모두 `close_browser(force)`로 닫고, 마지막 `on_before_close` 뒤(3초 안에 오지 않으면 그때) 메시지 루프를 끝내고, `CefShutdown` 뒤 `exit(0)`(`BrowserHost.shutdown`). CEF의 신호 처리기는 끈 채(`disable_signal_handlers`) 호스트가 SIGTERM을 잡아 이 순서를 밟는다. 처리기는 SIG_IGN이 아닌 빈 함수다: 무시한 신호는 Chromium 하위 프로세스에 물려지는데, Chromium은 하위 프로세스를 SIGTERM으로 끝낸다. SIGPIPE는 무시해 Yardlet이 끝난 뒤의 이벤트 쓰기가 EPIPE로 실패하게 한다. 10초(`shutdownDeadline`) 안에 끝나지 않으면 호스트는 자기 프로세스 그룹을 SIGKILL로 끝낸다(`Process`가 띄운 호스트는 자기 그룹의 우두머리이고 Chromium 하위 프로세스는 같은 그룹이다). Yardlet은 앱을 끝낼 때(`terminateHost`) `shutdown`을 보내고 호스트가 끝나기를 최대 5초(`shutdownTimeout`) 기다리며, 넘으면 SIGKILL로 끝낸다(`terminate()`). 유예 시간 뒤의 종료(`shutdownHost`)도 5초 뒤에는 같다. `CefShutdown`은 Chromium의 code-sign clone 정리 Helper(`--type=code-sign-clone-cleanup`)를 새 프로세스 그룹으로 띄우고, 그 Helper는 호스트가 끝나기를 기다렸다가(`getppid() == 1`) 호스트가 시작할 때 만든 번들 사본(8절)을 지운다. CEF는 이 Helper에 `--framework-dir-path`·`--main-bundle-path`를 붙이지 않으므로, Helper 실행 파일(`YardletCEFHelper/main.c`)이 빠진 스위치를 호스트 번들 경로로 채운다. 채우지 않으면 CEF가 실행 파일 경로의 가장 바깥 `.app`(Yardlet.app)을 주 번들로 보아 프레임워크를 찾지 못하고 CHECK(SIGTRAP)로 끝나, 질서 있게 끝날 때마다 충돌 보고서가 남고 사본이 쌓였다. 2026-10-24 전에는 앱 종료와 QA 끝이 `shutdown` 직후 SIGTERM을 보내 호스트가 `CefShutdown` 없이 끝났고, Yardlet이 갑자기 끝나면 호스트가 SIGPIPE로 죽었다. 호스트가 SIGKILL로 끝나면 하위 프로세스는 IPC가 끊겨 스스로 끝나고(QA에서 남은 것 0), 그 호스트의 사본만 남는다. 호스트가 끝나며 탭마다 보내는 `closed`는 페이지가 닫은 것이 아니다: Yardlet이 `shutdown`을 보낸 뒤(`isHostEnding`) 오는 `closed`는 받지 않고, 탭은 `terminated`에서 호스트와 함께 잃은 탭으로 남는다(`rememberedTabs`, 패널 탭과 저장도 그대로). 2026-10-24 위 변경부터 2026-10-25 수정 전까지는 이 `closed`를 페이지가 닫은 것으로 받아, 앱을 끝낼 때 엔진에 열려 있던 탭이 패널과 작업 저장에서 빠졌다(다시 켜면 그 작업의 브라우저 탭이 없고, 그 탭만 있던 패널은 닫혀 있었다). 전에는 SIGTERM이 호스트를 바로 끝내 `closed`가 거의 오지 않았다 |
| 전체 페이지 스크린숏 | 2026-10-24. Chromium은 `Page.captureScreenshot`의 `captureBeyondViewport`를 뷰를 캡처 크기로 잠깐 늘려(`PageHandler::CaptureScreenshot`이 뷰의 `SetSize`를 부름) 처리하는데, CEF의 창 없는 뷰는 `SetSize`·`SetBounds`가 빈 함수라(`render_widget_host_view_osr.cc`) 표면이 패널 크기에 머물고, 이미지에는 첫 화면이 그 높이마다 되풀이됐다(QA로 재현, 800 px마다). 그래서 `browser_screenshot`의 `fullPage`는 캡처하는 동안 그 탭을 캡처 크기로 그린다(`BrowserAgentTools.drawn`): `Emulation.setDeviceMetricsOverride`로 페이지의 레이아웃 뷰포트를 지금 크기(뷰의 정수 포인트)에 고정하고, 탭을 캡처 크기로 `resize`하고, 찍은 뒤 탭의 크기를 먼저 되돌리고 고정을 푼다. 명령은 같은 파이프로 차례대로 가므로 기다릴 것은 없다. 그동안 100vh와 `innerHeight`는 그대로이고, 페이지의 `resize` 이벤트는 Chromium의 캡처 자체가 내는 한 번뿐이다. 표면은 GPU 텍스처라 한 변이 장치 픽셀 16,384를 넘으면 GPU 프로세스가 `Invalid size=2560x20352, max_texture…`로 죽기를 거듭하고 호스트가 `GPU process isn't usable. Goodbye.`로 끝나 모든 탭을 잃었다(2배에서 10,176 CSS px 페이지로 확인). 그래서 그 안에서 잘라 위쪽을 찍는다(2배에서 8,190 CSS px). 패널이 그 탭을 보이고 있으면 그 사이의 큰 프레임이 패널에 오므로 패널 뷰는 자기 경계로 자른다(`clipsToBounds`). 요소(`ref`) 스크린숏은 지금처럼 뷰 안에서만 찍는다 |
| 그리기(전력) | 세션 탭은 **화면에 보이는** 패널이 보여 줄 때와 에이전트가 쓴 뒤(또는 연 뒤) 60초(`agentVisibleWindow`) 동안만 엔진에 "보임"이다. 그 밖에는 `was_hidden`으로 숨겨 프레임을 멈추고 페이지 타이머를 늦춘다(QA: 애니메이션 페이지 63 fps → 2초 동안 0). 패널이 붙어 있어도 창이 최소화·다른 창에 완전히 가림·다른 Space·앱 숨김(⌘H)이면(`NSWindow.occlusionState`에 `.visible` 없음, `BrowserHostView.isOccluded`) 패널은 "가려짐"으로 보고하고(`setPanelOccluded`) 탭은 숨겨진다. 탭은 그대로 붙어 있고(수명은 패널 수가 정함), 다시 보이면 `invalidate`로 새 프레임을 받는다(2026-10-22 QA: 최소화한 창에서 60 fps·CPU 합 약 40% → 0 fps·약 2%). 탭을 연 뒤 60초 동안 보이게 두는 규칙은 패널 없이 연 탭(에이전트의 탭)에만 쓴다. 패널이 한 번이라도 보여 준 탭은 에이전트가 쓴 뒤에만 보이므로, 패널이 연 탭은 창을 가리자마자 숨는다(이 규칙이 열린 지 60초 안의 탭을 가려도 그리게 두던 것을 2026-10-22 고침). 패널을 붙이거나 에이전트가 다시 쓰면 다음 명령보다 먼저 보이게 한다 |
| 프레임 속도 | 패널은 자기 창이 놓인 디스플레이의 주사율(`NSScreen.maximumFramesPerSecond`)을 뷰포트의 `framesPerSecond`로 보내고(크기·배율·디스플레이가 바뀔 때마다), 호스트는 `set_windowless_frame_rate`로 맞춘다 — 내장 ProMotion 120, 외장 LG 60. 패널 없는 탭(`offscreenDefault`)은 기본 60. requestAnimationFrame 애니메이션은 120 Hz 화면에서 120 fps가 된다(QA). 휠·키 스크롤은 입력 속도와 무관하게 60 fps에 머무는데, Chromium 쪽 스크롤 프레임 제한으로 보이며 원인은 아직 찾지 못했다(10절) |
| 프레임 표면 수명 | 호스트는 탭의 층(view·popup)마다 같은 크기의 IOSurface 최대 4개를 돌려 쓴다(`SurfaceRing`). 크기가 바뀌면 새 링을 만들고, 탭이 숨겨지면(`visibility` isHidden) 링을 버린 뒤 `hidden` 이벤트를 보내고, 닫히면 버린다. 포트로 보냈는지는 링 안의 표면마다 기억한다(이전의 전역 ID 집합은 ID가 재사용될 때 포트를 다시 보내지 않아 Yardlet이 200 ms씩 기다리며 프레임을 잃었다 — 2026-10-22 QA에서 크기 변경 40회 중 26회가 새 크기 프레임을 600 ms 안에 받지 못함 → 0회). Yardlet은 이벤트 파이프 큐에서 이벤트 순서대로(`BrowserSurfaceReceiver` 안의 `BrowserFrameSurfaceCache`) 같은 탭·층에서 크기가 다른 표면과 링 용량(4)을 넘는 오래된 표면을 프레임이 올 때 버리고, `hidden`·`closed`·팝업 닫힘 이벤트에 그 탭(층)의 표면을 모두 버린다. 그래서 숨겨진 탭은 표면 메모리가 0이다(QA: 크기 변경 40회 뒤 호스트 footprint +81 MiB → +9 MiB, 숨긴 뒤 220 → 75 MiB). 프레임이 이름 붙인 표면의 포트가 없으면 기다리지 않고 그 프레임을 버린다. 호스트는 포트를 보낸 뒤에 프레임 이벤트를 쓰므로, 이벤트를 읽을 때 포트가 없으면 오지 않는 것이다(전에는 200 ms씩 기다림) |
| 탭 | 작업마다 탭이 줄 순서대로 최대 9개(`maxTabsPerSession`)이고 하나가 앞 탭이다(Claude 앱 3.1623.3 Browser 창: 탭이 8개를 넘으면 "Tab limit reached", ⌘1…⌘9). 2026-10-23부터 탭 하나하나가 오른쪽 패널의 탭(`browser:<키>`)이다(Codex 앱 26.1016). 탭마다 패널의 키(`BrowserTab.key`)가 있고, 탭이 다른 작업으로 옮겨 가거나 호스트가 죽거나 Yardlet을 다시 켜도 같은 키로 다시 열린다. 패널과 엔진은 이 키로 같은 탭을 가리킨다(`TaskWorkspaceState.syncBrowserTabs`): 엔진이 연 탭(에이전트·페이지)은 패널 탭이 되어 엔진에서 바로 앞인 탭 뒤에 놓이고, 호스트가 도는 동안 엔진이 닫은 탭은 패널에서도 빠진다(호스트가 끝나며 닫은 탭은 빠지지 않는다, 위 "종료"). 패널이 보이는 브라우저 탭이 앞 탭이고(`frontShownBrowserTab`), 엔진이 앞 탭을 바꾸면(에이전트의 선택, 앞에 여는 새 창) 브라우저 탭을 보이던 패널이 그 탭을 보인다. 새 패널 탭(런처·+ 메뉴의 "브라우저", 페이지의 ⌘T, 탭 메뉴의 "오른쪽에 새 탭"·"복제", 대화의 링크)은 그 칸이 보일 때 엔진 탭을 연다(`openBrowserEngineTab`, 주소가 없으면 빈 탭에 주소 칸 초점). 패널 탭에는 페이지 제목·아이콘(아래 "아이콘")·로딩 스피너가 있고, 브라우저 칸 안의 탭 줄은 없다. 패널에서 탭을 닫으면 그 페이지가 닫히고(엔진 탭 닫기) 패널은 다른 패널 탭처럼 그 전에 쓴 탭으로 가며, 패널 탭이 다 닫힐 때만 패널이 닫힌다. 엔진에서 앞 탭을 닫으면 그 자리로 온 탭, 없으면 앞의 탭이 앞으로 온다(Chrome). 닫은 탭 주소는 작업마다 10개까지 ⌘⇧T로 새 패널 탭에 다시 연다. 패널이 보이는 탭을 바꾸면 같은 칸의 프레임 경로(`BrowserFrameRouter`)·접근성·이벤트 처리기가 새 탭으로 옮겨 가고(칸은 그대로라 키보드 초점이 남음), 앞에 있던 탭은 엔진에 숨김으로 알린다(에이전트가 60초 안에 썼으면 그동안 보임 — Claude 앱 "Background tabs keep running while you drive them"). 저장: 탭마다 키·주소·제목(`BrowserPreviewPreferences.pages`). 작업 상태를 처음 읽을 때 엔진에 열린 탭도 잃은 탭도 없으면 저장된 탭을 `rememberTabs`로 넘겨, 패널이 그중 하나를 보이거나 에이전트가 처음 쓸 때 함께 다시 연다(`restoreTabs`). 2026-10-22~23에는 패널 탭 "브라우저" 하나 안에 Claude 앱식 탭 줄(탭 둘 이상일 때, +와 ⌘T)을 두었고 마지막 탭을 닫으면 패널이 닫혔다. 페이지가 요청한 새 창은 아래 "새 창" |
| 새 창 | 2026-10-25. 페이지의 새 창 요청(`window.open`, `target=_blank`, 수정 키 클릭)에 사용자 제스처가 있으면 호스트는 `on_before_popup`에서 CEF가 창 없는 브라우저를 만들게 둔다. 그 브라우저는 Chrome의 팝업처럼 `window.opener`와 여는 탭의 요청 컨텍스트(작업 프로필)를 가진다. 호스트는 빈 슬롯을 예약해 그 슬롯의 클라이언트와 여는 탭의 크기·배율·프레임 속도를 주고, CEF가 브라우저를 만들면(`on_after_created`; 렌더 처리기의 질문이 먼저 오면 `get_opener_identifier`로 예약을 찾음) 탭 번호(2^30부터, Yardlet이 여는 탭은 1부터)를 붙여 `popupOpened(tab:opener:url:background:)`를 보낸다. Yardlet은 그 탭을 여는 탭의 작업 탭으로 받는다(`adoptPopup`: 줄 끝에, 배경 탭 클릭이면 뒤에, 아니면 앞에). 작업 밖의 탭이나 탭이 9개인 작업이면 그 브라우저를 닫고 여는 탭이 그 주소로 간다. 사용자 제스처가 없거나 슬롯(16개)이 다 찼으면 전처럼 `newWindow`로 알리고, Yardlet은 제스처 없는 요청을 열지 않는다(Chrome 팝업 차단과 같음). 다만 2026-10-25 저녁 전에는 제스처 없는 요청이 여기까지 오지 않았다: CEF의 `CanCreateWindow`가 Chrome 층(`ChromeContentBrowserClient::CanCreateWindow`)을 먼저 부르고, Chrome의 팝업 차단기(`blocked_content::MaybeBlockPopup`, `ShouldBlockPopup`의 `kNoGesture`)가 막은 요청을 Chrome 주소 칸용 `PopupBlockerTabHelper`에 넣어, 창 없는 탭에서는 아무도 그 목록을 보지 못했다(QA로 재현: 목록 0개). 그래서 브라우저 프로세스가 Chrome 자신의 스위치 `--disable-popup-blocking`으로 뜨고, 같은 규칙(사용자 제스처 없음)은 호스트의 `on_before_popup`이 지킨다. 프로필에는 아무것도 남지 않는다. 그 뒤로 그 주소는 Chrome 주소 칸의 "팝업 차단됨"처럼 패널 주소 칸 오른쪽 표시(빗금 친 창, 도움말 "이 페이지에서 팝업이 차단되었습니다.")의 목록에 남고(`BrowserTab.blockedPopups`, Chrome처럼 처음 25개, `kMaximumNumberOfPopups`), 사람이 고르면 작업의 새 탭으로 앞에 열린다(`BrowserHostClient.openBlockedPopup`). 엔진이 만든 창이 아니므로 그 탭에는 `window.opener`가 없다(Chrome은 막은 요청을 쥐고 있다가 opener와 함께 연다). 목록은 그 페이지가 새 문서로 바뀌면 지운다(`newDocument`: CEF `on_load_start`의 본 프레임, 같은 문서 안 이동에는 오지 않는다; Chrome `PopupBlockerTabHelper::DidFinishNavigation`). 에이전트 도구는 결과 끝에 막힌 팝업 주소를 알린다(그 주소는 `browser_tab_new`로 연다). Chrome의 "이 사이트의 팝업 항상 허용"은 넣지 않았다. 만들기가 실패하면(`on_before_popup_aborted`) 예약을 푼다. 팝업이 `window.close()`하면 `closed`로 그 탭이 빠지고, 패널은 그 전에 쓴 탭으로 간다. 그래서 카드사의 3-D Secure 창, PayPal, 로그인 팝업이 `window.opener.postMessage`로 연 페이지에 답할 수 있다(QA `checkout`). 창 크기 요청(`width`·`height`)은 쓰지 않고 탭으로 연다. 2026-10-22~25에는 호스트가 새 창을 모두 취소하고 Yardlet이 그 주소를 `window.opener` 없는 새 탭으로 열었고, 그 전에는 여는 탭에서 열었다. 두 앱(번들 바이트): Claude 앱 3.1623.3은 크기를 준 팝업만 Electron이 만든 창을 탭으로 받아 opener를 지키고 `target=_blank`는 여는 탭에서 열며, Codex 앱 26.1016은 `target=_blank`만 그렇게 받고 크기를 준 팝업은 opener 없는 새 탭으로 연다 |
| 탭 옮기기 | 새 작업 화면의 탭은 초안의 작업 공간 ID(`TaskWorkspaceStore.draftID`)가 가지고, 그 화면에서 보낸 작업이 만들어지면 탭 하나씩 그 작업으로 옮긴다(`move(_:toSession:select:)`, `moveTabs(fromSession:toSession:)`, 2026-10-23). 클라이언트의 소유(`BrowserTab.session`, 줄 순서, 앞 탭)만 바뀌고 호스트에는 아무것도 보내지 않으므로 페이지와 그 상태가 그대로다. 탭의 키도 그대로라 작업이 넘겨받은 패널 탭이 같은 탭이다. 옮긴 탭은 닫은 탭 목록에 들어가지 않고, 같은 줄 순서로 뒤에 붙으며 초안의 앞 탭이 작업의 앞 탭이 된다. 탭이 9개인 작업에는 옮기지 않는다. 호스트가 죽어 초안이 잃은 탭 주소(`rememberedTabs`)도 작업으로 넘긴다. QA: `--ui-fixture-browser-check-only=draft-handoff` |
| 아이콘 | 2026-10-23. CEF가 페이지의 아이콘 주소를 알리면(`on_favicon_urlchange`) 호스트가 첫 주소를 `download_image`(파비콘이라 쿠키를 보내지도 받지도 않음, 16 DIP, 2배까지)로 브라우저 자신의 네트워크·캐시로 받아 `get_as_png(2.0)`의 PNG를 `favicon(tab:url:png:)` 이벤트로 보낸다(받지 못하면 빈 데이터). 내려받기마다 자기 탭을 아는 콜백을 따로 할당하고 참조 수가 0이 되면 해제한다. Yardlet은 `BrowserTab.favicon`에 두고 탭 관찰자를 부르며, 다른 호스트(사이트)로 주소가 바뀌면 지운다. 저장하지 않는다 |
| 페이지 오류 | 2026-10-23. 패널 머리의 "사용할 수 없음"과 오류 카드는 보이는 탭의, 실패한 그 이동에만 붙는다. 본 프레임 `loadError`(-3 `ERR_ABORTED` 제외)는 그 주소가 커밋될 때 카드가 된다: 그 주소로의 `address`, 또는 Chromium이 오류 페이지에 보내는 상태 0의 `loadEnd`(CEF 154는 오류 페이지에 주소 변경을 보내지 않는다, QA `load-errors`). 커밋 없이 로딩이 끝나면(앞 페이지가 그대로) 카드 대신 "‹주소› 페이지를 열지 못했습니다" 알림이다. 로딩이 끝난 뒤에 온 오류는 이미 대체된 이동의 것이라 버린다. 카드는 다른 주소의 커밋(`address`, history.pushState 포함)이나 HTTP 상태가 있는 `loadEnd`(새로 고침이 성공함)에 지워지고, 오류 페이지 자신의 뒤이은 로딩(`loading` → -3 → 끝)에는 남는다(2026-10-23 전에는 이 로딩이 실제 실패를 지웠다). 다른 탭을 보이면 지운다. 호스트의 `failed`에는 탭이 붙어(`failed(message:tab:)`, 브라우저를 만들지 못한 탭) 그 탭에만 가고, 탭 없는 `failed`만 모든 탭에 간다. CDP 메시지를 받지 못한 탭(사라진 탭으로 간 에이전트의 호출)은 `failed` 대신 그 호출 `id`의 DevTools 오류 답(-32001)을 받아 호출이 바로 실패한다. 2026-10-23 전에는 이것이 탭 없는 `failed`로 모든 탭에 가서 멀쩡한 페이지에 "사용할 수 없음"과 카드가 떴다(QA로 재현). 진단: 호스트는 본 프레임 load error마다 host.log에 `load error tab=… code=… host=…`(호스트 이름만, 경로·쿼리 없음)와 `devtools message refused tab=…` 한 줄을 남긴다 |
| 응답 없음 | 2026-10-23. 탭의 페이지가 응답하지 않는다는 것은 두 사실 가운데 하나다: Chromium의 hang monitor가 렌더러가 입력을 15초 처리하지 못했다고 보는 것, 또는 렌더러가 답하는 DevTools 호출(이동 계열 `Page.navigate`·`reload`·`navigateToHistoryEntry`와 `Target.`·`Browser.` 밖의 모든 호출)이 시간 안에 답이 없던 것(`BrowserTab.unresponsive`: `.hangMonitor`·`.unanswered(method:)`). Chromium은 DevTools 세션이 붙은 탭(Yardlet의 탭은 에이전트·접근성 때문에 붙음)에는 `OnRenderProcessUnresponsive`를 부르지 않으므로(`WebContentsImpl::RendererUnresponsive`의 `IsDebuggerAttached`, QA에서 "responsive"만 오던 것으로 확인) 호스트가 열린 탭마다 1초 간격으로 `is_render_process_unresponsive`를 읽어 바뀔 때 `responsiveness(tab:isResponsive:)`를 보낸다. 콜백이 오는 탭은 그 콜백을 쥐어 둔다(`unresponsive(tab:action:)` 명령의 wait·terminate). 패널은 Chrome의 "페이지 응답 없음" 줄에 "기다리기"와 "새로고침"을 두고, 머리 상태는 "응답 없음" > "비정상 종료"(아래 "렌더러 종료") > "사용할 수 없음" > "로딩 중" > "준비됨" 한 줄이다(오류 카드는 응답 없음 동안 숨김). 기다리기는 15초 동안 줄을 숨기고 그때도 응답하지 않으면 다시 보인다(Chrome의 Wait). 새로고침과 응답 없는 탭으로 가는 에이전트의 `browser_navigate`는 탭을 같은 키·자리·앞 상태로 새로 연다(`BrowserHostClient.replace`: 쥔 콜백이 있으면 렌더러를 끝낸 뒤 닫고 연다). QA(`unresponsive`): 끝나지 않는 스크립트의 렌더러가 CPU 98–100%에서, 교체 뒤 사라짐. 응답하면(`responsiveness` true), 렌더러가 끝나면(`pageCrashed`), 렌더러가 답하는 호출에 답이 오면 풀린다. 호스트 로그에 `renderer unresponsive|responsive tab=…` |
| 렌더러 종료 | 2026-10-24. 렌더러가 끝나면(CEF `on_render_process_terminated`) 호스트는 host.log에 `renderer ended tab=… status=… code=…`
(`status`는 crashed·oom·killed·abnormal 등, `code`는 종료 코드로 충돌이면 신호 번호) 한 줄을 남기고 `pageCrashed(tab:reason:status:code:)`를
보낸다. `reason`은 호스트가 붙인 Chrome 오류 화면의 오류 코드다(SIGTRAP·SIGSEGV 등, Out of Memory; 신호 번호는 플랫폼마다 달라 엔진이 아니라
호스트가 이름을 붙인다). 탭은 `BrowserTab.crash`(`BrowserTabCrash`)를 다음 로딩이 시작될 때까지 갖는다. 패널은 머리 상태 "비정상 종료"와 Codex 앱 문구의 카드("This page crashed", "‹호스트› ended unexpectedly. Error code:
‹코드›", Reload)를, 에이전트 도구는 결과 끝의 사실("This tab's page crashed: its renderer ended (error code ‹코드›). …")과 `browser_tab_list`의
"Crashed: tab … (‹코드›)" 한 줄을 받는다. 설치본의 충돌 다섯 번은 모두 입력 시각 때문이었다(4절 "입력 시각") |
| 패스키(WebAuthn) | Chromium 자신의 WebAuthn(창 없는 탭도 Chrome 부트스트랩 위 Alloy 방식)을 쓴다. 창 없는 탭에는 부모 창이 없어 Chrome의 패스키 대화상자(Views `AuthenticatorRequestDialogView`)가 호스트의 별도 창(`NativeWidgetMacNSWindow`)으로 패널 위치에 뜬다. 지금 뜨는 것: 휴대폰·태블릿 패스키(하이브리드: QR 코드 + 블루투스) 시트와 USB 보안 키 시트(QA에서 대화상자의 글로 확인, 실제 휴대폰·키로 끝까지 등록한 확인은 없음). 그 사이트의 패스키가 어디에도 없을 때 어느 시트가 먼저 뜨는지는 Chromium 154의 `AuthenticatorRequestDialogController`가 정하고, Chrome과 규칙이 같다(2026-10-25, 원본 대조와 QA `--ui-fixture-browser-check-only=passkey`). (1) 조건부 요청은 창이 없고, 사람이 로그인 칸을 눌러도 없다(QA). (2) 즉시 요청(빈 `allowCredentials`, "패스키로 로그인")은 고를 것이 휴대폰 하나면 목록 없이 QR 시트로 간다(`IndexOfGetAssertionPriorityMechanism`의 "single mechanism"). Touch ID 프로필 인증기는 그 사이트의 자격 증명이 없다고 알리면 목록에서 빠지고(`PopulateMechanisms`), 블루투스가 켜져 있으면 USB 보안 키는 QR 시트 안의 단추가 된다. Chrome은 iCloud 패스키를 읽을 권한이 없을 때만 iCloud 키체인이 하나 더 들어가 목록("iCloud 키체인", "다른 휴대전화, 태블릿 또는 보안 키")을 먼저 보인다. 이 호스트에는 iCloud 키체인이 없으니 그 차이는 남는다. 바꾸려면 그 판단 코드를 바꿔야 하고(설정·기능 플래그·CEF API에 없음) 하지 않았다. (3) 만들기(`authenticatorAttachment` 없음)는 iCloud Drive가 켜진 Mac이면 Chromium이 iCloud 키체인을 첫 순위로 둔다(`ShouldCreateInICloudKeychain`, `WebAuthenticationICloudKeychainForInactiveWithDrive` 기본 켜짐, `IndexOfMakeCredentialPriorityMechanism`). 이 호스트에는 iCloud 키체인이 없어 다음 순위인 휴대폰 QR로 바로 갔고, Touch ID는 "다른 방법으로 저장" 뒤에 있었다. 2026-10-25부터 호스트는 요청 컨텍스트가 준비될 때마다(기본 프로필은 `on_context_initialized`, 작업 프로필은 `on_request_context_initialized`) Chrome 자신의 설정 `webauthn.create_in_icloud_keychain`을 끈다(`set_windowless_preferences`, CEF `set_preference`). 그러면 첫 순위가 Touch ID(`Transport(kInternal)`)라 "Chrome 프로필에 패스키 만들기" 시트(`kChromeProfileCreatePasskey`, "계속"·"다른 방법으로 저장")가 먼저 뜨고, QR은 "다른 방법으로 저장"에서 고를 때만 나온다. Touch ID가 없는 빌드에서는 전처럼 QR이다. QA 프로필 둘에 값이 `false`로 들어간 것은 확인했고, Touch ID 시트가 먼저 뜨는 것은 서명한 빌드가 있어야 볼 수 있어 확인하지 못했다(소스 근거). 블루투스는 호스트를 띄운 앱(책임 앱 = Yardlet)의 Info.plist에 `NSBluetoothAlwaysUsageDescription`이 있어야 Chromium이 쓴다(없으면 "Cannot use Bluetooth because the responsible app … does not have Bluetooth metadata" 뒤 보안 키 시트만). 그래서 Yardlet.app과 호스트 모두 넣었고(`Packaging/Info.plist`, `Packaging/CEF/BrowserHost-Info.plist`, 한국어는 `ko.lproj/InfoPlist.strings`), 처음 쓸 때 macOS가 블루투스 허용을 묻는다. 대화상자는 요청한 사이트가 정한 시간까지 기다리므로 사람이 보고 닫을 수 있어야 한다. 호스트는 평소 활성화되지 않으므로(`.prohibited`) 대화상자가 뜨면 (다른 앱 창 뒤에 뜬 창은 아무 알림도 내지 않아 1초마다도 본다) 활성화될 수 있게(`.accessory`) 바꾸고 `chromiumWindow(isShown: true, titles:)`를 보낸다. Yardlet은 `ChromiumWindowPresentation` 규칙대로 한다. Yardlet이 앞에 있으면 대화상자를 올리고(`raiseChromiumWindows` → `orderFrontRegardless`) 활성을 넘겨(`activate(from:)`) 키 창이 되게 한다(보안 키 PIN, Esc). 앞에 없으면(에이전트가 버튼을 눌렀거나 사람이 다른 앱에 있음) 다음에 Yardlet이 앞으로 올 때 그렇게 하고, 그 뒤로는 Yardlet이 앞으로 올 때마다 키는 두고 위로만 올린다. 대화상자가 닫히면 호스트가 활성을 Yardlet에 돌려준다(`ChromiumWindows`). 에이전트 도구는 대화상자가 열려 있다는 것과 제목을 결과에 붙이고 `browser_handle_dialog`(accept false)로 닫을 수 있다(`closeChromiumWindows`: Esc를 보내고 0.5초 뒤에도 남으면 닫음 → 페이지는 `NotAllowedError`). 이 기기의 패스키만 원하는 요청(`allowCredentials`의 transports `internal`, `hints: ["client-device"]`, `authenticatorAttachment: "platform"`)에는 Chrome처럼 "패스키 없음 — 이 기기에 …의 패스키가 없습니다" 또는 "이 사이트에서 기기를 사용할 수 없음" 시트에 "닫기"만 있다. 조건부 요청(`mediation: "conditional"`)은 창 없이 대기한다(명세대로, 위 (1)). `getClientCapabilities()`의 `passkeyPlatformAuthenticator`는 하이브리드로도 참이라(명세 "locally and/or via hybrid transport") Touch ID 없이 true다. Touch ID(Chromium의 프로필 패스키)는 7절 시제품으로 만든 빌드에서만 켜진다. 2026-10-25 설치본은 그렇게 빌드되어 호스트의 CEF 상수와 `keychain-access-groups`가 `<팀>.com.zzunkie.webauthn`·`…-uvk`이고, 기본 프로필에 `webauthn.touchid.metadata_secret`이 있다(`webauthn.touchid.last_used`는 없어 아직 쓴 적은 없다). 안 되는 것은 iCloud 키체인 패스키다. Touch ID는 브라우저 프로세스의 `keychain-access-groups` 엔타이틀먼트에 CEF가 빌드될 때 정해진 그룹이 글자 그대로 있어야 켜지는데(`chrome_web_authentication_delegate.cc`의 `MAC_TEAM_IDENTIFIER_STRING "." MAC_BUNDLE_IDENTIFIER_STRING ".webauthn"`, `keychain_util.mm`의 `containsObject`), CEF 배포본의 그룹은 팀 ID 없는 `.org.chromium.Chromium.webauthn`이라 어떤 프로필도 허용하지 못한다(그래서 7절의 시제품). iCloud 키체인은 `com.apple.developer.web-browser.public-key-credential`(Apple 승인)이 있으면 AuthenticationServices로 가지만, 그 discovery는 웹 콘텐츠의 NSWindow가 있을 때만 생긴다(`fido_discovery_factory.cc` `MaybeCreatePlatformDiscovery`). CEF 창 없는 탭의 `GetNativeView()`는 빈 값이라 승인만으로는 켜지지 않을 것으로 본다(소스 근거, 실행 확인 없음). `isUserVerifyingPlatformAuthenticatorAvailable()`은 Touch ID가 켜진 빌드에서만 true다 |
| 금고 | 에이전트용 금고([BROWSER_VAULT_DESIGN](BROWSER_VAULT_DESIGN.md))가 이 호스트에서 확인한 사실(2026-10-24, `run-check.sh … --ui-fixture-browser-check-only=vault`, 실제 CEF 154 QA 번들, 시험용 값만): (1) CDP `WebAuthn` 도메인이 있다. `WebAuthn.enable`·`addVirtualAuthenticator`(ctap2, `internal`, resident key, 사용자 확인, 자동 존재 확인)로 `localhost`에서 `navigator.credentials.create()`가 대화상자 없이 끝나고(`authenticatorAttachment: platform`) `WebAuthn.credentialAdded`가 오며 `getCredentials`가 개인 키를 준다. 그 자격 증명을 새 인증기에 `addCredential`로 넣으면 `get()`이 성공하고 `credentialAsserted`가 온다. 인증기가 붙어 있는 동안 그 탭의 다른 인증기(Touch ID 프로필 패스키, 휴대폰)는 쓰이지 않으므로 금고는 짧게만 붙인다. (2) `Accessibility.getFullAXTree`는 비밀번호 칸 값을 글자 수만큼의 •로 준다(26자 시험 값 → • 26개). (3) 격리 세계(`Page.createIsolatedWorld`, 이름 `yardlet-vault`)에서 기본 `value` setter와 `input`·`change`로 넣은 값을 일반 폼과 React식으로 값을 붙든 칸이 모두 받는다(그 칸의 `input` 이벤트는 `isTrusted: false`). 같은 이름의 `Page.addScriptToEvaluateOnNewDocument`·`Runtime.addBinding`(`executionContextName`)이 같은 세계에 들어가, 사람의 로그인 제출을 그 세계의 바인딩(`Runtime.bindingCalled`)으로만 받는다. (4) Chromium 비밀번호 관리자는 비밀번호를 저장하지 않는다(`Login Data`의 `logins` 0행). 자동 완성 기록(`Web Data`의 `autofill`)에는 일반 텍스트 칸의 값이 남았다: 사용자 이름, `autocomplete`가 없는 한 글자 코드 칸의 숫자(이미 만료된 코드). `autocomplete=one-time-code` 칸과 비밀번호 칸은 남지 않았다. 2026-10-25부터는 주소 자동 완성을 끄면서(아래 "자동 완성의 저장 제안") 이 기록도 남지 않는다(QA: vault 단계가 이메일 칸에 입력한 뒤에도 QA 프로필 넷의 `autofill`·`credit_cards`가 0행, `Preferences`의 두 설정 `false`). (5) 2026-10-25: 화면 밖 렌더링 탭의 `Page.captureScreenshot`(PNG) 그림에서 Vision `VNDetectBarcodesRequest`가 페이지의 2단계 인증 설정 QR(`img`, 43모듈을 215 CSS px로 픽셀 그대로 키움)과 Google Authenticator 형식 내보내기 QR(71모듈)을 읽는다. |
| 프로필 | 2026-10-24부터 작업마다 따로다([BROWSER_SESSION_ISOLATION](BROWSER_SESSION_ISOLATION.md)). `open` 명령의 `profile`(`key`, `seedFrom`)이 있으면 호스트는 `Browser/Task-<key>`를 `cache_path`로 하는 `CefRequestContext`에서 탭을 연다(같은 키의 탭은 한 컨텍스트, 마지막 탭이 닫히면 놓음). Chromium은 root cache 바로 아래 폴더만 디스크 프로필로 열고 다른 경로는 메모리 프로필로 바꾼다(`chromium.log`·`host.log`의 "Cannot create profile at path"). 디스크 프로필은 비동기로 읽히므로, 아직 읽히지 않은 프로필의 탭은 `on_request_context_initialized` 뒤에 만든다(`yardlet_cef_create_browser`가 2를 돌려주고 `YardletCEFEventProfileReady`로 알림). 폴더가 새로 생기면 기본 프로필의 Touch ID 패스키 키(`webauthn.touchid.metadata_secret`)를 넣고, 탭을 about:blank로 연 뒤 시작 쿠키(`seedFrom`의 프로필, 없으면 기본 프로필)를 쿠키 관리자로 복사하고 나서 요청한 주소를 연다. 복사는 쿠키를 Chromium이 저장한 모양대로 넣는다: 호스트 전용 쿠키는 도메인을 비워 호스트 전용으로, 파티션 쿠키는 CEF가 파티션 키를 받지 않아 빼고(2026-10-25 전에는 호스트 전용 쿠키가 도메인 쿠키가 되고 `__Host-` 쿠키가 빠져 Google 계정 사이트가 `CookieMismatch`로 돌려보냈다, [BROWSER_SESSION_ISOLATION](BROWSER_SESSION_ISOLATION.md) 8절). 프로필을 기다리는 동안과 복사하는 동안의 이동과 DevTools 메시지는 그 뒤로 미룬다. `copyCookies` 명령은 한 사이트의 쿠키를 다른 프로필로 옮긴다(사람의 로그인을 기본 프로필로). `profile`이 없는 탭(설정 "쿠키 보관: 모든 작업이 함께", 작업 없는 탭)은 기본 프로필 `~/Library/Application Support/Yardlet/Browser/Default`. 세션 쿠키도 저장해(persist_session_cookies) 호스트가 다시 떠도 로그인이 유지된다(작업 프로필도 같다) |
| 쿠키 암호화 | 호스트가 시작할 때 자기 서명을 본다(`CookieKeychain`, Gatekeeper의 Developer ID 요구 사항). Developer ID면 Chromium 기본대로 로그인 키체인 항목 "Chromium Safe Storage"(무작위 비밀번호)에서 키를 만든다. 그 항목은 만든 호스트의 서명을 믿으므로 같은 Developer ID로 서명한 업데이트에서는 묻지 않는다. ad-hoc·Apple Development 빌드와 `YARDLET_BROWSER_KEYCHAIN=mock`(QA 실행)은 전처럼 mock keychain(`--use-mock-keychain`, 고정 비밀번호 `mock_password`)을 쓴다. ad-hoc 서명은 빌드마다 서명이 달라져 로그인 키체인 허용 창이 매번 뜨기 때문이고, 대가로 이 사용자 계정의 파일을 읽을 수 있는 프로그램은 쿠키를 해독할 수 있다. 어느 쪽인지는 host.log 첫머리 "cookie key in …" 줄에 남는다. 두 키는 다르다. 쿠키 값은 `v10` + AES-128-CBC(PBKDF2-SHA1 1003회, salt `saltysalt`)이고 복호화에 실패한 쿠키는 읽지 않는다(`sqlite_persistent_cookie_store.cc` `kDecryptFailed`). 그래서 mock에서 Developer ID로 바꾸면(또는 되돌리면) 내장 브라우저의 사이트 로그인이 한 번 모두 풀린다. 기존 쿠키를 옮기는 코드는 두지 않았다(사용자 프로필 DB를 고쳐 써야 함) |
| 자동 완성의 저장 제안 | 2026-10-25. 카드나 주소가 든 폼이 제출되면 Chromium 자동 완성이 저장을 제안하는 Chrome 말풍선을 띄우는데, 그 코드(`SaveCardBubbleControllerImpl::DoShowBubble`, `AddressBubblesController`)는 탭의 Chrome 창을 확인 없이 가져온다. 창 없는 탭에는 그 창이 없어 브라우저 프로세스가 빈 포인터를 읽고(SIGSEGV, 주소 0x10) 호스트와 모든 탭이 함께 끝났다. 실제 Stripe Checkout 결제 페이지에서도 이것으로 호스트가 끝났다. 호스트는 패스키 설정과 같은 자리(`set_windowless_preferences`, 요청 컨텍스트가 준비될 때마다)에서 Chrome 자신의 설정 "결제 수단 저장 및 자동 완성"(`autofill.credit_card_enabled`)과 "주소 저장 및 자동 완성"(`autofill.profile_enabled`)을 끈다. 그러면 자동 완성은 제출된 폼에서 카드·주소·IBAN을 꺼내지 않아(`FormDataImporter::ExtractFormData`) 아무것도 제안하지 않는다. 주소 설정을 끄면 양식 기록(autocomplete, `Web Data`의 `autofill`)도 남지 않는다. 그 제안 목록은 탭의 뷰가 창 안에 있어야 뜨므로(`CanShowRootPopup`) 창 없는 탭에서는 뜨지 않는다(소스 근거) |
| 로캘 | 시스템 첫 언어가 한국어면 Chromium UI 로캘 `ko`, Accept-Language `ko-KR,ko,en-US,en`, 아니면 `en-US` |
| URL 정책 | http, https, file, about, data만 연다. 주소 입력, 페이지 링크·리디렉션·스크립트 이동·폼 POST(다른 사이트로 가고 돌아오는 3-D Secure 포함), 새 창, 에이전트의 CDP `Page.navigate` 모두 호스트의 `on_before_browse`에서 같은 목록으로 거른다(새 창의 첫 주소는 `on_before_popup`에서). 막으면 패널에 알림. 다른 앱의 주소(`mailto:`, `tel:`, `zoommtg:`, `slack:` …)는 2026-10-25 저녁부터 알림 대신 아래 "외부 앱 주소"로 간다. Chromium 자신의 주소(`blob`, `chrome`, `chrome-extension`, `devtools`, `view-source`, `ws` …), Chrome이 다른 앱에 넘기지 않는 주소(`external_protocol_handler.cc`의 `kDeniedSchemes`: `javascript`, `data`, `file`, `shell` …), 한 글자 주소(Windows 드라이브)는 전처럼 막고 알린다(`is_external_scheme`). 주소 칸과 에이전트의 `browser_navigate`는 여전히 다섯 가지만 연다. 2026-10-26부터 주소 칸은 주소가 아닌 입력을 Google 검색으로 연다(Chrome 주소 칸의 기본 검색엔진, `BrowserURLPolicy.addressFieldURL`) |
| 외부 앱 주소 | 2026-10-25 저녁. Chrome 154의 규칙(`ExternalProtocolHandler`)을 따른다. 호스트는 그런 이동을 취소하고 `externalApp(tab:request:)`(주소, 요청한 문서의 출처, 사용자 제스처, 그 출처에 "항상 허용"이 있는지)를 보내고, Yardlet이 정한다(`BrowserHostClient.handleExternalApp`, `BrowserExternalAppPolicy`). (1) 한 번 요청한 페이지는 다음 클릭·키 입력(사람이나 에이전트의 입력)이 있을 때까지 다시 요청해도 아무 일이 없다(Chrome의 홍수 방지 `g_accept_requests`). (2) 그 주소를 여는 앱이 없거나 그 앱이 Yardlet 자신이면 아무 일도 없다(Chrome은 콘솔에만 남긴다). (3) `mailto:`는 묻지 않고 기본 메일 앱으로 연다(Chrome: "every platform provides a default handler for it"). 사람이 "항상 허용"한 출처와 주소 종류도 묻지 않는다. (4) 그 밖에는 패널이 그 탭을 보일 때 페이지 위 막대로 묻는다: "‹앱›을(를) 여시겠습니까?", "‹출처›에서 이 애플리케이션을 열려고 합니다.", 취소·"‹앱› 열기"(Chrome의 문구, 앱 이름은 LaunchServices `urlForApplication(toOpen:)`). 출처가 안전하면(https, 이 Mac의 루프백 http; Chrome `MayRememberAllowDecisionsForThisOrigin`) "항상 ‹사이트›에서 연결된 앱에 있는 이 유형의 링크를 열도록 허용" 상자가 있고, 고르면 호스트가 그 탭의 프로필에 Chrome 자신의 설정 `protocol_handler.allowed_origin_protocol_pairs`(`{출처: {종류: true}}`)를 쓴다(`allowExternalApp`). (5) 에이전트의 입력에서 나온 요청은 (3)이어도 묻는다: 그 탭의 마지막 입력이 에이전트의 도구 호출이면(`BrowserTab.isDrivenByAgent`; 사람의 입력은 패널에서 페이지를 누르거나 키를 친 것, 주소·뒤로·앞으로·새로고침) 사람만 막대에서 연다. 에이전트 도구는 결과에 그 사실을 붙인다. 새 창으로 여는 앱 주소(`target=_blank` 메일 링크)는 탭을 만들지 않는다(Chrome은 그 탭을 닫는다). 막대는 그 페이지가 새 문서로 바뀌면 사라진다(Chrome의 탭 모달 창과 같음). 여는 일은 Yardlet이 `NSWorkspace.open`으로 하고, QA 실행(`YARDLET_QA_BACKGROUND`)은 열지 않는다. host.log에는 `external app tab=… scheme=… remembered=…`(주소는 남기지 않음). 두 앱(번들 바이트): Claude 앱 3.1623.3의 Browser pane은 http·https 밖을 묻지 않고 막고(`block-silent`), Codex 앱 26.1016은 에이전트가 쓰는 탭에서 http·https 밖을 막는다(`Browser Use URL policy`). 그 밖의 탐색은 Owl 프레임워크에 Chrome의 질문 문구와 같은 설정 이름이 있으나 쓰는지는 알 수 없다 |
| 다운로드 | 확인 없이 사용자의 `~/Downloads`에 제안된 이름으로 저장하고, 이름이 겹치면 `이름 (1).확장자`. 호스트가 `LSFileQuarantineEnabled`라 받은 파일에 격리 속성이 붙는다. 패널이 열려 있으면 끝날 때 Dock의 다운로드 스택이 튀고, 알림을 허용했다면 알림, 패널 아래에 "Finder에서 보기"가 뜬다(패널이 없으면 저장만 한다). 같은 페이지의 두 번째 자동 다운로드부터(한 번의 클릭으로 여러 파일, 스크립트가 만든 파일 저장)는 Chrome처럼 "여러 파일 다운로드" 권한을 묻는다(아래 "권한 요청"). 2026-10-25 전에는 아무도 답하지 않아 그 다운로드가 소리 없이 사라졌다(QA). 페이지가 새 창으로 연 탭(`target=_blank`로 연 파일 주소)이 페이지를 하나도 보이지 않은 채 다운로드로 끝나면, Chrome처럼 그 빈 탭을 닫고 연 탭을 앞으로 가져온다(`BrowserHostClient`의 `.download`, 연 탭은 `openedTab`으로 안다). 닫는 때는 다운로드가 끝난 뒤다. CEF는 탭이 닫힌 다운로드를 더 알리지 않아, 일찍 닫으면 패널의 다운로드 줄이 끝을 받지 못한다 |
| JS 대화상자 | alert/confirm/prompt/beforeunload를 패널 창의 시트로. 제목에 요청한 페이지의 호스트 이름을 넣어 페이지가 Yardlet을 사칭하지 못하게 한다. 패널이 창에 없거나 시트가 이미 떠 있으면 취소한다. 패널이 닫혀 있으면 Yardlet은 답하지 않는다(6절). 2026-10-25 저녁부터 사람이 패널에서 탭을 닫으면(✕, ⌘W, 탭 메뉴의 닫기들) Chrome처럼 페이지에 먼저 묻는다: 엔진에 열린 탭은 `requestClose`(호스트 `close_browser(0)`)로 닫고, "나가기 전에 확인"을 쓰는 페이지는 그 질문이 오는 동안 탭이 패널에 남아 Chrome의 "사이트에서 나가시겠습니까?"(나가기·취소, 이동의 질문과 같은 시트)로 묻는다. 취소면 탭과 페이지가 그대로이고, 나가기면 호스트가 닫은 뒤(`closed`) 패널은 다른 탭처럼 그 전에 쓴 탭으로 간다. 그런 처리기가 없는 페이지는 CEF가 바로 닫는다(`NeedToFireBeforeUnloadOrUnloadEvents`). 보이지 않는 탭이 묻으면 그 탭을 앞으로 가져와 묻는다(Chrome이 그 탭을 활성화해 묻는 것과 같음, `BrowserTab.closeQuestion`). 1초 안에 묻지도 닫히지도 않으면(`BrowserHostClient.closeAnswerWait`) 전처럼 바로 닫는다: Chromium은 답하지 않는 렌더러에 500 ms를 주고 닫지만, DevTools가 붙은 탭에는 그 시간 초과를 쓰지 않는다(`WebContentsImpl::ShouldIgnoreUnresponsiveRenderer`). 에이전트의 탭 닫기, 작업 보관·삭제, 앱 종료는 묻지 않는다. 이렇게 Yardlet이 바로 닫은 탭의 beforeunload는 호스트가 바로 "나가기"로 답하고(`BrowserSlot.closing`), 이미 Yardlet에 온 질문도 나가기로 답한다(`leaveDialog`). CEF는 강제 닫기(`close_browser(1)`)에도 페이지에 먼저 묻는데(`AlloyBrowserHostImpl::CloseBrowser`의 `DispatchBeforeUnload`), 그 탭은 이미 패널과 클라이언트에서 빠져 답할 곳이 없었다. 그래서 2026-10-25 전에는 "나가기 전에 확인"을 쓰는 페이지(편집기, 메일 작성)의 탭을 닫으면 그 브라우저와 렌더러가 호스트가 끝날 때까지 보이지 않게 남았다(QA: 닫은 탭의 `javaScriptDialog` kind 3이 종료 때 "requires a parent window handle"로 취소됨). 지금은 1초 안에 닫힌다(host.log `browser closed tab=…`) |
| 파일 선택 | `NSOpenPanel`/`NSSavePanel` 시트. 페이지의 `accept` 확장자를 허용 형식으로 넘긴다. `multiple`, `webkitdirectory`, `showOpenFilePicker`, `showSaveFilePicker`는 각자의 모드로 온다(QA `compat`). `showDirectoryPicker`는 파일 열기로 온다(10절) |
| 권한 요청 | 2026-10-25. 페이지가 Chrome이 권한 풍선으로 묻는 것(알림, 위치, 클립보드 읽기, 여러 파일 다운로드, 다른 사이트의 쿠키, 로컬 네트워크, 글꼴, 창 관리 등)을 요청하면 CEF가 `on_show_permission_prompt`를 부른다. Alloy 방식에서 처리기가 없으면 CEF는 답하지 않고(`CEF_PERMISSION_RESULT_IGNORE`) 페이지의 요청은 끝나지 않았다(QA: `Notification.requestPermission()`이 끝나지 않음, 위치는 페이지가 정한 시간 초과로만 끝남, 같은 페이지의 두 번째 다운로드가 사라짐). 이제 호스트가 `permissionPrompt`(사이트와 Chromium의 권한 이름들)로 넘기고, 패널이 그 탭을 보일 때 페이지 위 막대("‹사이트›에서 다음 권한을 요청합니다: 알림 표시", 차단·허용·닫기)로 묻는다. 답은 `permissionResult`(allow·block·dismiss)로 돌아가고, Chromium이 허용과 차단을 사이트별로 기억한다(Chrome과 같음, 다음 방문에는 묻지 않음). 페이지가 다른 곳으로 가거나 탭이 닫히면 CEF가 `on_dismiss_permission_prompt`를 불러 막대가 사라진다. 패널이 그 탭을 보이지 않는 동안 요청은 기다리고(Chrome도 그 탭이 앞에 올 때 묻는다), 에이전트 도구는 결과에 그 사실을 붙인다(답은 사람만 한다). 카메라·마이크(`getUserMedia`)도 2026-10-25 저녁부터 이 막대로 묻는다("카메라 사용", "마이크 사용"). CEF의 `on_request_media_access_permission`은 Alloy 방식 기본값이 바로 거부여서, 호스트가 자기 프롬프트 번호(2^62 이상)로 Yardlet에 묻고, 답을 Chrome 자신의 사이트 설정(`CEF_CONTENT_SETTING_TYPE_MEDIASTREAM_CAMERA`·`_MIC`, 그 탭의 프로필)에 남겨 다음에는 묻지 않는다(차단은 바로 거부, 허용은 바로 허용). 허용하면 Chromium이 장치를 열고, 그때 macOS가 Yardlet의 카메라·마이크 접근을 처음 한 번 묻는다(앱 Info.plist의 사용 설명, 호스트에도 같은 키와 entitlement). Chromium은 사이트가 허락되기 전에는 macOS에 묻지 않는다(content `MediaStreamManager`, CEF `media_access_query.cc` 원본). 페이지가 새 문서로 바뀌거나 탭이 닫히거나 렌더러가 끝나면 그 요청을 놓아 거부로 끝낸다. 화면 공유(`getDisplayMedia`)는 Chrome의 화면·창 고르기 창이 창 없는 탭에 없어 전처럼 거부한다. Codex 앱 26.1016은 같은 요청을 허용·이번만 허용·거부 창으로 묻고(`setPermissionPromptHandler`), Claude 앱 3.1623.3은 클립보드 쓰기 밖에는 모두 거부한다(둘 다 번들 바이트) |
| PDF | 2026-10-25. Chromium의 PDF 보기(내장 확장 `mhjfbmdgcfjbbpaeojofohoefgiehjai`의 `index.html`)가 PDF 페이지 안 프레임에 열리고, 탭 제목이 파일 이름이 된다. 그 프레임의 `chrome-extension:` 주소를 URL 정책이 막아 모든 PDF가 빈 화면이었던 것을(패널 알림 "chrome-extension://mhjf…/index.html 주소는 열지 않았습니다"), 그 확장으로 가는 하위 프레임만 통과시키게 했다(`is_pdf_viewer_frame`). 탭이나 주소 칸이 그 주소로 가는 것은 여전히 막는다. 보기의 다운로드 단추는 다운로드로, 인쇄 단추는 아래 "인쇄"로 간다 |
| 인증서 오류 | Chromium이 자기 경고 페이지("개인 정보 보호 오류", 고급 → ‹호스트›(으)로 이동(안전하지 않음))를 탭에 보인다. 2026-10-25부터 패널은 인증서 오류(`net::IsCertificateError`: -200부터 -219까지와 -150)에 오류 카드를 덮지 않는다. 전에는 카드("페이지를 열 수 없음 ERR_CERT_AUTHORITY_INVALID", 다시 시도)가 경고 페이지와 그 단추를 가렸다. 자체 서명 인증서에서 고급 → 이동으로 그 페이지가 열리는 것까지 QA로 확인했다(`compat`). Chromium이 넘어가기를 허락하지 않는 오류(HSTS 사이트 등)는 경고 페이지에 그 단추가 없다 |
| HTTP 인증 | Chromium 자신의 로그인 창(Views `LoginView`: 사용자 이름, 비밀번호, 취소·로그인)이 패스키 대화상자처럼 호스트의 별도 창으로 뜬다(2026-10-25 QA에서 창의 글로 확인, 로그인까지 하지는 않음). 그래서 `ChromiumWindows` 규칙(Yardlet 위로 올리기, 활성 넘기기, 에이전트의 닫기)을 그대로 탄다. 2026-10-25 저녁부터 호스트는 창마다 종류를 알린다(`chromiumWindow`의 `kinds`: Views 창 가운데 Chromium 자신의 제목 "Sign in"·"로그인"(`IDS_LOGIN_DIALOG_TITLE`, 호스트의 로캘 둘)이면 signIn, 그 밖의 Views 창은 passkey, AppKit 모달 창은 print). 에이전트 도구는 이 창을 "Chromium's sign-in window for the site's HTTP authentication"으로 부르고, 닫으면 로그인이 취소된다고 알린다. 전에는 "Chromium's passkey dialog"라고 불렀다(QA로 재현) |
| 인쇄 | `window.print()`와 PDF 보기의 인쇄는 Chromium이 macOS 인쇄 창(`PrintingContextMac::AskUserForSettings`의 `NSPrintPanel runModalWithPrintInfo:`)을 호스트의 별도 창으로 띄우는 길이다. CEF는 창 없는 탭에 인쇄 미리 보기를 쓰지 않는다(`CefBrowserPlatformDelegate::IsPrintPreviewSupported`). 원본 근거이고, 시스템 창이 뜨므로 QA로 실행하지 않았다. Codex 앱은 인쇄 명령에서 `webContents.print()`(같은 시스템 창)를 부른다. 2026-10-25 저녁부터 에이전트 도구는 이 창을 "the system's print dialog"로 부른다(호스트가 AppKit 모달 창을 print로 알림; 원본 근거이고 QA로 보지 않음) |
| 결제 API(지갑 단추) | 2026-10-25 저녁. 브라우저 프로세스가 `--disable-features=WebPayments`로 뜬다(알림을 끄는 `NativeNotifications`와 같은 자리, `disable_features`). Chromium은 그 기능으로 `WebPreferences.payment_request_enabled`를 정하고(`WebContentsImpl`) Blink가 그 값으로 `PaymentRequest`를 켜므로, 페이지에 `PaymentRequest`가 없다. 그러면 Google Pay·Apple Pay 같은 지갑 단추를 그 API로 고르는 결제 페이지는 단추를 보이지 않고, 사람은 카드를 입력해 결제한다. 전에는 단추가 보였지만 `show()`가 Chrome 창이 없어 늘 `AbortError`로 끝났다. 두 앱(번들 바이트): Claude 앱과 Codex 앱 모두 이 API를 끄는 지정이 앱 코드에 없고, 프레임워크에 Blink `PaymentRequest` 구현 문자열이 있다("Claude 앱의 Electron에는 이 API가 없다"는 바이트로 확인되지 않았다) |

## 4. 입력

- 마우스(클릭·드래그·이동·나감), 휠·트랙패드(정밀 델타와 관성 단계가 그대로 페이지 스크롤로 이어진다), 핀치 확대.
- 키: macOS 가상 키 코드 → Windows 키 코드 전체 표(`BrowserKeyCodes`, Chromium `keyboard_code_conversion_mac.mm` 기준):
  글자·숫자·기호, 방향키, Home/End/PageUp/PageDown, Delete, F1~F20, 키패드, 수정 키(Shift/Control/Option/Command/
  Caps Lock, 좌우 구분), 한/영(`kVK_JIS_Kana` → VKEY_HANGUL). 수정 키는 flagsChanged로 누름·뗌을 보낸다.
- 한글 등 입력기: 패널 뷰가 `NSTextInputClient`다. 조합 중인 글자는 `composition.set`(밑줄 포함), 확정은 `commit`, 조합 끝은
  `finish`로 보내고, 입력기가 쓴 키는 DOM에 `Process`(229)로 보인다. 입력기가 글자를 확정하고 그 키를 넘기면(`doCommandBySelector:`, 한글
  조합 뒤의 Return·방향키·Tab) 확정한 글자 다음에 그 키 자체를 보낸다(2026-10-24, Chrome `render_widget_host_view_cocoa.mm`과 같음, 전에는
  조합 뒤 첫 Return이 페이지에 가지 않았다). 후보 창 위치는 호스트가 알려 주는 글자 영역을 쓴다.
- 비밀번호 칸(2026-10-25): 페이지의 비밀번호 칸(`<input type=password>`, 어느
  프레임이든)이 키보드를 가진 동안, 곧 보이는 탭의 포커스된 칸이 비밀번호 칸이고 패널 뷰가 키 창의 first responder인 동안 Safari처럼 보안
  입력(`EnableSecureEventInput`)을 켜고 패널 뷰의 입력 맥락에는 로마자 입력 소스만 허용한다(`allowedInputSourceLocales =
  [NSAllRomanInputSourcesLocaleIdentifier]`, WebKit `WebViewImpl::updateSecureInputState`). 한글 입력 소스로 비밀번호 칸에 들어가면 입력 소스가
  로마자로 바뀌고, 다른 프로세스는 키를 엿보지 못한다. 전에는 입력기의 한글 조합이 그대로 들어갔다(점으로 가려져 보이지 않음). 다른 칸, 패널이
  키보드를 잃음, 다른 탭, 패널 닫힘(뷰가 창에서 빠짐), 다른 창·시트·앱(창의 키 상태), 렌더러 종료, 호스트 종료(탭이 뷰에서 떨어짐)에서 둘 다
  끄고, 켠 횟수만큼 끈다(`BrowserHostView.updateSecureInput`, `BrowserSecureInput`). 숨겨진 뷰는 AppKit이 first responder를 거두므로 같이
  꺼진다. 입력 소스 제한은 그 뷰의 입력 맥락에만 걸려 대화 입력창이나 다른 앱에 남지 않고, 보안 입력은 프로세스가 끝나면 시스템이 거둔다.
  Chrome은 같은 일을 `ui::ScopedPasswordInputEnabler`(보안 입력, `TSMSetDocumentProperty`로 ASCII 입력 소스만)로 하고 비밀번호 칸에서
  `inputContext`를 nil로 돌려 입력기도 끈다. Yardlet은 입력기를 끄지 않는다(10절).
  칸의 종류는 렌더러가 알린다. CEF 154의 창 없는 뷰는 브라우저 프로세스에 포커스된 칸의 종류를 주지 않는다(`on_virtual_keyboard_requested`는
  `inputmode`만, 그것도 입력기를 띄울 때만 준다). 그래서 Helper의 렌더러 처리기(`YardletCEFHelper/FocusedField.c`)가 프레임의 포커스가 바뀔
  때마다(`on_focused_node_changed`, cefclient가 편집 칸 알림에 쓰는 CEF 표준 경로) 새로 포커스된 요소가 비밀번호 칸인지를 프로세스 메시지로
  보내고, 호스트는 탭마다 값이 바뀔 때만 `passwordField` 이벤트를 낸다. 메인 프레임(또는 비밀번호 칸이 있던 프레임)에 새 문서가 들어오면 호스트는
  상태를 끄고 그 렌더러에 지금 포커스된 칸을 묻는다. 뒤로-앞으로 캐시에서 돌아온 페이지는 칸에 포커스를 둔 채 돌아와 포커스 변화를 알리지 않기
  때문이다. 새 문서에 밀려난 프레임의 보고(`is_valid`가 거짓)는 버리고, 렌더러가 끝나면 끈다. 탭은 마지막 값을 들고 있어 패널이 다시 보일 때 쓴다.
- 키보드 포커스: 패널 뷰가 창의 first responder이면 보이는 탭의 페이지가 포커스를 갖는다(`focus`). 같은 뷰가 다른 탭을 보이면(브라우저 탭
  사이, 다시 연 탭, 교체한 탭) 보이던 탭은 포커스를 잃고 새 탭이 받는다(2026-10-24, Chrome과 같음. 전에는 뷰가 first responder가 될 때만
  보냈다. QA에서는 그때도 페이지를 클릭하면 Chromium이 포커스를 주어 커서와 입력이 맞았다).
- 페이지가 바뀌어도 포커스가 남는다(2026-10-24): 새 문서로의 이동(링크, 폼 제출, 스크립트
  이동, 뒤로·앞으로, 새로고침, 뒤로-앞으로 캐시)과 다른 사이트 iframe의 커밋. Chromium은 새 페이지 뷰나 iframe의 렌더러에 이전 뷰가 포커스를
  가졌을 때만 포커스를 넘기는데(`RenderFrameHostManager::CommitPending`의 `old_view->HasFocus()`), CEF 154의 창 없는 뷰는 `HasFocus`가 늘
  false이고 `Focus`가 빈 함수다(CEF 156의 `dff7cc2c12`, chromiumembedded/cef#4301에서 고침). 그래서 전에는 새 페이지가 포커스를 잃었다:
  패널은 그대로 first responder라 키는 들어가는데 커서가 그려지지 않고 `document.hasFocus()`가 false였다. 아이디를 낸 뒤 다음 문서에 있는
  로그인 비밀번호 칸이 그 경우다(사용자 보고 "password input에서 왜 커서가 안보이지"). 호스트는 탭마다 Yardlet의 마지막 `focus`를 기억하고
  (`BrowserSlot.focused`) 프레임마다 새 문서가 커밋될 때(`on_load_start`) 그 값이 참이면 `set_focus(1)`을 다시 준다. 본 위젯의 포커스는
  Chromium이 페이지의 다른 프로세스(iframe)에 전하고(`ReplicatePageFocus`), 이미 포커스가 있으면 Blink는 아무것도 하지 않는다. 패널이
  키보드를 갖지 않으면 주지 않는다. CEF를 156 이상으로 올리면 CEF가 같은 일을 하지만, 남겨 두어도 같은 값을 다시 줄 뿐이다.
- 주소 칸에서 Enter나 열기 단추로 이동하면 페이지가 키보드를 받는다(2026-10-24, Chrome의 `BrowserUiController::UpdateUIForNavigationInTab` →
  `SetInitialFocus`). 전에는 키보드가 아무 데도 없어 autofocus 칸에 커서가 없고 타자가 페이지에 가지 않았다. 주소를 열 수 없으면(URL 정책)
  주소 칸에 남는다.
- 입력 시각: CEF의 macOS 경로는 넘겨받은 키·마우스·휠 이벤트의 시각을 `[NSApp currentEvent]`에서 읽고, 없으면 0을 쓴다
  (`browser_platform_delegate_native_mac.mm`). 호스트는 입력을 넘기는 동안 `currentEvent`로 지금 시각(`CLOCK_UPTIME_RAW`)의 이벤트를
  돌려준다(`YardletBrowserHostApplication`, 2026-10-24). 전에는 QA에서 키 이벤트가 1.8–4.1초 늦게 찍혔고(마우스는 맞았음), 페이지가
  열리기 전 시각으로 찍힌 입력으로 SPA가 이동하면 Blink의 soft navigation CHECK가 렌더러를 끝냈다(3절 "렌더러 종료").
- 단축키(패널 뷰에 초점이 있을 때): ⌘C/⌘X/⌘V/⌘A/⌘Z/⇧⌘Z, ⌘+/⌘−/⌘0 확대·축소, ⌘F 찾기, ⌘L 주소 칸, ⌘R 새로고침,
  ⌘[/⌘] 뒤로·앞으로. 탭(창의 초점이 페이지에 있을 때만): ⌘T 새 패널 브라우저 탭, ⌘W 이 탭 닫기(패널 탭 닫기 규칙),
  ⌘⇧T 닫은 탭을 새 탭으로, ⌃Tab·⌃⇧Tab 다음·이전 브라우저 탭, ⌘5…⌘8 그 탭, ⌘9 마지막 탭. ⌘1–⌘4는 창의 키(작업 패널)가
  먼저 받는다. 페이지 밖(대화·주소 칸)에서는 같은 키가 창의 작업 탭 줄에 간다.
- 끌어 놓기: Finder의 파일을 페이지에 놓을 수 있다(`drag` 명령 → CEF drag target). 페이지에서 밖으로 끌기는 지원하지 않는다.
- 커서 모양, `title` 툴팁, `<select>` 목록(popup 층), 우클릭 메뉴(CEF 메뉴 모델을 `NSMenu`로).

## 5. 접근성 (VoiceOver)

창 없는 렌더링이라 Chromium은 macOS 접근성 객체를 만들지 않는다(CEF 문서의 "TreeOnly" 모드). Yardlet이 CEF의 접근성
트리를 받아 `NSAccessibilityElement`로 다시 만든다. 구성은 cefclient의 OSR 접근성(`osr_accessibility_helper`,
`osr_accessibility_node`)과 같은 방식이다. 다만 cefclient 소스는 minimal 배포본에 없어 받지 않았고, 필드 이름과 단위는
실제 CEF 출력을 녹화해 확인했다.

**흐름.** 패널마다 `BrowserAccessibilityBridge`가 `BrowserHostView.accessibilitySource`에 붙는다.
1. 켤 때 `accessibility(tab:isEnabled:)` 명령을 보낸다. 호스트는 `set_accessibility_state`를 부른다.
2. CEF가 `on_accessibility_tree_change`와 `on_accessibility_location_change`를 부른다. CEF는 이 처리기에 브라우저를
   넘기지 않아서, 브리지는 탭마다 client·render handler·accessibility handler를 따로 두어 탭을 가린다.
3. 브리지는 `cef_write_json`으로 JSON을 만든다(큰 페이지 10 MB에 약 80 ms, CEF UI 스레드).
4. 호스트는 별도 직렬 큐에서 `CEFAccessibilityReducer`로 필요한 필드만 남겨 `accessibilityTree`·`accessibilityLocations`
   이벤트로 보낸다.
5. 엔진 `BrowserAccessibilityTree`가 Chromium 규칙으로 적용한다. 노드는 통째로 교체하고, `clear`는 자손을 지우고, 도달할 수
   없는 노드는 없애고, iframe 문서는 별도 트리로 둔다. 부모보다 먼저 온 iframe 트리도 둔다.
6. 브리지가 요소를 만들고 알림을 보낸다.

**필요할 때만 켠다.** 다음 경우에만 켠다.
- VoiceOver가 켜져 있다.
- 접근성 클라이언트가 패널 뷰의 자식, 좌표의 요소(hit test), 포커스 요소를 물었다.

다음 경우에는 끄고 트리를 버린다.
- VoiceOver가 꺼져 있고 60초 동안 묻는 곳이 없다.
- 패널을 닫았다.

켜기 전에는 렌더러가 접근성 일을 하지 않는다. QA에서 질의 전 트리 변경은 0건이었고, 끈 뒤 다시 물으면 트리 전체가 다시 왔다.
다른 접근성 앱(창 관리자, 자동화 도구 등)이 패널 안쪽까지 물으면 그때도 켜진다.

**남기는 필드.**
- 역할, 이름, 값, 설명, placeholder, 역할 설명
- 상태: 초점 가능, 편집, 펼침/접힘, 숨김, ignored, 여러 줄, 보호, 필수, 방문 등
- checked/selected/disabled, `haspopup`, 제목 수준, 표·집합 위치, 범위 값, 텍스트 선택, 링크 URL
- 하위 프레임 트리, 자식, 위치(offset container 기준 기기 픽셀), 스크롤

한 줄마다 생기는 inline text box(글자별 위치 목록 포함)를 버리는 것이 크기를 가장 많이 줄인다. CEF 출력에는 DOM 노드 번호가
없다.

**노출 규칙(엔진).**
- 부모로 펼치는 것: 이름 없는 일반 컨테이너·문단·label·form·rowGroup, iframe 문서.
- 빼는 것: 숨김(invisible) 하위 트리, list marker, 줄바꿈.
- 자식 없는 요소로 두는 것: 버튼·체크박스·텍스트 입력·select처럼 내용이 이름뿐인 역할.
- 텍스트를 이름으로 삼는 것: 텍스트만 가진 링크·제목·목록 항목·표 칸.
- select의 선택지(`menuListOption`)는 자식으로 두지 않고 select가 따로 내놓는다.

**역할.**
- 기본 역할: 버튼, 링크, 텍스트 필드/영역(보안·검색 하위 역할), 체크박스(스위치·토글), 라디오, 팝업 버튼(select),
  콤보박스, 제목(`AXHeading`, 값은 수준), 정적 텍스트, 이미지, 목록, 표·행·칸(행 수·칸 위치), 슬라이더, 진행률, 탭, 메뉴,
  툴바, 트리.
- 랜드마크 하위 역할: 배너(`header`)·탐색·주요·바닥글(`footer`)·보조·검색·영역, 글, 알림, 대화상자.
- AppKit이 설명하지 않는 역할(제목·랜드마크 등)은 한국어·영어 역할 이름을 직접 준다.

**좌표.**
1. 노드 위치에 offset container를 따라 올라가며 위치를 더하고 그 컨테이너의 스크롤을 뺀다(Chromium 규칙). 결과는 기기 픽셀
   페이지 좌표다.
2. 배율로 나눠 뷰 좌표를 얻고, 창 좌표를 거쳐 화면 좌표로 바꾼다. iframe 문서는 그 iframe 위치에서 이어진다.

평범한 스크롤은 Chromium이 트리로 보내지 않는다. CEF의 위치 변경은 빈 목록으로 오고, 루트의 `scrollY`는 크기가 바뀔 때만
다시 온다. 그래서 호스트가 `on_scroll_offset_changed`를 `scrollOffset(tab:x:y:)` 이벤트(뷰 포인트)로 보내고, 트리는 루트가
다시 올 때까지 이 값을 쓴다. QA에서 위치 요소, 스크롤 뒤, iframe 안 요소의 프레임이 페이지의 `getBoundingClientRect`와
0.00 pt 차이였다.

**알림.**

| 알림 | 보내는 때 |
|---|---|
| `layoutChanged` | 구조 변경 뒤(150 ms에 한 번) |
| `valueChanged`·`titleChanged` | 값·이름이 바뀐 요소 |
| `focusedUIElementChanged` | 포커스가 바뀌고 패널 뷰가 first responder일 때 |
| `uiElementDestroyed` | 사라진 요소(20개 이하일 때) |

**동작.**
- AXPress: 요소가 화면 밖이면 페이지를 스크롤한 뒤 요소 중앙을 패널의 마우스 입력으로 클릭한다. select는 선택지를 네이티브
  `NSMenu`로 띄운다.
- 포커스 설정(`AXFocused`), 텍스트 값 설정(`AXValue`), select 선택, `AXScrollToVisible`: CEF 트리에 DOM 노드 번호가 없어서
  위치로 찾는다. 필요하면 페이지를 스크롤하고, 요소 중앙의 DOM 요소에 `Runtime.evaluate` 한 번으로 한다. 값은 전체 선택 뒤
  `insertText`라 페이지의 input 이벤트가 돈다. select는 input·change 이벤트를 보낸다.
- 같은 출처 iframe은 따라 들어간다. 다른 출처 iframe 안에서는 AXPress만 된다.

**비용**(QA, 배율 2).

| 페이지 | CEF JSON → 보낸 크기 | 처리 시간 |
|---|---|---|
| 작은 폼 페이지(노드 107개) | 45 KB → 15 KB | 첫 질의부터 트리까지 27 ms, 적용 2 ms |
| 노드 18,020개(노출 10,009개) 페이지 | 변경 하나 10.0 MB → 2.9 MB(불러오는 동안 전체 트리가 두 번 왔다) | 호스트 가공 0.56~0.64 s(별도 큐), Yardlet 적용 63 ms |

큰 페이지의 나머지 수치:
- Yardlet 메인 스레드 최장 정지 66 ms. 해석을 파이프 큐로 옮기기 전에는 325 ms였다.
- 불러오기 시작부터 트리를 쓸 수 있을 때까지 1.6~1.7 s.
- 노출 트리 한 바퀴 42 ms, 요소 10,009개의 모든 속성 읽기 220 ms.

## 6. 에이전트 쪽 API (엔진)

에이전트 브라우저 도구와 Yardlet MCP 서버는 `MacBrowserHost.shared.client`(`BrowserHostClient`)를 쓴다.

| API | 쓰임 |
|---|---|
| `openTab(forSession:url:viewport:)` | 작업의 앞 탭을 얻는다. 있으면 그 탭(페이지를 다시 열지 않음), 없으면 연다(호스트도 시작). 패널 없이 열 때 `BrowserViewport.offscreenDefault`(1280×800, 2배) |
| `tab(forSession:)` | 작업의 앞 탭(패널이 보여 주고 `tabId` 없는 도구가 쓰는 탭) |
| `tabs(forSession:)` | 작업의 탭들(줄 순서, 패널의 브라우저 탭 순서와 같음) |
| `tab(key:forSession:)` | 패널 탭 키의 탭 |
| `newTab(forSession:url:viewport:select:key:after:)` | 맨 뒤(또는 `after` 바로 뒤)에 탭을 연다. `select`가 거짓이면 앞 탭 뒤에. `key`는 그 탭이 될 패널 탭(기본 새 키). 9개면 `BrowserTabLimitError`, 그 키의 탭이 이미 있으면 `BrowserTabKeyInUseError` |
| `select(_:)` / `BrowserTab.select()` | 앞 탭으로 |
| `closeTabs(forSession:)` | 작업의 탭을 모두 닫고 주소를 잊는다(보관·삭제) |
| `replace(_:url:)` | 응답하지 않는 탭을 같은 키·자리·앞 상태의 새 탭으로(닫은 탭 목록에 넣지 않음, 쥔 hang 콜백이 있으면 렌더러를 먼저 끝냄) |
| `waitForPage(_:)` | 응답 없는 탭의 기다리기(15초 뒤에도 응답하지 않으면 다시 알림) |
| `rememberedTabs(forSession:)`, `restoreTabs(forSession:viewport:)`, `rememberTabs(_:forSession:)`, `reopenClosedTab(forSession:viewport:)` | 호스트가 죽거나 끝나 잃은 탭(앱을 끝낼 때 포함), 또는 앱 재시작 전 작업에 저장된 탭을 순서·앞 탭·키 그대로 다시 연다(`BrowserRememberedTabs.keys`). 닫은 탭을 새 키로 다시 연다 |
| `addTabsObserver(forSession:_:)` / `removeTabsObserver` | 탭이 열리고 닫히고 앞 탭이 바뀌거나 제목·주소·아이콘이 바뀌거나 로딩이 시작·끝나면 부른다(프레임과 그 밖의 로딩 상태는 부르지 않음). 패널과 패널 탭 동기화가 쓴다 |
| `popupOpened`·`newWindow` 이벤트 → `openedTab` 이벤트 | 페이지의 새 창. 호스트가 만든 창(`popupOpened`)은 클라이언트가 작업의 탭으로 받고, 호스트가 만들지 않은 요청(`newWindow`)은 새 탭을 연다. 연 탭에 `openedTab(tab:newTab:url:)`(작업 밖이거나 9개면 `newTab` nil)을 보낸다. 에이전트 도구는 다음 결과에 알린다 |
| `noteAgentActivity(forSession:)` / `BrowserTab.noteAgentActivity()` | 에이전트가 브라우저를 쓸 때마다 부른다. 패널이 없어도 `agentVisibleWindow`(60초) 동안 탭을 엔진에 보이게 하고, 패널 머리글에 "에이전트" 표시가 4초 뜬다 |
| `BrowserTab.devTools` | CDP 클라이언트(`send(method:params:timeout:)`, `nextEvent`, `events`) |
| `BrowserTab.addEventObserver(_:)` / `removeEventObserver(_:)` | 패널의 `eventHandler`와 별도로 이벤트를 받는다(대화상자·다운로드·주소 등) |
| `BrowserTab.key`, `unresponsive`, `currentURL`, `lastPageURL`, `title`, `favicon`, `isLoading`, `canGoBack`, `canGoForward`, `session`, `isPanelAttached` | 상태(뒤에 있던 탭을 앞으로 가져올 때 패널이 읽는다) |
| `attachPanel(to:)` / `detachPanel(from:)` | 패널 전용 |
| `openTab(url:viewport:)`, `closeTab(_:)`, `BrowserTab.close()` | 세션 없는 탭(닫을 때까지 유지)과 명시적 닫기. 2차 시험의 이름 그대로 |
| `accessibility(tab:isEnabled:)` 명령, `accessibilityTree`·`accessibilityLocations`·`scrollOffset` 이벤트 | 패널의 접근성 브리지가 쓴다(5절). 에이전트 도구는 CDP `Accessibility` 도메인을 따로 쓸 수 있다 |

패널이 닫혀 있을 때 페이지가 JS 대화상자나 파일 선택을 열면 Yardlet 패널 쪽은 아무것도 하지 않는다. 대화상자는 누군가
`javaScriptDialogResult`/`fileDialogResult`로 답하거나 탭이 닫힐 때까지 열려 있고, 그동안 페이지 스크립트는 멈춘다.
에이전트 도구는 `addEventObserver`로 `javaScriptDialog`·`fileDialog` 이벤트를 받아 답해야 한다. 패널이 열려 있으면 시트가
뜬다. 이때 에이전트가 먼저 답해도 시트는 남고, 나중에 누른 시트의 답은 호스트가 무시한다(페이지 이동으로 대화상자가
취소되면 `javaScriptDialogReset`이 와서 시트가 닫힌다).

## 7. 빌드와 서명

- `scripts/build-app.sh`는 고정한 CEF를 쓴다: `154.0.28+g564dd6c+chromium-154.0.8037.58`, macOS arm64 minimal, 공식 배포본
  SHA-1 `f7c50c2719deb8aa0c78de517c1228d0b8c3fced`, 프레임워크 실행 파일 SHA-256
  `e2f817695b598f92dcc671238e508a7d7b984983072c36d5257d6c67ff776112`. `~/Library/Caches/Yardlet/CEF/`에 풀린 배포본을 검증해
  쓰고, 압축 파일만 있으면 SHA-1을 확인한 뒤 푼다. 둘 다 없으면 받는 명령을 보여 주고 멈춘다.
- release 번들은 항상 CEF를 넣는다. debug에서만 `YARDLET_WITHOUT_CEF=1`로 CEF 없이 만들 수 있다(패널은 WebKit 미리보기).
- 스크립트가 `YARDLET_CEF_DIR`를 설정해 `Package.swift`가 호스트·helper 타깃을 넣는다. 이 변수가 없으면(`swift build`,
  `swift test`) 그 타깃은 빠진다.
- 서명은 `scripts/sign-app.sh`가 조립한 번들을 안쪽부터 한다: 프레임워크의 dylib → 프레임워크 → helper 5개 → 호스트 → MCP
  실행 파일 → 앱. 각 번들은 자기 Info.plist의 identifier로 서명하므로 QA 복사본(`prepare-qa.sh`)도 같은 길을 쓴다.
  - ad-hoc(기본, `YARDLET_SIGNING_IDENTITY` 없음이나 `-`): 전과 같다. 각 부분에 identifier 기반 designated requirement
    (`com.zzunkie.yardlet.helper`, `….helper.gpu` 등, `com.zzunkie.yardlet.browser-host`, `com.zzunkie.yardlet.mcp`), hardened runtime 없음.
  - 인증서(`YARDLET_SIGNING_IDENTITY`에 이름·이름 일부·SHA-1): 실행 파일마다 hardened runtime(`--options runtime`)과
    `Packaging/Entitlements`의 엔타이틀먼트. Chrome 155 번들의 서명과 Chromium의 `chrome/installer/mac/signing/parts.py`를 따랐다 —
    Renderer·GPU helper만 `com.apple.security.cs.allow-jit`, 나머지 helper(기본·Alerts·Plugin)와 MCP는 예외 없음, 호스트는 패스키용
    `com.apple.security.device.bluetooth`·`…usb`, 앱은 호스트의 블루투스를 책임지므로 `…bluetooth`, 그리고 앱이 띄우는 명령(하네스, 그 도구,
    터미널)의 권한 요청이 macOS에서 앱의 것이 되므로 `com.apple.security.automation.apple-events`·`device.audio-input`·`device.camera`와
    Info.plist 사용 이유 문자열(Claude Code가 Apple Events·마이크를 선언하고, Claude 앱·Codex 앱·VS Code·Cursor·cmux가 같은 셋을 둔다.
    hardened runtime 앱에 엔타이틀먼트가 없으면 tccd가 묻지 않고 거절한다). 라이브러리는 자기 프로세스의
    hardened runtime을 따른다. Developer ID 인증서는 보안 타임스탬프(`--timestamp`, Apple 타임스탬프 서버)로, 다른 인증서는 없이
    서명한다(`YARDLET_SIGNING_TIMESTAMP`로 바꿈). 공증은 `scripts/notarize.sh`(README "Signing and notarization")가 먼저 모든 Mach-O의
    Developer ID·타임스탬프·hardened runtime·`get-task-allow` 없음과 notarytool 키체인 프로필(기본 `yardlet-notary`, 없으면
    `store-credentials` 명령을 보여 주고 멈춤)을 확인한 뒤, 앱(zip)을 `notarytool submit --wait`로 보내 스테이플하고, 그 앱과
    /Applications 링크를 담은 DMG를 앱의 인증서로 서명해 다시 보내 스테이플한 뒤 둘 다 `spctl`로 확인한다.
  - 프로필(`YARDLET_PROVISIONING_PROFILE`): 호스트의 `embedded.provisionprofile`로 넣는다. 프로필의 App ID가
    `<팀 ID>.com.zzunkie.yardlet.browser-host`인지, 팀이 서명 인증서와 같은지, 만료 전인지 확인하고, 호스트 엔타이틀먼트에
    `com.apple.application-identifier`·`com.apple.developer.team-identifier`를 넣는다. 앱 본체는 제한된 엔타이틀먼트를 쓰지 않아
    프로필이 필요 없다. Touch ID용 `keychain-access-groups`는 CEF 프레임워크가 기대하는 그룹(`scripts/cef-webauthn-group.sh list`)이 이 팀
    접두사로 시작할 때만 넣는다. 배포본은 `.org.chromium.Chromium.webauthn`·`…-uvk`라 넣지 않는다(넣으면 프로필이 허용하지 않아
    AMFI가 호스트 실행을 막는다).
  - Touch ID 시제품(`YARDLET_PATCH_CEF_WEBAUTHN_GROUP=1`, 프로필과 함께일 때만, 기본 꺼짐): 번들에 복사한 CEF 프레임워크 사본에서
    두 상수를 같은 길이(31·35바이트)로 `<팀 ID>.com.zzunkie.webauthn`·`…-uvk`로 바꾸고(받은 배포본과 그 고정 해시는 그대로) 그 그룹을
    엔타이틀먼트에 넣는다. 가짜 팀 ID로 바꾼 QA 빌드에서 host.log의 "Expected value"가 바뀐 그룹이 되는 것까지 확인했다. 실제 Touch ID
    등록·로그인은 2026-10-23 실제 팀의 Developer ID 프로필로 서명한 QA 번들에서 사용자의 Touch ID 지문으로 성공했다.
    바이너리 상수를 바꾸는 이 방식은 여전히 명시적 opt-in이며 기본값은 꺼져 있다.
- 업데이트: 설치본이 팀 서명(Developer ID)이면 `stage-update.sh`와 Install Update…·설치 스크립트가 새 빌드에 설치본의 designated
  requirement(같은 identifier, 같은 팀)를 요구한다(Sparkle과 같은 규칙). ad-hoc 설치본은 전처럼 서명이 맞는 어떤 Yardlet 빌드든 받는다.
- 새 CEF로 올릴 때: 버전·URL·두 해시를 바꾸고, C API 해시(`CEF_API_VERSION`)가 맞는지 호스트 시작으로 확인하고,
  `scripts/browser-host-qa/run-check.sh`를 돌린다.

## 8. 파일 위치

| 경로 | 내용 |
|---|---|
| `~/Library/Application Support/Yardlet/Browser/Default` | 기본 프로필(쿠키, 저장소, 캐시): 작업 없는 탭, "모든 작업이 함께", 새 작업의 시작 쿠키 |
| `~/Library/Application Support/Yardlet/Browser/Task-<key>` | 작업마다의 프로필(Chromium이 root cache 바로 아래만 디스크 프로필로 연다). `TaskProfiles.json`은 새 작업 화면의 키와 그 탭을 넘겨받은 작업의 키. 남은 작업에 속하지 않는 폴더는 호스트가 끝날 때 지우고, Chromium이 `Local State`에 남긴 그 프로필의 기록(`profile.info_cache`, `profile.profiles_order`, `variations_google_groups`)도 지운다 |
| `~/Library/Application Support/Yardlet/Browser/Home` | 호스트의 `CFFIXED_USER_HOME`. Chromium이 캐시 경로 밖에 쓰는 파일(`CEF/User Data`, `Google/RLZ` 등)이 여기 모인다 |
| `~/Library/Application Support/Yardlet/Browser/Logs/host.log` | 호스트 표준 오류(4 MB를 넘으면 새로 시작), `chromium.log` |
| `~/Downloads` | 다운로드 |
| `$TMPDIR/<bundle id>.browser-host.*` | Chromium의 임시 폴더(OS가 정리) |
| `/var/folders/…/X/<호스트 번들 ID>.code_sign_clone/code_sign_clone.XXXXXX` | 호스트 하나가 시작할 때 Chromium이 만드는 호스트 번들의 사본(APFS 사본에 실행 파일만 하드 링크). 업데이트가 번들을 바꿔도 실행 중인 호스트의 서명이 맞게 둔다. 호스트가 끝나면 Chromium의 정리 Helper가 지운다(3절 "종료"). 강제로 끝난 호스트의 것은 남고, macOS dirhelper가 3일 뒤 지운다. 사본이 생긴 뒤에는 커널이 알려 주는 호스트의 실행 경로(`proc_pidpath`)가 사본 쪽일 수 있다 |

## 9. 보안

- 프레임은 Mach로 받는다. Yardlet이 실행마다 `"<bundle id>.browser-host.<pid>.<128비트 난수>"` 이름으로 bootstrap check-in을
  하고, 이름과 256비트 토큰을 호스트 환경 변수로 넘긴다. 받은 메시지는 커널이 붙인 audit token의 PID가 띄운 호스트인지,
  토큰이 맞는지 확인하고 아니면 버린다(QA에서 Yardlet 자신이 보낸 위조 메시지 2건이 거부됨). 설치본과 QA 앱이 함께 떠도
  이름이 겹치지 않는다.
- 호스트 쓰기 파이프는 `F_SETNOSIGPIPE`라 호스트가 죽어도 Yardlet이 SIGPIPE로 끝나지 않는다.
- helper 샌드박스를 켠다. 프레임워크·helper가 호스트 번들 밖에 있으면 샌드박스가 GPU helper의 프레임워크 적재를 막는다.
- URL 정책, 새 창, 다운로드 격리 속성은 3절. 인증서 오류는 CEF 기본(차단 페이지), HTTP 인증 창은 지원하지 않는다.
- mock keychain의 절충은 3절.

## 10. 알려진 한계

- **접근성:** 요소 단위 이동(VO+화살표), 읽기, 누르기, 포커스, 값 설정, select 선택, 스크롤해서 보이기는 된다(5절). 다음은
  없다.
  - VoiceOver의 웹 탐색: 로터의 제목·링크 목록과 빠른 탐색(`AXUIElementsForSearchPredicate`), text marker 기반 글자·단어·줄
    이동. 루트를 `AXWebArea`가 아닌 그룹으로 내놓는 이유다.
  - 라이브 영역 알림, 슬라이더 증감(AXIncrement/Decrement).
  - 페이지 안 스크롤 영역의 스크롤과 CSS transform의 위치 반영: 다시 그려질 때까지 이전 위치로 보인다.
  - 다른 출처 iframe 안의 포커스·값 설정.
- **프로필 잠금:** 같은 사용자 홈을 쓰는 Yardlet 두 개(예: 설치본과 개발 빌드)가 동시에 브라우저를 열면 두 번째 호스트는
  Chromium 프로필 잠금 때문에 시작하지 못한다(`cef_initialize returned 0`, 로그에 "기존 브라우저 세션에서 여는 중").
  QA가 서로 다른 임시 홈을 쓰는 이유다.
- 트랙패드의 가장자리 탄성(rubber-band)과 스와이프 뒤로 가기는 없다(CEF 휠 이벤트에 단계 정보가 없음). 스마트 확대(두 번 탭)도 없다.
- 웹 알림은 보이지 않는다. 2026-10-25부터 브라우저 프로세스가 `--disable-features=NativeNotifications`로 떠서(`disable_native_notifications`,
  확장 스위치의 `disable-features`에 덧붙임) Chromium이 시스템 알림 브리지를 만들지 않는다. 그 전에는 시작할 때마다 지난 알림을 맞추느라
  배너 서비스(호스트 자신)와 `Yardlet Helper (Alerts)`를 macOS 알림에 연결해 권한을 요청했고, 새 bundle ID의 QA 번들마다 사람의 화면에
  허용 요청이 떴다. 웹 알림을 Yardlet 알림으로 넘기는 공개 CEF API는 없다.
- 페이지에서 밖으로 끌기, 확장 프로그램, DevTools 창은 없다.
- 카메라·마이크는 2026-10-25 저녁부터 권한 막대로 묻는다(3절 "권한 요청"). QA는 막대에서 차단까지만 본다: 허용하면 macOS의 허용 창이
  사람의 화면에 뜨기 때문이다. 그래서 허용 뒤 macOS가 묻는 단계, 실제 영상과 소리, 서명한 설치본에서 호스트 entitlement가 쓰이는지(Yardlet
  본체에는 전부터 있음)는 확인하지 않았다. 화면 공유(`getDisplayMedia`)는 고를 창이 없어 거부한다. 위치와 알림은 막대에서
  허용할 수 있지만, 그 뒤 macOS가 묻는 단계와 알림이 실제로 뜨는지는 확인하지 않았다(호스트와 Yardlet에 위치 사용 설명이 없다).
- 외부 앱 주소(`mailto:`, `tel:`, `zoommtg:`, `slack:` 등)는 2026-10-25 저녁부터 Chrome처럼 열거나 묻는다(3절 "외부 앱 주소"). 남은 차이:
  (1) 주소 칸에 그런 주소를 쳐 넣으면 Chrome은 앱을 열지만 Yardlet은 전처럼 막는다. (2) "항상 허용"은 그 탭의 프로필에 남아, 작업마다 따로인
  프로필에서는 작업마다 따로다(Chrome은 프로필 하나). (3) 에이전트의 입력에서 나온 요청은 메일 링크와 "항상 허용"한 사이트도 사람에게 묻는다
  (Chrome에는 에이전트가 없다). 실제 메일 앱·FaceTime·Zoom이 열리는지는 QA로 보지 않았다(여는 함수를 기록기로 바꿔 끼움).
- 사용자 제스처 없는 팝업은 Chrome처럼 열지 않고(`window.open`이 null), 2026-10-25 저녁부터 주소 칸 오른쪽의 "팝업 차단됨" 목록에서 연다(3절
  "새 창"). 그렇게 연 탭에는 `window.opener`가 없고, "이 사이트의 팝업 항상 허용"은 없다. 페이지가 사용자 제스처 뒤 5초 안에 연 창은 제스처가
  있는 것으로 친다(Chromium의 transient activation).
- 탭을 닫을 때 Chrome의 "사이트에서 나가시겠습니까?"는 2026-10-25 저녁부터 사람이 패널에서 닫을 때 묻는다(3절 "JS 대화상자"). 에이전트의 탭
  닫기, 작업 보관·삭제, 앱 종료는 묻지 않고 닫는다(Chrome은 창을 닫거나 끝낼 때도 묻는다). 1초 안에 답하지 않는 페이지는 묻지 않고 닫는다.
- `showDirectoryPicker()`는 파일 열기 창으로 온다. CEF가 폴더 고르기(`ui::SelectFileDialog::SELECT_FOLDER`)를 처리하지 않기 때문이다
  (`file_dialog_manager.cc`의 NOTIMPLEMENTED, 기본 모드 열기). `<input webkitdirectory>`는 폴더 창이다.
- 전체 화면(`requestFullscreen`)은 패널의 페이지 영역 안에서만 된다. 창을 전체 화면으로 바꾸지 않는다(CEF `on_fullscreen_mode_change` 없음).
- 비밀번호 칸(2026-10-25부터 보안 입력과 로마자 입력 소스 제한, 4절)에 남은 차이: (1) Chrome·Claude 앱·Codex 앱처럼 입력기 자체를 끄지는
  않는다(`inputContext`가 nil). 한글·일본어처럼 조합하는 입력기는 로마자 입력 소스 제한으로 빠지고, 로마자 입력 소스의 dead key 조합은 Safari처럼
  남는다. (2) 칸에 포커스가 있는 채 스크립트가 `type`을 바꾸면(포커스를 옮기지 않는 "비밀번호 보기" 단추) 다음 포커스 변화까지 앞 상태가 남는다.
  Chrome은 한 번 비밀번호 칸이었던 칸(`TEXT_INPUT_FLAG_HAS_BEEN_PASSWORD`)도 비밀번호 칸으로 보고, CEF의 DOM API는 그 표시를 주지 않는다.
  (3) 실제 입력 소스가 로마자로 바뀌고 칸을 떠나면 돌아오는지는 QA로 보지 못했다. 앞에 있는 앱에서만 일어나는데 QA 앱은 활성 앱이 되지 않고,
  사람의 입력기를 바꾸지 않으려고 기록기(`BrowserSecureInputRecorder`)로 켜고 끈 차례만 본다(11절).
- 패스키: iCloud 키체인은 없고, Touch ID는 7절 시제품으로 만든 빌드에만 있다(3절의 이유). 그 사이트의 패스키가 없는 즉시 요청은 Chrome처럼 QR 시트로 바로 간다(3절 (2)). 대화상자를 올리고 활성을 넘기는 동작은 QA에서 실행하지 못했다(QA 앱은 뒤에서
  떠 활성 앱이 되지 않는다; 규칙은 `ChromiumWindowPresentationTests`). 실제 USB 보안 키와 휴대폰으로 끝까지 등록·로그인한 확인도 없다.
- 탭은 작업당 9개까지다. 에이전트가 사용자가 보는 탭을 쓰면 입력이 섞일 수 있다(`browser_tab_new`로 뒤 탭에서 일할 수 있다).
  탭 끌어 순서 바꾸기·탭을 창으로 떼기·탭 이름 바꾸기·음소거는 없다(Codex 앱에는 있음). 페이지 초점에서 ⌘1–⌘4는 탭을 고르지 않는다(창의
  키가 먼저 받음). 아이콘은 저장하지 않아 다시 켠 뒤 페이지가 열릴 때까지 지구본이다.
- 새 창(3절 "새 창"): 사용자 제스처 없는 팝업은 열지 않고, 창 크기 요청은 쓰지 않고 탭으로 연다. 탭이 9개인 작업이나 작업 밖의 탭에서는
  여는 탭이 그 주소로 가므로 그때는 `window.opener`가 없다.
- 카드·주소 자동 완성(저장 제안, 저장한 것 채우기, 양식 기록)은 없다(3절 "자동 완성의 저장 제안"). Chrome의 그 화면들은 브라우저 창에 붙는다.
  Payment Request(Google Pay·Apple Pay 단추, Secure Payment Confirmation)는 2026-10-25 저녁부터 페이지에 없다(3절 "결제 API"). 전에는 `show()`가
  결제 시트를 띄우지 않고 `AbortError: Cannot show PaymentRequest UI in a preview page or a background tab.`로 끝났다. Chromium은 탭의 Chrome 창이
  활성일 때만 시트를 띄운다(`ChromePaymentRequestDelegate::IsBrowserWindowActive`). 그래서 지갑으로만 결제하는 사이트는 결제할 수 없고, 카드를
  입력하는 결제는 된다.
- 패널이 닫힌 탭의 JS 대화상자·파일 선택은 에이전트가 답할 때까지 열려 있다(6절). 권한 요청은 패널이 그 탭을 보일 때까지 기다린다
  (에이전트는 답하지 못한다). 다운로드 알림도 패널이 있을 때만 뜬다.
- **대화상자 로그 한 줄(2026-10-22 전, 새 창을 같은 탭에서 열던 때):** 사용자 제스처가 있는 `window.open`은 호스트가 새 창을 취소하고 같은 탭에서 열었다. 그 뒤 그
  페이지의 다음 main frame 이동에서 CEF가 `Default dialog implementation requires a parent window handle; canceling the JS
  dialog`를 한 번 남긴다. QA에서는 CDP로 부른 `window.open` 뒤에만 보였고, 실제로 클릭한 `target=_blank` 링크 뒤에는
  남지 않았다.
  - Yardlet의 JS 대화상자 처리기 네 개(on_jsdialog, on_before_unload_dialog, on_reset_dialog_state, on_dialog_closed)는 모두
    불리지 않는다.
  - 같은 탭으로 여는 방법을 바꿔도 남는다: 콜백 안의 `load_url`, 콜백 뒤로 미룬 `load_url`, 페이지 쪽 `location.assign`,
    아예 열지 않기.
  - 이동은 그대로 진행되고 사용자에게 보이는 것은 없다. 즉 Yardlet으로 보낼 수 있는 대화상자가 아니라, 취소된 새 창에 대한
    CEF 내부 처리로 본다. 무엇인지 더 알려면 CEF 소스나 verbose 로그가 필요하다(minimal 배포본에 없음).
  - DEBUG 호스트는 QA에서 명령과 대화상자 처리를 시각과 함께 로그에 남겨 대조할 수 있다.
- 호스트마다 시작할 때 로그에 `sandbox_extension_issue_file_to_process failed … Operation not permitted` 한 줄이 남는다. 기능 영향은 보지 못했다.
- 종료의 멈춤(2026-10-24): QA 전체 확인 8번 가운데 3번, 많이 쓴 첫 호스트가 유예 시간 뒤의 `shutdown`에서 Chromium 하위 프로세스를 끝낸 뒤
  `CefShutdown`에서 돌아오지 않았다(통계 줄 없음, 사본 정리 Helper도 뜨기 전). 5초 뒤 Yardlet이 SIGKILL로 끝내므로 그 호스트의 사본만 남는다.
  원인은 확인하지 못했다(멈춘 호스트의 표본을 아직 뜨지 못함). 2026-10-25 `--ui-fixture-browser-check-only=tabs`에서 탭 2개가 열린 채
  끝낼 때 두 번 연속 같은 모양으로 멈췄다(host.log가 `command shutdown`에서 끝남, 열린 탭의 `closed`는 둘 다 옴). 재현 길로 쓸 수 있다.
  2026-10-25 처음 뜬 멈춘 호스트의 표본(작업 트리 `~/Desktop/…/.build` 아래 QA 홈, `compat`)에서 주 스레드는 `yardlet_cef_shutdown` 안에서
  기다리고, Chromium 작업 스레드 셋이 프로필 파일의 `getxattr`(`NSURL getResourceValue:forKey:`) 둘과 `link` 하나에서 표본 내내 막혀
  있었다. `~/Desktop` 아래에서 돈 `compat` 실행 다섯 번은 모두 사본이 남았고, 같은 빌드를 `$TMPDIR` 아래 QA 홈으로 돌리자 정상 종료
  (통계 줄, 사본 없음)였다. QA에서의 원인은 macOS의 데스크탑 폴더 보호로 본다(11절, QA 앱의 `open()`도 같은 곳에서 멈췄다). 설치본의
  프로필은 `~/Library/Application Support` 아래라 해당하지 않을 것으로 보지만 확인하지 않았다.
- 프레임 전달: 호스트는 새 IOSurface를 Mach 메시지로 기다리지 않고 보내고(큐가 차면 그 프레임만 버림), Yardlet은 프레임
  이벤트가 오는 대로 파이프 큐에서 받는다(2절). 전에는 패널 없는 탭에서 큐가 차 CEF UI 스레드가 프레임마다 1초씩 막혀 CDP가 수 초 늦었다.
- 가속 그리기의 복사: `on_accelerated_paint`의 IOSurface는 콜백 밖에서 쓸 수 없어(CEF 풀) 호스트가 Metal blit으로 자기 링에
  복사하고 끝나기를 기다린다. 2026-10-22 QA(840×1536 px, 120 fps 애니메이션 3초)에서 CEF UI 스레드 표본 1,497개 중 콜백 399개,
  그중 대기 216개 — 프레임당 약 0.6 ms. 완료 핸들러로 비동기화하면 UI 스레드 시간을 더 줄일 수 있지만 아직 하지 않았다.
- 스크롤 프레임 속도: 120 Hz 디스플레이에서 requestAnimationFrame은 120 fps지만 휠(정밀 델타 120·240 이벤트/초)·Page Down 스크롤은
  60 fps다(QA `run-perf.sh`). CEF OSR의 BeginFrame은 120 Hz로 돌고 있으니 Chromium 컴포지터가 입력 스크롤 프레임을 절반으로 제한하는
  규칙으로 보이며, 어느 기능(`cc` 프레임 속도 추정, `viz` FrameRateDecider 등)인지는 확인하지 못했다.
- 번들이 크다: release 303 MiB(zip 134 MiB), 그중 호스트 272 MiB.

## 11. QA

DEBUG 번들에서 `scripts/browser-host-qa/`의 도구로 실제 패널·호스트·CDP 경로를 확인한다.

```sh
./scripts/build-app.sh
QA="$TMPDIR/browser-host-qa"; mkdir -p "$QA"
./scripts/browser-host-qa/prepare-qa.sh .build/Yardlet.app "$QA/Yardlet Browser QA.app" com.zzunkie.yardlet.browserqa
./scripts/browser-host-qa/run-check.sh "$QA/Yardlet Browser QA.app" "$QA/run1" \
    --ui-fixture-browser-grace=12 --ui-fixture-browser-accessibility-idle=6
./scripts/browser-host-qa/cleanup-qa.sh "$QA/Yardlet Browser QA.app" "Yardlet QA builds $(date +%F)"
```

QA 앱은 별도 bundle ID(안쪽 호스트·helper 포함), 임시 홈, `--ui-fixture=conversation`, `open -g`와 `YARDLET_QA_BACKGROUND=1`로
뜬다. 그 변수(`QABackground`)가 있으면 앱은 Dock·메뉴 막대·⌘Tab에 나오지 않는 accessory 앱이고, 활성 앱이 되지 않으며, 창은 모든 화면의
왼쪽 아래 바깥에 놓인다. 알림 클릭·Dock 튀기기·업데이트 알림·패스키 창 넘김도 이 변수를 따르고, 같은 변수를 물려받은 호스트는 Chromium의
창(패스키)을 화면 밖에 두고 활성화하지 않는다(2026-10-24, 전에는 창이 화면에 "Yardlet"으로 떠 사람이 클릭하고 키를 칠 수 있었다).
`run-perf.sh`만은 디스플레이의 프레임을 재야 해서 창을 화면에 두되(`--ui-fixture-browser-perf`) 활성화하지 않는다. 사람이 Mac을 쓰지 않을
때 돌린다. `run-check.sh`는 끝나든 끊기든 자기가 띄운 앱과 그 프로세스 트리를 PID로 끝내고, 번들 안의 프로세스가 남으면 실패로 적는다.
끝난 뒤에는 이 QA 번들의 프로세스가 남긴 충돌 보고서(`~/Library/Logs/DiagnosticReports`, 보고서 첫 줄의 bundleID로 가림, `crash-reports.txt`)와
남은 호스트 사본(8절)도 보고, fixture가 일부러 끝낸 렌더러(`result.json`의 `intentionalRendererCrashes`, `input`의 `Page.crash`) 밖의 보고서나
남은 사본이 있으면 실패로 적는다(2026-10-24). `YARDLET_PROVISIONING_PROFILE`을 지정하면 호스트만 원래 App ID를 유지해 프로필과
일치시키고, 앱 본체·helper는 QA ID로 바꾼다. 프로필·CEF 패치 변수는 `sign-app.sh`에 그대로 전달한다. 쿠키는 QA의 mock 키체인을
쓰지만, Touch ID 등록·인증은 실제 팀의 키체인 그룹과 사용자의 지문을 사용한다(README "Signing and notarization"). `run-check.sh`는 단계마다 프로세스 트리의 메모리·깨어남을 재고, 끝나면 남은 프로세스가 없는지 본다.
`cleanup-qa.sh`는 LaunchServices 등록을 해제하고 번들과 환경설정 파일을 휴지통 폴더로 옮긴다. 알림 등록은 지우지 못한다(`usernoted`의
저장소는 공개 방법으로 지울 수 없다). 그래서 QA 번들은 처음부터 알림에 등록되지 않는다: 본체는 QA ID나 `YARDLET_QA_BACKGROUND`이면 알림
센터를 쓰지 않고, 호스트와 helper는 위 10절대로 macOS 알림에 연결하지 않는다(2026-10-25). 사람이 볼 때는
`qa-launch.sh`로 fixture만 띄워 창을 앞으로 가져온다. 뒤에서 뜬 QA 창은 다른 창에 가려져 있을 수 있어 `run-check.sh`와
`run-latency.sh`는 `--ui-fixture-browser-ignore-occlusion`(DEBUG)을 넘겨 가림과 관계없이 패널이 그리게 한다(가림 자체는
`BrowserHostVisibilityTests`와 `run-perf.sh`의 최소화 단계가 본다). 마지막 단계 바로 앞에서는 에이전트 도구가 패널 없는 탭에 `/tall`(800 px
뷰포트에서 4,086 px, 띠마다 다른 색)을 열어 `fullPage`로 찍고, 띠마다 가운데 색이 한 번씩 순서대로 나오는지와 이미지가 페이지 크기인지, 뒤에 탭의
크기와 페이지의 `innerHeight`·높이가 그대로인지 본다(`fullpage-screenshot.png`, 2026-10-24). `run-check.sh`의 마지막 단계는 패널이 닫힌 채 에이전트가 탭을
열어 쓰고, 그동안 다른 탭의 크기를 30번 바꿔 표면 ID가 다시 쓰이게 한 뒤 패널을 연다. 크기마다 그 크기의 프레임이 보이는지와
패널이 에이전트의 페이지를 패널 크기로 보이는지를 확인한다.
"tabs: side-panel tabs"(⌘T, 에이전트가 뒤에 연 탭, 그 탭을 앞으로 가져와 닫기, ⌘⇧T, 닫기)는 2026-10-23부터 25일까지 자주 실패했다. 부하
때문이 아니라 제품의 경쟁 조건이었다. 칸(`BrowserHostPaneController`)은 패널이 보이는 탭을 SwiftUI `.onChange(of: key)`로만 따라갔는데,
SwiftUI는 그 동작을 한 프레임에 한 번만 돌리고 같은 프레임의 두 번째 변화는 버린다(시스템 로그 `onChange(of: UUID) action tried to update
multiple times per frame`). 그려지지 않는 QA 창에서는 프레임이 잘 넘어가지 않아 30~60 ms 간격의 탭 전환 두 번이 한 프레임에 묶였고, 칸은
다음 전환이 올 때까지 이전 탭이나 닫힌 탭에 남았다(실패 글의 "new tab in front false", "pane key …/-1"). 2026-10-25부터 칸은 작업 공간의
`panels`를 `withObservationTracking`으로 직접 따라간다(`followPanel`). tabs 단독 실행에서 고치기 전 빌드는 16번 중 12번(부하 평균 5~10),
중간 수정 빌드는 5번 중 2번 실패했고, 실패한 실행에만 그 경고가 하나씩 있었다. 고친 빌드는 8번(부하 평균 8~24)과 전체 확인 51개가 모두
통과했다. 이 단계가 다시 실패하면 같은 시각의 `/usr/bin/log show --predicate 'eventMessage CONTAINS "multiple times per frame"'`부터 본다.
`--ui-fixture-browser-check-only=input`(QA 경로 `/login`)은 일반 칸과 비밀번호 칸의 포커스·커서(프레임 픽셀에서 커서 열)·입력, 같은 칸이 다른
탭을 보인 뒤의 포커스, 페이지가 바뀐 뒤의 포커스와 비밀번호 칸 커서(같은 사이트와 다른 사이트(`localhost`)의 새 문서 `/login?autofocus=pass`, 다른
사이트 iframe `/login-frame`, 뒤로, 실제 주소 칸의 Enter)와 패널이 키보드를 갖지 않을 때의 이동(페이지가 포커스를 받지 않음), 페이지가 받은 입력 이벤트의 나이(`performance.now() - event.timeStamp`), 클릭과 Enter 뒤의 SPA 이동(pushState와 새
내용)에도 렌더러가 남는지, 로딩 중 페이지 높이, `Page.crash` 뒤의 머리 상태와 host.log 줄을 `input.json`에 적는다. 같은 단계가 비밀번호 칸의
보안 입력(2026-10-25, 4절)도 본다. QA 앱(`QABackground`)과 검사는 실제 보안 입력과 입력 소스를 건드리지 않고 기록기(`BrowserSecureInputRecorder`,
창을 키 창으로 셈)로 켜고 끈 차례를 적는다: 일반 칸과 비밀번호 칸 클릭, 패널이 키보드를 잃고 되찾기, 위의 페이지 이동마다(다른 사이트 iframe의
비밀번호 칸, 뒤로-앞으로 캐시에서 돌아온 페이지(`/login`의 `window.__restored`), 주소 칸 Enter), 칸 없는 페이지, 패널이 키보드를 갖지 않을 때의
autofocus, 두 탭이 각자 지키는 칸, 렌더러 종료와 새로고침, 호스트 종료와 다시 열기, 패널 닫기에서 켜짐·꺼짐과 켠 횟수만큼 끈 것
(`input.json`의 `secureInput.calls`). `run-check.sh`는 도는 동안 이 실행의 프로세스가 실제 보안 입력을 쥐는지(IORegistry 루트의
`kCGSSessionSecureInputPID`) 보고 쥐면 실패로 적는다(`secure-input.txt`).

성능은 `run-perf.sh <QA 앱> <출력>/perf-1`(`BrowserHostPerfFixture`)로 잰다. 창을 주사율이
가장 높은 디스플레이로 옮겨 1400×900으로 두고(패널 420×768 pt), 패널 열기(콜드·웜·돌아가는 호스트의 새 탭)부터 첫 프레임까지,
`/large`에서 정밀 휠 120·240 이벤트/초와 Page Down의 프레임 수·그린 뒤 화면까지 지연, `/animation`의 프레임 수와 페이지 자신의
rAF 수, 창을 최소화한 2초와 복원 뒤, 창 높이 40번 변경(새 크기 프레임까지 시간, 전후 footprint), 패널을 닫아 탭이 숨겨진 뒤의
footprint를 `perf.json`에 쓴다. 단계마다 프로세스 트리의 CPU·footprint(`samples/`)와 애니메이션 중 호스트 `sample`을 남긴다.
QA 홈은 출력 폴더의 형제 `qa-home`이다. 동시에 도는 다른 QA와는
출력 폴더의 부모를 달리해 홈이 겹치지 않게 한다(프로필 잠금).

지연은 `run-latency.sh`(`--ui-fixture-browser-latency`)로 잰다. 실제 패널·호스트에서 메인 스레드가 한가할 때와 설치본이
흐를 때만큼 바쁠 때(17 ms 막기를 초당 28번) 애니메이션 페이지의 그림→화면 지연·화면에 놓인 프레임 간격, 긴 페이지의
휠 입력→화면 지연을 `latency.json`에 남긴다. 입력은 창 서버 이벤트처럼 다른 스레드에서 메인 큐로 넣는다.

```sh
./scripts/browser-host-qa/prepare-qa.sh .build/Yardlet.app "$QA/Yardlet Latency QA.app" com.zzunkie.yardlet.latencyqa
./scripts/browser-host-qa/run-latency.sh "$QA/Yardlet Latency QA.app" "$QA/latency1"
```

`--ui-fixture-browser-check-only=tabs`는 오른쪽 패널의 브라우저 탭만 돈다("tabs: side-panel tabs"). 끝에 탭이 열린 채 앱 종료처럼 호스트를 끝내고(`terminateHost`), 호스트가 탭마다 보낸 `closed` 수와 패널 탭·기억한 탭이 그대로인지 본다("tabs: quitting keeps the panel's tabs", 2026-10-25).

`--ui-fixture-browser-check-only=compat`은 일반 사이트가 브라우저에 바라는 것을 QA 서버의 `/compat`에서 돈다(2026-10-25,
`exerciseCompat`). 검사: 같은 페이지의 두 번째 다운로드부터 패널 막대가 "여러 파일 다운로드"를 묻고 허용하면 받는다(blob, data 주소,
한 번에 둘), `target=_blank`로 연 파일 주소는 받은 뒤 그 빈 탭이 닫히고 연 탭이 앞에 온다, 알림·위치·클립보드 읽기 요청이 막대에
뜨고 차단하면 페이지의 요청이 거부로 끝난다(`denied`, `PERMISSION_DENIED`, `NotAllowedError`), PDF가 Chromium 보기로 열린다(탭 제목이
파일 이름), 자체 서명 인증서에 패널 카드 대신 Chromium 경고 페이지가 뜨고 고급 → 이동으로 페이지가 열린다. 2026-10-25 저녁에 더한 검사:
`PaymentRequest`가 없고 페이지가 지갑 단추를 숨긴다, 사용자 제스처 없는 팝업이 패널의 "팝업 차단됨" 목록에 하나 남고 거기서 작업의 새 탭으로
열린다, 카메라·마이크 요청이 막대에 뜨고 차단하면 거부로 끝나며 다시 요청하면 묻지 않고 거부된다, 다른 앱의 주소가 Chrome의 규칙대로
간다(메일 링크는 묻지 않고 열림, 새 탭으로 여는 메일 링크는 탭을 남기지 않음, 전화 링크는 "FaceTime을(를) 여시겠습니까?"와 "항상 허용"
상자가 뜨고 취소하면 열리지 않으며 "항상 허용"과 열기 뒤에는 묻지 않고 열림, 여는 앱이 없는 주소는 아무 일 없음, 에이전트가 누른 같은
전화 링크는 다시 사람에게 묻고 에이전트는 그렇다고 들음), 에이전트가 HTTP 인증 창을 로그인 창으로 듣고 닫는다, 사람이 "나가기 전에 확인"을
건 탭을 닫으면 "사이트에서 나가시겠습니까?" 시트가 뜨고 취소하면 탭이 남으며 나가기면 호스트에서 닫힌다(host.log `browser closed tab=…`).
QA는 다른 앱을 열지 않는다: Yardlet이 열 주소를 기록기(`RecordingExternalApps`)가 받고, 앱 이름만 LaunchServices에서 읽는다. 기록만 하는 것:
권한 상태(`navigator.permissions.query`), 전체 화면, 파일 고르기 모드(`multiple`, `webkitdirectory`, 세 File System Access 함수), 다른 사이트
프레임의 쿠키·저장소(`localhost` 프레임의 `SameSite=None` 쿠키, `localStorage`, `hasStorageAccess`), HTTP 기본 인증(`/basic-auth`, 사용자
qa, 비밀번호 secret: 호스트 창의 글). 결과는 `result.json`의 `compat`, 막대와 PDF·경고 페이지·팝업 표시·"사이트에서 나가시겠습니까?"는
`compat-*.png`. 카메라 차단처럼 프로필에 남는 답이 다음 실행에 섞이지 않도록, 실행마다 출력 폴더의 부모를 달리해 QA 홈을 새로 쓴다. QA 서버는 같은 페이지를 자체 서명 인증서의 두 번째 포트(HTTPS)로도 주고(`openssl`이 출력 폴더에 인증서를 만든다), 페이지가
그 주소를 `window.qa.tls`로 알려 준다. QA 번들, QA 홈, 출력은 모두 `$TMPDIR` 아래에 둔다(위 예시). 작업 트리가 `~/Desktop` 아래일 때 그 안의 `.build`에 두면, 새 QA 번들 ID마다 macOS가 데스크탑 폴더 접근을 묻고(2026-10-25 실제로 허용 창이 떴다), 그동안 다른 프로세스가 쓴 파일을 여는 `open()`이 `sandboxd`의 확인에서 풀리지 않아 QA 앱이 마감 시간까지 멈췄다(같은 날 두 번, 앱 표본은 `open`). 그래서 QA 앱은 작업 트리의 파일을 열지 않는다. `$TMPDIR`(`/var/folders/…`)의 번들을 LaunchServices는 `/private/var/folders/…`로 띄우므로 `qa-launch.sh`는 두 모양을 모두 찾는다. 위치, 클립보드 읽기, 카메라, 마이크는 macOS에 닿기 전에
막대에서 차단한다(Chromium은 사이트가 허락되기 전에는 macOS에 묻지 않는다, 3절 "권한 요청"). 인쇄는 시스템 인쇄 창이 떠서 부르지 않는다.

`--ui-fixture-browser-check-only=checkout`은 카드 결제와 카드사 확인(3-D Secure)만 돈다(전체 확인에도 들어 있다, 2026-10-25). QA 서버가 두 번째 포트를
`localhost`(다른 사이트)로 열어 카드사를 흉내 낸다. 카드 폼(`/checkout`, Stripe의 공식 시험 번호 4242…, 이 루프백 페이지에만 넣음)과 배송 주소 폼을 칸마다
입력해 제출하고 호스트가 그대로인지, 숨은 iframe의 기기 정보 POST와 iframe 안 인증(`/checkout/frame`, 확인 단추는 실제 클릭)이 카드사로 갔다
가맹점으로 POST해 돌아와 postMessage로 알리는지, 페이지 전체가 카드사로 POST했다 돌아오는지(`/checkout/redirect`), 클릭으로 연 카드사 창이
`window.opener.postMessage`로 답하고 스스로 닫히는지(`/checkout/popup`), 지갑 단추의 Payment Request(`/checkout/wallet`)에도 호스트가 그대로인지 본다.
호스트를 끝낸 단계는 사람처럼 "다시 시도"로 다시 열고 다음 단계를 잇는다. 단계마다 `checkout.json`에 남는다. 고치기 전 빌드에서는 카드 폼 제출이
호스트를 signal 11로 끝냈다(충돌 보고서의 스택이 설치본과 같음).


`--ui-fixture-browser-check-only=visual-context`는 요소 고르기와 첨부 이미지 표시만 돈다(2026-10-26,
`exerciseVisualContext`, QA 경로 `/pick`). 검사: 고르기 중 마우스를 올린 단추의 가장자리 픽셀이 Chromium 검사 모드의 칠로 바뀐다(패널
프레임, `visual-context-hover.png`), 누르면 그 작업 입력창 초안에 요소가 붙고(선택자가 그 요소 하나만 찾음, HTML·스타일·캡처 크기) 모드가 끝난다,
고르는 동안의 클릭은 페이지에 가지 않고 끝난 뒤의 클릭은 간다, Esc와 단추가 아무것도 붙이지 않고 끝낸다, 입력한 값·hidden·비밀번호·금고가 채운
값(QA가 `noteVaultValues`로 알림)이 맥락 글에 없고 "[saved value]"로 바뀌며 캡처의 입력 칸에는 글자가 없다(페이지 프레임에는 있음), 표시 편집기는
여는 함수(`ImageMarkupPresenter.open`)를 바꿔 끼워 화면에 아무것도 띄우지 않고 그려(`visual-context-markup-editor.png`) 표시한 사본이 캡처 자리에
들어가며 원본은 남고 다음 메시지가 캡처마다 번호를 단다. 입력창 칩은 창 그림 `visual-context-composer.png`, 보낼 글은
`visual-context-draft-message.txt`에 남는다.

`--ui-fixture-browser-check-only=isolation`은 작업마다 프로필만 돈다(`BrowserHostIsolationQA`, [BROWSER_SESSION_ISOLATION](BROWSER_SESSION_ISOLATION.md) 6절).

`--ui-fixture-browser-check-only=vault`는 금고만 돈다(`BrowserHostVaultQA`): 시험용 항목을 앱의 금고(QA에서는 메모리)에 넣고 Yardlet MCP 브로커를 거쳐 `/vault/*` 페이지에 채우기·코드·가림·거절·끄기, CDP 가상 인증기, Yardlet 패스키 등록과 사용, 그리고 그 작업의 패널에서 사람의 저장 막대·열쇠 단추·오른쪽 클릭 항목·머리글 표시를 확인하고 패널 화면을 PNG로 남긴다. WebAuthn이 도메인을 요구하므로 금고 페이지는 `localhost`로 연다.

`run-check.sh`의 패스키 단계("passkey requests observed", `--ui-fixture-browser-check-only=passkey`면 이것만)는 `localhost`(보안 컨텍스트이고
유효한 RP ID, 패스키 없음)의 `/passkey` 페이지에서 `getClientCapabilities()`를 읽고, 사이트가 보내는 요청을 하나씩 부른다: 로그인 칸의 조건부
요청(부른 뒤 칸을 누른다), "패스키로 로그인"(빈 `allowCredentials`), 이 기기만 원하는 로그인, 만들기(attachment 없음), 이 기기에 만들기. DEBUG 호스트가
자기 창(제목·키 창 여부·층)을 `<출력>/host-windows/windows.jsonl`에, 창의 글을 자기 접근성으로 `window-text-N.txt`에 남긴다(Views는 합성기로 그려
PNG는 비어 나온다. 접근성 읽기는 Chromium 전체의 접근성을 켤 수 있어 창마다 세 번까지만). 요청은 끝에 AbortController로 거둔다. 조건부 요청이
창을 띄우면 실패다("a passkey autofill request with no passkey opens no window"). 휴대폰 QR로 먼저 가는 두 요청은 Chromium이 macOS에 블루투스를
묻게 하고, macOS는 앱 identifier마다 처음 한 번 사람에게 자기 창으로 묻는다. 그래서 그 둘은 QA 앱의 답이 정해졌을 때만 부른다
(`CBManager.authorization`은 묻지 않고 읽는다. 2026-10-25 `com.zzunkie.yardlet.browserqa`는 정해지지 않아 건너뜀). 전에는 전체 확인의 첫
만들기 요청이 QR로 가며 그 창을 띄웠을 수 있다(그 창이 떠 있는 동안 대화상자는 뜨지 않아 결과에 창 0개로 남았다, 확인 못 함).

접근성 단계는 권한 없이 앱이 자기 패널의 접근성 트리를 직접 읽는다. `/a11y` 페이지(랜드마크, 제목, 폼 컨트롤, 목록, 표,
이미지, iframe, 위치 지정 버튼, 아래쪽 버튼)와 `/large` 페이지(노드 약 18,000개)를 쓴다. 트리는 `accessibility-dump.json`로
남긴다. DEBUG 호스트는 받은 CEF 접근성 값을 그대로 `<출력>/accessibility-raw/`에 저장한다. 단위 검사의 녹화 fixture
(`Tests/NativeHarnessClientTests/Fixtures/cef-accessibility-qa-page.json`)가 여기서 나왔다.
