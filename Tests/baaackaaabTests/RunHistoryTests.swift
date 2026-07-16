import XCTest
@testable import baaackaaab

// The append-only run history is the unattended timer's black box. These tests
// pin the read/write round-trip, newest-first ordering with a limit, and the
// tolerance for a corrupt line (a crash mid-write must not lose the good
// records). The store is relocated via BAAACKAAAB_SUPPORT_DIR so the real
// history is untouched.
final class RunHistoryTests: XCTestCase {

    private var supportDir: URL!

    override func setUp() {
        super.setUp()
        supportDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("baaackaaab-runs-\(UUID().uuidString)", isDirectory: true)
        setenv("BAAACKAAAB_SUPPORT_DIR", supportDir.path, 1)
    }

    override func tearDown() {
        unsetenv("BAAACKAAAB_SUPPORT_DIR")
        supportDir = nil
        super.tearDown()
    }

    private func record(_ tag: String, exit: Int = 0) -> RunRecord {
        RunRecord(runTag: tag, start: Date(timeIntervalSince1970: 1_700_000_000),
                  end: Date(timeIntervalSince1970: 1_700_000_060), exitCode: exit,
                  verified: 5, total: 5, sourceFailures: 0,
                  destinations: [RunRecord.Dest(name: "default", ok: exit == 0, error: nil)])
    }

    func testRecentOnMissingFileIsEmpty() {
        XCTAssertEqual(RunHistory.recent(10).count, 0)
    }

    func testAppendThenRecentRoundTrip() throws {
        try RunHistory.append(record("run-1"))
        let got = RunHistory.recent(10)
        XCTAssertEqual(got.count, 1)
        XCTAssertEqual(got.first?.runTag, "run-1")
        XCTAssertEqual(got.first?.verified, 5)
        XCTAssertEqual(got.first?.destinations.first?.name, "default")
        XCTAssertTrue(got.first?.clean ?? false)
    }

    func testRecentIsNewestFirstAndRespectsLimit() throws {
        for i in 1...5 { try RunHistory.append(record("run-\(i)")) }
        let last3 = RunHistory.recent(3)
        XCTAssertEqual(last3.map { $0.runTag }, ["run-5", "run-4", "run-3"])
    }

    func testRecentToleratesACorruptTrailingLine() throws {
        try RunHistory.append(record("good-1"))
        try RunHistory.append(record("good-2"))
        // Simulate a crash mid-write: a non-JSON fragment appended after the records.
        let fd = open(RunHistory.file.path, O_WRONLY | O_APPEND)
        XCTAssertGreaterThanOrEqual(fd, 0)
        let junk = Data("{ this is not valid json\n".utf8)
        _ = junk.withUnsafeBytes { write(fd, $0.baseAddress, junk.count) }
        close(fd)

        let got = RunHistory.recent(10)
        XCTAssertEqual(got.map { $0.runTag }, ["good-2", "good-1"])   // junk dropped
    }

    // The reader is line-by-line tolerant, not just trailing-tolerant: a corrupt
    // line ANYWHERE (e.g. the O_APPEND interleaving of two writers mangling one
    // record) must still yield every surrounding good record.
    func testRecentToleratesACorruptLineInTheMiddle() throws {
        try RunHistory.append(record("good-1"))
        let fd = open(RunHistory.file.path, O_WRONLY | O_APPEND)
        XCTAssertGreaterThanOrEqual(fd, 0)
        let junk = Data("{ mangled mid-file record\n".utf8)
        _ = junk.withUnsafeBytes { write(fd, $0.baseAddress, junk.count) }
        close(fd)
        try RunHistory.append(record("good-2"))

        let got = RunHistory.recent(10)
        XCTAssertEqual(got.map { $0.runTag }, ["good-2", "good-1"])
    }

    func testCleanReflectsExitCode() throws {
        try RunHistory.append(record("ok", exit: 0))
        try RunHistory.append(record("partial", exit: 2))
        let got = RunHistory.recent(10)
        XCTAssertEqual(got.first(where: { $0.runTag == "ok" })?.clean, true)
        XCTAssertEqual(got.first(where: { $0.runTag == "partial" })?.clean, false)
    }

    // MARK: - Restore-drill records

    private func drillRecord(_ tag: String, exit: Int = 0) -> RunRecord {
        RunRecord(runTag: tag, start: Date(timeIntervalSince1970: 1_700_000_000),
                  end: Date(timeIntervalSince1970: 1_700_000_060), exitCode: exit,
                  verified: 4, total: 5, sourceFailures: 0,
                  destinations: [RunRecord.Dest(name: "default", ok: exit == 0, error: nil)],
                  kind: "drill", bytes: 4096, snapshots: ["a1b2", "c3d4"])
    }

    func testDrillRecordRoundTrip() throws {
        try RunHistory.append(drillRecord("drill", exit: 0))
        let got = try XCTUnwrap(RunHistory.recent(10).first)
        XCTAssertTrue(got.isDrill)
        XCTAssertEqual(got.kind, "drill")
        XCTAssertEqual(got.bytes, 4096)
        XCTAssertEqual(got.snapshots, ["a1b2", "c3d4"])
        XCTAssertEqual(got.verified, 4)
    }

    func testBackupRecordHasNoDrillFields() throws {
        // A backup record encodes without the drill keys (encodeIfPresent), and
        // decodes back with nil kind — so it never counts as a drill.
        try RunHistory.append(record("backup"))
        let got = try XCTUnwrap(RunHistory.recent(1).first)
        XCTAssertNil(got.kind)
        XCTAssertNil(got.bytes)
        XCTAssertNil(got.snapshots)
        XCTAssertFalse(got.isDrill)
    }

    func testLastDrillSkipsBackupsAndCounts() throws {
        try RunHistory.append(record("backup-1"))
        try RunHistory.append(drillRecord("drill-1"))
        try RunHistory.append(record("backup-2"))   // newest overall, but not a drill
        XCTAssertEqual(RunHistory.lastDrill()?.runTag, "drill-1")
        XCTAssertEqual(RunHistory.drillCount(), 1)
    }

    func testLastDrillReturnsNewestDrill() throws {
        try RunHistory.append(drillRecord("drill-old"))
        try RunHistory.append(record("backup"))
        try RunHistory.append(drillRecord("drill-new"))
        XCTAssertEqual(RunHistory.lastDrill()?.runTag, "drill-new")
        XCTAssertEqual(RunHistory.drillCount(), 2)
    }

    func testLastDrillNilWhenOnlyBackups() throws {
        try RunHistory.append(record("backup-1"))
        try RunHistory.append(record("backup-2"))
        XCTAssertNil(RunHistory.lastDrill())
        XCTAssertEqual(RunHistory.drillCount(), 0)
    }
}
