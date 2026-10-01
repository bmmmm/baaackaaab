import XCTest
@testable import baaackaaab

// Ransomware-detection proof of concept: drives the REAL pipeline the tripwire
// depends on — restic backs up a real source tree, the parsed ResticSummary is
// aggregated into ChurnMetrics exactly as BackupRun does, and the verdict comes
// from ChurnAnomaly.evaluate — against a simulated mass-encryption of the source
// (every file's content replaced with fresh random bytes, sizes and names kept,
// the shape an in-place file encryptor produces; random bytes because encrypted
// output is incompressible by definition).
//
// Two scales, one code path:
//  - default: ~6 MiB source with proportionally scaled thresholds — proves the
//    pipeline end-to-end on every `swift test` without gigabyte I/O. The
//    production threshold VALUES stay pinned by ChurnAnomalyTests.
//  - BAAACKAAAB_POC_FULL=1: >1 GiB source evaluated with the UNMODIFIED
//    production thresholds (10x median AND >1 GiB floor) — the evidence run
//    behind docs/poc-ransomware-detection.md. Prints a `POC:` measurement block.
//
// Out of scope, deliberately (see the report's "limits"): the console/banner
// wiring in BackupRun (process-exiting), the launchd-scheduled path, and
// slow-roll attacks that stay under the spike factor per run.
final class RansomwarePoCTests: XCTestCase {

    private var tmp: URL!
    private var repoPath: String!
    private let password = "correct-horse-battery-staple"

