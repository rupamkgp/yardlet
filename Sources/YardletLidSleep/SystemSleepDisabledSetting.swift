import Foundation
import IOKit

/// The real setting, through the IOKit calls `pmset disablesleep` makes. They are exported by IOKit
/// but declared only in its private headers, so they are looked up at run time; a macOS without them
/// leaves the setting alone.
public final class SystemSleepDisabledSetting: SleepDisabledSetting {
    private typealias SetSetting = @convention(c) (CFString, CFTypeRef) -> IOReturn
    private typealias CopySettings = @convention(c) () -> Unmanaged<CFDictionary>?
    private static let key = "SleepDisabled"

    private let setSetting: SetSetting?
    private let copySettings: CopySettings?

    public init() {
        let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)
        setSetting = dlsym(iokit, "IOPMSetSystemPowerSetting").map { unsafeBitCast($0, to: SetSetting.self) }
        copySettings = dlsym(iokit, "IOPMCopySystemPowerSettings").map { unsafeBitCast($0, to: CopySettings.self) }
    }

    public var isOn: Bool {
        guard let settings = copySettings?()?.takeRetainedValue() as? [String: Any] else { return false }
        return settings[Self.key] as? Bool ?? false
    }

    public func set(_ on: Bool) -> Bool {
        guard let setSetting else { return false }
        return setSetting(Self.key as CFString, on ? kCFBooleanTrue : kCFBooleanFalse) == kIOReturnSuccess
    }
}

/// The helper's record, a short text file that also tells a person who finds it what it means.
public final class SleepDisabledRecordFile: SleepDisabledRecord {
    public static let defaultURL = URL(filePath: "/Library/Application Support/Yardlet/Lid Helper Turned Off Sleep.txt")

    private let url: URL

    public init(url: URL = SleepDisabledRecordFile.defaultURL) { self.url = url }

    public var exists: Bool { FileManager.default.fileExists(atPath: url.path) }

    public func write() -> Bool {
        let note = """
        Yardlet's lid helper turned on macOS's SleepDisabled power setting at \(Date.now.ISO8601Format()) \
        so tasks keep working with the lid closed. It turns the setting off when the tasks stop, when \
        Yardlet quits, and when it next starts. If Yardlet is gone, turn it off with \
        `sudo pmset -a disablesleep 0` and delete this file.

        """
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(note.utf8).write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    public func remove() {
        try? FileManager.default.removeItem(at: url)
        // The folder goes too when nothing else is in it (rmdir leaves a folder that has files).
        rmdir(url.deletingLastPathComponent().path)
    }
}
