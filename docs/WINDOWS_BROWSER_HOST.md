# Windows 브라우저 호스트 설계 (WebView2)

작성: 2026-09-28. 근거는 제품 결정(macOS는 CEF, Windows는 WebView2)과
[이식성 점검](PLATFORM_PORTABILITY.md)이다. 이 Mac에서는 Windows 코드를 빌드하거나 실행할 수 없으므로,
이 문서는 Windows 앱을 만들 때 그대로 따를 설계이며 아직 구현·검증되지 않았다. API 이름은 Microsoft의
[WebView2 문서](https://learn.microsoft.com/microsoft-edge/webview2/) 기준이며 구현 때 SDK 버전에 맞춰 다시 확인한다.

## 1. 원칙

- 엔진의 브라우저 호스트 규약(`Sources/NativeHarnessClient/BrowserHost/BrowserHostProtocol.swift`), CDP 클라이언트,
  에이전트 브라우저 도구, Yardlet MCP 서버는 macOS와 같은 코드를 쓴다. Windows에서 새로 만드는 것은 규약을
  WebView2로 실행하는 호스트 구현 하나와 CDP 전송 어댑터 하나다.
- WebView2는 운영체제가 공유하는 Chromium 런타임(Evergreen)이라 앱 크기가 늘지 않고, 브라우저·렌더러·GPU
  프로세스를 런타임이 따로 띄운다. 그래서 macOS처럼 호스트 프로세스를 직접 만들 필요가 없다.
- 창 방식(`CreateCoreWebView2Controller`에 패널의 HWND를 부모로 넘김)을 기본으로 한다. 이 방식에서는 입력,
  한글 IME, 커서, `<select>` 팝업, 우클릭 메뉴, 접근성(UI Automation)을 WebView2가 스스로 처리한다. macOS에서
  직접 만든 입력 전달과 접근성 연결이 Windows에서는 필요 없다.
- Windows UI 기술(Swift + WinUI 3, 또는 다른 기술)은 아직 정하지 않았다. 이 설계는 패널이 HWND 하나를 줄 수 있으면
  UI 기술과 관계없이 적용된다.

## 2. 규약 대응

### 명령

| 규약 명령 | WebView2 |
|---|---|
| `open(tab, url, viewport)` | 앱당 하나인 환경(`CreateCoreWebView2EnvironmentWithOptions`, 사용자 데이터 폴더 지정)에서 탭마다 `CreateCoreWebView2Controller(패널 HWND)`, 이어서 `Navigate(url)` |
| `resize` | `ICoreWebView2Controller::put_Bounds`, 배율은 `put_RasterizationScale` |
| `navigate` | `ICoreWebView2::Navigate` |
| `navigation(back/forward/reload/stop)` | `GoBack`, `GoForward`, `Reload`, `Stop` |
| `focus` | `ICoreWebView2Controller::MoveFocus` |
| `visibility` | `put_IsVisible`. 오래 숨길 때는 `TrySuspend`로 렌더러를 멈출 수 있다 |
| `devTools(message)` | `CallDevToolsProtocolMethod(method, paramsJSON)`. 이벤트 구독은 `GetDevToolsProtocolEventReceiver(eventName)` |
| `close(tab)` | `ICoreWebView2Controller::Close` |
| `shutdown` | 모든 컨트롤러를 닫고 환경을 해제 |
| `mouse`, `wheel`, `key`, `composition`, `edit`, `contextMenuResult` | 창 방식에서는 쓰지 않는다(WebView2가 직접 받음). composition(Visual) 방식을 고르면 `mouse`·`wheel`만 `ICoreWebView2CompositionController::SendMouseInput`으로 옮긴다 |

### 이벤트

| 규약 이벤트 | WebView2 |
|---|---|
| `ready` | 환경 생성 완료. `engine`에는 런타임의 `BrowserVersionString`을 넣고 `acceleratedPaint`는 의미가 없어 `false` |
| `opened` | 컨트롤러 생성 완료 |
| `address` | `SourceChanged` 뒤 `get_Source` |
| `title` | `DocumentTitleChanged` |
| `loading` | `NavigationStarting`·`NavigationCompleted`와 `HistoryChanged`에서 `CanGoBack`·`CanGoForward` |
| `loadEnd`, `loadError` | `NavigationCompleted`의 `IsSuccess`, `WebErrorStatus`, `HttpStatusCode` |
| `console` | CDP `Runtime.consoleAPICalled`를 DevTools 이벤트 수신기로 받는다(macOS와 같은 경로) |
| `popupBlocked` 또는 새 창 | `NewWindowRequested`를 처리해 같은 탭에서 연다(macOS와 같은 정책) |
| `terminated`, `failed` | `ProcessFailed`, 환경의 `BrowserProcessExited` |
| `frame`, `popup`, `cursor`, `contextMenu`, `compositionBounds` | 창 방식에서는 생기지 않는다 |

macOS 제품화에서 추가되는 JS 대화상자, 파일 선택, 다운로드는 각각 `ScriptDialogOpening`(기본 대화상자를 끄고 Yardlet
시트로), WebView2 기본 파일 선택 창, `DownloadStarting`으로 대응한다.

## 3. 수명과 메모리

- 호스트 수명 규칙은 macOS와 같다. 패널이 열려 있거나 최근 5분 안에 에이전트가 그 작업의 브라우저를 썼으면 유지하고,
  둘 다 아니면 60초 유예 뒤 그 탭의 컨트롤러를 닫는다. 마지막 컨트롤러를 닫고 환경을 해제하면 런타임이 브라우저
  프로세스를 끝내며, `BrowserProcessExited`로 메모리 반환을 확인한다.
- 프로필은 모든 작업이 공유하는 `%LOCALAPPDATA%\Yardlet\Browser\Default`이다. 쿠키 암호화는 WebView2가 DPAPI로 처리하므로
  macOS의 mock keychain 같은 절충이 필요 없다.

## 4. 에이전트 도구와 MCP 서버

- 엔진의 CDP 클라이언트는 전송 방식만 바꾼다. macOS는 호스트 IPC로 CDP 메시지를 보내고, Windows는
  `CallDevToolsProtocolMethod`와 이벤트 수신기로 보낸다. 도구(`browser_snapshot` 등)와 참조(`@e3`) 처리는 그대로다.
- Yardlet MCP 서버는 Foundation만 쓰는 실행 파일이라 Windows용으로 다시 빌드한다. IPC의 Unix 도메인 소켓은 Windows 10
  이후 AF_UNIX로 쓸 수 있고, 권한은 폴더 ACL로 사용자만 접근하게 한다.
- 하네스 주입 경로(Claude `--mcp-config`, Codex `thread/start` 설정, ACP `session/new`)는 플랫폼과 무관하다.

## 5. 배포

- Windows 11과 최신 Windows 10에는 Evergreen WebView2 런타임이 기본으로 있다. 앱 시작 때
  `GetAvailableCoreWebView2BrowserVersionString`으로 확인하고, 없으면 Microsoft의 공식 설치 안내를 보여 준다. 고정
  버전 런타임을 앱에 넣는 방식은 크기 때문에 쓰지 않는다.

## 6. 남은 결정과 선행 작업

- Windows UI 기술 선택(패널이 HWND를 줄 수 있어야 한다).
- [이식성 점검](PLATFORM_PORTABILITY.md)의 걸림돌 해소: 프로세스 트리 종료(job object), 실행 파일 탐색(PATHEXT·`.cmd`),
  계정 로그인 터미널(ConPTY).
- 실제 Windows 기기에서 위 대응표의 동작 확인.
