import XCTest
@testable import baaackaaab

// The catch-up staleness gate decides whether a RunAtLoad/boot fire backs up or
// exits quietly. Getting it wrong either skips a genuinely overdue backup (data
// loss risk) or backs up on every login (wasteful). Pure decision, fully pinned;
// the exactly-at-interval edge matters most — it must count as overdue so a due
// daily run is never swallowed.
final class CatchUpTests: XCTestCase {

    private let day: TimeInterval = 86_400

    func testNoHistoryIsOverdueByDedicatedCase() {
        XCTAssertEqual(CatchUp.decide(lastSuccess: nil, interval: day, now: Date()), .noHistory)
    }

    func testFreshWhenYoungerThanInterval() {
        let now = Date()
        let last = now.addingTimeInterval(-day / 2)   // 12h ago, daily schedule
        XCTAssertEqual(CatchUp.decide(lastSuccess: last, interval: day, now: now), .fresh(ageDays: 0))
    }

    func testStaleWhenOlderThanInterval() {
        let now = Date()
        let last = now.addingTimeInterval(-3 * day)   // 3 days ago, daily schedule
        XCTAssertEqual(CatchUp.decide(lastSuccess: last, interval: day, now: now), .overdue(ageDays: 3))
    }

    func testExactlyAtIntervalIsOverdue() {
        // The load-bearing edge: age == interval must NOT be fresh, or a punctual
        // daily calendar run gets skipped.
        let now = Date()
        let last = now.addingTimeInterval(-day)
        XCTAssertEqual(CatchUp.decide(lastSuccess: last, interval: day, now: now), .overdue(ageDays: 1))
    }

    func testJustUnderIntervalIsFresh() {
        let now = Date()
        let last = now.addingTimeInterval(-day + 60)   // 1 minute short of a day
        if case .fresh = CatchUp.decide(lastSuccess: last, interval: day, now: now) { }
        else { XCTFail("just under the interval should be fresh") }
    }

    func testWeeklyScheduleUsesItsWiderInterval() {
        // A 3-day interval (mon/wed/fri): a 2-day-old backup is still fresh.
        let now = Date()
        let last = now.addingTimeInterval(-2 * day)
        XCTAssertEqual(CatchUp.decide(lastSuccess: last, interval: 3 * day, now: now), .fresh(ageDays: 2))
        // …but 3 days old (the Fri→Mon gap) is due.
        let older = now.addingTimeInterval(-3 * day)
        XCTAssertEqual(CatchUp.decide(lastSuccess: older, interval: 3 * day, now: now), .overdue(ageDays: 3))
    }
}
