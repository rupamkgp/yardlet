import Foundation
import XCTest
@testable import NativeHarnessClient

/// When a schedule's slots fall: wall-clock times across daylight saving time, month ends and time
/// zones, elapsed-hour intervals, weekday filters and one-offs. Pure date math; nothing runs.
final class ScheduleTriggerTests: XCTestCase {
    private func calendar(_ zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        calendar.firstWeekday = 2
        return calendar
    }

    private func date(_ calendar: Calendar, _ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func local(_ date: Date?, _ calendar: Calendar) -> String {
        guard let date else { return "nil" }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm ZZZZZ"
        return formatter.string(from: date)
    }

    // MARK: - Daily and weekly

    func testADailyTimeComesNextTodayOrTomorrow() {
        let seoul = calendar("Asia/Seoul")
        let trigger = ScheduleTrigger.daily(ScheduleTime(hour: 9, minute: 30))
        XCTAssertEqual(local(trigger.nextSlot(after: date(seoul, 2026, 10, 17, 8, 0), calendar: seoul), seoul),
                       "2026-10-17 09:30 +09:00")
        XCTAssertEqual(local(trigger.nextSlot(after: date(seoul, 2026, 10, 17, 9, 30), calendar: seoul), seoul),
                       "2026-10-18 09:30 +09:00", "The slot itself is not after itself")
        XCTAssertEqual(local(trigger.latestSlot(after: date(seoul, 2026, 10, 10), notAfter: date(seoul, 2026, 10, 17, 9, 29),
                                                calendar: seoul), seoul),
                       "2026-10-16 09:30 +09:00")
        XCTAssertNil(trigger.latestSlot(after: date(seoul, 2026, 10, 16, 9, 30), notAfter: date(seoul, 2026, 10, 17, 9, 29),
                                        calendar: seoul), "The lower bound is exclusive")
    }

    func testWeekdaysSkipTheWeekendBothWays() {
        let seoul = calendar("Asia/Seoul")
        let trigger = ScheduleTrigger.weekly(days: ScheduleWeekday.weekdays, time: ScheduleTime(hour: 9, minute: 0))
        // 2026-10-16 is a Friday.
        XCTAssertEqual(local(trigger.nextSlot(after: date(seoul, 2026, 10, 16, 10), calendar: seoul), seoul),
                       "2026-10-19 09:00 +09:00", "Friday after nine runs next on Monday")
        XCTAssertEqual(local(trigger.latestSlot(after: date(seoul, 2026, 10, 1), notAfter: date(seoul, 2026, 10, 19, 8),
                                                calendar: seoul), seoul),
                       "2026-10-16 09:00 +09:00", "Over the weekend the latest slot is Friday's")
        let mondays = ScheduleTrigger.weekly(days: [.monday, .wednesday], time: ScheduleTime(hour: 7, minute: 15))
        XCTAssertEqual(local(mondays.nextSlot(after: date(seoul, 2026, 10, 19, 7, 15), calendar: seoul), seoul),
                       "2026-10-21 07:15 +09:00")
        XCTAssertNil(ScheduleTrigger.weekly(days: [], time: ScheduleTime(hour: 7, minute: 0))
            .nextSlot(after: date(seoul, 2026, 10, 19), calendar: seoul))
        XCTAssertFalse(ScheduleTrigger.weekly(days: [], time: ScheduleTime(hour: 7, minute: 0)).isValid)
    }

    func testMonthAndYearEnds() {
        let seoul = calendar("Asia/Seoul")
        let daily = ScheduleTrigger.daily(ScheduleTime(hour: 23, minute: 59))
        XCTAssertEqual(local(daily.nextSlot(after: date(seoul, 2026, 10, 31, 23, 59), calendar: seoul), seoul),
                       "2026-11-01 23:59 +09:00")
        XCTAssertEqual(local(daily.nextSlot(after: date(seoul, 2026, 12, 31, 23, 59), calendar: seoul), seoul),
                       "2027-01-01 23:59 +09:00")
        let leap = ScheduleTrigger.daily(ScheduleTime(hour: 0, minute: 0))
        XCTAssertEqual(local(leap.nextSlot(after: date(seoul, 2028, 2, 28, 12), calendar: seoul), seoul),
                       "2028-02-29 00:00 +09:00")
        XCTAssertEqual(local(daily.latestSlot(after: date(seoul, 2026, 2, 27), notAfter: date(seoul, 2026, 3, 1, 1),
                                              calendar: seoul), seoul),
                       "2026-02-28 23:59 +09:00")
    }

    // MARK: - Daylight saving time

    func testATimeTheClockSkipsRunsRightAfterTheGapAndTheNextDayAsUsual() {
        let la = calendar("America/Los_Angeles")
        let trigger = ScheduleTrigger.daily(ScheduleTime(hour: 2, minute: 30))
        // 2026-03-08 02:00 PST becomes 03:00 PDT: 02:30 does not exist.
        let slot = trigger.nextSlot(after: date(la, 2026, 3, 8, 0, 0), calendar: la)
        XCTAssertEqual(local(slot, la), "2026-03-08 03:00 -07:00")
        XCTAssertEqual(local(trigger.nextSlot(after: slot!, calendar: la), la), "2026-03-09 02:30 -07:00")
        XCTAssertEqual(local(trigger.latestSlot(after: date(la, 2026, 3, 8, 0, 0), notAfter: date(la, 2026, 3, 8, 4, 0),
                                                calendar: la), la), "2026-03-08 03:00 -07:00")
    }

    func testATimeTheClockRepeatsRunsOnce() {
        let la = calendar("America/Los_Angeles")
        let trigger = ScheduleTrigger.daily(ScheduleTime(hour: 1, minute: 30))
        // 2026-11-01 02:00 PDT goes back to 01:00 PST: 01:30 happens twice.
        let first = trigger.nextSlot(after: date(la, 2026, 11, 1, 0, 0), calendar: la)
        XCTAssertEqual(local(first, la), "2026-11-01 01:30 -07:00", "The first of the two")
        XCTAssertEqual(local(trigger.nextSlot(after: first!, calendar: la), la), "2026-11-02 01:30 -08:00",
                       "The repeated 01:30 is not a second slot")
        let secondOccurrence = first!.addingTimeInterval(3_600)
        XCTAssertNil(trigger.latestSlot(after: first!, notAfter: secondOccurrence.addingTimeInterval(60), calendar: la))
    }

    func testAWallClockTimeStaysAtItsHourAcrossTheChange() {
        let la = calendar("America/Los_Angeles")
        let trigger = ScheduleTrigger.daily(ScheduleTime(hour: 9, minute: 0))
        let before = trigger.nextSlot(after: date(la, 2026, 3, 7, 10), calendar: la)!
        let after = trigger.nextSlot(after: before, calendar: la)!
        XCTAssertEqual(local(before, la), "2026-03-08 09:00 -07:00")
        XCTAssertEqual(local(after, la), "2026-03-09 09:00 -07:00")
        XCTAssertEqual(after.timeIntervalSince(before), 24 * 3_600)
        let saturday = trigger.nextSlot(after: date(la, 2026, 3, 6, 10), calendar: la)!
        XCTAssertEqual(before.timeIntervalSince(saturday), 23 * 3_600, "The short day is 23 hours")
    }

    func testAnIntervalCountsElapsedHoursAcrossTheChange() {
        let la = calendar("America/Los_Angeles")
        let anchor = date(la, 2026, 3, 7, 21, 0)
        let trigger = ScheduleTrigger.interval(hours: 3, anchor: anchor, days: [])
        let slot = trigger.nextSlot(after: date(la, 2026, 3, 8, 0, 30), calendar: la)
        XCTAssertEqual(local(slot, la), "2026-03-08 04:00 -07:00", "21:00 + 6 elapsed hours over the skipped hour")
        let daily = ScheduleTrigger.interval(hours: 24, anchor: date(la, 2026, 3, 7, 9, 0), days: [])
        XCTAssertEqual(local(daily.nextSlot(after: date(la, 2026, 3, 7, 9, 0), calendar: la), la), "2026-03-08 10:00 -07:00")
    }

    func testATimeZoneChangeKeepsTheWallClockTime() {
        let seoul = calendar("Asia/Seoul")
        let london = calendar("Europe/London")
        let trigger = ScheduleTrigger.daily(ScheduleTime(hour: 9, minute: 0))
        let now = date(seoul, 2026, 10, 17, 6, 0)
        XCTAssertEqual(local(trigger.nextSlot(after: now, calendar: seoul), seoul), "2026-10-17 09:00 +09:00")
        XCTAssertEqual(local(trigger.nextSlot(after: now, calendar: london), london), "2026-10-17 09:00 +01:00",
                       "After flying to London the schedule runs at nine there")
    }

    // MARK: - Intervals and one-offs

    func testAnIntervalRunsFromItsAnchorOnChosenDays() {
        let seoul = calendar("Asia/Seoul")
        let anchor = date(seoul, 2026, 10, 16, 10, 0)
        let trigger = ScheduleTrigger.interval(hours: 3, anchor: anchor, days: [])
        XCTAssertEqual(local(trigger.nextSlot(after: date(seoul, 2026, 10, 16, 8, 0), calendar: seoul), seoul),
                       "2026-10-16 10:00 +09:00", "Before the anchor the anchor is first")
        XCTAssertEqual(local(trigger.nextSlot(after: date(seoul, 2026, 10, 16, 14, 0), calendar: seoul), seoul),
                       "2026-10-16 16:00 +09:00")
        XCTAssertEqual(local(trigger.latestSlot(after: anchor, notAfter: date(seoul, 2026, 10, 16, 18, 59), calendar: seoul), seoul),
                       "2026-10-16 16:00 +09:00")
        // Weekdays only: Friday 22:00 is followed by Monday 01:00.
        let weekdays = ScheduleTrigger.interval(hours: 3, anchor: anchor, days: ScheduleWeekday.weekdays)
        XCTAssertEqual(local(weekdays.nextSlot(after: date(seoul, 2026, 10, 16, 22, 0), calendar: seoul), seoul),
                       "2026-10-19 01:00 +09:00")
        XCTAssertEqual(local(weekdays.latestSlot(after: anchor, notAfter: date(seoul, 2026, 10, 18, 12), calendar: seoul), seoul),
                       "2026-10-16 22:00 +09:00")
        XCTAssertFalse(ScheduleTrigger.interval(hours: 0, anchor: anchor, days: []).isValid, "At most once an hour")
        XCTAssertTrue(ScheduleTrigger.interval(hours: 1, anchor: anchor, days: []).isValid)
    }

    func testAOneOffHasOneSlot() {
        let seoul = calendar("Asia/Seoul")
        let moment = date(seoul, 2026, 10, 17, 14, 30)
        let trigger = ScheduleTrigger.once(moment)
        XCTAssertEqual(trigger.nextSlot(after: date(seoul, 2026, 10, 17), calendar: seoul), moment)
        XCTAssertNil(trigger.nextSlot(after: moment, calendar: seoul))
        XCTAssertEqual(trigger.latestSlot(after: date(seoul, 2026, 10, 17), notAfter: moment, calendar: seoul), moment)
        XCTAssertNil(trigger.latestSlot(after: moment, notAfter: moment.addingTimeInterval(60), calendar: seoul))
        XCTAssertFalse(trigger.isRecurring)
    }

    func testTriggersRoundTripThroughTheirStoredForm() throws {
        let anchor = Date(timeIntervalSince1970: 1_792_000_000.25)
        let triggers: [ScheduleTrigger] = [
            .daily(ScheduleTime(hour: 9, minute: 5)),
            .weekly(days: [.monday, .friday], time: ScheduleTime(hour: 22, minute: 0)),
            .interval(hours: 6, anchor: anchor, days: [.saturday]),
            .interval(hours: 1, anchor: anchor, days: []),
            .once(anchor),
        ]
        for trigger in triggers {
            let data = try JSONEncoder().encode(trigger)
            XCTAssertEqual(try JSONDecoder().decode(ScheduleTrigger.self, from: data), trigger)
        }
        let text = String(decoding: try JSONEncoder().encode(triggers[1]), as: UTF8.self)
        XCTAssertTrue(text.contains("\"time\":\"22:00\""), text)
        XCTAssertTrue(text.contains("\"days\":[2,6]"), text)
    }
}
