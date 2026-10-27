# 엔진 이식성 점검 — 2026-09-27

상태: 점검표 작성, 기계적으로 옮길 수 있는 macOS 코드 세 가지를 `Platform/macOS/`로 이동, 새 위반을 막는
검사 추가. macOS 동작은 바꾸지 않았다.
기준: 2026-09-27의 코드와 제품 결정(macOS·Windows 지원, 엔진은 플랫폼 공통
Swift, 화면은 플랫폼별). Windows에서 실제로 빌드하지는 않았다. 의존성과 Foundation 동작은 공식 소스로 확인한
것만 "확인"으로 적고, 나머지는 "확인 못 함"으로 둔다.

## 범위

- **엔진:** `Account`, `Adapters`, `Diff`, `Domain`, `Files`, `Presentation`, `Runtime`, `Store`,
  `Transcript`, 루트의 `AppModel.swift`, `Localization.swift`, `ProductIdentity.swift` — 127개 파일.
  새 폴더는 기본적으로 엔진으로 본다.
- **화면·플랫폼 층(검사 제외):** `Views/`(40), `Browser/`(1, WebKit 미리보기 — 제품 결정에 따라 CEF·WebView2로
  바뀐다), `Development/`(6, 시각 fixture), `Platform/macOS/`(3, 이번에 새로 만듦), `NativeHarnessClientApp.swift`.

## 요약

| 분류 | 점검 시 파일 수 | 이동 후 | 파일 |
| --- | --- | --- | --- |
| UI 프레임워크 import(SwiftUI·AppKit·WebKit·SwiftTerm) | 3 | 1 | `AccountLoginController`(이동 전: `HarnessLogoCatalog`, `SystemNotificationCenter`) |
| Darwin·POSIX API(신호, 프로세스 그룹, `proc_*`, `waitpid`, PTY, `copyfile`) | 3 | 3 | `NativeProcessTree`, `AccountLoginController`, `CodexEnvironmentManager` |
| macOS 전용 프레임워크(Security, UserNotifications, NSWorkspace, CryptoKit, NSDataDetector) | 5 | 2 | `AccountLoginController`, `CodexEnvironmentManager`(이동 전: `HarnessAccountBroker`, `SystemNotificationCenter`, `HarnessLogoCatalog`) |
| 경로 가정·실행 파일 탐색 | 15 | 15 | 아래 3절 |
| Foundation `Process`·`FileHandle`·파일 권한의 Windows 의미 차이 | 19 | 19 | 아래 4절 |
| 외부 의존성(swift-markdown, SwiftTerm, SQLite) | 3개 의존성, 엔진 5개 파일 | 같음 | 아래 5절 |

가장 큰 걸림돌 세 가지:

