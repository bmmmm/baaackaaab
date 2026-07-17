import Foundation

// Per-run churn metrics for the source-side ransomware early-warning. The
// append-only store already protects OLD snapshots — a compromised Mac can add but
// never delete history. What it does NOT tell you is that the SOURCE is being
// mass-rewritten right now: ransomware that encrypts your iCloud files makes every
// file look "changed", so the next backup re-uploads everything. This file holds
// the aggregated metrics one run produces; the warn-only tripwire that reads them
// lives alongside in ChurnAnomaly (added with the detector).

/// The churn a run produced, aggregated across every restic snapshot it wrote to
/// one destination (one baaackaaab run can create several snapshots — Photos are
/// backed up in batches). `snapshotCount` is how many restic summaries fed this;
/// zero means the run carries no metrics (a dry run, or a run whose backups were
/// all skipped), which the persistence and the tripwire both treat as "no data".
struct ChurnMetrics: Equatable {
    var dataAdded: Int64 = 0
    var filesChanged: Int64 = 0
    var filesNew: Int64 = 0
    var bytesProcessed: Int64 = 0
    var snapshotCount: Int = 0

    /// True once at least one restic summary has been folded in — i.e. the run
    /// actually has churn metrics worth persisting / evaluating.
    var hasData: Bool { snapshotCount > 0 }

    /// Fold one restic `summary` into the running aggregate for this destination.
    mutating func add(_ s: ResticSummary) {
        dataAdded += Int64(s.dataAdded)
        filesChanged += Int64(s.filesChanged)
        filesNew += Int64(s.filesNew)
        bytesProcessed += Int64(s.totalBytesProcessed)
        snapshotCount += 1
    }
}

/// Pure, testable churn-anomaly evaluator — the warn-only source-side tripwire.
/// Given the current run's aggregated metrics and a baseline drawn from prior
/// successful runs, it returns a verdict. No I/O, no side effects: the wiring in
/// BackupRun does the console warning and the notification, and NEVER lets a
/// verdict change the run's exit code or eviction (an explicit warn-only decision
/// — a false positive must cost a banner, not a backup).
enum ChurnAnomaly {

    /// Below this many baseline runs the verdict is `.insufficientBaseline`
    /// (silent): with too little history the median is not trustworthy and every
    /// early run would false-positive.
    static let minBaselineRuns = 3

    /// SPIKE: current data-added must exceed this multiple of the baseline median
    /// AND the absolute floor below, so a small repo's noise never trips it.
    static let spikeFactor = 10.0

    /// SPIKE absolute floor: a spike under 1 GiB is not worth a ransomware alarm
    /// (re-encoding a few photos, a new document folder) — mass modification of a
    /// real iCloud source moves far more than this.
    static let spikeFloorBytes: Int64 = 1 << 30   // 1 GiB

    /// SHRINK: current processed-bytes below this fraction of the baseline median
    /// means the source more than halved between runs.
    static let shrinkFraction = 0.5

    /// How many recent history records to draw the baseline from.
    static let baselineWindow = 30

    static let spikeMessage =
        "unusually large change volume — if you did not add/re-encode large amounts of data, check the source for mass modification (ransomware encrypts files → everything reuploads)"
    static let shrinkMessage =
        "source shrank by more than half — check that iCloud is signed in and folders/albums still resolve"

    enum Verdict: Equatable {
        case clean
        /// Fewer than `minBaselineRuns` baseline runs — silent, no warning.
        case insufficientBaseline
        case spike(String)
        case shrink(String)
    }

    /// The median of `values` as a Double: the mean of the two middle elements for
    /// an even count, the middle element for an odd count, 0 for an empty input.
    static func median(_ values: [Int64]) -> Double {
        guard !values.isEmpty else { return 0 }
        let s = values.sorted()
        let n = s.count
        if n % 2 == 1 { return Double(s[n / 2]) }
        return (Double(s[n / 2 - 1]) + Double(s[n / 2])) / 2.0
    }

    /// Evaluate the current run against the baseline. Spike is checked before
    /// shrink (a run cannot be both). Pure — the caller decides how to surface it.
    static func evaluate(current: ChurnMetrics, baseline: [ChurnMetrics]) -> Verdict {
        guard baseline.count >= minBaselineRuns else { return .insufficientBaseline }

        let medianAdded = median(baseline.map { $0.dataAdded })
        if Double(current.dataAdded) > spikeFactor * medianAdded,
           current.dataAdded > spikeFloorBytes {
            return .spike(spikeMessage)
        }

        let medianProcessed = median(baseline.map { $0.bytesProcessed })
        if medianProcessed > 0,
           Double(current.bytesProcessed) < shrinkFraction * medianProcessed {
            return .shrink(shrinkMessage)
        }

        return .clean
    }

    /// Build the baseline for `destination` from history: successful backup-kind
    /// records (not drills or integrity checks, exit 0) whose entry for that
    /// destination succeeded and carries churn metrics. Drills, checks, failures,
    /// and pre-metrics records are skipped, so an old runs.ndjson simply yields a
    /// smaller (possibly insufficient) baseline rather than a wrong one.
    static func baseline(from records: [RunRecord], destination: String) -> [ChurnMetrics] {
        records.compactMap { rec -> ChurnMetrics? in
            guard rec.isBackup, rec.exitCode == 0 else { return nil }
            guard let d = rec.destinations.first(where: { $0.name == destination }),
                  d.ok, let processed = d.bytesProcessed else { return nil }
            return ChurnMetrics(
                dataAdded: d.dataAdded ?? 0,
                filesChanged: d.filesChanged ?? 0,
                filesNew: d.filesNew ?? 0,
                bytesProcessed: processed,
                snapshotCount: 1)
        }
    }
}
