import XCTest
@testable import baaackaaab

// The drill's sample selection is pure logic with real consequences: a broken
// rotation would silently keep re-testing the same source and never cover the
// others, so "every source gets covered over time" would be a lie. And the
// dashboard verdict decides whether a stale/failed restore proof is visible at
// all. Both are pinned here; the I/O-bound restore itself is exercised by the
// live restic tests, not unit tests.
final class RestoreDrillTests: XCTestCase {

    private func snap(_ id: String, tags: [String], paths: [String]) -> ResticBackend.Snapshot {
        ResticBackend.Snapshot(shortID: id, id: id, time: "", hostname: "h", tags: tags, paths: paths)
    }

    // MARK: - rotate

    func testRotateEmptyIsNil() {
        XCTAssertNil(DrillPlan.rotate([Int](), priorDrills: 0))
        XCTAssertNil(DrillPlan.rotate([String](), priorDrills: 7))
    }

    func testRotateCyclesThroughEveryEntry() {
        let xs = ["a", "b", "c"]
        XCTAssertEqual(DrillPlan.rotate(xs, priorDrills: 0), "a")
        XCTAssertEqual(DrillPlan.rotate(xs, priorDrills: 1), "b")
        XCTAssertEqual(DrillPlan.rotate(xs, priorDrills: 2), "c")
        XCTAssertEqual(DrillPlan.rotate(xs, priorDrills: 3), "a")   // wraps
        XCTAssertEqual(DrillPlan.rotate(xs, priorDrills: 4), "b")
    }

    // MARK: - candidates

    func testCandidatesTakeLatestDrivePerFolderAndAllPhotoBatches() {
        // Newest-first, as listSnapshots() returns.
        let snaps = [
            snap("dA2", tags: ["run-3", "drive"], paths: ["/A"]),          // latest for /A
            snap("p1", tags: ["run-3", "photos", "batch-1"], paths: ["/s/1"]),
            snap("p0", tags: ["run-3", "photos", "batch-0"], paths: ["/s/0"]),
            snap("dB", tags: ["run-2", "drive"], paths: ["/B"]),
            snap("dA1", tags: ["run-1", "drive"], paths: ["/A"]),          // older /A → dropped
        ]
        let c = DrillPlan.candidates(from: snaps)
        XCTAssertEqual(c.drive.map { $0.snapshotID }, ["dA2", "dB"])
        XCTAssertEqual(c.drive.map { $0.label }, ["/A", "/B"])
        XCTAssertEqual(c.photos.map { $0.snapshotID }, ["p1", "p0"])
        XCTAssertEqual(c.photos.first?.label, "photos batch-1")
    }

    // MARK: - select (one drive + one photo, rotating independently)

    func testSelectPicksOneDriveOnePhotoRotating() {
        let snaps = [
            snap("dA", tags: ["drive"], paths: ["/A"]),
            snap("dB", tags: ["drive"], paths: ["/B"]),
            snap("p0", tags: ["photos", "batch-0"], paths: ["/s/0"]),
        ]
        XCTAssertEqual(DrillPlan.select(from: snaps, priorDrills: 0).map { $0.snapshotID }, ["dA", "p0"])
        XCTAssertEqual(DrillPlan.select(from: snaps, priorDrills: 1).map { $0.snapshotID }, ["dB", "p0"])
        XCTAssertEqual(DrillPlan.select(from: snaps, priorDrills: 2).map { $0.snapshotID }, ["dA", "p0"])
    }

    func testSelectDriveOnlyWhenNoPhotos() {
        let snaps = [snap("dA", tags: ["drive"], paths: ["/A"])]
        let r = DrillPlan.select(from: snaps, priorDrills: 0)
        XCTAssertEqual(r.map { $0.kind }, ["drive"])
    }

    func testSelectEmptyWhenNoSnapshots() {
        XCTAssertTrue(DrillPlan.select(from: [], priorDrills: 0).isEmpty)
    }

    // MARK: - dashboard thresholds

    private func drill(exit: Int, endDaysAgo: Int, now: Date) -> RunRecord {
        RunRecord(runTag: "drill", start: now,
                  end: now.addingTimeInterval(-Double(endDaysAgo) * 86_400),
                  exitCode: exit, verified: 5, total: 5, sourceFailures: 0,
                  destinations: [RunRecord.Dest(name: "default", ok: exit == 0, error: nil)],
                  kind: "drill", bytes: 100, snapshots: ["abc"])
    }

    func testDashboardNoneWhenNeverRun() {
        XCTAssertEqual(DrillDashboard.line(lastDrill: nil, now: Date()).level, .none)
    }

    func testDashboardOkWhenRecentPass() {
        let now = Date()
        XCTAssertEqual(DrillDashboard.line(lastDrill: drill(exit: 0, endDaysAgo: 3, now: now), now: now).level, .ok)
    }

    func testDashboardStaleWhenPassButOverdue() {
        let now = Date()
        let line = DrillDashboard.line(lastDrill: drill(exit: 0, endDaysAgo: 60, now: now), now: now, overdueDays: 45)
        XCTAssertEqual(line.level, .stale)
    }

    func testDashboardFailedRegardlessOfAge() {
        let now = Date()
        // A fresh but FAILED drill is red — a backup that won't restore isn't a backup.
        XCTAssertEqual(DrillDashboard.line(lastDrill: drill(exit: 2, endDaysAgo: 1, now: now), now: now).level, .failed)
    }

    func testDashboardTextCarriesAgeInDays() {
        let now = Date()
        let line = DrillDashboard.line(lastDrill: drill(exit: 0, endDaysAgo: 5, now: now), now: now)
        XCTAssertTrue(line.text.contains("5d ago"), line.text)
    }
}
