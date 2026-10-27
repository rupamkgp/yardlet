#if DEBUG
import AppKit
import Darwin
import Foundation
import IOSurface

/// DEBUG-only performance run of the browser panel (`--ui-fixture=conversation
/// --ui-fixture-browser-perf=<output directory> --ui-fixture-browser-url=<qa page>`). On the real
/// panel and host it measures: panel open times (cold host, warm reopen, a new tab in a running
/// host), frames per second and paint-to-display latency while scrolling and during an animation,
/// frames while the window is miniaturized, the host's memory across panel resizes and after the
/// tab hides, and the CPU of Yardlet and of the host's process tree in each phase. It writes
/// `perf.json` and phase markers for scripts/browser-host-qa/run-perf.sh. Product builds never
/// compile it.
@MainActor
enum BrowserHostPerfFixture {
    private static var started = false

    static func startIfRequested(session: UUID) {
        guard !started, MacBrowserHost.isAvailable,
              let output = BrowserHostQAFixture.argument("ui-fixture-browser-perf").map({ URL(filePath: $0) }),
              let base = BrowserHostQAFixture.argument("ui-fixture-browser-url") else { return }
        started = true
        Task { @MainActor in await BrowserHostPerfRunner(output: output, base: base, session: session).run() }
    }
}

@MainActor
private final class BrowserHostPerfRunner {
    let output: URL
    let base: String
    let session: UUID
    private var record: [String: JSONValue] = [:]
    private var phases: [JSONValue] = []
    private let start = DispatchTime.now().uptimeNanoseconds
    private var client: BrowserHostClient { MacBrowserHost.shared.client }

    init(output: URL, base: String, session: UUID) {
        self.output = output
        self.base = base
        self.session = session
    }

    func run() async {
        try? FileManager.default.createDirectory(at: output.appending(path: "markers"), withIntermediateDirectories: true)
        record["pid"] = .integer(Int64(ProcessInfo.processInfo.processIdentifier))
        try? await Task.sleep(for: .seconds(2))
        await phase("0-idle-no-host", holding: .seconds(4))

        moveWindowToTheFastestDisplay()
        guard let cold = await openPanel(label: "cold", address: base + "large"), let coldView = cold.view else {
            return await finish()
        }
        if let screen = coldView.window?.screen {
            record["screen"] = .object([
                "name": .string(screen.localizedName),
                "maximumFramesPerSecond": .integer(Int64(screen.maximumFramesPerSecond)),
                "scale": .number(screen.backingScaleFactor)
            ])
        }
        record["viewPoints"] = .object(["width": .number(coldView.bounds.width), "height": .number(coldView.bounds.height)])
        record["acceleratedPaint"] = client.acceleratedPaint.map { .bool($0) } ?? .null
        _ = await waitUntilAsync(.seconds(15)) { (try? await self.evaluate(cold, "document.readyState")) == "complete" }

        // Warm reopen: the panel closes and opens again while the host keeps the tab.
        await closePanel()
        try? await Task.sleep(for: .seconds(1))
        guard let controller = await openPanel(label: "warm", address: nil), let view = controller.view else {
            return await finish()
        }
        await measureNewTabInRunningHost()
        await measureScroll(controller, view)
        await measureAnimation(controller, view)
        await measureResize(controller, view)
        await measureHidden()
        await finish()
    }

    // MARK: Panel

    /// The window goes to the display with the highest refresh rate (the built-in ProMotion display
    /// when there is one), at a size that gives the side panel a realistic height.
    private func moveWindowToTheFastestDisplay() {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
              let screen = NSScreen.screens.max(by: { $0.maximumFramesPerSecond < $1.maximumFramesPerSecond }) else { return }
        let area = screen.visibleFrame
        let size = CGSize(width: min(1400, area.width - 40), height: min(900, area.height - 40))
        window.setFrame(CGRect(x: area.minX + 20, y: area.maxY - 20 - size.height, width: size.width, height: size.height),
                        display: true)
        record["window"] = .object(["width": .number(size.width), "height": .number(size.height), "screen": .string(screen.localizedName)])
    }