    private var fullScale: Bool {
        ProcessInfo.processInfo.environment["BAAACKAAAB_POC_FULL"] == "1"
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(ResticBackend.locateExecutable() != nil,
                          "restic not on PATH — skipping live PoC test")
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("baaackaaab-poc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        setenv("RESTIC_CACHE_DIR", tmp.appendingPathComponent("cache").path, 1)
        repoPath = tmp.appendingPathComponent("repo", isDirectory: true).path
    }

    override func tearDownWithError() throws {
        if let tmp { try? FileManager.default.removeItem(at: tmp) }
        tmp = nil
        try super.tearDownWithError()
    }

    private func makeBackend() -> ResticBackend {
        let dest = Destination(name: "poc", link: "default", order: 0, enabled: true,
                               repo: .value(repoPath), password: .value(password))
        return ResticBackend(destination: dest)
    }

    /// Globally-unique random bytes (arc4random_buf). Uniqueness matters: a
    /// repeated block would dedup/compress in restic and collapse `dataAdded`,
    /// understating the attack — encrypted output never dedups.
    private func randomData(_ count: Int) -> Data {
        var data = Data(count: count)
        data.withUnsafeMutableBytes { buf in
            arc4random_buf(buf.baseAddress, count)
        }
        return data
    }

    /// Back up `source` through the real backend and fold the parsed summary into
    /// ChurnMetrics — the exact aggregation BackupRun performs per destination.
    private func backupRun(_ backend: ResticBackend, _ source: URL) throws -> ChurnMetrics {
        var metrics = ChurnMetrics()
        if let summary = try backend.backup(paths: [source], tags: ["poc"], host: "poc-host") {
            metrics.add(summary)
        }
        return metrics
    }

    private func fmtMiB(_ bytes: Int64) -> String {
        String(format: "%.1f MiB", Double(bytes) / Double(1 << 20))
    }

    func testMassEncryptionRaisesSpikeAndSourceLossRaisesShrink() throws {
        // Scale: file count x file size, and the thresholds the verdict uses.
        // Full scale = production thresholds, untouched.
        let (fileCount, fileBytes, thresholds): (Int, Int, ChurnAnomaly.Thresholds) = fullScale
            ? (64, 20 << 20, .production)                       // 1.25 GiB source
            : (24, 256 << 10, .init(minBaselineRuns: 3,         // 6 MiB source
                                    spikeFactor: 10.0,
                                    spikeFloorBytes: 4 << 20,   // floor scaled 1 GiB -> 4 MiB
                                    shrinkFraction: 0.5))

        let backend = makeBackend()
        try backend.ensureInitialized()

        // A media-like source: incompressible files, as photo/video-heavy iCloud
        // data is (the conservative case — compressible text would only make the
        // attack's dataAdded delta MORE pronounced, never less).
        let source = tmp.appendingPathComponent("icloud-source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        var files: [URL] = []
        for i in 0..<fileCount {
            let f = source.appendingPathComponent(String(format: "IMG_%04d.heic", i))
            try randomData(fileBytes).write(to: f)
            files.append(f)
        }
        let sourceBytes = Int64(fileCount * fileBytes)

        // Baseline life: an initial full upload, then organic runs that each add
        // one new small file — the shape of normal incremental use.
        var history: [ChurnMetrics] = []
        history.append(try backupRun(backend, source))          // run 1: everything new
        for i in 0..<3 {
            let f = source.appendingPathComponent(String(format: "IMG_new_%d.heic", i))
            try randomData(fileBytes / 8).write(to: f)
            history.append(try backupRun(backend, source))      // runs 2-4: small growth
        }

        // While the baseline is still arming (< minBaselineRuns) the tripwire
        // must stay silent — early runs never false-alarm.
        XCTAssertEqual(
            ChurnAnomaly.evaluate(current: history[1],
                                  baseline: Array(history[0..<1]),
                                  thresholds: thresholds),
            .insufficientBaseline)

        // A normal organic run against the armed baseline is clean.
        let cleanVerdict = ChurnAnomaly.evaluate(current: history[3],
                                                 baseline: Array(history[0..<3]),
                                                 thresholds: thresholds)
        XCTAssertEqual(cleanVerdict, .clean,
                       "an organic small-growth run must not alarm")

        // THE ATTACK: rewrite every original file's content with fresh random
        // bytes, same size, same name — a mass in-place encryption. To restic
        // every block is new: the next backup re-uploads the whole source.
        for f in files {
            try randomData(fileBytes).write(to: f)
        }
        let attack = try backupRun(backend, source)
        let attackVerdict = ChurnAnomaly.evaluate(current: attack, baseline: history,
                                                  thresholds: thresholds)
        guard case .spike = attackVerdict else {
            return XCTFail("mass encryption must raise SPIKE, got \(attackVerdict) " +
                           "(dataAdded \(attack.dataAdded), baseline medians " +
                           "\(history.map(\.dataAdded)))")
        }

        // THE OUTAGE: the source largely vanishes (signed-out iCloud, folder no
        // longer resolving) — the next run processes a fraction of the baseline.
        for f in files.dropFirst(fileCount / 8) {
            try FileManager.default.removeItem(at: f)
        }
        let outage = try backupRun(backend, source)
        let outageVerdict = ChurnAnomaly.evaluate(current: outage, baseline: history,
                                                  thresholds: thresholds)
        guard case .shrink = outageVerdict else {
            return XCTFail("mass source loss must raise SHRINK, got \(outageVerdict) " +
                           "(bytesProcessed \(outage.bytesProcessed), baseline " +
                           "\(history.map(\.bytesProcessed)))")
        }

        // Measurement block for docs/poc-ransomware-detection.md (full scale).
        let mode = fullScale ? "FULL (production thresholds)" : "scaled"
        print("POC: mode=\(mode) source=\(fmtMiB(sourceBytes)) files=\(fileCount)")
        print("POC: thresholds spikeFactor=\(thresholds.spikeFactor) " +
              "spikeFloor=\(fmtMiB(thresholds.spikeFloorBytes)) " +
              "shrinkFraction=\(thresholds.shrinkFraction) " +
              "minBaselineRuns=\(thresholds.minBaselineRuns)")
        for (i, m) in history.enumerated() {
            print("POC: baseline run \(i + 1): dataAdded=\(fmtMiB(m.dataAdded)) " +
                  "processed=\(fmtMiB(m.bytesProcessed))")
        }
        print("POC: baseline median dataAdded=\(fmtMiB(Int64(ChurnAnomaly.median(history.map(\.dataAdded)))))")
        print("POC: attack run: dataAdded=\(fmtMiB(attack.dataAdded)) " +
              "processed=\(fmtMiB(attack.bytesProcessed)) verdict=SPIKE")
        print("POC: outage run: dataAdded=\(fmtMiB(outage.dataAdded)) " +
              "processed=\(fmtMiB(outage.bytesProcessed)) verdict=SHRINK")
    }
}
