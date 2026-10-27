import AppKit
import XCTest

/// Reads every frame Core Animation commits for a window that is never shown, and says which of them
/// drew a blank conversation: a scroll view whose layers put nothing but the canvas on screen, or no
/// conversation at all.
///
/// An unshown window has no display cycle of its own, so the probe gives it one: before the run loop
/// waits it lays the hosting view out and displays it, as a shown window does before each frame.
/// Core Animation commits at observer order 2,000,000; the probe reads the committed layers right
/// after (2,100,000), with `CALayer.render(in:)`, so it sees what that frame put on screen.
/// An unsignalled source keeps that display cycle available when the mode has no other input or timers.
@MainActor
final class BlankFrameProbe {
    struct Frame: CustomStringConvertible {
        /// Seconds since `record` began.
        let time: TimeInterval
        /// The share of the conversation's area its layers draw on (`ink(_:)`); 0 when there is no
        /// conversation scroll view.
        let ink: Double
        /// What the probe was told happened last before this frame.
        let action: String
        /// The scroll view's visible rect and its document's height then.
        var visible: CGRect = .zero
        var documentHeight: CGFloat = 0

        var description: String {
            String(format: "%.3fs %.4f y %.0f-%.0f of %.0f %@", time, ink, visible.minY, visible.maxY, documentHeight, action)
        }
    }

    /// A run of blank frames: where it starts, how many frames, and how long until a frame drew again
    /// (or until recording stopped).
    struct BlankRun: CustomStringConvertible {
        let start: Int
        let count: Int
        let duration: TimeInterval
        let action: String
        var description: String {
            String(format: "%d frame(s) from #%d, %.0f ms, after %@", count, start, duration * 1000, action)
        }
    }

    /// Below this share of drawn samples a frame reads as blank. The scenarios' conversations fill
    /// the viewport with text and draw 2–30 % (a request bubble and a two-line answer about 2 %); the
    /// empty state's icon and line, or a loading spinner, draw under 0.6 %: no conversation either.
    static let blankInk = 0.008

    private let hosting: NSView
    private let conversation: () -> NSScrollView?
    private let runLoopMode: CFRunLoopMode
    private var displaySource: CFRunLoopSource?
    private var display: CFRunLoopObserver?
    private var probe: CFRunLoopObserver?
    private var started = Date()
    private(set) var frames: [Frame] = []
    /// What the test did last, recorded with each frame.
    var action = "start"
    var maximumFrames = 3000

