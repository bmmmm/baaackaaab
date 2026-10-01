import XCTest
@testable import baaackaaab

// The churn tripwire is the source-side ransomware early-warning: nothing else in
// the tool tells you the SOURCE is being mass-rewritten (the append-only store
// only protects old snapshots). It is warn-only, so a wrong verdict is either a
// false alarm or a missed attack — both matter. These pin the pure evaluator (the
// spike/shrink thresholds, the median math, the insufficient-baseline silence),
// the per-run aggregation across several snapshots, and the history→baseline
// extraction. The console/notification wiring is process-exiting and not unit
// tested, exactly like the other run-finalizer paths.
final class ChurnAnomalyTests: XCTestCase {

    private let gib: Int64 = 1 << 30

    private func metrics(dataAdded: Int64 = 0, bytesProcessed: Int64 = 0,
                         filesNew: Int64 = 0, filesChanged: Int64 = 0) -> ChurnMetrics {
        ChurnMetrics(dataAdded: dataAdded, filesChanged: filesChanged,
                     filesNew: filesNew, bytesProcessed: bytesProcessed, snapshotCount: 1)
    }

    // MARK: - median (even / odd / empty)

    func testMedianOddCountTakesMiddle() {
        XCTAssertEqual(ChurnAnomaly.median([10, 2, 6]), 6.0)          // sorts to [2,6,10]
        XCTAssertEqual(ChurnAnomaly.median([1, 2, 3, 4, 5]), 3.0)
    }

    func testMedianEvenCountAveragesTwoMiddle() {
        XCTAssertEqual(ChurnAnomaly.median([1, 2, 3, 4]), 2.5)
        XCTAssertEqual(ChurnAnomaly.median([20, 10]), 15.0)          // sorts to [10,20]
    }

    func testMedianEmptyIsZero() {
        XCTAssertEqual(ChurnAnomaly.median([]), 0.0)
    }

    // MARK: - evaluate

    func testInsufficientBaselineIsSilent() {
        let baseline = [metrics(dataAdded: 1_000, bytesProcessed: 1_000),
                        metrics(dataAdded: 1_000, bytesProcessed: 1_000)]   // only 2
        XCTAssertEqual(baseline.count, 2)
        let v = ChurnAnomaly.evaluate(current: metrics(dataAdded: 50 * gib, bytesProcessed: 50 * gib),
                                      baseline: baseline)
        XCTAssertEqual(v, .insufficientBaseline)
    }

    func testCleanRunWithinNormalRange() {
        let baseline = Array(repeating: metrics(dataAdded: 100_000_000, bytesProcessed: 10 * gib), count: 4)
        // ~50 MB added, full source walked — a normal incremental run.
        let v = ChurnAnomaly.evaluate(current: metrics(dataAdded: 50_000_000, bytesProcessed: 10 * gib),
                                      baseline: baseline)
        XCTAssertEqual(v, .clean)
    }

    func testSpikeWhenBothFactorAndFloorExceeded() {
        let baseline = Array(repeating: metrics(dataAdded: 50_000_000, bytesProcessed: 10 * gib), count: 3)
        // 2 GB added: > 10x the 50 MB median AND > the 1 GiB floor.
        let v = ChurnAnomaly.evaluate(current: metrics(dataAdded: 2_000_000_000, bytesProcessed: 12 * gib),
                                      baseline: baseline)
        XCTAssertEqual(v, .spike(ChurnAnomaly.spikeMessage))
    }

    func testNoSpikeWhenFactorHugeButUnderFloor() {
        // 500x the median, but only 500 MB — under the 1 GiB floor, so NOT an alarm
        // (re-encoding a few files must not cry ransomware).
        let baseline = Array(repeating: metrics(dataAdded: 1_000_000, bytesProcessed: 10 * gib), count: 3)
        let v = ChurnAnomaly.evaluate(current: metrics(dataAdded: 500_000_000, bytesProcessed: 10 * gib),
                                      baseline: baseline)
        XCTAssertEqual(v, .clean)
    }

