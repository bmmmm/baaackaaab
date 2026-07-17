import XCTest
@testable import baaackaaab

// The --repo-usage aggregation is pure: it turns a flat `restic ls -l` listing
// into top-level buckets plus a drill-down under the largest one. No process,
// no filesystem — hand-built LsEntry fixtures exercise every shape a real
// `restic ls -l --json` stream can produce (files, dirs, empty).
final class RepoUsageTests: XCTestCase {

    private func file(_ path: String, _ size: Int) -> ResticBackend.LsEntry {
        ResticBackend.LsEntry(name: (path as NSString).lastPathComponent, path: path, type: "file", size: size)
    }

    private func dir(_ path: String) -> ResticBackend.LsEntry {
        ResticBackend.LsEntry(name: (path as NSString).lastPathComponent, path: path, type: "dir", size: 0)
    }

    // MARK: - components (pure helper)

    func testComponentsSplitsAbsolutePathDroppingLeadingEmpty() {
        XCTAssertEqual(RepoUsage.components(of: "/Users/demo/Documents/a.txt"), ["Users", "bma", "Documents", "a.txt"])
    }

    // MARK: - aggregate

    func testAggregateBucketsByTopLevelComponent() {
        let entries = [
            file("/Users/demo/Documents/a.txt", 100),
            file("/Users/demo/Documents/b.txt", 200),
            file("/Volumes/Backup/big.dmg", 5_000),
        ]
        let (top, _, _) = RepoUsage.aggregate(entries: entries)
        XCTAssertEqual(top.count, 2)
        XCTAssertEqual(top[0].path, "Volumes")   // largest first
        XCTAssertEqual(top[0].bytes, 5_000)
        XCTAssertEqual(top[1].path, "Users")
        XCTAssertEqual(top[1].bytes, 300)
    }

    func testAggregateIgnoresDirectoryNodesEntirely() {
        let entries = [
            dir("/Users/demo"),
            file("/Users/demo/x.txt", 42),
        ]
        let (top, _, _) = RepoUsage.aggregate(entries: entries)
        XCTAssertEqual(top.count, 1)
        XCTAssertEqual(top[0].bytes, 42, "a dir node's own size must never be added on top of its contents")
    }

    func testAggregateSecondaryDrillsIntoLargestTopBucketOnly() {
        let entries = [
            file("/Users/alice/photo.jpg", 1_000),
            file("/Users/bob/video.mov", 4_000),
            file("/Volumes/small.txt", 10),
        ]
        let (top, secondaryOf, secondary) = RepoUsage.aggregate(entries: entries)
        XCTAssertEqual(top[0].path, "Users")   // 5000 > 10
        XCTAssertEqual(secondaryOf, "Users")
        XCTAssertEqual(secondary.count, 2)
        XCTAssertEqual(secondary[0].path, "bob")     // largest second-level first
        XCTAssertEqual(secondary[0].bytes, 4_000)
        XCTAssertEqual(secondary[1].path, "alice")
        // The unrelated top bucket ("Volumes") must not leak into the secondary table.
        XCTAssertFalse(secondary.contains { $0.path == "small.txt" })
    }

    func testAggregateEmptyEntriesYieldsEmptyBuckets() {
        let (top, secondaryOf, secondary) = RepoUsage.aggregate(entries: [])
        XCTAssertTrue(top.isEmpty)
        XCTAssertNil(secondaryOf)
        XCTAssertTrue(secondary.isEmpty)
    }

    func testAggregateHandlesFileDirectlyUnderTopLevel() {
        // A file directly under the top-level component (only one level below
        // it, e.g. "/Users/x.txt") has no subdirectory to bucket by, so its own
        // name becomes its second-level bucket — it still must be accounted for
        // somewhere in the drill-down, not silently dropped.
        let entries = [file("/Users/x.txt", 10), file("/Users/nested/y.txt", 20)]
        let (top, secondaryOf, secondary) = RepoUsage.aggregate(entries: entries)
        XCTAssertEqual(top[0].bytes, 30)
        XCTAssertEqual(secondaryOf, "Users")
        XCTAssertEqual(Set(secondary.map(\.path)), Set(["nested", "x.txt"]))
        XCTAssertEqual(secondary.reduce(0) { $0 + $1.bytes }, 30, "every byte in the top bucket must be accounted for in the drill-down")
    }

    func testAggregateTreatsMissingSizeAsZero() {
        let entries = [ResticBackend.LsEntry(name: "a.txt", path: "/Users/a.txt", type: "file", size: nil)]
        let (top, _, _) = RepoUsage.aggregate(entries: entries)
        XCTAssertEqual(top[0].bytes, 0)
    }
}
