// Captures one app's window, for scripts/showcase/capture.sh. Built with `swiftc -O`.
//
//   record-window shot <pid> <output.png> [--size <w>x<h>]
//       A still of the process's main window (its largest), with its sheets and popovers on it.
//       With --size it waits for the window to be that many points wide and high.
//   record-window record <pid> <output.mp4> [--size <w>x<h>] [--seconds <s>] [--wait-loop] [--fps <n>]
//       The same, recorded to an H.264 MP4 with a constant frame rate (60 by default). With
//       --wait-loop it starts on the showcase playback's next "Yardlet.showcase.loopStarted"
//       distributed notification and, unless --seconds says otherwise, records that round's
//       length, so the file loops without a seam.
//
// Both draw only the process's own windows, from the display, cut to the main window's frame at
// the display's scale: no shadow, no wallpaper, nothing that covers it, no pointer. The filter is
// the display less every other application, not the process's windows: a filter that names
// windows or applications makes macOS mark them as shared (a purple badge in place of the window
// buttons) for as long as a recording runs. Leaving others out misses what a process started after
// the filter was made shows over the window, so a recording makes its filter again every second,
// and the window's frame is watched for any window of a process the filter does not leave out: a
// still waits until none is over it, and a recording that had one starts again on the next round.
// The window has to be on the display, and the screen unlocked. Outside the window's rounded
// corners both are black, the same in a still and a video.
import AppKit
import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("record-window: \(message)\n".utf8))
    exit(1)
}

struct Target {
    let filter: SCContentFilter
    let configuration: SCStreamConfiguration
    let width: Int
    let height: Int
    /// The main window's frame in global coordinates, and the processes the filter leaves out.
    let frame: CGRect
    let pid: pid_t
    let excludedProcesses: Set<pid_t>

    /// A window over the frame that the filter draws though it is not the process's own: one of a
    /// process that was not there to leave out when the filter was made.
    func intruder() -> String? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        for info in list {
            guard let owner = info[kCGWindowOwnerPID as String] as? pid_t, owner != pid,
                  let layer = info[kCGWindowLayer as String] as? Int, layer >= 0,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let number = info[kCGWindowNumber as String] as? Int,
                  let bounds = (info[kCGWindowBounds as String] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0) }),
                  bounds.intersects(frame) else { continue }
            if !excludedProcesses.contains(owner) {
                return "\(info[kCGWindowOwnerName as String] as? String ?? "process \(owner)") (window \(number), layer \(layer))"
            }
        }
        return nil
    }
}

/// The process's windows on the display that holds its main window, cut to that window. Waits up
/// to ten seconds for the window to come on screen, at `size` when one is given.
func makeTarget(pid: pid_t, size: CGSize?, fps: Int32) async -> Target {
    var content: SCShareableContent?
    var main: SCWindow?
    for _ in 0..<50 {
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            fail("can't list windows (Screen Recording permission?): \(error.localizedDescription)")
        }
        main = content?.windows.filter { $0.owningApplication?.processID == pid && $0.isOnScreen && $0.windowLayer == 0 }
            .max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
        if let main, size == nil || main.frame.size == size { break }
        try? await Task.sleep(for: .milliseconds(200))
    }
    guard let content, let main else { fail("process \(pid) has no window on screen") }
    if let size, main.frame.size != size {
        fail("the window is \(Int(main.frame.width))x\(Int(main.frame.height)) points, not \(Int(size.width))x\(Int(size.height))")
    }
    guard let display = content.displays.first(where: { $0.frame.contains(main.frame) }) else {
        fail(content.displays.isEmpty ? "no display to capture: unlock the screen and wake the display"
                                      : "the window is not wholly on one display")
    }
    let others = content.applications.filter { $0.processID != pid }
    let filter = SCContentFilter(display: display, excludingApplications: others, exceptingWindows: [])
    let scale = CGFloat(filter.pointPixelScale)
    let rect = main.frame.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
    let configuration = SCStreamConfiguration()
    configuration.sourceRect = rect
    configuration.width = Int((rect.width * scale).rounded())
    configuration.height = Int((rect.height * scale).rounded())
    configuration.pixelFormat = kCVPixelFormatType_32BGRA
    configuration.colorSpaceName = CGColorSpace.sRGB
    configuration.showsCursor = false
    configuration.ignoreShadowsDisplay = true
    configuration.minimumFrameInterval = CMTime(value: 1, timescale: fps)
    configuration.queueDepth = 8
    return Target(filter: filter, configuration: configuration, width: configuration.width, height: configuration.height,
                  frame: main.frame, pid: pid, excludedProcesses: Set(others.map(\.processID)))
}