    private func openPanel(label: String, address: String?) async -> BrowserHostPaneController? {
        let previous = BrowserHostPaneController.current
        let launches = client.launchCount
        let postedAt = DispatchTime.now().uptimeNanoseconds
        NotificationCenter.default.post(name: BrowserHostQAFixture.openBrowserPanel, object: nil)
        guard await waitUntil(.seconds(10), { BrowserHostPaneController.current !== previous
                && BrowserHostPaneController.current?.view != nil }),
              let controller = BrowserHostPaneController.current else {
            record["open-\(label)"] = .object(["error": .string("no panel")])
            return nil
        }
        if let address {
            controller.addressInput = address
            controller.submitAddress()
        }
        var firstFrame: UInt64?
        let visible = await waitUntil(.seconds(30), poll: .milliseconds(2)) {
            if controller.hasTab, controller.view?.viewSurface != nil { firstFrame = DispatchTime.now().uptimeNanoseconds }
            return firstFrame != nil
        }
        record["open-\(label)"] = .object([
            "hostWasRunning": .bool(client.launchCount == launches),
            "firstFrameShown": .bool(visible),
            "openToFirstFrameMs": firstFrame.map { .number(Double($0 &- postedAt) / 1_000_000) } ?? .null
        ])
        return controller
    }

    private func closePanel() async {
        NotificationCenter.default.post(name: BrowserHostQAFixture.closeBrowserPanel, object: nil)
        try? await Task.sleep(for: .milliseconds(800))
    }

    /// Another task opening its browser panel while the host runs: a new tab, from the open command
    /// to its first frame event.
    private func measureNewTabInRunningHost() async {
        let other = UUID()
        let openedAt = DispatchTime.now().uptimeNanoseconds
        guard let tab = try? client.openTab(forSession: other, url: base + "a11y", viewport: .offscreenDefault) else {
            record["open-new-tab"] = .object(["error": .string("could not open")])
            return
        }
        var firstFrame: UInt64?
        let observer = tab.addEventObserver { event in
            if case .frame = event, firstFrame == nil { firstFrame = DispatchTime.now().uptimeNanoseconds }
        }
        _ = await waitUntil(.seconds(20), poll: .milliseconds(2)) { firstFrame != nil }
        tab.removeEventObserver(observer)
        record["open-new-tab"] = .object([
            "openToFirstFrameMs": firstFrame.map { .number(Double($0 &- openedAt) / 1_000_000) } ?? .null
        ])
        tab.close()
        try? await Task.sleep(for: .milliseconds(500))
    }

    // MARK: Phases

    /// Scrolling a long page for four seconds: trackpad-like precise wheel deltas from a 120 Hz timer
    /// (direction flipping every second), then mouse-wheel line deltas every 300 ms, which Chromium
    /// animates (smooth scrolling) at its frame rate. Frames shown, peak frames per second over any
    /// half second, paint-to-display latency, and CPU.
    private func measureScroll(_ controller: BrowserHostPaneController, _ view: BrowserHostView) async {
        guard let tab = controller.tab else { return }
        let frames = FrameTally()
        controller.frameObserver = { frame, latency in frames.add(frame, latency: latency) }
        defer { controller.frameObserver = nil }
        let usage = ProcessTreeUsage(root: client.hostProcessID)
        await phase("1-scroll", holding: .zero)
        let started = ContinuousClock.now
        let point = (x: view.bounds.width / 2, y: view.bounds.height / 2)
        var results: [String: JSONValue] = [:]
        // Precise (trackpad-like) deltas at 120 and at 240 events per second.
        for rate in [120, 240] {
            let wheelEvents = WheelPump(tab: tab, x: point.x, y: point.y, eventsPerSecond: rate)
            frames.reset()
            let pumpStart = ContinuousClock.now
            wheelEvents.start()
            try? await Task.sleep(for: .seconds(3))
            wheelEvents.stop()
            var summary = frames.summary(seconds: seconds(since: pumpStart))
            summary["wheelEvents"] = .integer(Int64(wheelEvents.count))
            results["precise\(rate)"] = .object(summary)
        }
        // Page Down presses: Chromium animates keyboard scrolling at its frame rate.
        frames.reset()
        let keysStart = ContinuousClock.now
        for _ in 0..<8 {
            for kind in [BrowserKeyInput.Kind.rawDown, .up] {
                tab.send(.key(tab: tab.id, input: BrowserKeyInput(kind: kind, windowsKeyCode: 0x22, nativeKeyCode: 0x79)))
            }
            try? await Task.sleep(for: .milliseconds(400))
        }
        results["pageDown"] = .object(frames.summary(seconds: seconds(since: keysStart)))
        let elapsed = seconds(since: started)
        results["usage"] = usage.delta(seconds: elapsed)
        record["scroll"] = .object(results)
        try? await Task.sleep(for: .seconds(1))
    }

