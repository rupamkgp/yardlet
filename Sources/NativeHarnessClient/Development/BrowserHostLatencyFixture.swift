#if DEBUG
import AppKit
import Foundation

/// DEBUG-only latency run of the browser panel (`--ui-fixture=conversation
/// --ui-fixture-browser-latency=<output directory> --ui-fixture-browser-url=<qa page>`). On the real
/// panel and host, with the main thread idle and then as busy as the installed app's while tasks
/// stream (one 17 ms block 28 times a second, the window updates measured on 2026-10-22), it
/// measures paint-to-display latency and the spacing of displayed frames during an animation, and
/// wheel-input-to-display latency on a long page (input waits for the main thread like a real
/// event). It writes `latency.json`; scripts/browser-host-qa/run-latency.sh runs it. Product builds
/// never compile it.
@MainActor
enum BrowserHostLatencyFixture {
    private static var started = false

    static func startIfRequested() {
        guard !started, MacBrowserHost.isAvailable,
              let output = BrowserHostQAFixture.argument("ui-fixture-browser-latency").map({ URL(filePath: $0) }),
              let base = BrowserHostQAFixture.argument("ui-fixture-browser-url") else { return }
        started = true
        Task { @MainActor in await BrowserHostLatencyRunner(output: output, base: base).run() }
    }
}

/// Frames as they were placed on screen, from whichever thread places them.
private final class ShownFrames: @unchecked Sendable {
    struct Entry { var paintedAt: UInt64; var shownAt: UInt64; var onMain: Bool }
    private let lock = NSLock()
    private var entries: [Entry] = []

    func add(_ frame: BrowserFrame, latencyMs: Double) {
        guard frame.layer == .view else { return }
        let entry = Entry(paintedAt: frame.paintedAt, shownAt: frame.paintedAt &+ UInt64(max(0, latencyMs) * 1_000_000),
                          onMain: Thread.isMainThread)
        lock.withLock { entries.append(entry) }
    }

    func take() -> [Entry] { lock.withLock { defer { entries.removeAll() }; return entries } }
    func snapshot() -> [Entry] { lock.withLock { entries } }
}

/// Keeps the main thread busy the way the installed app's window updates did while tasks streamed.
private final class MainThreadLoad: @unchecked Sendable {
    private var timer: DispatchSourceTimer?

    func start(blockMs: Double = 17, perSecond: Double = 28) {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        timer.schedule(deadline: .now(), repeating: 1 / perSecond)
        timer.setEventHandler {
            DispatchQueue.main.async {
                let end = DispatchTime.now().uptimeNanoseconds + UInt64(blockMs * 1_000_000)
                while DispatchTime.now().uptimeNanoseconds < end {}
            }
        }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }
}

@MainActor
private final class BrowserHostLatencyRunner {
    let output: URL
    let base: String
    private var record: [String: JSONValue] = [:]
    private let frames = ShownFrames()
    private var client: BrowserHostClient { MacBrowserHost.shared.client }

    init(output: URL, base: String) {
        self.output = output
        self.base = base
    }

    func run() async {
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try? await Task.sleep(for: .seconds(2))
        guard let controller = await openPanel(), let view = controller.view else { return finish("no panel") }
        record["acceleratedPaint"] = client.acceleratedPaint.map { .bool($0) } ?? .null
        let frames = frames
        controller.frameObserver = { frame, latency in frames.add(frame, latencyMs: latency) }
        for (name, loaded) in [("idle", false), ("busyMain", true)] {
            let load = MainThreadLoad()
            if loaded { load.start() }
            var result: [String: JSONValue] = [:]
            result["animation"] = await measureAnimation(controller)
            result["wheelInput"] = await measureWheelInput(controller, view)
            load.stop()
            record[name] = .object(result)
            try? await Task.sleep(for: .milliseconds(500))
        }
        finish(nil)
    }

    private func openPanel() async -> BrowserHostPaneController? {
        let previous = BrowserHostPaneController.current
        NotificationCenter.default.post(name: BrowserHostQAFixture.openBrowserPanel, object: nil)
        guard await waitUntil(.seconds(10), { BrowserHostPaneController.current !== previous
                && BrowserHostPaneController.current?.view != nil }),
              let controller = BrowserHostPaneController.current else { return nil }
        controller.addressInput = base + "large"
        controller.submitAddress()
        guard await waitUntil(.seconds(30), { controller.hasTab && controller.view?.viewSurface != nil }) else { return nil }
        return controller
    }

