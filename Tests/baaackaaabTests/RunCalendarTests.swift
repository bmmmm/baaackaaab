import XCTest
@testable import baaackaaab

// The coverage calendar's job is making a bad day findable at a glance. Two ways
// it could lie: aggregating a day's runs so a failure disappears behind a success,
// and drifting the grid out of alignment with its own weekday header so a cell is
// read as the wrong day.
final class RunCalendarTests: XCTestCase {

    /// Fixed calendar — a locale whose week starts on Sunday must not shift cells
    /// out from under the literal "Mo Tu … Su" header.
    private var berlin: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return c
    }

    private func at(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 12) -> Date {
        berlin.date(from: DateComponents(year: y, month: mo, day: d, hour: h))!
    }

    private func record(end: Date, exit: Int, kind: String? = nil) -> RunRecord {
        RunRecord(runTag: "t", start: end.addingTimeInterval(-60), end: end, exitCode: exit,
                  verified: 1, total: 1, sourceFailures: 0,
                  destinations: [RunRecord.Dest(name: "default", ok: exit == 0, error: nil)],
                  kind: kind)
    }

    // MARK: - Day aggregation

    func testCleanDayIsOk() {
        let byDay = RunCalendar.statusByDay([record(end: at(2026, 8, 3), exit: 0)], calendar: berlin)
        XCTAssertEqual(byDay[berlin.startOfDay(for: at(2026, 8, 3))], .ok)
    }

    func testFailedDayIsFailed() {
        let byDay = RunCalendar.statusByDay([record(end: at(2026, 8, 3), exit: 2)], calendar: berlin)
        XCTAssertEqual(byDay[berlin.startOfDay(for: at(2026, 8, 3))], .failed)
    }

    func testASucceedingBackupDoesNotHideAFailingCheckOnTheSameDay() {
        // The aggregation that matters: green backup + red check = mixed, not ok.
        // Folding it to ok would make the failure unfindable in the grid.
        let byDay = RunCalendar.statusByDay([
            record(end: at(2026, 8, 3, 20), exit: 0),
            record(end: at(2026, 8, 3, 3), exit: 2, kind: "check"),
        ], calendar: berlin)
        XCTAssertEqual(byDay[berlin.startOfDay(for: at(2026, 8, 3))], .partial)
    }

    func testDaysWithNoRunHaveNoEntry() {
        let byDay = RunCalendar.statusByDay([record(end: at(2026, 8, 3), exit: 0)], calendar: berlin)
        XCTAssertNil(byDay[berlin.startOfDay(for: at(2026, 8, 4))])
    }

    // MARK: - Month layout

    func testMonthStartsEndWithTheCurrentMonth() {
        let starts = RunCalendar.monthStarts(months: 3, end: at(2026, 8, 5), calendar: berlin)
        XCTAssertEqual(starts.count, 3)
        XCTAssertEqual(starts.map { berlin.component(.month, from: $0) }, [6, 7, 8])
    }

    func testMonthStartsCrossTheYearBoundary() {
        let starts = RunCalendar.monthStarts(months: 3, end: at(2026, 1, 15), calendar: berlin)
        XCTAssertEqual(starts.map { berlin.component(.month, from: $0) }, [11, 12, 1])
        XCTAssertEqual(berlin.component(.year, from: starts[0]), 2025)
    }

    func testFirstOfMonthLandsUnderItsWeekdayColumn() {
        // 2026-08-01 is a Saturday, so five padding cells precede it (Mon…Fri).
        let cells = RunCalendar.monthCells(monthStart: at(2026, 8, 1, 0), statusByDay: [:],
                                           now: at(2026, 8, 31), calendar: berlin)
        let first = cells[0]
        XCTAssertEqual(first.prefix(5).map { $0.label }, Array(repeating: "  ", count: 5))
        XCTAssertEqual(first[5].label.trimmingCharacters(in: .whitespaces), "\u{00B7}")
    }

    func testFutureDaysRenderBlankNotAsAMissedRun() {
        // Everything after "now" must be empty: a column of dots to the end of the
        // month reads as a coverage gap that has not happened yet.
        let cells = RunCalendar.monthCells(monthStart: at(2026, 8, 1, 0), statusByDay: [:],
                                           now: at(2026, 8, 5), calendar: berlin)
        let flat = cells.flatMap { $0 }
        let dots = flat.filter { $0.label.contains("\u{00B7}") }
        XCTAssertEqual(dots.count, 5, "only Aug 1–5 are in the past")
    }

    func testDaysBeforeTheHistoryStartsRenderBlank() {
        // A store whose history begins mid-month must not paint the days before it
        // as missed runs — nothing was recorded either way, and a wall of dots
        // reads as a coverage gap to act on.
        let cells = RunCalendar.monthCells(monthStart: at(2026, 8, 1, 0), statusByDay: [:],
                                           now: at(2026, 8, 10), knownFrom: at(2026, 8, 6),
                                           calendar: berlin)
        let dots = cells.flatMap { $0 }.filter { $0.label.contains("\u{00B7}") }
        XCTAssertEqual(dots.count, 5, "only Aug 6–10 were observed")
    }

    func testStatusReachesItsCell() {
        let byDay = RunCalendar.statusByDay([record(end: at(2026, 8, 3), exit: 2)], calendar: berlin)
        let cells = RunCalendar.monthCells(monthStart: at(2026, 8, 1, 0), statusByDay: byDay,
                                           now: at(2026, 8, 31), calendar: berlin)
        let failed = cells.flatMap { $0 }.filter { $0.status == .failed }
        XCTAssertEqual(failed.count, 1)
        XCTAssertTrue(failed[0].label.contains("\u{2717}"), failed[0].label)
    }

    // MARK: - Grid alignment

    func testEveryRowIsExactlyAsWideAsTheWeekdayHeader() {
        // The alignment invariant: cells are joined with a space by the renderer,
        // so a row's plain width must equal the header's or every cell is read as
        // the wrong day.
        let grid = RunCalendar.grid(months: 3, now: at(2026, 8, 5), statusByDay: [:], calendar: berlin)
        for row in grid.rows {
            let width = row.map { $0.label.count }.reduce(0, +) + max(0, row.count - 1)
            XCTAssertEqual(width, grid.weekdayHeader.count, "row width drifted from the header")
        }
        XCTAssertEqual(grid.monthHeader.count, grid.weekdayHeader.count)
    }

    func testGridDropsTrailingAllPaddingWeeks() {
        // February 2026 starts on a Sunday, so it needs the 6th row; a quarter that
        // does not must not pad the panel with an empty week.
        let grid = RunCalendar.grid(months: 3, now: at(2026, 8, 5), statusByDay: [:], calendar: berlin)
        XCTAssertLessThanOrEqual(grid.rows.count, 6)
        XCTAssertFalse(grid.rows.isEmpty)
        let last = grid.rows[grid.rows.count - 1]
        XCTAssertFalse(last.allSatisfy { $0.label.trimmingCharacters(in: .whitespaces).isEmpty })
    }
}