    /// - Parameter conversation: finds the conversation's scroll view now; it can be a new one after
    ///   a task switch rebuilt the surface.
    init(hosting: NSView, runLoopMode: CFRunLoopMode = .commonModes, conversation: @escaping () -> NSScrollView?) {
        self.hosting = hosting
        self.conversation = conversation
        self.runLoopMode = runLoopMode
        // Observers do not keep a run-loop mode runnable. Without a source, an idle offscreen
        // window can produce zero samples because run(until:) returns before the display observer.
        var context = CFRunLoopSourceContext()
        context.perform = { _ in }
        let source = CFRunLoopSourceCreate(nil, 0, &context)
        displaySource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, runLoopMode)
        let hosting = hosting
        let display = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 1_900_000) { _, _ in
            hosting.layoutSubtreeIfNeeded()
            hosting.displayIfNeeded()
        }
        self.display = display
        CFRunLoopAddObserver(CFRunLoopGetMain(), display, runLoopMode)
    }

    /// Starts reading frames, from none.
    func record(_ action: String = "start") {
        frames = []
        started = Date()
        self.action = action
        guard probe == nil else { return }
        let probe = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 2_100_000) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.read() }
        }
        self.probe = probe
        CFRunLoopAddObserver(CFRunLoopGetMain(), probe, runLoopMode)
    }

    /// Stops reading frames; the display cycle goes on until `close()`.
    func stop() {
        if let probe { CFRunLoopRemoveObserver(CFRunLoopGetMain(), probe, runLoopMode) }
        probe = nil
    }

    func close() {
        stop()
        if let display { CFRunLoopRemoveObserver(CFRunLoopGetMain(), display, runLoopMode) }
        display = nil
        if let displaySource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), displaySource, runLoopMode)
            CFRunLoopSourceInvalidate(displaySource)
        }
        displaySource = nil
    }

    /// Notes what the test does next and turns the run loop for `seconds`.
    func run(_ action: String, for seconds: TimeInterval = 0, _ change: () -> Void = {}) {
        self.action = action
        change()
        if seconds > 0 { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
    }

    /// Where the first blank frame of each run is written, when set.
    var blankImageDirectory: URL?
    private var wroteBlankImage = false

    private func read() {
        guard frames.count < maximumFrames else { return }
        let scroll = conversation()
        var image: CGImage?
        let ink: Double
        if let scroll, blankImageDirectory != nil {
            ink = withUnsafeMutablePointer(to: &image) { Self.ink(scroll, image: $0) }
        } else {
            ink = scroll.map(Self.ink) ?? 0
        }
        var frame = Frame(time: Date().timeIntervalSince(started), ink: ink, action: action)
        if let scroll {
            frame.visible = scroll.contentView.bounds
            frame.documentHeight = scroll.documentView?.frame.height ?? 0
        }
        let wasBlank = frames.last.map { $0.ink < Self.blankInk } ?? false
        if ink < Self.blankInk, !wasBlank, let image, let directory = blankImageDirectory {
            try? WindowlessRender.writePNG(image, to: directory.appending(path: "blank-\(frames.count).png"))
        }
        frames.append(frame)
    }

    var blankFrames: [Int] { frames.indices.filter { frames[$0].ink < Self.blankInk } }

    var blankRuns: [BlankRun] {
        var runs: [BlankRun] = []
        var index = 0
        while index < frames.count {
            guard frames[index].ink < Self.blankInk else { index += 1; continue }
            let start = index
            while index < frames.count, frames[index].ink < Self.blankInk { index += 1 }
            let end = index < frames.count ? frames[index].time : Date().timeIntervalSince(started)
            runs.append(BlankRun(start: start, count: index - start, duration: end - frames[start].time,
                                 action: frames[start].action))
        }
        return runs
    }

    /// The longest a blank conversation stayed on screen.
    var longestBlank: TimeInterval { blankRuns.map(\.duration).max() ?? 0 }

    /// What one measurement found.
    struct Summary {
        let frames: Int
        let blank: Int
        /// Blank frames after the first one that drew: a conversation that loaded and then went blank.
        let blankAfterDrawn: Int
        let runs: Int
        let longest: TimeInterval
        let text: String
    }

    var result: Summary {
        let afterDrawn = frames.drop { $0.ink < Self.blankInk }.filter { $0.ink < Self.blankInk }.count
        return Summary(frames: frames.count, blank: blankFrames.count, blankAfterDrawn: afterDrawn,
                       runs: blankRuns.count, longest: longestBlank, text: summary)
    }

    var summary: String {
        let runs = blankRuns
        return "\(frames.count) frames, \(blankFrames.count) blank in \(runs.count) run(s)"
            + String(format: ", longest %.0f ms", longestBlank * 1000)
            + (runs.isEmpty ? "" : ": " + runs.prefix(6).map(\.description).joined(separator: "; "))
    }

    // MARK: - Reading a frame

    /// The conversation's scroll view in a window: the leftmost scroll view right of `minX` (the
    /// sidebar's) that is taller than a composer, whose own text views scroll too.
    static func conversationScrollView(in root: NSView, minX: CGFloat = 0) -> NSScrollView? {
        func all(_ view: NSView) -> [NSScrollView] {
            ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(all)
        }
        // The leftmost: the session rail and side panels scroll too, beside it on the right.
        var best: NSScrollView?
        var bestX = CGFloat.infinity
        for scroll in all(root) where !scroll.isHiddenOrHasHiddenAncestor && scroll.window != nil {
            let frame: CGRect = scroll.convert(scroll.bounds, to: root)
            guard frame.minX >= minX - 1, frame.height >= 160, frame.width >= 240 else { continue }
            if frame.minX < bestX - 1 { best = scroll; bestX = frame.minX }
        }
        return best
    }

    /// How far the scroll view is from the end of its document.
    static func distance(_ scroll: NSScrollView) -> CGFloat {
        (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.maxY
    }

    /// The share of the scroll view's area its committed layers draw on: 0 when they draw nothing
    /// but the light canvas (or the window's gray background behind it).
    static func ink(_ scroll: NSScrollView) -> Double {
        ink(scroll, image: nil)
    }

    /// `ink(_:)`, and the rendered layers as an image in `image` when asked for.
    static func ink(_ scroll: NSScrollView, image: UnsafeMutablePointer<CGImage?>?) -> Double {
        guard let layer = scroll.layer else { return 0 }
        let width = Int(scroll.bounds.width), height = Int(scroll.bounds.height)
        guard width > 80, height > 8,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return 0 }
        // Nothing drawn reads as fully transparent.
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        layer.render(in: context)
        guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return 0 }
        image?.pointee = context.makeImage()
        let bytesPerRow = context.bytesPerRow
        var drawn = 0, total = 0
        // The scroll bar's track and the "Latest response" button sit at the right edge.
        for y in stride(from: 4, to: height - 4, by: 3) {
            for x in stride(from: 40, to: width - 60, by: 3) {
                total += 1
                let red = data[y * bytesPerRow + x * 4], alpha = data[y * bytesPerRow + x * 4 + 3]
                // Text, bubbles and rows are darker than the light canvas and the window's gray.
                if alpha > 0, red < 200 { drawn += 1 }
            }
        }
        return Double(drawn) / Double(max(total, 1))
    }
}
