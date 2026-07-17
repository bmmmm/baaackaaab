import XCTest
@testable import baaackaaab

// The timer schedule is the highest-risk pure logic with no coverage: a wrong
// StartCalendarInterval is a silently missed unattended backup. These tests pin
// the human-readable rendering and the full write→read round-trip — the exact
// XML `--install-timer` writes, parsed back by the same code the TUI uses to
// show the installed schedule.
final class ScheduleTests: XCTestCase {

    // MARK: - Rendering

    func testDescribeDaily() {
        let s = Schedule(times: [(hour: 12, minute: 0)], weekdays: [])
        XCTAssertEqual(s.describe(), "daily at 12:00")
    }

    func testDescribeWeekdaysAndMultipleTimes() {
        let s = Schedule(times: [(hour: 2, minute: 0), (hour: 18, minute: 30)], weekdays: [1, 3, 5])
        XCTAssertEqual(s.describe(), "Mon, Wed, Fri at 02:00, 18:30")
    }

    func testWeekdayNameWrapsSundayForms() {
        // launchd allows both 0 and 7 for Sunday.
        XCTAssertEqual(Schedule.weekdayName(0), "Sun")
        XCTAssertEqual(Schedule.weekdayName(7), "Sun")
        XCTAssertEqual(Schedule.weekdayName(6), "Sat")
    }

    // MARK: - Plist round-trip (write → parse back)

    private func roundTrip(_ schedule: Schedule) -> Schedule? {
        let xml = LaunchdTimer.plistXML(
            label: "io.baaackaaab.backup",
            program: ["/usr/local/bin/baaackaaab", "--run-tag", "scheduled"],
            schedule: schedule, log: "/tmp/baaackaaab.log")
        return LaunchdTimer.schedule(fromPlistData: Data(xml.utf8))
    }

    func testSingleDailyTimeRoundTrips() throws {
        // One (time × day) entry exercises the single-<dict> branch.
        let back = try XCTUnwrap(roundTrip(Schedule(times: [(hour: 9, minute: 15)], weekdays: [])))
        XCTAssertEqual(back.times.map { "\($0.hour):\($0.minute)" }, ["9:15"])
        XCTAssertEqual(back.weekdays, [])
    }

    func testWeekdayScheduleRoundTrips() throws {
        // Several (time × day) entries exercise the <array> branch; times must
        // dedup across days and weekdays must come back sorted.
        let back = try XCTUnwrap(roundTrip(
            Schedule(times: [(hour: 2, minute: 0), (hour: 18, minute: 30)], weekdays: [5, 1, 3])))
        XCTAssertEqual(back.times.map { "\($0.hour):\($0.minute)" }, ["2:0", "18:30"])
        XCTAssertEqual(back.weekdays, [1, 3, 5])
    }

    func testDescribeMonthly() {
        let s = Schedule(times: [(hour: 3, minute: 30)], weekdays: [], dayOfMonth: 15)
        XCTAssertEqual(s.describe(), "monthly on day 15 at 03:30")
    }

    func testMonthlyDrillScheduleRoundTrips() throws {
        // A monthly schedule emits a single <dict> with a Day key (not a Weekday);
        // it must come back with the same day-of-month and no weekdays.
        let back = try XCTUnwrap(roundTrip(
            Schedule(times: [(hour: 3, minute: 0)], weekdays: [], dayOfMonth: 1)))
        XCTAssertEqual(back.times.map { "\($0.hour):\($0.minute)" }, ["3:0"])
        XCTAssertEqual(back.weekdays, [])
        XCTAssertEqual(back.dayOfMonth, 1)
    }

    func testDailyScheduleHasNoDayOfMonth() throws {
        // A daily schedule must not acquire a spurious day-of-month on round-trip.
        let back = try XCTUnwrap(roundTrip(Schedule(times: [(hour: 9, minute: 15)], weekdays: [])))
        XCTAssertNil(back.dayOfMonth)
    }

    // MARK: - intendedInterval (the catch-up / overdue anchor)

    func testDailyIntervalIsOneDay() {
        let s = Schedule(times: [(hour: 12, minute: 0)], weekdays: [])
        XCTAssertEqual(s.intendedInterval(), 86_400, accuracy: 0.5)
    }

    func testWeekdayListIntervalIsLargestGap() {
        // Mon/Wed/Fri: gaps 2,2 and the Fri→Mon wrap of 3 → 3 days.
        let s = Schedule(times: [(hour: 2, minute: 0)], weekdays: [1, 3, 5])
        XCTAssertEqual(s.intendedInterval(), 3 * 86_400, accuracy: 0.5)
    }

    func testSingleWeekdayIntervalIsOneWeek() {
        let s = Schedule(times: [(hour: 2, minute: 0)], weekdays: [3])   // weekly on Wed
        XCTAssertEqual(s.intendedInterval(), 7 * 86_400, accuracy: 0.5)
    }

    func testMaxWeekdayGapHandlesWrapAndSundayForms() {
        XCTAssertEqual(Schedule.maxWeekdayGap([1, 3, 5]), 3)     // Mon,Wed,Fri
        XCTAssertEqual(Schedule.maxWeekdayGap([0, 6]), 6)        // Sun,Sat → 6-day gap Sun→Sat
        XCTAssertEqual(Schedule.maxWeekdayGap([1]), 7)           // single day → weekly
        XCTAssertEqual(Schedule.maxWeekdayGap([]), 1)            // empty → daily fallback
    }

    // MARK: - RunAtLoad (backup timer's boot catch-up)

    func testBackupTimerPlistHasRunAtLoadAndCatchUp() {
        let xml = LaunchdTimer.plistXML(
            label: LaunchdTimer.label,
            program: ["/usr/local/bin/baaackaaab", "--run-tag", "scheduled", "--catch-up"],
            schedule: Schedule(times: [(hour: 12, minute: 0)], weekdays: []),
            log: "/tmp/baaackaaab.log", runAtLoad: true)
        XCTAssertTrue(xml.contains("<key>RunAtLoad</key>"), xml)
        XCTAssertTrue(xml.contains("<string>--catch-up</string>"), xml)
    }

    func testDrillAndCheckTimersHaveNoRunAtLoad() {
        // Only the backup timer opts into RunAtLoad; the drill/check are calendar-only.
        let xml = LaunchdTimer.plistXML(
            label: LaunchdTimer.drillLabel,
            program: ["/usr/local/bin/baaackaaab", "--restore-drill"],
            schedule: Schedule(times: [(hour: 3, minute: 0)], weekdays: [], dayOfMonth: 1),
            log: "/tmp/baaackaaab.log")   // runAtLoad defaults false
        XCTAssertFalse(xml.contains("<key>RunAtLoad</key>"), xml)
    }

    func testScheduleParserRejectsPlistWithoutInterval() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>Label</key><string>x</string></dict></plist>
        """
        XCTAssertNil(LaunchdTimer.schedule(fromPlistData: Data(xml.utf8)))
        XCTAssertNil(LaunchdTimer.schedule(fromPlistData: Data("not a plist".utf8)))
    }
}