1. **프로세스 수명 관리.** 모든 하네스 transport, Git, 계정 명령이 종료를 `NativeProcessTree`에 맡긴다.
   이 코드는 `proc_listchildpids`로 자손을 모으고 `kill`로 프로세스 그룹까지 신호를 보낸다. Windows
   Foundation의 `Process`는 job object를 만들지 않고 `terminate()`가 루트 프로세스만 `TerminateProcess`로
   끝내므로, node·MCP 서버 같은 손자 프로세스가 남는다. `interrupt()`도 Windows에서는
   `TerminateProcess(handle, SIGINT)`라 부드러운 중단이 아니다(확인:
   [swift-corelibs-foundation `Process.swift`](https://github.com/swiftlang/swift-corelibs-foundation/blob/main/Sources/Foundation/Process.swift)).
2. **실행 파일 탐색과 실행 환경.** `:`로 잇는 `PATH`, Homebrew·`/usr/local`·`.app/Contents` 경로, `HOME`,
   확장자 없는 실행 파일 이름을 전제로 한다. Windows의 `;` 구분, `PATHEXT`·`.exe`, npm의 `.cmd` shim,
   `USERPROFILE`을 다루지 않는다. Foundation `Process`는 `.cmd`·`.bat`을 `cmd.exe`로 보내지 않는다(확인: 같은 소스).
3. **계정 로그인 터미널.** `AccountLoginController`는 SwiftTerm의 `LocalProcessTerminalView`(PTY와 AppKit 뷰)에
   붙은 controller인데 엔진의 `AccountCenterModel`이 직접 소유하고, `HarnessAccountBroker`가 그 정적 함수로 출력을
   해석한다. SwiftTerm은 Windows에서 PTY 계층을 빼고 빌드되고, URL 탐지에 쓰는 `NSDataDetector`는 Apple 밖
   Foundation에 없다.

## 이번에 옮긴 것

동작은 그대로다. 옮긴 코드의 내용은 같고, 엔진 쪽에서는 이름 참조만 바뀌었다. 옮긴 파일은 검사 허용 목록에
들어가지 않는다.

| 이전 | 새 위치(macOS 층) | 엔진에 남은 것 |
| --- | --- | --- |
| `Domain/HarnessLogoCatalog.swift` 전체(NSImage 로딩·캐시, SwiftUI 아이콘 뷰) | `Platform/macOS/HarnessLogoCatalog.swift` | `Domain/HarnessLogoAsset.swift`: 하네스별 자산 이름과 하위 폴더 이름 |
| `Domain/SystemNotificationCenter.swift`의 `LocalSystemNotificationCenter`(UserNotifications), `systemSettingsURL`·`openSystemSettings()`(NSWorkspace) | `Platform/macOS/LocalSystemNotificationCenter.swift` | `SystemNotificationCenter` protocol, `SystemNotificationAuthorization`, `SystemNotificationSettingsModel`(쓰이지 않던 기본 인자 제거) |
| `HarnessAccountBroker.antigravityCredentialState`(Keychain `SecItemCopyMatching`) | `Platform/macOS/AntigravityKeychainProbe.swift`(같은 이름의 extension) | 호출부 `Self.antigravityCredentialState()`. Windows 층이 같은 함수를 제공해야 한다 |

## 점검표와 권장 처리

권장 처리는 세 가지다. **이동:** 플랫폼 층으로 옮긴다. **추상화:** 엔진에 작은 protocol이나 값만 남기고
구현을 플랫폼 층이 준다. **대체:** Windows에서 쓸 수단.

### 1. UI 프레임워크와 macOS 전용 프레임워크

| 파일 | 항목 | 권장 처리 |
| --- | --- | --- |
| `Account/AccountLoginController.swift` | `import AppKit`, `SwiftTerm`, `Darwin`; `NSWorkspace.open`, `NSPasteboard`; `LocalProcessTerminalView`(PTY); `pid_t`; `NSDataDetector`(`firstHTTPSURL`) | 추상화: 엔진에 로그인 세션 protocol(상태·phase·입력 전송)과 순수 텍스트 해석(`stripANSI`, `firstDeviceCode`, `outputRequiresInput`, URL 찾기)을 둔다. URL 찾기는 `NSDataDetector` 대신 정규식. SwiftTerm 호스트는 이동. 대체: Windows는 ConPTY 호스트. **옮기지 않은 이유:** PTY·프로세스 종료와 묶여 있고 `AccountCenterModel`, `HarnessAccountBroker`, 테스트 여러 곳이 타입을 직접 참조해 기계적 이동이 아니다. |
| `Runtime/CodexEnvironmentManager.swift` | `import CryptoKit`(`SHA256` 지문); `import Darwin`과 `copyfile(COPYFILE_ALL | COPYFILE_CLONE)` | 대체: CryptoKit은 API가 같은 swift-crypto의 `Crypto`로(패키지 추가가 필요해 이번에 하지 않음). `copyfile`은 이미 `FileManager.copyItem` 폴백이 있으므로 복제 함수만 플랫폼 층으로 추상화하거나 `#if canImport(Darwin)`로 감싼다. |
| `Account/HarnessAccountBroker.swift` | Antigravity 자격 증명 위치를 Keychain으로 적은 사용자 문구 4곳; `Self.antigravityCredentialState()`가 macOS 층 extension에 있음 | 추상화: 자격 증명 위치 문구와 탐지를 플랫폼이 제공. Antigravity CLI가 Windows에서 어디에 저장하는지는 확인 못 함. |
| `Domain/HarnessKind.swift` | `symbolName`에 SF Symbols 이름(엔진 데이터 안의 macOS 아이콘 이름) | 추상화: 화면 층이 하네스 ID로 아이콘을 고른다. Windows는 로고 자산을 우선 쓴다. 문자열이라 검사 대상은 아니다. |
| `AppModel.swift` | 기본 인자 `LocalSystemNotificationCenter()`가 macOS 구현을 이름으로 참조 | 이동: target 분리 때 앱이 주입한다. 지금은 호출부가 많아 그대로 둔다. |

### 2. Darwin·POSIX 프로세스 API

| 파일 | 항목 | 권장 처리 |
| --- | --- | --- |
| `Runtime/NativeProcessTree.swift` | `proc_listchildpids`로 자손 수집, `kill(pid, SIGHUP/SIGKILL)`, `kill(-pgid, …)`, `waitpid`, `usleep`, `pid_t` | 추상화: 엔진에 `terminate(process:) -> Int32`, `terminate(rootPID:)`를 가진 protocol을 두고 지금 코드는 macOS 구현으로 그대로 옮긴다. 대체: Windows는 시작 직후 job object(`JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`)에 넣고 `TerminateJobObject`로 끝낸다. Foundation `Process`가 시작한 뒤 넣으면 짧은 틈이 생기므로 `CREATE_SUSPENDED`로 직접 만드는 방법을 함께 검토한다. **옮기지 않은 이유:** 모든 transport의 종료 경로라 동작 위험이 있다. |
| `NativeProcessTree` 호출부(엔진 9개): `AccountCommandRunner`, `AccountLoginController`, `ACPProcessTransport`, `ClaudeProcessTransport`, `CodexProcessTransport`, `PiRPCProcessTransport`, `StructuredHeadlessAdapter`, `GitDiffService`, `HarnessProtocolProcessHost` | 종료를 위 함수에 맡김 | 위 protocol로 바꾸면 호출부는 이름만 바뀐다. |
| `Adapters/Headless/StructuredHeadlessAdapter.swift` | `process.interrupt()`(macOS는 SIGINT) | 대체: Windows에서는 즉시 종료가 되므로 하네스 프로토콜의 취소를 먼저 쓰고, 없으면 `CREATE_NEW_PROCESS_GROUP`과 `GenerateConsoleCtrlEvent(CTRL_BREAK_EVENT)`를 검토한다. 각 CLI가 이를 중단으로 처리하는지는 확인 못 함. |
| PTY | 엔진에서는 `AccountLoginController`만(SwiftTerm `LocalProcess` 경유). 화면 층 `Views/TerminalPane`도 PTY | 대체: Windows ConPTY(`CreatePseudoConsole`). |

### 3. 경로 가정과 실행 파일 탐색

| 파일 | 항목 | 권장 처리 |
| --- | --- | --- |
| `Runtime/RuntimeProcessEnvironment.swift` | `PATH`를 `:`로 나누고 잇는다. `/opt/homebrew/bin`, `/usr/local/bin`, `/usr/bin`, `/bin`, `/usr/sbin`, `/sbin`, `~/.local/bin`, `~/.bun/bin` 고정; `HOME` | 추상화: 구분자와 기본 경로 목록을 플랫폼이 준다. Windows는 `;`, `Path` 대소문자 무시 키, `USERPROFILE`, `%APPDATA%\npm` 등. |
| `Runtime/RuntimeSelectionStore.swift` | Homebrew·`/usr/local` 후보, `/Applications/ChatGPT.app/Contents/Resources/codex`, `~/Library/Application Support/Claude/claude-code/<버전>/claude.app/Contents/MacOS/claude`, `PATH`를 `:`로 나눔, `/`로 상대 경로 분해 | 추상화: 하네스별 설치 후보를 플랫폼이 준다. Windows 후보(각 CLI의 설치 위치)는 확인 못 함. |
| `Diff/GitExecutableLocator.swift` | `/opt/homebrew/bin/git`, `/usr/local/bin/git`, `/opt/local/bin/git`, 폴백 `/usr/bin/git` | 추상화: 후보 목록을 플랫폼이 준다. Windows는 `PATH`의 `git.exe`와 Git for Windows 설치 경로. |
| `Diff/GitDiffService.swift` | Git 인자로 `/dev/null`(`hash-object`, `diff --no-index`) | Git for Windows가 이 경로를 받아들이는지 확인 못 함. 빈 트리는 `git hash-object -t tree --stdin`처럼 경로 없는 방식을 검토. `UnifiedDiffParser`의 `/dev/null`은 Git 출력 형식이라 그대로 둔다. |
| `Domain/HarnessKind.swift` | `relativeExecutablePaths`가 확장자 없는 POSIX 경로(`.local/bin/codex`, `.hermes/hermes-agent/venv/bin/hermes` 등) | 추상화: 플랫폼별 후보. Windows venv는 `Scripts\*.exe`. |
| `Account/ProviderConnections.swift`, `Account/ProviderConnectionService.swift`, `Domain/ProviderSessionTitleResolver.swift`, `Domain/WorkspaceGitOrigin.swift` | 절대 경로 판정을 `hasPrefix("/")`로 함 | 대체: `C:\`·UNC 경로를 받는 공통 판정 함수 하나로 모은다. |
| `Domain/CodexWorkSurfaceProjection.swift`, `Files/WorkspaceFileService.swift`, `Domain/Project.swift` | 작업 폴더 포함 여부를 `root + "/"` 문자열 접두어로 판정, `/` 분해 | 대체: 경로 구성 요소 비교로 바꾸고 Windows의 대소문자 무시 파일 시스템을 고려한다. 포함 판정은 보안 경계라 Windows 작업 때 테스트를 함께 둔다. |
| `Runtime/CodexEnvironmentManager.swift` | `~/` 확장 | Windows에서도 쓸 수 있으나 `\` 구분을 함께 받는다. |
| `Account/HarnessAccountBroker.swift` | Grok 홈을 환경 변수 `HOME`에서 찾음(Windows에는 보통 없음) | `homeDirectoryForCurrentUser`로 통일. |
| `Store/SessionRepository.swift`, `Domain/ProviderSessionTitleResolver.swift` | SQLite에 `URL.path(percentEncoded: false)` 문자열을 넘김 | 대체: `withUnsafeFileSystemRepresentation`. Windows에서 `path()`가 `/C:/…`가 되는지는 확인 못 함. |

`ProductIdentity.swift`와 `AppModel.swift`의 `~/.yardlet`, `applicationSupportDirectory`, `UserDefaults`는
Foundation이 Windows에서도 제공한다. 실제 저장 위치(AppData, 레지스트리 등)는 확인 못 함.

### 4. Foundation `Process`·`FileHandle`·파일 권한

대상 19개: `AccountCommandRunner`, `AccountLoginController`, `ProviderConnections`, `ACPAdapter`,
`ACPProcessTransport`, `ClaudeAdapter`, `ClaudeProcessTransport`, `CodexAdapter`, `CodexProcessTransport`,
`StructuredHeadlessAdapter`, `MuseAdapter`, `PiRPCAdapter`, `PiRPCProcessTransport`, `GitDiffService`,
`GitExecutableLocator`, `HarnessProtocolProcessHost`, `HarnessRuntimeCompatibility`, `RuntimeSelectionStore`,
`ComposerDraftRepository`.

| 항목 | Windows 동작 | 권장 처리 |
| --- | --- | --- |
| `Process.run()`(12개 파일) | 인자를 Windows 규칙으로 인용해 `CreateProcessW`에 넘기고 `.cmd`·`.bat`을 따로 처리하지 않음(확인) | 탐색 단계에서 실제 `.exe`를 찾는다. shim만 있으면 `cmd.exe /d /s /c`로 감싸되 인자 이스케이프(BatBadBut 계열)에 주의한다. |
| `isExecutableFile(atPath:)`(8개 파일) | swift-foundation은 `SHGetFileInfoW(SHGFI_EXETYPE)`로 판정 | `.cmd` shim을 실행 파일로 보는지 확인 못 함. 판정을 탐색 추상화에 넣는다. |
| `terminate()` / `interrupt()` | 둘 다 `TerminateProcess`, 루트만 종료(확인) | 2절의 job object. |
| `readabilityHandler` | `DuplicateHandle`·`_open_osfhandle`·Dispatch 읽기 소스로 지원(확인: [`FileHandle.swift`](https://github.com/swiftlang/swift-corelibs-foundation/blob/main/Sources/Foundation/FileHandle.swift)) | 변경 불필요. |
| `process.environment` | Windows 환경 변수 이름은 대소문자를 구분하지 않음 | `PATH`와 `Path`가 함께 생기지 않도록 키를 정규화한다. |
| `.posixPermissions` 0o600·0o700(`ProviderConnections`, `ComposerDraftRepository`) | POSIX 모드가 없어 사용자 전용 접근이 보장되지 않음 | 대체: 사용자 프로필 아래 저장 + ACL. Foundation이 이 속성을 어떻게 적용하는지는 확인 못 함. |

### 5. 외부 의존성

CryptoKit, Observation, `NSDataDetector`는 패키지 의존성이 아니지만 같은 판단이 필요해 함께 적는다.

| 의존성 | 엔진 사용처 | Windows | 근거 | 권장 처리 |
| --- | --- | --- | --- | --- |
| swift-markdown 0.8.0(swift-cmark 0.8.0) | `TranscriptInlineContent`, `TranscriptMarkdownDocument` | 매니페스트에 Windows 조건 설정이 있음. 실제 빌드는 확인 못 함 | swift-markdown `Package.swift`의 `CMARK_GFM_STATIC_DEFINE` `.when(platforms: [.windows])`, swift-cmark `Package.swift`의 `#if os(Windows)` | 그대로 엔진에 둔다. Windows 시험판에서 빌드로 확인. |
| SwiftTerm 1.18.0 | `AccountLoginController` | 터미널 해석기만 빌드됨. PTY·뷰 없음(확인) | 매니페스트의 `os(Windows)` 분기가 `Apple`·`Mac`·`iOS` 소스를 빼고, `LocalProcess.swift`·`Pty.swift`·`HeadlessTerminal.swift`는 `#if !os(iOS) && !os(Windows)` | 엔진에서 뺀다(1절). Windows 터미널은 ConPTY와 Windows 뷰. |
| CSQLite(`systemLibrary`, `pkgConfig: "sqlite3"`, brew provider, `link "sqlite3"`) | `Store/SessionRepository`, `Domain/ProviderSessionTitleResolver` | macOS SDK의 libsqlite3에 기댐. Windows에는 기본 헤더·pkg-config가 없음 | `Package.swift`, `Sources/CSQLite/module.modulemap` | 대체: SQLite amalgamation을 C target으로 넣는 관례적 방식. 방식 결정은 Windows 시험판 때. |
| CryptoKit | `CodexEnvironmentManager` | Apple 전용 | — | swift-crypto `Crypto`(패키지 추가 승인 필요). |
| Observation | `@Observable` 모델 다수 | Swift 툴체인 모듈. Windows 빌드로는 확인 못 함 | — | 그대로. |
| Foundation `NSDataDetector` | `AccountLoginController` | 없음(확인) | [swift-corelibs-foundation #4305](https://github.com/swiftlang/swift-corelibs-foundation/issues/4305), 계획 없음으로 닫힘 | 정규식으로 대체. |

## 새 위반을 막는 검사

`Tests/NativeHarnessClientTests/EnginePortabilityTests.swift`.

- 엔진 파일(위 범위, 새 폴더 포함)에서 금지 import(SwiftUI, AppKit, UIKit, Cocoa, WebKit, SwiftTerm, Darwin,
  Security, UserNotifications, CryptoKit 등)와 macOS 전용 API 규칙(`Darwin.` 한정 이름, 신호·`waitpid`·`pid_t`,
  `proc_*`·`sysctl`, PTY 함수, `posix_spawn`, `copyfile`, Keychain, `UN*` 알림 타입, AppKit 타입, FSEvents·kqueue,
  Apple 밖 Foundation에 없는 API, `x-apple.` URL)을 찾는다. 줄 주석은 건너뛴다.
- 허용 목록은 파일별 규칙 이름의 집합이다. 지금은 3개 파일, 13개 항목이다.
  `AccountLoginController`(6), `CodexEnvironmentManager`(3), `NativeProcessTree`(4).
- 허용 목록에 없는 파일의 위반, 허용된 파일의 새 종류 위반은 실패한다. 허용 항목이 더 이상 맞지 않으면
  목록에서 지우라고 실패한다. 항목 수 상한 13은 줄이기만 한다.
- 경로 가정(3절)과 `Process` 의미(4절)는 문자열·동작 문제라 검사에 넣지 않았다.

## 다음 순서 제안

1. `AccountLoginController`의 텍스트 해석을 엔진 타입으로 분리(동작 불변, 작음).
2. 실행 파일 후보·`PATH` 구성을 플랫폼이 주는 목록으로 추상화하고 macOS 값은 그대로 둔다.
3. `NativeProcessTree`를 protocol 뒤로 옮기고 macOS 구현은 그대로 둔다. Windows job object 구현은 Windows
   시험판에서 한다.
4. swift-crypto 도입과 SQLite 포함 방식을 결정한다(패키지 추가는 별도 승인).

## SwiftPM target 분리 때 할 일

지금은 executable target 하나라 모든 선언이 `internal`이고 테스트는 `@testable import`로 접근한다.
엔진 library target과 macOS 앱 target으로 나눌 때 필요한 일이다.

- **공개 범위:** 화면이 쓰는 엔진 타입과 멤버(`AppModel`, 저장소, 프로젝션 등)를 target 밖에 열어야 한다.
  `public` 대신 같은 패키지 안에서만 보이는 `package` 접근 수준을 쓰면 외부 API를 만들지 않고 나눌 수 있다.
  대상이 많으므로 컴파일 오류를 따라 기계적으로 바꾼다.
- **순환 의존 제거:** 엔진이 플랫폼 코드를 부르는 곳을 주입으로 바꾼다. 다른 모듈의 extension은 엔진이 부를
  수 없으므로 macOS 층 extension에 기댄 호출도 여기에 든다.
  - `AppModel`의 기본 인자 `LocalSystemNotificationCenter()` → 앱이 주입.
  - `AccountCenterModel`이 소유한 `AccountLoginController` → 엔진 protocol로 주입.
  - `HarnessAccountBroker` → `AccountLoginController.stripANSI` → 엔진 텍스트 유틸로 이동.
  - `HarnessAccountBroker` → `antigravityCredentialState()`(macOS 층 extension) → 주입되는 자격 증명 탐지 protocol.
  - transport들 → `NativeProcessTree` → protocol 또는 엔진 안의 플랫폼별 구현.
  - 반대 방향(`Platform/macOS` → `HarnessLogoAsset`, `SystemNotificationSettingsModel` extension)은 문제 없다.
- **리소스:** `Localizable.strings`는 엔진과 화면이 모두 `L10n`으로 쓰므로 엔진 target이 소유하고,
  `L10n`의 `Bundle.main` 우선 규칙이 앱 번들에서 그대로 동작하는지 확인한다. `HarnessLogos` PNG는 macOS target.
- **의존성 배치:** `CSQLite`, `Markdown`은 엔진. `SwiftTerm`은 `AccountLoginController` 분리 뒤 macOS target만.
  `Development/`의 fixture(SwiftUI)는 macOS target 또는 별도 fixture target.
- **테스트 target:** 114개 테스트 파일 중 12개가 AppKit·SwiftUI·SwiftTerm·WebKit·Darwin·Security를 import한다.
  엔진 테스트(`@testable import` 엔진, Windows에서도 실행)와 macOS 테스트로 나눈다. 분리 뒤에는 Windows에서
  엔진 target을 빌드하는 것이 가장 강한 검사가 되므로 `EnginePortabilityTests`는 그때 줄이거나 없앤다.
