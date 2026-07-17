import XCTest
@testable import baaackaaab

// status.json is a STABLE PUBLIC CONTRACT (unlike runs.ndjson, which is free to
// change shape) — these tests pin its exact key set so an accidental rename/
// removal fails loudly, cover the pure build() logic against fake RunRecords,
// the atomic-write behavior (a failed write must never corrupt the previous
// file), the Prometheus textfile's formatting/escaping, and the new
// --set-prom-textfile config + flag wiring.
final class StatusExportTests: XCTestCase {

    private var supportDir: URL!

    override func setUp() {
        super.setUp()
        supportDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("baaackaaab-status-\(UUID().uuidString)", isDirectory: true)
        setenv("BAAACKAAAB_SUPPORT_DIR", supportDir.path, 1)
    }

    override func tearDown() {
        // Undo any permission lockdown a test applied, so cleanup can actually remove it.
        if let supportDir, FileManager.default.fileExists(atPath: supportDir.path) {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: supportDir.path)
            try? FileManager.default.removeItem(at: supportDir)
        }
        unsetenv("BAAACKAAAB_SUPPORT_DIR")
        supportDir = nil
        super.tearDown()
    }

    private func record(_ tag: String, exit: Int = 0, dataAdded: Int64? = nil,
                        bytesProcessed: Int64? = nil, end: Date = Date(timeIntervalSince1970: 1_700_000_060)) -> RunRecord {
        RunRecord(runTag: tag, start: Date(timeIntervalSince1970: 1_700_000_000), end: end,
                  exitCode: exit, verified: 5, total: 6, sourceFailures: 1,
                  destinations: [RunRecord.Dest(name: "default", ok: exit == 0, error: exit == 0 ? nil : "boom",
                                                dataAdded: dataAdded, bytesProcessed: bytesProcessed)])
    }

    private func drillRecord(ok: Bool = true, end: Date = Date(timeIntervalSince1970: 1_700_100_000)) -> RunRecord {
        RunRecord(runTag: "drill", start: end.addingTimeInterval(-60), end: end,
                  exitCode: ok ? 0 : 2, verified: ok ? 2 : 1, total: 2, sourceFailures: 0,
                  destinations: [RunRecord.Dest(name: "default", ok: ok, error: nil)],
                  kind: "drill", bytes: 4096, snapshots: ["a1b2", "c3d4"])
    }

    // MARK: - outcome() mapping

    func testOutcomeMapsKnownExitCodes() {
        XCTAssertEqual(StatusExport.outcome(exitCode: 0), "ok")
        XCTAssertEqual(StatusExport.outcome(exitCode: 2), "partial")
        XCTAssertEqual(StatusExport.outcome(exitCode: 130), "cancelled")
        XCTAssertEqual(StatusExport.outcome(exitCode: 1), "failed")
        XCTAssertEqual(StatusExport.outcome(exitCode: 99), "failed")   // no other producer today, but never crashes
    }

    // MARK: - build() — pure composition from fake RunRecords

    func testBuildWithNoHistoryOmitsLastRunAndDestinations() {
        let snap = StatusExport.build(records: [], lastDrill: nil, repoSizeBytes: nil, quotaBytes: nil)
        XCTAssertEqual(snap.schemaVersion, 1)
        XCTAssertNil(snap.lastRun)
        XCTAssertTrue(snap.destinations.isEmpty)
        XCTAssertNil(snap.repo)
        XCTAssertNil(snap.lastDrill)
    }

    func testBuildTakesNewestNonDrillRecordAsLastRun() {
        let records = [record("run-2", exit: 2), drillRecord(), record("run-1", exit: 0)]   // newest-first, like RunHistory.recent
        let snap = StatusExport.build(records: records, lastDrill: nil, repoSizeBytes: nil, quotaBytes: nil)
        XCTAssertEqual(snap.lastRun?.tag, "run-2")
        XCTAssertEqual(snap.lastRun?.outcome, "partial")
        XCTAssertEqual(snap.lastRun?.verified, 5)
        XCTAssertEqual(snap.lastRun?.total, 6)
        XCTAssertEqual(snap.lastRun?.sourceFailures, 1)
    }

    func testBuildOmitsChurnMetricsWhenAbsentButKeepsThemWhenPresent() {
        let withMetrics = record("with", dataAdded: 1024, bytesProcessed: 2048)
        let snap1 = StatusExport.build(records: [withMetrics], lastDrill: nil, repoSizeBytes: nil, quotaBytes: nil)
        XCTAssertEqual(snap1.destinations.first?.dataAdded, 1024)
        XCTAssertEqual(snap1.destinations.first?.bytesProcessed, 2048)

        let withoutMetrics = record("without")
        let snap2 = StatusExport.build(records: [withoutMetrics], lastDrill: nil, repoSizeBytes: nil, quotaBytes: nil)
        XCTAssertNil(snap2.destinations.first?.dataAdded)
        XCTAssertNil(snap2.destinations.first?.bytesProcessed)
    }

    func testBuildRepoBlockOnlyWhenSizeKnown() {
        let noSize = StatusExport.build(records: [], lastDrill: nil, repoSizeBytes: nil, quotaBytes: 1_000_000)
        XCTAssertNil(noSize.repo)

        let known = StatusExport.build(records: [], lastDrill: nil, repoSizeBytes: 500_000, quotaBytes: 1_000_000)
        XCTAssertEqual(known.repo?.sizeBytes, 500_000)
        XCTAssertEqual(known.repo?.quotaBytes, 1_000_000)
        XCTAssertEqual(known.repo?.quotaFraction ?? 0, 0.5, accuracy: 0.0001)

        let noQuota = StatusExport.build(records: [], lastDrill: nil, repoSizeBytes: 500_000, quotaBytes: nil)
        XCTAssertEqual(noQuota.repo?.sizeBytes, 500_000)
        XCTAssertNil(noQuota.repo?.quotaBytes)
        XCTAssertNil(noQuota.repo?.quotaFraction)
    }

    func testBuildDrillBlockCarriesSnapshotCountNotIds() {
        let snap = StatusExport.build(records: [], lastDrill: drillRecord(ok: true), repoSizeBytes: nil, quotaBytes: nil)
        XCTAssertEqual(snap.lastDrill?.ok, true)
        XCTAssertEqual(snap.lastDrill?.bytes, 4096)
        XCTAssertEqual(snap.lastDrill?.snapshotCount, 2)
    }

    func testBuildDrillFailureReflectsCleanFalse() {
        let snap = StatusExport.build(records: [], lastDrill: drillRecord(ok: false), repoSizeBytes: nil, quotaBytes: nil)
        XCTAssertEqual(snap.lastDrill?.ok, false)
    }

    // MARK: - Stable key pinning (the public-contract guarantee)

    func testStatusJSONTopLevelKeysAreStable() throws {
        let snap = StatusExport.build(
            records: [record("run-1", dataAdded: 10, bytesProcessed: 20)],
            lastDrill: drillRecord(), repoSizeBytes: 100, quotaBytes: 200)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let data = try enc.encode(snap)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(Set(json.keys),
                       Set(["schema_version", "generated_at", "last_run", "destinations", "repo", "last_drill"]))

        let lastRun = json["last_run"] as! [String: Any]
        XCTAssertEqual(Set(lastRun.keys),
                       Set(["tag", "start", "end", "exit_code", "outcome", "verified", "total", "source_failures"]))

        let dest = (json["destinations"] as! [[String: Any]]).first!
        XCTAssertEqual(Set(dest.keys), Set(["name", "ok", "data_added", "bytes_processed"]))

        let repo = json["repo"] as! [String: Any]
        XCTAssertEqual(Set(repo.keys), Set(["size_bytes", "quota_bytes", "quota_fraction"]))

        let drill = json["last_drill"] as! [String: Any]
        XCTAssertEqual(Set(drill.keys), Set(["time", "ok", "bytes", "snapshots"]))
    }

    // A destination with no churn metrics omits those keys entirely rather than
    // emitting null — same forward-compat discipline as RunRecord.Dest.
    func testDestinationOmitsChurnKeysWhenAbsent() throws {
        let snap = StatusExport.build(records: [record("run-1")], lastDrill: nil, repoSizeBytes: nil, quotaBytes: nil)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let data = try enc.encode(snap)
        let json = String(data: data, encoding: .utf8)!
        XCTAssertFalse(json.contains("data_added"))
        XCTAssertFalse(json.contains("bytes_processed"))
    }

    // MARK: - Atomic write + round trip (via BAAACKAAAB_SUPPORT_DIR)

    func testWriteThenReadRoundTripsThroughDisk() throws {
        // ISO-8601 (whole-second resolution) is lossy for sub-second precision, so
        // generatedAt must be second-aligned for an exact post-round-trip Equatable
        // comparison — Date() itself would spuriously fail this on fractional seconds.
        let now = Date(timeIntervalSince1970: 1_700_500_000)
        let snap = StatusExport.build(records: [record("run-1", dataAdded: 5, bytesProcessed: 9)],
                                      lastDrill: drillRecord(), repoSizeBytes: 42, quotaBytes: 84, now: now)
        try StatusExport.write(snap)
        let data = try Data(contentsOf: StatusExport.file)
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let got = try dec.decode(StatusSnapshot.self, from: data)
        XCTAssertEqual(got, snap)
    }

    func testWriteCreatesFile0600() throws {
        try StatusExport.write(StatusExport.build(records: [], lastDrill: nil, repoSizeBytes: nil, quotaBytes: nil))
        let attrs = try FileManager.default.attributesOfItem(atPath: StatusExport.file.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(perms, 0o600)
    }

    // A failed write (the support dir made read-only after a first successful
    // write) must never corrupt or truncate the previous good file — the
    // temp-then-rename pattern means the failed write never even reaches the
    // real target.
    func testFailedWriteLeavesPreviousStatusJSONIntact() throws {
        let first = StatusExport.build(records: [record("good")], lastDrill: nil, repoSizeBytes: nil, quotaBytes: nil)
        try StatusExport.write(first)
        let before = try Data(contentsOf: StatusExport.file)

        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: supportDir.path)
        let second = StatusExport.build(records: [record("would-be-newer")], lastDrill: nil, repoSizeBytes: nil, quotaBytes: nil)
        XCTAssertThrowsError(try StatusExport.write(second))

        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: supportDir.path)
        let after = try Data(contentsOf: StatusExport.file)
        XCTAssertEqual(before, after)

        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let got = try dec.decode(StatusSnapshot.self, from: after)
        XCTAssertEqual(got.lastRun?.tag, "good")
    }

    // exportAfterRun is best-effort: a write failure must not throw/crash the
    // caller (it's called from deep inside a real backup run).
    func testExportAfterRunNeverThrowsEvenWhenUnwritable() throws {
        try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o500])
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: supportDir.path) }
        let snap = StatusExport.exportAfterRun(repoSizeBytes: nil, quotaBytes: nil, promTextfileDir: nil)
        XCTAssertNotNil(snap)   // build() still succeeds; only the write is best-effort
    }

    // MARK: - Prometheus textfile: pure rendering

    func testRenderEmitsHelpAndTypeLines() {
        let snap = StatusExport.build(records: [record("run-1")], lastDrill: nil, repoSizeBytes: nil, quotaBytes: nil)
        let text = PrometheusTextfile.render(snap)
        XCTAssertTrue(text.contains("# HELP baaackaaab_last_run_timestamp_seconds"))
        XCTAssertTrue(text.contains("# TYPE baaackaaab_last_run_timestamp_seconds gauge"))
    }

    func testRenderLastRunGauges() {
        let end = Date(timeIntervalSince1970: 1_700_000_060)
        let snap = StatusExport.build(records: [record("run-1", exit: 0, end: end)], lastDrill: nil,
                                      repoSizeBytes: nil, quotaBytes: nil)
        let text = PrometheusTextfile.render(snap)
        XCTAssertTrue(text.contains("baaackaaab_last_run_timestamp_seconds 1700000060"))
        XCTAssertTrue(text.contains("baaackaaab_last_run_success 1"))
        XCTAssertTrue(text.contains("baaackaaab_last_run_exit_code 0"))
        XCTAssertTrue(text.contains("baaackaaab_verified_files 5"))
        XCTAssertTrue(text.contains("baaackaaab_total_files 6"))
    }

    func testRenderLastRunSuccessIsZeroOnNonZeroExit() {
        let snap = StatusExport.build(records: [record("run-1", exit: 2)], lastDrill: nil, repoSizeBytes: nil, quotaBytes: nil)
        let text = PrometheusTextfile.render(snap)
        XCTAssertTrue(text.contains("baaackaaab_last_run_success 0"))
        XCTAssertTrue(text.contains("baaackaaab_last_run_exit_code 2"))
    }

    func testRenderDestGaugesIncludeLabelAndDataAddedOnlyWhenKnown() {
        let snap = StatusExport.build(records: [record("run-1", dataAdded: 12345)], lastDrill: nil,
                                      repoSizeBytes: nil, quotaBytes: nil)
        let text = PrometheusTextfile.render(snap)
        XCTAssertTrue(text.contains(#"baaackaaab_dest_ok{dest="default"} 1"#))
        XCTAssertTrue(text.contains(#"baaackaaab_dest_data_added_bytes{dest="default"} 12345"#))
    }

    func testRenderOmitsDestDataAddedGaugeEntirelyWhenNoDestHasIt() {
        let snap = StatusExport.build(records: [record("run-1")], lastDrill: nil, repoSizeBytes: nil, quotaBytes: nil)
        let text = PrometheusTextfile.render(snap)
        XCTAssertTrue(text.contains("baaackaaab_dest_ok"))
        XCTAssertFalse(text.contains("baaackaaab_dest_data_added_bytes"))
    }

    func testRenderRepoGaugesOmittedWhenUnknown() {
        let snap = StatusExport.build(records: [], lastDrill: nil, repoSizeBytes: nil, quotaBytes: nil)
        let text = PrometheusTextfile.render(snap)
        XCTAssertFalse(text.contains("baaackaaab_repo_size_bytes"))
        XCTAssertFalse(text.contains("baaackaaab_repo_quota_bytes"))
    }

    func testRenderRepoGaugesPresentWhenKnown() {
        let snap = StatusExport.build(records: [], lastDrill: nil, repoSizeBytes: 999, quotaBytes: 2000)
        let text = PrometheusTextfile.render(snap)
        XCTAssertTrue(text.contains("baaackaaab_repo_size_bytes 999"))
        XCTAssertTrue(text.contains("baaackaaab_repo_quota_bytes 2000"))
    }

    func testRenderLastDrillTimestamp() {
        let end = Date(timeIntervalSince1970: 1_700_100_000)
        let snap = StatusExport.build(records: [], lastDrill: drillRecord(end: end), repoSizeBytes: nil, quotaBytes: nil)
        let text = PrometheusTextfile.render(snap)
        XCTAssertTrue(text.contains("baaackaaab_last_drill_timestamp_seconds 1700100000"))
    }

    func testRenderEmptySnapshotYieldsEmptyText() {
        let snap = StatusExport.build(records: [], lastDrill: nil, repoSizeBytes: nil, quotaBytes: nil)
        XCTAssertEqual(PrometheusTextfile.render(snap), "")
    }

    // MARK: - Prometheus label escaping

    func testEscapeLabelHandlesBackslashQuoteAndNewline() {
        XCTAssertEqual(PrometheusTextfile.escapeLabel(#"back\slash"#), #"back\\slash"#)
        XCTAssertEqual(PrometheusTextfile.escapeLabel(#"has"quote"#), #"has\"quote"#)
        XCTAssertEqual(PrometheusTextfile.escapeLabel("line\nbreak"), "line\\nbreak")
    }

    func testRenderEscapesDestNameLabel() {
        let rec = RunRecord(runTag: "r", start: Date(), end: Date(), exitCode: 0, verified: 1, total: 1,
                            sourceFailures: 0, destinations: [RunRecord.Dest(name: #"weird"name"#, ok: true, error: nil)])
        let snap = StatusExport.build(records: [rec], lastDrill: nil, repoSizeBytes: nil, quotaBytes: nil)
        let text = PrometheusTextfile.render(snap)
        XCTAssertTrue(text.contains(#"dest="weird\"name""#))
    }

    // MARK: - Prometheus textfile: atomic write to disk

    func testPrometheusWriteCreatesFileInGivenDir() throws {
        let dir = supportDir.appendingPathComponent("prom", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try PrometheusTextfile.write("baaackaaab_test 1\n", to: dir.path)
        let content = try String(contentsOf: dir.appendingPathComponent("baaackaaab.prom"), encoding: .utf8)
        XCTAssertEqual(content, "baaackaaab_test 1\n")
    }

    func testPrometheusWriteThrowsWhenDirMissing() {
        let missing = supportDir.appendingPathComponent("does-not-exist").path
        XCTAssertThrowsError(try PrometheusTextfile.write("x", to: missing))
    }

    func testPrometheusWriteOverwritesAtomically() throws {
        let dir = supportDir.appendingPathComponent("prom2", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try PrometheusTextfile.write("first\n", to: dir.path)
        try PrometheusTextfile.write("second\n", to: dir.path)
        let content = try String(contentsOf: dir.appendingPathComponent("baaackaaab.prom"), encoding: .utf8)
        XCTAssertEqual(content, "second\n")
        // No leftover temp file after a successful rename.
        let entries = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(entries, ["baaackaaab.prom"])
    }

    // MARK: - BackupSet config round-trip for the new knob

    func testBackupSetPromTextfileDirRoundTrip() throws {
        var set = BackupSet()
        XCTAssertNil(set.promTextfileDir)
        XCTAssertTrue(set.setPromTextfileDir("  /var/lib/node_exporter/textfile  "))
        XCTAssertEqual(set.promTextfileDir, "/var/lib/node_exporter/textfile")
        XCTAssertFalse(set.setPromTextfileDir("/var/lib/node_exporter/textfile"))   // unchanged, no-op
        XCTAssertTrue(set.clearPromTextfileDir())
        XCTAssertNil(set.promTextfileDir)
        XCTAssertFalse(set.clearPromTextfileDir())   // already clear
    }

    func testBackupSetDecodesAndEncodesPromTextfileDirKey() throws {
        let json = """
        { "drive_folders": [], "photo_albums": [], "prom_textfile_dir": "/tmp/textfiles" }
        """
        let set = try JSONDecoder().decode(BackupSet.self, from: Data(json.utf8))
        XCTAssertEqual(set.promTextfileDir, "/tmp/textfiles")

        // Round-trip through save()'s own encoder settings (.withoutEscapingSlashes),
        // matching how the value actually lands on disk.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(set)
        XCTAssertTrue(String(data: data, encoding: .utf8)!.contains("\"prom_textfile_dir\":\"/tmp/textfiles\""))
    }

    func testBackupSetOmitsPromTextfileDirWhenNil() throws {
        let set = BackupSet()
        let encoder = JSONEncoder()
        let data = try encoder.encode(set)
        XCTAssertFalse(String(data: data, encoding: .utf8)!.contains("prom_textfile_dir"))
    }

    // MARK: - CLIArguments flag recognition

    func testSetAndClearPromTextfileAreRecognizedFlags() {
        XCTAssertNil(CLIArguments.unknownArgument(in: ["baaackaaab", "--set-prom-textfile", "/tmp/textfiles"]))
        XCTAssertNil(CLIArguments.unknownArgument(in: ["baaackaaab", "--clear-prom-textfile"]))
        XCTAssertNil(CLIArguments.unknownArgument(in: ["baaackaaab", "--status-export"]))
    }

    func testSetPromTextfileValueParses() {
        XCTAssertEqual(CLIArguments(tokens: ["--set-prom-textfile", "/tmp/textfiles"]).value("--set-prom-textfile"),
                       "/tmp/textfiles")
    }
}
