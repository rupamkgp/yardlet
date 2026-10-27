import XCTest
@testable import NativeHarnessClient

@MainActor final class RunningWorkActivityTests: XCTestCase {
    func testTheSleepAssertionFollowsWhetherATaskIsWorking() {
        let activity = RunningWorkActivity()
        XCTAssertFalse(activity.isHolding)
        activity.update(isWorking: true)
        activity.update(isWorking: true)
        XCTAssertTrue(activity.isHolding, "Repeated updates keep one assertion")
        activity.update(isWorking: false)
        XCTAssertFalse(activity.isHolding)
        activity.update(isWorking: false)
        XCTAssertFalse(activity.isHolding)
    }

    /// The display is held only while tasks work with the setting on, and lets go on a low battery,
    /// which it says; a hot Mac keeps it (REMOTE_V2_DESIGN.md §6.5).
    func testTheScreenStaysOnOnlyWhileWorkingWithTheSettingOnAndPowerToSpare() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("RunningWorkActivity")))
        var conditions = ScreenAwakeConditions(onBattery: true, batteryPercent: 80)
        let activity = RunningWorkActivity(defaults: defaults, conditions: { conditions })
        activity.update(isWorking: true)
        XCTAssertTrue(activity.isHolding)
        XCTAssertFalse(activity.isHoldingDisplay, "Off by default")
        defaults.set(true, forKey: KeepScreenAwakePreference.key)
        activity.refreshDisplay()
        XCTAssertTrue(activity.isHoldingDisplay)
        conditions.batteryPercent = 19
        activity.refreshDisplay()
        XCTAssertFalse(activity.isHoldingDisplay, "A battery under 20% lets the screen lock")
        XCTAssertTrue(activity.isPausedForBattery, "and says so")
        conditions = ScreenAwakeConditions(onBattery: false, batteryPercent: 5)
        activity.refreshDisplay()
        XCTAssertTrue(activity.isHoldingDisplay, "On power a low charge does not matter")
        XCTAssertFalse(activity.isPausedForBattery)
        activity.update(isWorking: false)
        XCTAssertFalse(activity.isHoldingDisplay)
        XCTAssertFalse(activity.isHolding)
    }
}
