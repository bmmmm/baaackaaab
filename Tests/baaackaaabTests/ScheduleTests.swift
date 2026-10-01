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

    // ALL three timers carry RunAtLoad + --catch-up now: without the make-up
    // fire, a Mac that is asleep at the scheduled hour never drills / never
    // advances the read-data rotation (the old calendar-only choice silently
    // stalled both coverage guarantees). The gate keeps the login fire cheap.
    func testDrillTimerPlistHasRunAtLoadAndCatchUp() {
        let xml = LaunchdTimer.plistXML(
            label: LaunchdTimer.drillLabel,
            program: ["/usr/local/bin/baaackaaab", "--restore-drill", "--catch-up"],
            schedule: Schedule(times: [(hour: 3, minute: 0)], weekdays: [], dayOfMonth: 1),
            log: "/tmp/baaackaaab.log", runAtLoad: true)
        XCTAssertTrue(xml.contains("<key>RunAtLoad</key>"), xml)
        XCTAssertTrue(xml.contains("<string>--catch-up</string>"), xml)
    }

    // MARK: - nextFireDate (what the dashboard shows as "next run")

    /// A fixed calendar so these assertions don't drift with the machine's zone —
    /// the schedules dashboard's whole value is being exact about when a job fires.
    private var berlin: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return c
    }

    private func at(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        berlin.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    func testDailyFiresLaterTheSameDay() throws {
        let s = Schedule(times: [(hour: 20, minute: 0)], weekdays: [])
        let next = try XCTUnwrap(s.nextFireDate(after: at(2026, 8, 5, 19, 0), calendar: berlin))
        XCTAssertEqual(next, at(2026, 8, 5, 20, 0))
    }

    func testDailyRollsToTomorrowOnceThePassingTimeIsPast() throws {
        // The 20:00 slot has gone by, so the next fire is tomorrow's — the case the
        // dashboard is showing right after an evening backup.
        let s = Schedule(times: [(hour: 20, minute: 0)], weekdays: [])
        let next = try XCTUnwrap(s.nextFireDate(after: at(2026, 8, 5, 21, 0), calendar: berlin))
        XCTAssertEqual(next, at(2026, 8, 6, 20, 0))
    }

    func testSeveralTimesPickTheNextOneNotTheFirst() throws {
        let s = Schedule(times: [(hour: 18, minute: 0), (hour: 9, minute: 0)], weekdays: [])
        let next = try XCTUnwrap(s.nextFireDate(after: at(2026, 8, 5, 12, 0), calendar: berlin))
        XCTAssertEqual(next, at(2026, 8, 5, 18, 0))
    }

    func testWeekdayScheduleSkipsToTheNextScheduledDay() throws {
        // 2026-08-05 is a Wednesday; a Mon-only schedule fires the following Monday.
        let s = Schedule(times: [(hour: 3, minute: 0)], weekdays: [1])
        let next = try XCTUnwrap(s.nextFireDate(after: at(2026, 8, 5, 12, 0), calendar: berlin))
        XCTAssertEqual(next, at(2026, 8, 10, 3, 0))
    }

    func testMonthlyScheduleRollsToNextMonth() throws {
        // Day 1 has passed this month, so the drill's next fire is next month's.
        let s = Schedule(times: [(hour: 3, minute: 0)], weekdays: [], dayOfMonth: 1)
        let next = try XCTUnwrap(s.nextFireDate(after: at(2026, 8, 5, 12, 0), calendar: berlin))
        XCTAssertEqual(next, at(2026, 9, 1, 3, 0))
    }

    func testMonthlyScheduleCrossesTheYearBoundary() throws {
        let s = Schedule(times: [(hour: 3, minute: 0)], weekdays: [], dayOfMonth: 1)
        let next = try XCTUnwrap(s.nextFireDate(after: at(2026, 12, 15, 12, 0), calendar: berlin))
        XCTAssertEqual(next, at(2027, 1, 1, 3, 0))
    }

    func testScheduleWithNoTimesNeverFires() {
        XCTAssertNil(Schedule(times: [], weekdays: []).nextFireDate(after: Date(), calendar: berlin))
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

    // MARK: - Yank / put across the monthly ↔ weekly boundary
    //
    // launchd's monthly `Day` and daily/weekly `Weekday` are different plist keys
    // and each job reads only its own, so a paste across that line is necessarily
    // lossy. What must never happen is a SILENT loss — every case below pins both
    // halves: what carried, and that what could not was reported.

    /// The target's current fields, i.e. what a paste leaves alone when the
    /// source has nothing to say about that dimension.
    private let target = (hour: 9, minute: 30, weekdays: [1, 3], dayOfMonth: 7)

    func testPasteWithinTheSameShapeCarriesEverything() {
        let source = Schedule(times: [(hour: 20, minute: 15)], weekdays: [2, 4])
        let put = Schedule.paste(source, onto: .backup, target: target)
        XCTAssertEqual(put.hour, 20)
        XCTAssertEqual(put.minute, 15)
        XCTAssertEqual(put.weekdays, [2, 4])
        XCTAssertTrue(put.dropped.isEmpty, "a same-shape paste is lossless: \(put.dropped)")
    }

    func testPasteOntoMonthlyKeepsTheTargetsDayAndReportsTheWeekdays() {
        let source = Schedule(times: [(hour: 20, minute: 15)], weekdays: [2, 4])
        let put = Schedule.paste(source, onto: .drill, target: target)
        XCTAssertEqual(put.hour, 20)
        XCTAssertEqual(put.minute, 15)
        XCTAssertEqual(put.dayOfMonth, 7, "the drill's own day-of-month must survive a weekly paste")
        XCTAssertTrue(put.weekdays.isEmpty, "a monthly job ignores Weekday — carrying it would be a silent no-op")
        XCTAssertEqual(put.dropped, ["its weekday list"])
    }

    func testPasteOfADailyScheduleOntoMonthlyReportsTheLostCadence() {
        // "every day" is not a weekday list, but it is still something a monthly
        // job cannot honour — it must not pass as a lossless paste.
        let source = Schedule(times: [(hour: 6, minute: 0)], weekdays: [])
        let put = Schedule.paste(source, onto: .drill, target: target)
        XCTAssertEqual(put.dayOfMonth, 7)
        XCTAssertEqual(put.dropped, ["its every-day cadence"])
    }

    func testPasteOntoWeeklyKeepsTheTargetsWeekdaysAndReportsTheDayOfMonth() {
        let source = Schedule(times: [(hour: 4, minute: 45)], weekdays: [], dayOfMonth: 12)
        let put = Schedule.paste(source, onto: .check, target: target)
        XCTAssertEqual(put.hour, 4)
        XCTAssertEqual(put.minute, 45)
        XCTAssertEqual(put.weekdays, [1, 3], "the check's own weekdays must survive a monthly paste")
        XCTAssertEqual(put.dropped, ["its day-of-month"])
    }

    func testMonthlyToMonthlyCarriesTheDayOfMonth() {
        let source = Schedule(times: [(hour: 4, minute: 45)], weekdays: [], dayOfMonth: 12)
        let put = Schedule.paste(source, onto: .drill, target: target)
        XCTAssertEqual(put.dayOfMonth, 12)
        XCTAssertTrue(put.dropped.isEmpty, "monthly onto monthly is lossless: \(put.dropped)")
    }

    func testMultiTimeSourceCollapsesToItsEarliestAndSaysSo() {
        // Only reachable via repeated --at on the CLI; the editor holds one time.
        let source = Schedule(times: [(hour: 18, minute: 0), (hour: 6, minute: 30)], weekdays: [])
        let put = Schedule.paste(source, onto: .backup, target: target)
        XCTAssertEqual(put.hour, 6, "the earliest time wins, not the first in the array")
        XCTAssertEqual(put.minute, 30)
        XCTAssertEqual(put.dropped, ["1 further time(s)"])
    }

    func testSourceWithNoTimesLeavesTheTargetsClockAlone() {
        // Same rule as the day dimension: what the source cannot express is left
        // as the target had it, rather than silently inventing midnight.
        let put = Schedule.paste(Schedule(times: [], weekdays: [5]), onto: .backup, target: target)
        XCTAssertEqual(put.hour, 9)
        XCTAssertEqual(put.minute, 30)
    }
}
