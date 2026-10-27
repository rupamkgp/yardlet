# Windows browser host design (WebView2)

Written: 2026-09-28. It rests on the product decision (CEF on macOS, WebView2 on Windows) and the [portability
review](PLATFORM_PORTABILITY.md). Windows code cannot be built or run on this Mac, so this document is the design to
follow as it is when the Windows app is built, and it is not implemented or verified yet. API names follow Microsoft's
[WebView2 documentation](https://learn.microsoft.com/microsoft-edge/webview2/) and are to be checked again against the
SDK version at implementation time.

## 1. Principles

- The engine's browser host protocol (`Sources/NativeHarnessClient/BrowserHost/BrowserHostProtocol.swift`), the CDP
  client, the agent browser tools and the Yardlet MCP server use the same code as on macOS. What Windows adds is one
  host implementation that runs the protocol on WebView2, and one CDP transport adapter.
- WebView2 is a Chromium runtime the operating system shares (Evergreen), so the app does not grow, and the runtime
  starts the browser, renderer and GPU processes on its own. So unlike macOS, there is no need to build a host process
  ourselves.
- Windowed hosting (passing the panel's HWND as the parent to `CreateCoreWebView2Controller`) is the default. In this
  mode WebView2 handles input, the Korean IME, the cursor, `<select>` popups, the context menu and accessibility (UI
  Automation) on its own. The input forwarding and accessibility bridge built by hand on macOS are not needed on
  Windows.
- The Windows UI technology (Swift + WinUI 3, or another technology) is not decided yet. This design applies whatever
  the UI technology, as long as the panel can give one HWND.

## 2. Protocol mapping

### Commands

| Protocol command | WebView2 |
|---|---|
| `open(tab, url, viewport)` | In the one environment per app (`CreateCoreWebView2EnvironmentWithOptions`, with a user data folder given), `CreateCoreWebView2Controller(panel HWND)` per tab, then `Navigate(url)` |
| `resize` | `ICoreWebView2Controller::put_Bounds`, and the scale with `put_RasterizationScale` |
| `navigate` | `ICoreWebView2::Navigate` |
| `navigation(back/forward/reload/stop)` | `GoBack`, `GoForward`, `Reload`, `Stop` |
| `focus` | `ICoreWebView2Controller::MoveFocus` |
| `visibility` | `put_IsVisible`. When the tab is hidden for long, `TrySuspend` can pause the renderer |
| `devTools(message)` | `CallDevToolsProtocolMethod(method, paramsJSON)`. Event subscription is `GetDevToolsProtocolEventReceiver(eventName)` |
| `close(tab)` | `ICoreWebView2Controller::Close` |
| `shutdown` | Close every controller and release the environment |
| `mouse`, `wheel`, `key`, `composition`, `edit`, `contextMenuResult` | Not used in windowed hosting (WebView2 receives the input directly). If composition (Visual) hosting is chosen, only `mouse` and `wheel` carry over, to `ICoreWebView2CompositionController::SendMouseInput` |

### Events

| Protocol event | WebView2 |
|---|---|
| `ready` | The environment is created. `engine` gets the runtime's `BrowserVersionString`, and `acceleratedPaint` has no meaning, so it is `false` |
| `opened` | The controller is created |
| `address` | `get_Source` after `SourceChanged` |
| `title` | `DocumentTitleChanged` |
| `loading` | `NavigationStarting` and `NavigationCompleted`, and `CanGoBack` and `CanGoForward` on `HistoryChanged` |
| `loadEnd`, `loadError` | `IsSuccess`, `WebErrorStatus` and `HttpStatusCode` of `NavigationCompleted` |
| `console` | CDP `Runtime.consoleAPICalled` received through the DevTools event receiver (the same path as on macOS) |
| `popupBlocked` or a new window | Handle `NewWindowRequested` and open it in the same tab (the same policy as on macOS) |
| `terminated`, `failed` | `ProcessFailed`, and the environment's `BrowserProcessExited` |
| `frame`, `popup`, `cursor`, `contextMenu`, `compositionBounds` | Do not occur in windowed hosting |

JS dialogs, file choosing and downloads, which the macOS productization adds, map to `ScriptDialogOpening` (with the
default dialog turned off, shown as a Yardlet sheet), the WebView2 default file chooser, and `DownloadStarting`
respectively.

## 3. Lifetime and memory

- The host lifetime rules are the same as on macOS. While the panel is open, or when the agent used that task's browser
  in the last 5 minutes, the tab stays; when neither holds, that tab's controller closes after a 60-second grace period.
  When the last controller is closed and the environment is released, the runtime ends the browser process, and
  `BrowserProcessExited` confirms that the memory was returned.
- The profile is `%LOCALAPPDATA%\Yardlet\Browser\Default`, which every task shares. WebView2 handles cookie encryption
  with DPAPI, so no compromise like the mock keychain on macOS is needed.

## 4. Agent tools and the MCP server

- The engine's CDP client changes only its transport. macOS sends CDP messages over the host IPC, and Windows sends them
  with `CallDevToolsProtocolMethod` and the event receiver. The handling of tools (`browser_snapshot` and the others)
  and references (`@e3`) stays the same.
- The Yardlet MCP server is an executable that uses only Foundation, so it is rebuilt for Windows. The Unix domain
  socket of the IPC can be used as AF_UNIX from Windows 10 on, and folder ACLs limit access to the user.
- The harness injection paths (Claude `--mcp-config`, Codex `thread/start` settings, ACP `session/new`) do not depend on
  the platform.

## 5. Distribution

- Windows 11 and current Windows 10 have the Evergreen WebView2 runtime by default. At app start Yardlet checks with
  `GetAvailableCoreWebView2BrowserVersionString`, and when it is missing, shows Microsoft's official install
  instructions. Bundling a fixed-version runtime in the app is not used, because of its size.

## 6. Open decisions and prerequisites

- Choosing the Windows UI technology (the panel must be able to give an HWND).
- Clearing the blockers in the [portability review](PLATFORM_PORTABILITY.md): ending process trees (job object), finding
  executables (PATHEXT and `.cmd`), and the account sign-in terminal (ConPTY).
- Checking the behavior of the mapping tables above on a real Windows device.
