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