    /// A page animating with requestAnimationFrame: frames shown per second against the page's own
    /// frame count, then the same while the window is miniaturized and after it comes back.
    private func measureAnimation(_ controller: BrowserHostPaneController, _ view: BrowserHostView) async {
        await navigate(controller, base + "animation")
        try? await Task.sleep(for: .milliseconds(500))
        let frames = FrameTally()
        controller.frameObserver = { frame, latency in frames.add(frame, latency: latency) }
        defer { controller.frameObserver = nil }
        func pageFrames() async -> Int {
            Int((try? await evaluate(controller, "document.getElementById('frames').textContent")) ?? "") ?? 0
        }

        let usage = ProcessTreeUsage(root: client.hostProcessID)
        let pageBefore = await pageFrames()
        frames.reset()
        await phase("2-animation", holding: .zero)
        let started = ContinuousClock.now
        try? await Task.sleep(for: .seconds(4))
        let elapsed = seconds(since: started)
        var summary = frames.summary(seconds: elapsed)
        summary["pageFramesPerSecond"] = .number(Double(await pageFrames() - pageBefore) / elapsed)
        summary["usage"] = usage.delta(seconds: elapsed)
        record["animation"] = .object(summary)

        guard let window = view.window else { return }
        window.miniaturize(nil)
        try? await Task.sleep(for: .seconds(1))
        let hiddenUsage = ProcessTreeUsage(root: client.hostProcessID)
        let hiddenPageBefore = await pageFrames()
        frames.reset()
        let hiddenStart = ContinuousClock.now
        try? await Task.sleep(for: .seconds(2))
        let hiddenElapsed = seconds(since: hiddenStart)
        var hidden = frames.summary(seconds: hiddenElapsed)
        hidden["pageFramesPerSecond"] = .number(Double(await pageFrames() - hiddenPageBefore) / hiddenElapsed)
        hidden["pageVisibility"] = .string((try? await evaluate(controller, "document.visibilityState")) ?? "")
        hidden["windowOccluded"] = .bool(!window.occlusionState.contains(.visible))
        hidden["usage"] = hiddenUsage.delta(seconds: hiddenElapsed)
        record["miniaturized"] = .object(hidden)

        window.deminiaturize(nil)
        let restoredAt = DispatchTime.now().uptimeNanoseconds
        frames.reset()
        _ = await waitUntil(.seconds(5), poll: .milliseconds(2)) { frames.count > 0 }
        let firstFrameMs = frames.count > 0 ? Self.milliseconds(since: restoredAt) : -1
        frames.reset()
        let restoredStart = ContinuousClock.now
        try? await Task.sleep(for: .seconds(1))
        var restored = frames.summary(seconds: seconds(since: restoredStart))
        restored["firstFrameAfterRestoreMs"] = .number(firstFrameMs)
        restored["pageVisibility"] = .string((try? await evaluate(controller, "document.visibilityState")) ?? "")
        record["restored"] = .object(restored)
    }

