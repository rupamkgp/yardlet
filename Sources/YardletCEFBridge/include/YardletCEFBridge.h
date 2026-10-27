#ifndef YARDLET_CEF_BRIDGE_H
#define YARDLET_CEF_BRIDGE_H

// CEF C API bridge used only by the Yardlet browser host process. Browsers are windowless
// (off-screen rendering): CEF paints into buffers or IOSurfaces that the host hands to Yardlet,
// and Yardlet forwards input back. Every callback arrives on the CEF UI thread, which is the host
// process's main thread.

#include <stddef.h>
#include <stdint.h>

#if defined(__OBJC__)
#import "YardletBrowserHostApplication.h"
#endif

#ifdef __cplusplus
extern "C" {
#endif

/// Around forwarding a key, mouse or wheel event: CEF reads the event's time from AppKit's current event,
/// which these make an event of now (YardletBrowserHostApplication.m).
void yardlet_host_input_began(void);
void yardlet_host_input_ended(void);

typedef enum {
    YardletCEFEventContextInitialized = 1,
    YardletCEFEventAfterCreated = 2,
    YardletCEFEventBeforeClose = 3,
    YardletCEFEventAddress = 4,
    YardletCEFEventTitle = 5,
    /// number: bit 0 loading, bit 1 can go back, bit 2 can go forward.
    YardletCEFEventLoadingState = 6,
    /// text: URL, number: HTTP status.
    YardletCEFEventLoadEnd = 7,
    /// text: failed URL, detail: error text, number: CEF error code.
    YardletCEFEventLoadError = 8,
    /// text: message, detail: source, number: line (level in the high 16 bits).
    YardletCEFEventConsole = 9,
    /// A new-window request the host made no browser for (no user gesture, or no browser slot free).
    /// text: its URL, number: 1 background, 2 user gesture.
    YardletCEFEventPopupBlocked = 10,
    /// number: 1 shown, 0 hidden.
    YardletCEFEventPopupShow = 11,
    /// number: cef_cursor_type_t.
    YardletCEFEventCursor = 12,
    /// text: tooltip, or NULL to hide it.
    YardletCEFEventTooltip = 13,
    /// text: the refused URL.
    YardletCEFEventNavigationBlocked = 14,
    /// text: why the renderer ended.
    YardletCEFEventPageCrashed = 15,
    /// A page went away while a JavaScript dialog was open.
    YardletCEFEventDialogReset = 16,
    /// number: drag operation mask the page accepts.
    YardletCEFEventDragOperation = 17,
    /// number: 0 Chromium's hang monitor found the renderer unresponsive (no input handled for 15 s),
    /// 1 it answers again.
    YardletCEFEventResponsiveness = 18,
    /// Process-wide (tab -1): a cookie copy finished. number: its request ID, detail: how many cookies.
    YardletCEFEventCookiesCopied = 19,
    /// The profile a tab waited for has loaded. number: 1 its browser was made, 0 Chromium could not make it
    /// (the tab is gone).
    YardletCEFEventProfileReady = 20,
    /// number: 1 the page's focused field is a password field (an <input type=password> in any frame), 0 it
    /// is not. Sent when that changes.
    YardletCEFEventPasswordField = 21,
    /// The host made a browser for a page's new window, which keeps window.opener; tab is the new tab.
    /// text: its URL, detail: the opener's tab, number: 1 the page asked for it behind.
    YardletCEFEventPopupOpened = 22,
    /// A page asked to open another app's address (mailto:, tel:, zoommtg:, slack: …), which the host does not
    /// load. text: the address, detail: the address of the document that asked, number: 1 with a user gesture.
    YardletCEFEventExternalProtocol = 23,
    /// The main frame committed a new document (never for a same-document move). text: its address.
    YardletCEFEventDocumentStart = 24
} YardletCEFEvent;

typedef struct {
    int commandID;
    /// 0 command, 1 separator, 2 check, 3 radio, 4 submenu (not expanded).
    int kind;
    int isEnabled;
    int isChecked;
    const char *title;
} YardletCEFMenuItem;

typedef struct {
    int x, y, width, height;
} YardletCEFRect;

typedef struct {
    /// Tab-scoped events; tab is -1 for process-wide events.
    void (*event)(int tab, int event, const char *text, const char *detail, int number);
    void (*devTools)(int tab, const char *message, size_t length);
    /// CPU paint: BGRA, upper-left origin, width*height*4 bytes. layer 0 view, 1 popup.
    void (*paint)(int tab, int layer, const void *buffer, int width, int height);
    /// GPU paint: an IOSurfaceRef valid only during the call. format is cef_color_type_t.
    void (*acceleratedPaint)(int tab, int layer, void *ioSurface, int format);
    void (*popupRect)(int tab, YardletCEFRect rect);
    void (*contextMenu)(int tab, int menuID, int x, int y, const YardletCEFMenuItem *items, int count);
    void (*compositionBounds)(int tab, const YardletCEFRect *rects, int count);
    /// kind: 0 alert, 1 confirm, 2 prompt, 3 beforeunload. Answer with yardlet_cef_jsdialog_result.
    void (*javaScriptDialog)(int tab, int dialogID, int kind, const char *message,
                             const char *defaultPrompt, const char *origin, int isReload);
    /// mode: cef_file_dialog_mode_t. Answer with yardlet_cef_file_dialog_result.
    void (*fileDialog)(int tab, int dialogID, int mode, const char *title, const char *defaultPath,
                       const char *const *extensions, int extensionCount);
    /// Returns a malloc'd absolute path for a new download; the bridge frees it.
    char *(*downloadPath)(int tab, int downloadID, const char *suggestedName);
    /// state: 0 started, 1 in progress, 2 completed, 3 cancelled, 4 interrupted.
    void (*download)(int tab, int downloadID, int state, const char *path, int64_t received,
                     int64_t total);
    void (*findResult)(int tab, int matches, int activeMatch, int isFinal);
    /// CEF's accessibility value written as JSON (UTF-8, not terminated). kind: 0 tree change,
    /// 1 location change. Arrives only while the tab's accessibility is enabled.
    void (*accessibility)(int tab, int kind, const char *json, size_t length);
    /// The main frame's scroll offset changed (in view points).
    void (*scrollOffset)(int tab, double x, double y);
    /// The page's icon finished downloading: PNG bytes valid only during the call, or none (length 0)
    /// when it did not load.
    void (*favicon)(int tab, const char *url, const void *png, size_t length);
    /// A page asks for `permissions` (cef_permission_request_types_t bits) for `origin`, as Chrome's
    /// permission bubble asks; a camera or microphone request comes the same way under the host's own prompt
    /// IDs. Answer with yardlet_cef_permission_result.
    void (*permissionPrompt)(int tab, uint64_t promptID, const char *origin, uint32_t permissions);
    /// The prompt went away: after Yardlet's answer, or without one (the page moved on, the tab closed).
    void (*permissionPromptDismissed)(int tab, uint64_t promptID);
} YardletCEFCallbacks;

typedef struct {
    const char *frameworkDirectory;
    const char *mainBundlePath;
    const char *helperExecutablePath;
    /// Root for every profile, cache and crash directory. Must be absolute and writable.
    const char *rootCachePath;
    /// The persistent profile, inside rootCachePath.
    const char *profilePath;
    /// Chromium UI locale (a Resources/<locale>.lproj present in the framework), e.g. "en-US" or "ko".
    const char *locale;
    /// Accept-Language header list, e.g. "ko-KR,ko,en-US,en".
    const char *acceptLanguages;
    const char *logFile;
    int noSandbox;
    /// Optional space-separated Chromium switches (`name` or `name=value`). May be NULL.
    const char *extraSwitches;
} YardletCEFConfiguration;

/// Loads the framework with dlopen and resolves the C API. Returns 1 on success.
int yardlet_cef_load(const char *frameworkBinaryPath, char *error, size_t errorCapacity);

/// cef_initialize for windowless rendering with CEF's own message loop.
int yardlet_cef_initialize(const YardletCEFConfiguration *configuration,
                           const YardletCEFCallbacks *callbacks);

/// Runs CEF's message loop (NSApp run) until yardlet_cef_quit_message_loop.
void yardlet_cef_run_message_loop(void);
void yardlet_cef_quit_message_loop(void);
void yardlet_cef_shutdown(void);

/// Creates a windowless browser for `tab`. sharedTexture asks CEF for IOSurface paints
/// (on_accelerated_paint) instead of CPU buffers. Returns 1 on success, 0 on failure, and 2 when the
/// profile is still loading: the browser is made at `url` once it has (YardletCEFEventProfileReady), and
/// closing the tab before that only lets it go.
/// profilePath: the request context's cache folder (a direct child of the root cache: Chromium makes a
/// profile in memory for any other folder), or empty for the global context. Browsers with the same path
/// share one context: cookies, storage and cache.
int yardlet_cef_create_browser(int tab, const char *url, double width, double height, double scale,
                               double screenX, double screenY, int frameRate, int sharedTexture,
                               const char *profilePath);
/// frameRate: the display's refresh rate (1...240); 0 keeps the current one.
void yardlet_cef_set_viewport(int tab, double width, double height, double scale, double screenX,
                              double screenY, int frameRate);
void yardlet_cef_close_browser(int tab);
/// Closes `tab` as a person closing it would: a page with a beforeunload handler is asked first (its
/// leave-page question comes as a JavaScript dialog), and Stay keeps it open. yardlet_cef_close_browser
/// closes it at once, answering such a question Leave.
void yardlet_cef_request_close(int tab);
/// 1 when the person told Chrome to always let `origin` open `scheme` addresses in their app, in `tab`'s profile
/// (protocol_handler.allowed_origin_protocol_pairs).
int yardlet_cef_external_scheme_allowed(int tab, const char *origin, const char *scheme);
/// Keeps that answer in `tab`'s profile. Returns 1 when it was kept.
int yardlet_cef_allow_external_scheme(int tab, const char *origin, const char *scheme);
/// Answers Chromium's hang monitor for `tab`: terminate 1 ends the unresponsive renderer (the page
/// then reports a crash), 0 waits another 15 seconds. Returns 0 when the renderer is not unresponsive.
int yardlet_cef_unresponsive_action(int tab, int terminate);
/// 1 while `tab`'s renderer has not handled input for 15 seconds. Chromium keeps this state also for a
/// tab with a DevTools session, for which it does not call OnRenderProcessUnresponsive (a debugger may
/// be paused there), so the host reads it.
int yardlet_cef_is_unresponsive(int tab);
int yardlet_cef_open_browser_count(void);
/// Copies the cookies of one request context into another (an empty path is the global context),
/// only those of `domain` and its subdomains when it is not empty, then flushes the target's store and
/// emits YardletCEFEventCookiesCopied with `request`. A host-only cookie stays host-only; a partitioned
/// cookie is left out, since CEF cannot set one. Returns 0 when the copy could not start.
int yardlet_cef_copy_cookies(int request, const char *fromPath, const char *toPath, const char *domain);

void yardlet_cef_load_url(int tab, const char *url);
/// 0 back, 1 forward, 2 reload, 3 stop.
void yardlet_cef_navigation(int tab, int action);
/// 0 undo, 1 redo, 2 cut, 3 copy, 4 paste, 5 delete, 6 select all (on the focused frame).
void yardlet_cef_edit(int tab, int action);
void yardlet_cef_set_focus(int tab, int focused);
void yardlet_cef_set_hidden(int tab, int hidden);

/// kind: 0 move, 1 down, 2 up, 3 leave. button: 0 left, 1 middle, 2 right. modifiers:
/// cef_event_flags_t.
void yardlet_cef_send_mouse(int tab, int kind, int x, int y, int button, int clickCount,
                            uint32_t modifiers);
void yardlet_cef_send_wheel(int tab, int x, int y, int deltaX, int deltaY, uint32_t modifiers);
/// kind: cef_key_event_type_t.
void yardlet_cef_send_key(int tab, int kind, uint32_t modifiers, int windowsKeyCode,
                          int nativeKeyCode, int isSystemKey, uint16_t character,
                          uint16_t unmodifiedCharacter);

/// underlines: count triples of (from, to, thick). A negative replacementFrom means none.
void yardlet_cef_ime_set_composition(int tab, const char *text, const int *underlines,
                                     int underlineCount, int selectionFrom, int selectionTo,
                                     int replacementFrom, int replacementTo);
void yardlet_cef_ime_commit_text(int tab, const char *text, int replacementFrom,
                                 int replacementTo, int relativeCursor);
void yardlet_cef_ime_finish_composing_text(int tab, int keepSelection);
void yardlet_cef_ime_cancel_composition(int tab);

/// Answers a context menu. commandID < 0 cancels it.
void yardlet_cef_context_menu_result(int menuID, int commandID);

void yardlet_cef_jsdialog_result(int dialogID, int accepted, const char *text);
/// count < 0 cancels the dialog.
void yardlet_cef_file_dialog_result(int dialogID, const char *const *paths, int count);
void yardlet_cef_cancel_download(int downloadID);
/// result: 0 allow, 1 block, 2 dismiss (cef_permission_request_result_t). Chromium keeps an allow or a
/// block for the site; for the camera and microphone the host keeps it in the same site settings.
void yardlet_cef_permission_result(uint64_t promptID, int result);

/// action: 0 zoom in, 1 zoom out, 2 reset.
void yardlet_cef_zoom(int tab, int action);
void yardlet_cef_find(int tab, const char *text, int forward, int matchCase, int findNext);
void yardlet_cef_stop_finding(int tab, int clearSelection);
/// phase: 0 enter, 1 over, 2 leave, 3 drop. files only for enter.
void yardlet_cef_drag(int tab, int phase, int x, int y, const char *const *files, int fileCount,
                      uint32_t operations, uint32_t modifiers);

int yardlet_cef_send_devtools_message(int tab, const char *message, size_t length);

/// Turns the renderer's accessibility tree on or off for `tab`. While on, CEF computes the whole
/// tree (windowless browsers use Chromium's WebContentsOnly mode) and reports it through the
/// accessibility callback; while off the renderer does no accessibility work.
void yardlet_cef_set_accessibility(int tab, int enabled);

#ifdef __cplusplus
}
#endif

#endif
