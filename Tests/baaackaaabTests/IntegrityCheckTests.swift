import XCTest
@testable import baaackaaab

// The rotating integrity check re-reads 1/t of the pack data per run and advances
// the slice so that, over t runs, every pack is re-hashed once. A broken rotation
// would silently keep re-reading the same eighth forever — the bit-rot coverage
// claim would be a lie. The rotation arithmetic, the dashboard verdict, and the
// timer's plist wiring are pinned here; the restic check itself is exercised by
// the live restic tests.
final class IntegrityCheckTests: XCTestCase {

    // MARK: - rotation arithmetic

    func testFirstRunStartsAtSliceOne() {
        XCTAssertEqual(RotatingCheck.nextSlice(lastSlice: nil), 1)
    }

    func testAdvancesByOne() {
        XCTAssertEqual(RotatingCheck.nextSlice(lastSlice: 1), 2)
        XCTAssertEqual(RotatingCheck.nextSlice(lastSlice: 2), 3)
        XCTAssertEqual(RotatingCheck.nextSlice(lastSlice: 7), 8)
    }

    func testWrapsAfterLastSlice() {
        XCTAssertEqual(RotatingCheck.nextSlice(lastSlice: 8), 1)   // 8/8 → 1/8
    }

    func testCoversEverySliceOverTRuns() {
        // Simulate t consecutive runs and assert each 1…t slice is hit exactly once.
        var last: Int? = nil
        var seen: [Int] = []
        for _ in 0..<RotatingCheck.slices {
            let s = RotatingCheck.nextSlice(lastSlice: last)
            seen.append(s)
            last = s
        }
        XCTAssertEqual(seen.sorted(), Array(1...RotatingCheck.slices))
        // The very next run wraps back to the first slice it started with.
        XCTAssertEqual(RotatingCheck.nextSlice(lastSlice: last), seen.first)
    }

    func testClampsOutOfRangeStoredSlice() {
        // A hand-mangled history must never yield an invalid restic subset.
        XCTAssertTrue((1...RotatingCheck.slices).contains(RotatingCheck.nextSlice(lastSlice: 0)))
        XCTAssertTrue((1...RotatingCheck.slices).contains(RotatingCheck.nextSlice(lastSlice: 99)))
        XCTAssertTrue((1...RotatingCheck.slices).contains(RotatingCheck.nextSlice(lastSlice: -3)))
    }

    func testSubsetSpecFormat() {
        XCTAssertEqual(RotatingCheck.subsetSpec(slice: 3), "3/8")
        XCTAssertEqual(RotatingCheck.subsetSpec(slice: 1, slices: 10), "1/10")
    }

    // MARK: - dashboard line

    private func check(exit: Int, slice: Int?, endDaysAgo: Int, now: Date) -> RunRecord {
        RunRecord(runTag: "check", start: now,
                  end: now.addingTimeInterval(-Double(endDaysAgo) * 86_400),
                  exitCode: exit, verified: exit == 0 ? 1 : 0, total: 1, sourceFailures: 0,
                  destinations: [RunRecord.Dest(name: "default", ok: exit == 0, error: nil)],
                  kind: "check", slice: slice)
    }

    func testDashboardNoneWhenNeverRun() {
        XCTAssertEqual(CheckDashboard.line(lastCheck: nil, now: Date()).level, .none)
    }

    func testDashboardOkCarriesSliceAndAge() {
        let now = Date()
        let line = CheckDashboard.line(lastCheck: check(exit: 0, slice: 3, endDaysAgo: 2, now: now), now: now)
        XCTAssertEqual(line.level, .ok)
        XCTAssertTrue(line.text.contains("3/8"), line.text)
        XCTAssertTrue(line.text.contains("2d ago"), line.text)
    }

    func testDashboardFailedIsRed() {
        let now = Date()
        let line = CheckDashboard.line(lastCheck: check(exit: 2, slice: 5, endDaysAgo: 1, now: now), now: now)
        XCTAssertEqual(line.level, .failed)
        XCTAssertTrue(line.text.contains("FAILED"), line.text)
    }

    // MARK: - check-timer plist wiring

    func testCheckTimerPlistHasRotatingProgramAndOwnLabel() {
        let xml = LaunchdTimer.plistXML(
            label: LaunchdTimer.checkLabel,
            program: ["/usr/local/bin/baaackaaab", "--verify-repo", "--rotate-read-data"],
            schedule: Schedule(times: [(hour: 4, minute: 0)], weekdays: [1, 4]),
            log: "/tmp/baaackaaab.log")
        XCTAssertTrue(xml.contains("<string>io.baaackaaab.check</string>"), xml)
        XCTAssertTrue(xml.contains("<string>--verify-repo</string>"), xml)
        XCTAssertTrue(xml.contains("<string>--rotate-read-data</string>"), xml)
        // The check timer's own label must differ from the backup and drill timers.
        XCTAssertNotEqual(LaunchdTimer.checkLabel, LaunchdTimer.label)
        XCTAssertNotEqual(LaunchdTimer.checkLabel, LaunchdTimer.drillLabel)
    }

    func testCheckTimerScheduleRoundTrips() throws {
        // A daily/weekly (not monthly) schedule, like the backup timer.
        let xml = LaunchdTimer.plistXML(
            label: LaunchdTimer.checkLabel,
            program: ["/usr/local/bin/baaackaaab", "--verify-repo", "--rotate-read-data"],
            schedule: Schedule(times: [(hour: 4, minute: 0)], weekdays: [1, 4]),
            log: "/tmp/baaackaaab.log")
        let back = try XCTUnwrap(LaunchdTimer.schedule(fromPlistData: Data(xml.utf8)))
        XCTAssertEqual(back.times.map { "\($0.hour):\($0.minute)" }, ["4:0"])
        XCTAssertEqual(back.weekdays, [1, 4])
        XCTAssertNil(back.dayOfMonth)
    }
}