func shot(pid: pid_t, size: CGSize?, to output: URL) async {
    for _ in 0..<30 {
        let target = await makeTarget(pid: pid, size: size, fps: 60)
        if let intruder = target.intruder() {
            FileHandle.standardError.write(Data("record-window: waiting for \(intruder) to leave the window\n".utf8))
            try? await Task.sleep(for: .seconds(1))
            continue
        }
        do {
            let image = try await SCScreenshotManager.captureImage(contentFilter: target.filter, configuration: target.configuration)
            guard target.intruder() == nil else { continue }
            guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                fail("can't encode PNG")
            }
            try data.write(to: output)
            print("\(output.path) \(image.width)x\(image.height)")
            return
        } catch {
            fail("can't capture: \(error.localizedDescription)")
        }
    }
    fail("another window stayed over the window")
}

/// Writes the newest frame at every tick of a fixed rate, so the file has a constant frame rate
/// however rarely the window changes. Each take writes a new file.
final class Recorder: NSObject, SCStreamOutput, @unchecked Sendable {
    let width: Int
    let height: Int
    let fps: Int32
    private let lock = NSLock()
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var latest: CVPixelBuffer?
    private var start: CMTime?
    private var written: Int64 = 0

    init(width: Int, height: Int, fps: Int32) {
        self.width = width
        self.height = height
        self.fps = fps
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let buffer = sampleBuffer.imageBuffer else { return }
        lock.withLock { latest = buffer }
    }

    var hasFrame: Bool { lock.withLock { latest != nil } }

    /// Forgets the frame on hand, so the next one is the first the window draws from now on.
    func dropFrame() { lock.withLock { latest = nil } }

    /// Starts a take into `output`, its time zero at `time`.
    func begin(_ output: URL, at time: CMTime) throws {
        try? FileManager.default.removeItem(at: output)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 40_000_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoMaxKeyFrameIntervalKey: Int(fps),
                AVVideoAllowFrameReorderingKey: false
            ]
        ])
        input.expectsMediaDataInRealTime = true
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        lock.withLock {
            self.writer = writer
            self.input = input
            self.adaptor = adaptor
            written = 0
            start = time
        }
    }

    /// Appends the newest frame for every tick up to `now`.
    func tick(now: CMTime) {
        lock.lock()
        defer { lock.unlock() }
        guard let start, let latest, let input, let adaptor else { return }
        let due = Int64((CMTimeGetSeconds(now) - CMTimeGetSeconds(start)) * Double(fps))
        while written <= due, input.isReadyForMoreMediaData {
            adaptor.append(latest, withPresentationTime: CMTime(value: written, timescale: fps))
            written += 1
        }
    }

    func finish(frames: Int64) async {
        let (writer, input) = lock.withLock { () -> (AVAssetWriter?, AVAssetWriterInput?) in
            while written < frames, let latest, let input, let adaptor {
                while !input.isReadyForMoreMediaData { usleep(1_000) }
                adaptor.append(latest, withPresentationTime: CMTime(value: written, timescale: fps))
                written += 1
            }
            defer { start = nil }
            return (self.writer, self.input)
        }
        guard let writer, let input else { return }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: frames, timescale: fps))
        await writer.finishWriting()
        if writer.status != .completed { fail("writing failed: \(writer.error?.localizedDescription ?? "unknown")") }
    }

    /// Throws the take away.
    func discard(_ output: URL) {
        let writer = lock.withLock { () -> AVAssetWriter? in
            defer { start = nil; self.writer = nil }
            return self.writer
        }
        writer?.cancelWriting()
        try? FileManager.default.removeItem(at: output)
    }
}

func hostNow() -> CMTime { CMClockGetTime(CMClockGetHostTimeClock()) }

/// The playback's next round starting, and its length in seconds.
func nextRound() async -> Double {
    await withCheckedContinuation { continuation in
        let center = DistributedNotificationCenter.default()
        var token: NSObjectProtocol?
        token = center.addObserver(forName: Notification.Name("Yardlet.showcase.loopStarted"), object: nil,
                                   queue: .main) { note in
            if let token { center.removeObserver(token) }
            continuation.resume(returning: (note.userInfo?["seconds"] as? Double) ?? 15)
        }
    }
}