    private func navigate(_ controller: BrowserHostPaneController, _ address: String) async {
        controller.addressInput = address
        controller.submitAddress()
        let deadline = ContinuousClock.now + .seconds(15)
        while ContinuousClock.now < deadline {
            if let tab = controller.tab,
               let state = try? await tab.devTools.send("Runtime.evaluate", [
                   "expression": .string("location.href + ' ' + document.readyState"), "returnByValue": .bool(true)
               ])["result"]?["value"]?.stringValue,
               state == "\(address) complete" { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        try? await Task.sleep(for: .seconds(1))
    }

    /// Four seconds of a requestAnimationFrame page: how long each painted frame took to reach the
    /// screen and how evenly the shown frames were spaced.
    private func measureAnimation(_ controller: BrowserHostPaneController) async -> JSONValue {
        await navigate(controller, base + "animation")
        _ = frames.take()
        let started = DispatchTime.now().uptimeNanoseconds
        try? await Task.sleep(for: .seconds(4))
        let shown = frames.take()
        let seconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9
        let latencies = shown.map { Double($0.shownAt &- $0.paintedAt) / 1e6 }
        let ordered = shown.map(\.shownAt).sorted()
        let intervals = zip(ordered.dropFirst(), ordered).map { Double($0 &- $1) / 1e6 }
        return .object([
            "framesPerSecond": .number((Double(shown.count) / seconds * 10).rounded() / 10),
            "shownOnMainThread": .integer(Int64(shown.filter(\.onMain).count)),
            "frames": .integer(Int64(shown.count)),
            "paintToDisplayMs": Self.summary(latencies),
            "displayIntervalMs": Self.summary(intervals),
            "intervalsOver25Ms": .integer(Int64(intervals.filter { $0 > 25 }.count))
        ])
    }

    /// Wheel ticks on a long, otherwise still page. Each tick is queued to the main thread from
    /// another thread, as the window server's events are; the latency runs from queuing to the
    /// first frame painted after it reaching the screen.
    private func measureWheelInput(_ controller: BrowserHostPaneController, _ view: BrowserHostView) async -> JSONValue {
        await navigate(controller, base + "large")
        var latencies: [Double] = []
        var missed = 0
        let point = (x: view.bounds.midX, y: view.bounds.midY)
        for index in 0..<40 {
            guard let tabID = view.tabID else { break }
            let command = BrowserHostCommand.wheel(tab: tabID, input: BrowserWheelInput(
                x: point.x, y: point.y, deltaX: 0, deltaY: index % 8 < 4 ? -60 : 60, modifiers: [.preciseScrolling]
            ))
            _ = frames.take()
            let queuedAt = DispatchTime.now().uptimeNanoseconds
            let target = WeakView(view)
            DispatchQueue.global(qos: .userInteractive).async {
                DispatchQueue.main.async { MainActor.assumeIsolated { target.view?.sendCommand?(command) } }
            }
            try? await Task.sleep(for: .milliseconds(160 + (index * 37) % 60))
            if let first = frames.snapshot().filter({ $0.paintedAt > queuedAt }).min(by: { $0.shownAt < $1.shownAt }) {
                latencies.append(Double(first.shownAt &- queuedAt) / 1e6)
            } else {
                missed += 1
            }
        }
        return .object(["inputToDisplayMs": Self.summary(latencies), "inputsWithoutFrame": .integer(Int64(missed))])
    }

    private static func summary(_ values: [Double]) -> JSONValue {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return .null }
        func at(_ fraction: Double) -> JSONValue {
            .number((sorted[min(sorted.count - 1, Int(Double(sorted.count) * fraction))] * 100).rounded() / 100)
        }
        return .object(["count": .integer(Int64(sorted.count)), "median": at(0.5), "p95": at(0.95), "max": at(1)])
    }

    private func finish(_ error: String?) {
        if let error { record["error"] = .string(error) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(JSONValue.object(record)).write(to: output.appending(path: "latency.json"), options: .atomic)
        client.terminateHost()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { _exit(0) }
    }

    private func waitUntil(_ timeout: Duration, _ condition: @escaping @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }
}

private final class WeakView: @unchecked Sendable {
    weak var view: BrowserHostView?
    init(_ view: BrowserHostView) { self.view = view }
}

#endif