    func testShrinkWhenSourceMoreThanHalves() {
        let baseline = Array(repeating: metrics(dataAdded: 50_000_000, bytesProcessed: 10 * gib), count: 3)
        // 3 GB processed vs a 10 GB median → below 50%. dataAdded tiny (no spike).
        let v = ChurnAnomaly.evaluate(current: metrics(dataAdded: 1_000_000, bytesProcessed: 3 * gib),
                                      baseline: baseline)
        XCTAssertEqual(v, .shrink(ChurnAnomaly.shrinkMessage))
    }

    func testNoShrinkAtExactlyHalf() {
        // Boundary: exactly 50% is "< 0.5x" false, so still clean.
        let baseline = Array(repeating: metrics(dataAdded: 50_000_000, bytesProcessed: 10 * gib), count: 3)
        let v = ChurnAnomaly.evaluate(current: metrics(dataAdded: 1_000_000, bytesProcessed: 5 * gib),
                                      baseline: baseline)
        XCTAssertEqual(v, .clean)
    }

    // MARK: - aggregation across several snapshots per run

    func testAggregateSumsAcrossSnapshots() {
        var agg = ChurnMetrics()
        XCTAssertFalse(agg.hasData)
        // One run, three restic snapshots (e.g. a Drive folder + two photo batches).
        agg.add(ResticSummary(filesNew: 10, filesChanged: 2, dataAdded: 1_000,
                              totalBytesProcessed: 5_000, totalDuration: 1, snapshotID: "a"))
        agg.add(ResticSummary(filesNew: 5, filesChanged: 3, dataAdded: 2_000,
                              totalBytesProcessed: 7_000, totalDuration: 1, snapshotID: "b"))
        agg.add(ResticSummary(filesNew: 0, filesChanged: 1, dataAdded: 500,
                              totalBytesProcessed: 3_000, totalDuration: 1, snapshotID: "c"))
        XCTAssertTrue(agg.hasData)
        XCTAssertEqual(agg.snapshotCount, 3)
        XCTAssertEqual(agg.filesNew, 15)
        XCTAssertEqual(agg.filesChanged, 6)
        XCTAssertEqual(agg.dataAdded, 3_500)
        XCTAssertEqual(agg.bytesProcessed, 15_000)
    }

    // MARK: - baseline extraction from history

    private func backupRecord(dest: String, exit: Int, ok: Bool, withMetrics: Bool) -> RunRecord {
        let d = withMetrics
            ? RunRecord.Dest(name: dest, ok: ok, error: ok ? nil : "boom",
                             dataAdded: 100, filesChanged: 2, filesNew: 3, bytesProcessed: 9_000)
            : RunRecord.Dest(name: dest, ok: ok, error: ok ? nil : "boom")
        return RunRecord(runTag: "r", start: Date(), end: Date(), exitCode: exit,
                         verified: 1, total: 1, sourceFailures: 0, destinations: [d])
    }

    func testBaselineKeepsOnlySuccessfulMetricBearingBackupsForDestination() {
        let drill = RunRecord(runTag: "drill", start: Date(), end: Date(), exitCode: 0,
                              verified: 1, total: 1, sourceFailures: 0,
                              destinations: [RunRecord.Dest(name: "primary", ok: true, error: nil,
                                                            dataAdded: 1, filesChanged: 1,
                                                            filesNew: 1, bytesProcessed: 1)],
                              kind: "drill", bytes: 1, snapshots: ["x"])
        let records = [
            backupRecord(dest: "primary", exit: 0, ok: true, withMetrics: true),    // KEEP
            drill,                                                                    // skip: drill
            backupRecord(dest: "primary", exit: 2, ok: false, withMetrics: true),    // skip: failed run
            backupRecord(dest: "primary", exit: 0, ok: true, withMetrics: false),    // skip: no metrics
            backupRecord(dest: "offsite", exit: 0, ok: true, withMetrics: true),     // skip: other dest
            backupRecord(dest: "primary", exit: 0, ok: true, withMetrics: true),     // KEEP
        ]
        let baseline = ChurnAnomaly.baseline(from: records, destination: "primary")
        XCTAssertEqual(baseline.count, 2)
        XCTAssertTrue(baseline.allSatisfy { $0.bytesProcessed == 9_000 && $0.dataAdded == 100 })
    }
}
