import XCTest
@testable import baaackaaab

// The "last backup" dashboard line turns overdue at 1.5× the installed cadence,
// and shows age-only when no timer is installed (no cadence to violate). Pure
// verdict, pinned here so a wrong threshold doesn't either hide a stalled backup
// or cry wolf on a backup that merely slipped a few hours.
final class BackupDashboardTests: XCTestCase {

    private let day: TimeInterval = 86_400

    private func backup(endDaysAgo: Double, now: Date) -> RunRecord {
        RunRecord(runTag: "run", start: now, end: now.addingTimeInterval(-endDaysAgo * 86_400),
                  exitCode: 0, verified: 5, total: 5, sourceFailures: 0,
                  destinations: [RunRecord.Dest(name: "default", ok: true, error: nil)])
    }

    func testNoneWhenNoSuccessfulBackup() {
        XCTAssertEqual(BackupDashboard.line(lastSuccess: nil, interval: day, now: Date()).level, .none)
    }

    func testOkWhenWithinCadence() {
        let now = Date()
        let line = BackupDashboard.line(lastSuccess: backup(endDaysAgo: 1, now: now), interval: day, now: now)
        XCTAssertEqual(line.level, .ok)
        XCTAssertTrue(line.text.contains("1d ago"), line.text)
    }

    func testOverdueBeyondOnePointFiveInterval() {
        let now = Date()
        // Daily cadence, last success 2 days ago → past 1.5× → overdue.
        let line = BackupDashboard.line(lastSuccess: backup(endDaysAgo: 2, now: now), interval: day, now: now)
        XCTAssertEqual(line.level, .overdue)
        XCTAssertTrue(line.text.contains("OVERDUE"), line.text)
    }

    func testExactlyAtOnePointFiveIsNotYetOverdue() {
        let now = Date()
        // age == 1.5× interval → strictly-greater threshold keeps it OK.
        let line = BackupDashboard.line(lastSuccess: backup(endDaysAgo: 1.5, now: now), interval: day, now: now)
        XCTAssertEqual(line.level, .ok)
    }

    func testNoIntervalShowsAgeWithoutOverdueJudgment() {
        let now = Date()
        // No timer installed (interval nil): even a very old backup is not "overdue".
        let line = BackupDashboard.line(lastSuccess: backup(endDaysAgo: 30, now: now), interval: nil, now: now)
        XCTAssertEqual(line.level, .ok)
        XCTAssertTrue(line.text.contains("30d ago"), line.text)
        XCTAssertFalse(line.text.contains("OVERDUE"), line.text)
    }

    func testWeeklyCadenceUsesItsWiderThreshold() {
        let now = Date()
        // 7-day cadence: 8 days old is within 1.5× (10.5d) → still OK.
        let ok = BackupDashboard.line(lastSuccess: backup(endDaysAgo: 8, now: now), interval: 7 * day, now: now)
        XCTAssertEqual(ok.level, .ok)
        // 12 days old is past 10.5d → overdue.
        let od = BackupDashboard.line(lastSuccess: backup(endDaysAgo: 12, now: now), interval: 7 * day, now: now)
        XCTAssertEqual(od.level, .overdue)
    }
}
