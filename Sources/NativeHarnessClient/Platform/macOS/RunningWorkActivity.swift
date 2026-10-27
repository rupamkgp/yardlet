import Foundation
import IOKit.ps
import Observation

/// Settings › General › "Keep the screen unlocked while tasks work". Off by default: a Mac left alone
/// stays unlocked while it is on (docs/REMOTE_V2_DESIGN.md §6.5).
enum KeepScreenAwakePreference {
    static let key = "Yardlet.keepScreenAwakeWhileWorking"

    static func isOn(in defaults: UserDefaults = .yardlet) -> Bool {
        defaults.bool(forKey: key)
    }
}

/// What lets the screen stay on: not on a battery under 20%. A hot Mac does not count: the work goes on
/// either way, and the display adds little heat, so letting it lock only surprised the person (2026-10-26).
struct ScreenAwakeConditions: Equatable, Sendable {
    var onBattery = false
    var batteryPercent: Int?

    static let batteryFloor = 20

    var allowsKeepingScreenAwake: Bool {
        guard onBattery, let batteryPercent else { return true }
        return batteryPercent >= Self.batteryFloor
    }

    /// The power source now (IOKit power sources; reads only).
    static func current() -> ScreenAwakeConditions {
        var conditions = ScreenAwakeConditions()
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

/// Keeps the Mac from idle-sleeping while a task is working, as the Codex app does; the display may
/// still sleep. A task waiting for the person's approval is not working, so it does not count,
/// unless a paired phone can answer it (`AppModel.keepsMacAwake`). With "Keep the screen unlocked
/// while tasks work" on, the display stays on too for that time, so the screen does not lock and a
/// harness's computer use keeps working while the person is away; not on a battery under 20%, which
/// the person is told once and the menu bar menu says. The assertions end with the work or the process;
/// no system setting changes.
@MainActor final class RunningWorkActivity {
    private var token: NSObjectProtocol?
    private var displayToken: NSObjectProtocol?
    private weak var followed: AppModel?
    private var working = false
    private var observers: [NSObjectProtocol] = []
    private var powerCheck: Timer?
    private let defaults: UserDefaults
    private let conditions: @MainActor () -> ScreenAwakeConditions

    init(defaults: UserDefaults = .yardlet,
         conditions: @escaping @MainActor () -> ScreenAwakeConditions = ScreenAwakeConditions.current) {
        self.defaults = defaults
        self.conditions = conditions
    }

    var isHolding: Bool { token != nil }
    /// The display is kept on now.
    var isHoldingDisplay: Bool { displayToken != nil }
    /// The setting wants the display on now, but a battery under 20% lets the screen lock.
    private(set) var isPausedForBattery = false

    /// Follows `model.keepsMacAwake` from now on. It is observed here rather than in a view: the
    /// value reads every task's record, and the scene observing it re-evaluated the window's root
    /// whenever any task's record changed.
    func follow(_ model: AppModel) {
        guard followed !== model else { return }
        followed = model
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: UserDefaults.didChangeNotification, object: defaults, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshDisplay() }
            }
        ]
        track()
    }

    func update(isWorking: Bool) {
        working = isWorking
        if isWorking, token == nil {
            token = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled],
                reason: "A Yardlet task is running")
        } else if !isWorking, let token {
            ProcessInfo.processInfo.endActivity(token)
            self.token = nil
        }
        refreshDisplay()
    }

    /// Holds or lets go of the display as the work, the setting and the battery say.
    func refreshDisplay() {
        let wanted = working && KeepScreenAwakePreference.isOn(in: defaults)
        let allowed = conditions().allowsKeepingScreenAwake
        let holds = wanted && allowed
        let paused = wanted && !allowed
        if paused, !isPausedForBattery, let model = followed {
            Task {
                await model.systemNotificationCenter.post(
                    title: L10n.string("The screen can lock now"),
                    body: L10n.string("The battery is under 20%. Yardlet keeps the screen unlocked again on power."),
                    identifier: "yardlet.screenAwakePausedForBattery")
            }
        }
        isPausedForBattery = paused
        followed?.screenAwakePausedForBattery = paused
        if holds, displayToken == nil {
            displayToken = ProcessInfo.processInfo.beginActivity(options: [.idleDisplaySleepDisabled],
                reason: "A Yardlet task is running and the screen stays unlocked")
        } else if !holds, let displayToken {
            ProcessInfo.processInfo.endActivity(displayToken)
            self.displayToken = nil
        }
        followed?.keepsScreenAwake = displayToken != nil
        // While it is wanted, the battery is read again every minute.
        if wanted, powerCheck == nil {
            powerCheck = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshDisplay() }
            }
        } else if !wanted {
            powerCheck?.invalidate()
            powerCheck = nil
        }
    }

    private func track() {
        guard let model = followed else { return }
        let working = withObservationTracking { model.keepsMacAwake } onChange: { [weak self] in
            Task { @MainActor in self?.track() }
        }
        update(isWorking: working)
    }
}