    /// The panel changes height 40 times (the window's height, as a drag of the terminal divider or
    /// the window edge does): time from the resize to a frame of the new size, and memory before and
    /// after.
    private func measureResize(_ controller: BrowserHostPaneController, _ view: BrowserHostView) async {
        await navigate(controller, base + "large")
        try? await Task.sleep(for: .milliseconds(500))
        guard let window = view.window else { return }
        let original = window.frame
        let scale = window.backingScaleFactor
        let before = ProcessTreeUsage(root: client.hostProcessID)
        var times: [Double] = []
        var setFrameTimes: [Double] = []
        var timeouts = 0
        var heights: Set<Int> = []
        for index in 0..<40 {
            var frame = original
            frame.size.height = original.height - CGFloat(10 + (index * 37) % 160)
            frame.origin.y = original.maxY - frame.size.height
            let resizedAt = DispatchTime.now().uptimeNanoseconds
            let previousHeight = view.bounds.height
            window.setFrame(frame, display: true)
            setFrameTimes.append(Self.milliseconds(since: resizedAt))
            // The host paints at the viewport the view reported (whole points times the scale).
            let shown = await waitUntil(.milliseconds(600), poll: .milliseconds(2)) {
                guard view.bounds.height != previousHeight, let surface = view.viewSurface else { return false }
                return IOSurfaceGetHeight(surface) == Int(view.viewport.height * scale)
            }
            heights.insert(Int(view.bounds.height))
            times.append(Self.milliseconds(since: resizedAt))
            if !shown { timeouts += 1 }
        }
        window.setFrame(original, display: true)
        try? await Task.sleep(for: .seconds(1))
        let after = ProcessTreeUsage(root: client.hostProcessID)
        let sorted = times.sorted()
        let setFrameSorted = setFrameTimes.sorted()
        record["resize"] = .object([
            "count": .integer(Int64(times.count)),
            "distinctPanelHeights": .integer(Int64(heights.count)),
            "setFrameMedianMs": .number(setFrameSorted[setFrameSorted.count / 2]),
            "toFrameMedianMs": .number(sorted[sorted.count / 2]),
            "toFrameP95Ms": .number(sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]),
            "toFrameMaxMs": .number(sorted.last ?? 0),
            "timeouts": .integer(Int64(timeouts)),
            "cachedSurfacesAfter": .integer(Int64(MacBrowserHost.shared.process?.cachedSurfaceCount ?? -1)),
            "before": before.footprints(),
            "after": after.footprints()
        ])
        await phase("3-after-resize", holding: .seconds(4))
    }

    /// The panel closes; the tab hides once the agent-visible window has passed. Memory after.
    private func measureHidden() async {
        let before = ProcessTreeUsage(root: client.hostProcessID)
        await closePanel()
        try? await Task.sleep(for: client.agentVisibleWindow + .seconds(2))
        let after = ProcessTreeUsage(root: client.hostProcessID)
        record["hidden"] = .object([
            "before": before.footprints(),
            "after": after.footprints(),
            "cachedSurfacesAfter": .integer(Int64(MacBrowserHost.shared.process?.cachedSurfaceCount ?? -1)),
            "openTabs": .integer(Int64(client.openTabCount))
        ])
        await phase("4-hidden", holding: .seconds(4))
    }

    // MARK: Helpers

    private func navigate(_ controller: BrowserHostPaneController, _ url: String) async {
        controller.addressInput = url
        controller.submitAddress()
        _ = await waitUntilAsync(.seconds(15)) {
            let state = (try? await self.evaluate(controller, "location.href + ' ' + document.readyState")) ?? ""
            return state.hasPrefix(url) && state.hasSuffix("complete")
        }
    }

    private func evaluate(_ controller: BrowserHostPaneController, _ expression: String) async throws -> String {
        guard let tab = controller.tab else { throw PerfFailure("no tab") }
        let result = try await tab.devTools.send("Runtime.evaluate", [
            "expression": .string(expression), "returnByValue": .bool(true)
        ], timeout: .seconds(10))
        return result["result"]?["value"]?.stringValue ?? result["result"]?["value"]?.readableText ?? ""
    }

    private func phase(_ name: String, holding: Duration) async {
        let entry: [String: JSONValue] = [
            "name": .string(name), "atMs": .number(Self.milliseconds(since: start)),
            "hostRunning": .bool(client.isHostRunning), "openTabs": .integer(Int64(client.openTabCount))
        ]
        phases.append(.object(entry))
        try? write(.object(entry), to: "markers/\(name).json")
        if holding > .zero { try? await Task.sleep(for: holding) }
    }

    private func write(_ value: JSONValue, to name: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(value).write(to: output.appending(path: name), options: .atomic)
    }

    private func finish() async {
        record["phases"] = .array(phases)
        try? write(.object(record), to: "perf.json")
        try? "done".write(to: output.appending(path: "markers/finished"), atomically: true, encoding: .utf8)
        client.terminateHost()
        try? await Task.sleep(for: .seconds(1))
        _exit(0)
    }

    private func waitUntil(_ timeout: Duration, poll: Duration = .milliseconds(25),
                           _ condition: @escaping @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now >= deadline { return false }
            try? await Task.sleep(for: poll)
        }
        return true
    }

    private func waitUntilAsync(_ timeout: Duration, _ condition: @escaping @MainActor () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !(await condition()) {
            if ContinuousClock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return true
    }

    private func seconds(since instant: ContinuousClock.Instant) -> Double {
        let elapsed = ContinuousClock.now - instant
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }

    private static func milliseconds(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds &- start) / 1_000_000
    }
}

