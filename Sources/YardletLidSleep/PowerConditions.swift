import Foundation
import IOKit.ps

/// What lets Yardlet keep the screen on, or the Mac awake with its lid closed, while tasks work: not
/// on a battery under 20%. A hot Mac does not count for the screen: the work goes on either way, and
/// the display adds little heat, so letting it lock only surprised the person (2026-10-26). It does
/// count for the lid at its worst (critical), since sleeping is what lets a closed Mac cool down
/// (2026-10-27).
public struct PowerConditions: Equatable, Sendable {
    public var onBattery = false
    public var batteryPercent: Int?
    public var thermalState: ProcessInfo.ThermalState = .nominal

    public static let batteryFloor = 20

    public init(onBattery: Bool = false, batteryPercent: Int? = nil, thermalState: ProcessInfo.ThermalState = .nominal) {
        self.onBattery = onBattery
        self.batteryPercent = batteryPercent
        self.thermalState = thermalState
    }

    /// The battery allows it: on power, or at 20% or more.
    public var allowsKeepingAwake: Bool {
        guard onBattery, let batteryPercent else { return true }
        return batteryPercent >= Self.batteryFloor
    }

    /// The Mac is too hot to keep awake with its lid closed.
    public var isCriticallyHot: Bool { thermalState == .critical }

    /// The battery and the heat allow keeping the Mac awake with its lid closed.
    public var allowsKeepingLidClosedAwake: Bool { allowsKeepingAwake && !isCriticallyHot }

    /// The power source and the heat now (IOKit power sources and `ProcessInfo`; reads only).
    public static func current() -> PowerConditions {
        var conditions = PowerConditions(thermalState: ProcessInfo.processInfo.thermalState)
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return conditions }
        let providing = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        conditions.onBattery = providing == kIOPMBatteryPowerKey
        let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] ?? []
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
            conditions.batteryPercent = current * 100 / maximum
        }
        return conditions
    }
}
