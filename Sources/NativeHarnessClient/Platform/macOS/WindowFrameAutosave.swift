import AppKit
import SwiftUI

/// A window frame in screen coordinates, kept between launches.
struct SavedWindowFrame: Codable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    /// Filled its screen with the zoom button, so it fills the screen it reopens on.
    var isZoomed: Bool

    init(_ frame: NSRect, isZoomed: Bool = false) {
        x = frame.minX
        y = frame.minY
        width = frame.width
        height = frame.height
        self.isZoomed = isZoomed
    }

    var frame: NSRect { NSRect(x: x, y: y, width: width, height: height) }
}

/// The main window's frame in the user's defaults. SwiftUI keys its own saved frame by the type of
/// the window's root view, which changes whenever a build adds a modifier there; that is why an
/// updated Yardlet opened at the default size in the middle of the screen.
struct WindowFrameStore {
    static let mainWindowKey = "Yardlet.mainWindowFrame"
    let defaults: UserDefaults
    var key = WindowFrameStore.mainWindowKey

    func load() -> SavedWindowFrame? {
        guard let data = defaults.data(forKey: key),
              let saved = try? JSONDecoder().decode(SavedWindowFrame.self, from: data),
              [saved.x, saved.y, saved.width, saved.height].allSatisfy(\.isFinite),
              saved.width > 0, saved.height > 0 else { return nil }
        return saved
    }

    func save(_ frame: SavedWindowFrame) {
        guard let data = try? JSONEncoder().encode(frame) else { return }
        defaults.set(data, forKey: key)
    }
}

enum WindowFramePlacement {
    /// Puts a saved frame back on the screens attached now (their visible frames, the main screen
    /// first). A frame that still lies on those screens comes back unchanged. Otherwise it moves onto
    /// the screen showing most of it, or onto the main screen when its own screen is gone, shrinking
    /// to fit there. A zoomed window that had to move fills its new screen.
    static func restoredFrame(_ saved: SavedWindowFrame, screens: [NSRect], minimumSize: NSSize) -> NSRect {
        var frame = saved.frame
        frame.size.width = max(frame.width, minimumSize.width)
        frame.size.height = max(frame.height, minimumSize.height)
        guard !screens.isEmpty else { return frame }
        let area = frame.width * frame.height
        let covered = screens.reduce(0) { total, screen in
            let overlap = screen.intersection(frame)
            return overlap.isNull ? total : total + overlap.width * overlap.height
        }
        if covered >= area - 1 { return frame }

        let overlaps = screens.map { screen -> CGFloat in
            let overlap = screen.intersection(frame)
            return overlap.isNull ? 0 : overlap.width * overlap.height
        }
        let best = overlaps.indices.max { overlaps[$0] < overlaps[$1] } ?? 0
        let onItsScreen = overlaps[best] > 0
        let screen = onItsScreen ? screens[best] : screens[0]
        if saved.isZoomed { return screen }
        frame.size.width = min(frame.width, screen.width)
        frame.size.height = min(frame.height, screen.height)
        if onItsScreen {
            frame.origin.x = min(max(frame.minX, screen.minX), screen.maxX - frame.width)
            frame.origin.y = min(max(frame.minY, screen.minY), screen.maxY - frame.height)
        } else {
            frame.origin.x = (screen.midX - frame.width / 2).rounded()
            frame.origin.y = (screen.midY - frame.height / 2).rounded()
        }
        return frame
    }
}

/// Restores one window's saved frame when it opens and saves the frame whenever it moves or
/// resizes. Only one window keeps a given frame at a time; another window (File › New Window)
/// opens where AppKit places it. Full screen is not restored, as in the Codex app; the frame
/// from before full screen is the one kept.
@MainActor
final class WindowFrameKeeper {
    private static var owners: [String: ObjectIdentifier] = [:]
    private let store: WindowFrameStore
    private let screens: () -> [NSRect]
    private weak var window: NSWindow?
    private var observers: [NSObjectProtocol] = []
    /// From entering full screen until it has been left, the frames are AppKit's, not the person's.
    private var isInFullScreen = false

    /// Returns nil when another window already keeps this frame.
    static func attach(
        to window: NSWindow,
        store: WindowFrameStore,
        screens: @escaping () -> [NSRect] = { NSScreen.screens.map(\.visibleFrame) }
    ) -> WindowFrameKeeper? {
        guard owners[store.key] == nil else { return nil }
        owners[store.key] = ObjectIdentifier(window)
        let keeper = WindowFrameKeeper(window: window, store: store, screens: screens)
        keeper.restore()
        keeper.observe()
        return keeper
    }

    private init(window: NSWindow, store: WindowFrameStore, screens: @escaping () -> [NSRect]) {
        self.window = window
        self.store = store
        self.screens = screens
    }

    private func restore() {
        guard let window, let saved = store.load() else { return }
        let contentMinimum = window.frameRect(forContentRect: NSRect(origin: .zero, size: window.contentMinSize)).size
        let minimum = NSSize(width: max(window.minSize.width, contentMinimum.width),
                             height: max(window.minSize.height, contentMinimum.height))
        let frame = WindowFramePlacement.restoredFrame(saved, screens: screens(), minimumSize: minimum)
        window.setFrame(frame, display: true)
    }

    func save() {
        guard let window, !isInFullScreen, !window.styleMask.contains(.fullScreen), !window.isMiniaturized,
              !window.inLiveResize else { return }
        store.save(SavedWindowFrame(window.frame, isZoomed: window.isVisible && window.isZoomed))
    }

    func detach() {
        save()
        let center = NotificationCenter.default
        observers.forEach(center.removeObserver)
        observers.removeAll()
        if let window, Self.owners[store.key] == ObjectIdentifier(window) { Self.owners[store.key] = nil }
        window = nil
    }

    private func observe() {
        guard let window else { return }
        let center = NotificationCenter.default
        let saveNames: [Notification.Name] = [
            NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification
        ]
        for name in saveNames {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.save() }
            })
        }
        observers.append(center.addObserver(forName: NSWindow.willEnterFullScreenNotification, object: window,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.isInFullScreen = true }
        })
        observers.append(center.addObserver(forName: NSWindow.didExitFullScreenNotification, object: window,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isInFullScreen = false
                self?.save()
            }
        })
        observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) {
            [weak self] _ in MainActor.assumeIsolated { self?.detach() }
        })
        observers.append(center.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) {
            [weak self] _ in MainActor.assumeIsolated { self?.save() }
        })
    }
}

/// Keeps the main window's frame across launches. Placed behind the window's content.
struct MainWindowFrameAutosave: NSViewRepresentable {
    var store = WindowFrameStore(defaults: .yardlet)

    func makeNSView(context: Context) -> WindowFrameAutosaveView { WindowFrameAutosaveView(store: store) }
    func updateNSView(_ nsView: WindowFrameAutosaveView, context: Context) {}
}

final class WindowFrameAutosaveView: NSView {
    private let store: WindowFrameStore
    private var keeper: WindowFrameKeeper?
    private var attempted = false

    init(store: WindowFrameStore) {
        self.store = store
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, !attempted else { return }
        attempted = true
        // SwiftUI finishes placing a new window (its default size, centered) in the same turn it adds
        // the content; the saved frame goes on after that, and nothing is saved before it does.
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            self.keeper = WindowFrameKeeper.attach(to: window, store: self.store)
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil, window != nil {
            keeper?.detach()
            keeper = nil
        }
        super.viewWillMove(toWindow: newWindow)
    }
}