/// Frames the panel showed and their paint-to-display latency, recorded on the thread that showed
/// them (the event pipe's queue).
private final class FrameTally: @unchecked Sendable {
    private let lock = NSLock()
    private var shown = 0
    private var latencies: [Double] = []
    private var shownAt: [UInt64] = []
    private var sources: Set<String> = []
    private var pixelSizes: Set<String> = []

    var count: Int { lock.withLock { shown } }

    func add(_ frame: BrowserFrame, latency: Double) {
        lock.withLock {
            shown += 1
            latencies.append(latency)
            shownAt.append(DispatchTime.now().uptimeNanoseconds)
            sources.insert(frame.source)
            pixelSizes.insert("\(frame.pixelWidth)x\(frame.pixelHeight)")
        }
    }

    func reset() {
        lock.withLock {
            shown = 0
            latencies = []
            shownAt = []
            sources = []
            pixelSizes = []
        }
    }

    /// The most frames shown in any half second, doubled.
    private var peakFramesPerSecond: Double {
        var peak = 0
        var start = 0
        for (index, time) in shownAt.enumerated() {
            while time - shownAt[start] > 500_000_000 { start += 1 }
            peak = max(peak, index - start + 1)
        }
        return Double(peak) * 2
    }

    func summary(seconds: Double) -> [String: JSONValue] {
        lock.withLock { unlockedSummary(seconds: seconds) }
    }

    private func unlockedSummary(seconds: Double) -> [String: JSONValue] {
        let count = shown
        let sorted = latencies.sorted()
        func percentile(_ fraction: Double) -> Double {
            sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * fraction))]
        }
        return [
            "seconds": .number((seconds * 100).rounded() / 100),
            "frames": .integer(Int64(count)),
            "framesPerSecond": .number((Double(count) / max(seconds, 0.001) * 10).rounded() / 10),
            "peakFramesPerSecond": .number(peakFramesPerSecond),
            "latencyMedianMs": .number((percentile(0.5) * 100).rounded() / 100),
            "latencyP95Ms": .number((percentile(0.95) * 100).rounded() / 100),
            "latencyMaxMs": .number(((sorted.last ?? 0) * 100).rounded() / 100),
            "sources": .array(sources.sorted().map { .string($0) }),
            "pixelSizes": .array(pixelSizes.sorted().map { .string($0) })
        ]
    }
}

/// Trackpad-like wheel input at 120 events per second from a timer queue, so the pace does not
/// depend on the main actor; the command itself is sent on the main actor like the view's.
private final class WheelPump: @unchecked Sendable {
    private let tab: BrowserTab
    private let x: Double
    private let y: Double
    private let timer: DispatchSourceTimer
    private let lock = NSLock()
    private var sent = 0
    private var step = 0