func record(pid: pid_t, size: CGSize?, to output: URL, seconds requested: Double?, waitsForLoop: Bool, fps: Int32) async {
    var target = await makeTarget(pid: pid, size: size, fps: fps)
    let recorder = Recorder(width: target.width, height: target.height, fps: fps)
    let stream = SCStream(filter: target.filter, configuration: target.configuration, delegate: nil)
    do {
        try stream.addStreamOutput(recorder, type: .screen, sampleHandlerQueue: DispatchQueue(label: "record-window.frames"))
        try await stream.startCapture()
    } catch {
        fail("can't capture: \(error.localizedDescription)")
    }

    for take in 1...6 {
        var seconds = requested ?? 15
        if waitsForLoop {
            let round = await nextRound()
            seconds = requested ?? round
            // A round starts on the app's next frame: the one on hand is the end of the last round.
            // The take ends a little before the next round's first frame could arrive.
            recorder.dropFrame()
            seconds -= 0.15
        }
        for _ in 0..<250 where !recorder.hasFrame { try? await Task.sleep(for: .milliseconds(4)) }
        guard recorder.hasFrame else { fail("the window sent no frames (is the display asleep?)") }
        let start = hostNow()
        do { try recorder.begin(output, at: start) } catch {
            fail("can't write \(output.path): \(error.localizedDescription)")
        }
        let frames = Int64((seconds * Double(fps)).rounded())
        let end = CMTimeAdd(start, CMTime(seconds: seconds, preferredTimescale: 600))
        var intruder: String?
        var lastLook = start, lastFilter = start
        while CMTimeCompare(hostNow(), end) < 0 {
            recorder.tick(now: hostNow())
            if CMTimeGetSeconds(CMTimeSubtract(hostNow(), lastLook)) >= 0.1 {
                lastLook = hostNow()
                intruder = intruder ?? target.intruder()
            }
            // Processes started since leave the picture too.
            if CMTimeGetSeconds(CMTimeSubtract(hostNow(), lastFilter)) >= 1 {
                lastFilter = hostNow()
                let next = await makeTarget(pid: pid, size: size, fps: fps)
                try? await stream.updateContentFilter(next.filter)
                target = next
            }
            try? await Task.sleep(for: .milliseconds(Int(1_000 / fps / 2)))
        }
        if let intruder, waitsForLoop {
            recorder.discard(output)
            FileHandle.standardError.write(Data("record-window: \(intruder) came over the window; take \(take) again\n".utf8))
            continue
        }
        try? await stream.stopCapture()
        await recorder.finish(frames: frames)
        print("\(output.path) \(target.width)x\(target.height) \(fps) fps \(String(format: "%.2f", seconds)) s")
        return
    }
    try? await stream.stopCapture()
    fail("another window kept coming over the window")
}

// ScreenCaptureKit needs the window server connection an app has.
_ = NSApplication.shared
let arguments = Array(CommandLine.arguments.dropFirst())
let usage = "usage: record-window shot <pid> <output.png> [--size <w>x<h>] | record <pid> <output.mp4> [--size <w>x<h>] [--seconds <s>] [--wait-loop] [--fps <n>]"
guard arguments.count >= 3, let pid = pid_t(arguments[1]) else { fail(usage) }
func value(_ flag: String) -> String? {
    arguments.firstIndex(of: flag).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
}
let output = URL(filePath: arguments[2])
let size = value("--size").flatMap { text -> CGSize? in
    let parts = text.split(separator: "x").compactMap { Double($0) }
    return parts.count == 2 ? CGSize(width: parts[0], height: parts[1]) : nil
}
let done = DispatchSemaphore(value: 0)
switch arguments[0] {
case "shot":
    Task { await shot(pid: pid, size: size, to: output); done.signal() }
case "record":
    let seconds = value("--seconds").flatMap(Double.init)
    let fps = value("--fps").flatMap(Int32.init) ?? 60
    let waits = arguments.contains("--wait-loop")
    Task { await record(pid: pid, size: size, to: output, seconds: seconds, waitsForLoop: waits, fps: fps); done.signal() }
default:
    fail(usage)
}
while done.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
