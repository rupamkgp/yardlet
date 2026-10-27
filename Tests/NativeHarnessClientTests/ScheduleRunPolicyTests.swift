import Foundation
import XCTest
@testable import NativeHarnessClient

/// When a schedule runs: on time, once after a sleep or a closed Yardlet within the Claude app's
/// seven-day window, never for slots before it was made or while it was paused, off after repeated
/// failed starts, and done after a one-off. Pure decisions with a fixed clock.
final class ScheduleRunPolicyTests: XCTestCase {
    private var seoul: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        return calendar
    }()

    private func date(_ day: Int, _ hour: Int = 0, _ minute: Int = 0, month: Int = 10) -> Date {
        seoul.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    private func schedule(_ trigger: ScheduleTrigger, createdAt: Date) -> ScheduledTask {
        ScheduledTask(name: "Morning check", prompt: "Check the overnight jobs.", trigger: trigger,
                      destination: ScheduleDestination(harness: .claudeCode), createdAt: createdAt)
    }

    private let nine = ScheduleTrigger.daily(ScheduleTime(hour: 9, minute: 0))

    func testASlotRunsOnTimeWithinTwoMinutes() {
        let task = schedule(nine, createdAt: date(12, 8))
        XCTAssertEqual(ScheduleRunPolicy.decide(task, now: date(12, 8, 59), calendar: seoul),
                       .wait(next: date(12, 9)))
        XCTAssertEqual(ScheduleRunPolicy.decide(task, now: date(12, 9, 0), calendar: seoul),
                       .run(slot: date(12, 9), trigger: .scheduled))
        XCTAssertEqual(ScheduleRunPolicy.decide(task, now: date(12, 9, 2), calendar: seoul),
                       .run(slot: date(12, 9), trigger: .scheduled))
        XCTAssertEqual(ScheduleRunPolicy.decide(task, now: date(12, 9, 3), calendar: seoul),
                       .run(slot: date(12, 9), trigger: .missed), "Later than two minutes is a missed run")
    }

    func testAfterASleepOnlyTheLatestMissedSlotRunsOnce() {
        var task = schedule(nine, createdAt: date(1))
        task.state.lastSlot = date(10, 9)
        // The Mac slept from the 10th's evening until the 13th at noon: three slots passed.
        let wake = date(13, 12)
        let decision = ScheduleRunPolicy.decide(task, now: wake, calendar: seoul)
        XCTAssertEqual(decision, .run(slot: date(13, 9), trigger: .missed))
        let ran = ScheduleRunPolicy.record(
            ScheduledTaskRun(slot: date(13, 9), at: wake, trigger: .missed, outcome: .started, taskID: UUID()), in: task)
        XCTAssertEqual(ScheduleRunPolicy.decide(ran, now: wake.addingTimeInterval(60), calendar: seoul),
                       .wait(next: date(14, 9)), "The earlier missed slots do not run")
        XCTAssertEqual(ran.state.lastSlot, date(13, 9))
        XCTAssertEqual(ran.state.runs.count, 1)
    }

    func testOnlySlotsWithinTheLastSevenDaysRunLate() {
        let monday = ScheduleTrigger.weekly(days: [.monday], time: ScheduleTime(hour: 9, minute: 0))
        var task = schedule(monday, createdAt: date(1, month: 9))
        task.state.lastSlot = date(28, 9, month: 9)
        // Yardlet was closed from Sep 28 until Oct 13 (Tuesday): Oct 5 and Oct 12 passed; Oct 12 is within a week.
        XCTAssertEqual(ScheduleRunPolicy.decide(task, now: date(13, 10), calendar: seoul),
                       .run(slot: date(12, 9), trigger: .missed))
        // A slot older than seven days is never looked for, whatever the last run was.
        XCTAssertNil(monday.latestSlot(after: date(13, 10).addingTimeInterval(-ScheduleRunPolicy.catchUpWindow),
                                       notAfter: date(12, 8, 59), calendar: seoul),
                     "Oct 5 09:00 lies before the window that ends on Oct 13 at 10:00")
        task.state.lastSlot = date(12, 9)
        XCTAssertEqual(ScheduleRunPolicy.decide(task, now: date(19, 8), calendar: seoul), .wait(next: date(19, 9)))
        XCTAssertEqual(ScheduleRunPolicy.decide(task, now: date(19, 9, 1), calendar: seoul),
                       .run(slot: date(19, 9), trigger: .scheduled))
    }

    func testAOneOffMissedOutsideTheWindowEndsWithoutRunning() {
        let task = schedule(.once(date(1, 14)), createdAt: date(1))
        XCTAssertEqual(ScheduleRunPolicy.decide(task, now: date(5, 10), calendar: seoul),
                       .run(slot: date(1, 14), trigger: .missed), "Within a week it runs late once")
        let expired = ScheduleRunPolicy.decide(task, now: date(9, 10), calendar: seoul)
        XCTAssertEqual(expired, .expire(slot: date(1, 14)))
        let ended = ScheduleRunPolicy.expire(task, slot: date(1, 14))
        XCTAssertFalse(ended.isEnabled)
        XCTAssertEqual(ended.state.stopReason, .expired)
        XCTAssertNil(ScheduleRunPolicy.nextRun(of: ended, now: date(9, 10), calendar: seoul))
    }

    func testAOneOffIsDoneOnceItRan() {
        let task = schedule(.once(date(17, 14, 30)), createdAt: date(16))
        XCTAssertEqual(ScheduleRunPolicy.decide(task, now: date(17, 14, 30), calendar: seoul),
                       .run(slot: date(17, 14, 30), trigger: .scheduled))
        let ran = ScheduleRunPolicy.record(
            ScheduledTaskRun(slot: date(17, 14, 30), at: date(17, 14, 30), trigger: .scheduled, outcome: .started), in: task)
        XCTAssertFalse(ran.isEnabled)
        XCTAssertEqual(ran.state.stopReason, .finished)
        XCTAssertEqual(ScheduleRunPolicy.decide(ran, now: date(17, 15), calendar: seoul), .wait(next: nil))
    }

    func testSlotsBeforeTheScheduleWasMadeNeverRun() {
        let task = schedule(nine, createdAt: date(12, 9, 30))
        XCTAssertEqual(ScheduleRunPolicy.decide(task, now: date(12, 9, 31), calendar: seoul), .wait(next: date(13, 9)))
    }

    func testPausedSchedulesWaitAndResumingSkipsWhatPassed() {
        let task = schedule(nine, createdAt: date(1))
        let paused = ScheduleRunPolicy.setEnabled(false, task, now: date(5, 12))
        XCTAssertEqual(ScheduleRunPolicy.decide(paused, now: date(8, 9, 0), calendar: seoul), .wait(next: nil))
        XCTAssertNil(ScheduleRunPolicy.nextRun(of: paused, now: date(8, 9, 0), calendar: seoul))
        let resumed = ScheduleRunPolicy.setEnabled(true, paused, now: date(8, 12))
        XCTAssertEqual(resumed.state.scanFloor, date(8, 12))
        XCTAssertEqual(ScheduleRunPolicy.decide(resumed, now: date(8, 12, 1), calendar: seoul), .wait(next: date(9, 9)),
                       "The slots passed while paused do not run late")
        XCTAssertEqual(ScheduleRunPolicy.decide(resumed, now: date(9, 9, 0), calendar: seoul),
                       .run(slot: date(9, 9), trigger: .scheduled))
    }

    func testThreeFailedStartsInARowTurnTheScheduleOff() {
        var task = schedule(nine, createdAt: date(1))
        for day in 2...3 {
            task = ScheduleRunPolicy.record(ScheduledTaskRun(slot: date(day, 9), at: date(day, 9), trigger: .scheduled,
                                                             outcome: .failed, failure: "Claude Code is not available"), in: task)
        }
        XCTAssertTrue(task.isEnabled)
        XCTAssertEqual(task.state.consecutiveFailures, 2)
        // A start in between resets the count.
        let recovered = ScheduleRunPolicy.record(
            ScheduledTaskRun(slot: date(4, 9), at: date(4, 9), trigger: .scheduled, outcome: .started), in: task)
        XCTAssertEqual(recovered.state.consecutiveFailures, 0)
        task = ScheduleRunPolicy.record(ScheduledTaskRun(slot: date(4, 9), at: date(4, 9), trigger: .scheduled,
                                                         outcome: .failed, failure: "x"), in: task)
        XCTAssertFalse(task.isEnabled)
        XCTAssertEqual(task.state.stopReason, .repeatedFailures)
        let resumed = ScheduleRunPolicy.setEnabled(true, task, now: date(6))
        XCTAssertTrue(resumed.isEnabled)
        XCTAssertNil(resumed.state.stopReason)
        XCTAssertEqual(resumed.state.consecutiveFailures, 0)
    }

    func testASkipTakesTheSlotWithoutCountingAsARun() {
        let task = schedule(nine, createdAt: date(1))
        let skipped = ScheduleRunPolicy.record(
            ScheduledTaskRun(slot: date(2, 9), at: date(2, 9), trigger: .scheduled, outcome: .skipped,
                             skipReason: .previousRunActive), in: task)
        XCTAssertEqual(skipped.state.lastSlot, date(2, 9))
        XCTAssertNil(skipped.state.lastRunAt)
        XCTAssertEqual(skipped.state.consecutiveFailures, 0)
        XCTAssertEqual(ScheduleRunPolicy.decide(skipped, now: date(2, 9, 1), calendar: seoul), .wait(next: date(3, 9)))
    }

    func testANewTriggerCountsFromTheEditAndAFinishedOneOffMayRunAgain() {
        var task = schedule(.once(date(2, 9)), createdAt: date(1))
        task = ScheduleRunPolicy.record(ScheduledTaskRun(slot: date(2, 9), at: date(2, 9), trigger: .scheduled,
                                                         outcome: .started), in: task)
        var edited = task
        edited.trigger = .once(date(3, 9))
        let result = ScheduleRunPolicy.edit(task, to: edited, now: date(2, 12))
        XCTAssertTrue(result.isEnabled)
        XCTAssertNil(result.state.stopReason)
        XCTAssertEqual(result.state.scanFloor, date(2, 12))
        XCTAssertEqual(result.state.runs.count, 1, "The history stays")
        XCTAssertEqual(ScheduleRunPolicy.decide(result, now: date(3, 9), calendar: seoul),
                       .run(slot: date(3, 9), trigger: .scheduled))
        var renamed = task
        renamed.name = "Renamed"
        XCTAssertEqual(ScheduleRunPolicy.edit(task, to: renamed, now: date(2, 12)).state, task.state,
                       "A change that keeps the trigger keeps where it stands")
    }

    func testTheHistoryKeepsTheLatestFifty() {
        var task = schedule(nine, createdAt: date(1, month: 1))
        for index in 0..<60 {
            task = ScheduleRunPolicy.record(ScheduledTaskRun(slot: nil, at: date(1, month: 1).addingTimeInterval(Double(index)),
                                                             trigger: .manual, outcome: .started), in: task)
        }
        XCTAssertEqual(task.state.runs.count, ScheduleRunPolicy.runHistoryLimit)
        XCTAssertEqual(task.state.runs.first?.at, date(1, month: 1).addingTimeInterval(59), "Newest first")
    }
}