    private let eventsPerSecond: Int

    @MainActor init(tab: BrowserTab, x: Double, y: Double, eventsPerSecond: Int) {
        self.tab = tab
        self.x = x
        self.y = y
        self.eventsPerSecond = eventsPerSecond
        timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "yardlet.perf.wheel"))
    }

    var count: Int { lock.withLock { sent } }

    func start() {
        timer.schedule(deadline: .now(), repeating: .microseconds(1_000_000 / eventsPerSecond), leeway: .microseconds(300))
        timer.setEventHandler { [self] in
            let index = lock.withLock { step += 1; sent += 1; return step }
            let direction: Double = (index / eventsPerSecond).isMultiple(of: 2) ? -16 : 16
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.tab.send(.wheel(tab: self.tab.id, input: BrowserWheelInput(
                        x: self.x, y: self.y, deltaX: 0, deltaY: direction, modifiers: [.preciseScrolling]
                    )))
                }
            }
        }
        timer.resume()
    }

    func stop() {
        timer.cancel()
    }
}

/// CPU time and footprint of Yardlet and of the host's process tree, grouped: the host, its
/// renderers, its other helpers (GPU, network, storage).
private struct ProcessTreeUsage {
    struct Usage { var cpuNanoseconds: UInt64; var footprint: UInt64 }
    let root: Int?
    var byGroup: [String: Usage] = [:]
    var processCount = 0

    init(root: Int?) {
        self.root = root
        add(group: "yardlet", pid: getpid())
        guard let root else { return }
        for pid in Self.tree(pid_t(root)) {
            let path = Self.path(pid)
            let group = pid == pid_t(root) ? "host"
                : path.contains("Helper (Renderer)") ? "renderers"
                : path.contains("Yardlet Helper") ? "helpers" : "other"
            add(group: group, pid: pid)
        }
    }

    private mutating func add(group: String, pid: pid_t) {
        guard let usage = Self.usage(pid) else { return }
        processCount += 1
        var total = byGroup[group] ?? Usage(cpuNanoseconds: 0, footprint: 0)
        total.cpuNanoseconds += usage.cpuNanoseconds
        total.footprint += usage.footprint
        byGroup[group] = total
    }

    /// CPU percent per group since `self`, and footprints now.
    func delta(seconds: Double) -> JSONValue {
        let now = ProcessTreeUsage(root: root)
        var result: [String: JSONValue] = [:]
        for (group, usage) in now.byGroup {
            let before = byGroup[group]?.cpuNanoseconds ?? 0
            let cpu = Double(usage.cpuNanoseconds &- before) / (max(seconds, 0.001) * 1e9) * 100
            result[group] = .object([
                "cpuPercent": .number((cpu * 10).rounded() / 10),
                "footprintMiB": .number((Double(usage.footprint) / 1_048_576).rounded())
            ])
        }
        return .object(result)
    }

    func footprints() -> JSONValue {
        .object(byGroup.mapValues { .number((Double($0.footprint) / 1_048_576).rounded()) })
    }

    private static func children(of pid: pid_t) -> [pid_t] {
        var buffer = [pid_t](repeating: 0, count: 256)
        let count = proc_listchildpids(pid, &buffer, Int32(buffer.count * MemoryLayout<pid_t>.size))
        guard count > 0 else { return [] }
        return Array(buffer.prefix(Int(count)))
    }

    private static func tree(_ pid: pid_t) -> [pid_t] {
        [pid] + children(of: pid).flatMap(tree)
    }

    private static func path(_ pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return "" }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func usage(_ pid: pid_t) -> Usage? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard result == 0 else { return nil }
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let cpu = (info.ri_user_time + info.ri_system_time) * UInt64(timebase.numer) / UInt64(timebase.denom)
        return Usage(cpuNanoseconds: cpu, footprint: info.ri_phys_footprint)
    }
}

private struct PerfFailure: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
#endif
