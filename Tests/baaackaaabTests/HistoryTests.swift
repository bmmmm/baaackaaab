import XCTest
@testable import baaackaaab

// groupHistoryBySnapshot is the pure core of `--history`: turn raw `find`
// hits (one per matching snapshot, in whatever order restic returns them)
// into one FileVersion per snapshot, ordered newest-first. Pinned here so the
// ordering and dedup rules don't silently drift; the live restic roundtrip
// lives in ResticIntegrationTests.
final class HistoryTests: XCTestCase {

    private func found(_ snapshot: String, size: Int, mtime: String) -> ResticBackend.Found {
        ResticBackend.Found(path: "/src/doc.txt", type: "file", size: size,
                            snapshot: snapshot, mtime: mtime)
    }

    func testGroupsAndOrdersNewestMtimeFirst() {
        let hits = [
            found("aaaa", size: 10, mtime: "2026-01-01T10:00:00+02:00"),
            found("cccc", size: 30, mtime: "2026-01-03T10:00:00+02:00"),
            found("bbbb", size: 20, mtime: "2026-01-02T10:00:00+02:00"),
        ]
        let versions = groupHistoryBySnapshot(hits)
        XCTAssertEqual(versions.map { $0.snapshot }, ["cccc", "bbbb", "aaaa"])
        XCTAssertEqual(versions.map { $0.size }, [30, 20, 10])
    }

    func testEmptyInputYieldsEmptyOutput() {
        XCTAssertTrue(groupHistoryBySnapshot([]).isEmpty)
    }

    /// A literal --include path yields at most one match per snapshot in
    /// practice, but grouping must still degrade sanely if a future glob ever
    /// matched more than one path in the same snapshot: one FileVersion per
    /// snapshot, not one per match.
    func testDuplicateSnapshotCollapsesToOneVersion() {
        let hits = [
            found("aaaa", size: 10, mtime: "2026-01-01T10:00:00+02:00"),
            found("aaaa", size: 99, mtime: "2026-01-01T10:00:00+02:00"),
        ]
        let versions = groupHistoryBySnapshot(hits)
        XCTAssertEqual(versions.count, 1)
        XCTAssertEqual(versions.first?.snapshot, "aaaa")
    }

    func testMissingMtimeSortsLast() {
        let hits = [
            found("aaaa", size: 10, mtime: "2026-01-01T10:00:00+02:00"),
            ResticBackend.Found(path: "/src/doc.txt", type: "file", size: 5,
                                snapshot: "zzzz", mtime: nil),
        ]
        let versions = groupHistoryBySnapshot(hits)
        XCTAssertEqual(versions.map { $0.snapshot }, ["aaaa", "zzzz"])
    }
}
