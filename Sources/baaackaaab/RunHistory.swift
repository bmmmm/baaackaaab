import Foundation

// Append-only run history: one NDJSON line per backup run under the support dir.
// It is the unattended timer's black box — a scheduled run prints to a log nobody
// reads, so this is where "did last night's backup succeed, and to which
// destinations" actually lives. The dashboard reads the tail of it.
//
// Contains no secrets: run tag, timestamps, verified/total counts, per-destination
// name + ok flag + (already-redacted) restic error string. Written 0600 anyway,
// to match the rest of the store.

enum RunHistoryError: Error, CustomStringConvertible {
    case cannotOpen(String)
    case shortWrite(written: Int, expected: Int)

    var description: String {
        switch self {
        case .cannotOpen(let why): return "could not open run history for append: \(why)"
        case .shortWrite(let w, let e): return "run history append was truncated (\(w)/\(e) bytes)"
        }
    }
}

/// One recorded backup run. Times are ISO-8601; `exitCode` mirrors the process
/// exit (0 ok, 2 partial/failed, 1 crashed early, 130 cancelled).
///
/// A restore-drill run is stored in the SAME history with `kind == "drill"` and
/// the drill-only fields (`bytes`, `snapshots`) set — the dashboard keeps drills
/// out of the "recent runs" list and counts them separately for the "last
/// verified restore" line. The three added fields are optionals encoded with
/// `encodeIfPresent`, so a backup record's on-disk JSON is byte-identical to
/// before (no new keys) — the append-only history stays forward/backward-readable.
struct RunRecord: Codable {
    let runTag: String
    let start: Date
    let end: Date
    let exitCode: Int
    let verified: Int
    let total: Int
    let sourceFailures: Int
    let destinations: [Dest]
    /// nil / "backup" = a normal backup run; "drill" = a scheduled restore drill.
    let kind: String?
    /// Restore-drill only: total bytes restored + byte-verified this drill.
    let bytes: Int?
    /// Restore-drill only: the snapshot ids the drill exercised.
    let snapshots: [String]?

    /// Per-destination outcome for the run. `error` is nil on success; on failure
    /// it is the restic error description (already redacted, never a secret).
    struct Dest: Codable {
        let name: String
        let ok: Bool
        let error: String?
    }

    enum CodingKeys: String, CodingKey {
        case runTag = "run_tag"
        case start, end
        case exitCode = "exit"
        case verified, total
        case sourceFailures = "source_failures"
        case destinations
        case kind, bytes, snapshots
    }

    // Explicit init so the drill fields default to nil — existing backup call
    // sites (BackupRun, the crash-early path, the tests) keep compiling unchanged.
    init(runTag: String, start: Date, end: Date, exitCode: Int, verified: Int, total: Int,
         sourceFailures: Int, destinations: [Dest],
         kind: String? = nil, bytes: Int? = nil, snapshots: [String]? = nil) {
        self.runTag = runTag
        self.start = start
        self.end = end
        self.exitCode = exitCode
        self.verified = verified
        self.total = total
        self.sourceFailures = sourceFailures
        self.destinations = destinations
        self.kind = kind
        self.bytes = bytes
        self.snapshots = snapshots
    }

    /// True when every destination got every byte and nothing was skipped (for a
    /// drill: every sampled file restored + verified).
    var clean: Bool { exitCode == 0 }

    /// A restore-drill record rather than a backup run.
    var isDrill: Bool { kind == "drill" }
}

enum RunHistory {
    /// ~/Library/Application Support/baaackaaab/runs.ndjson (honors the
    /// BAAACKAAAB_SUPPORT_DIR override via CredentialFiles.dir, so tests and a
    /// relocated store keep their history together with their credentials).
    static var file: URL { CredentialFiles.dir.appendingPathComponent("runs.ndjson") }

    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// Append one record as a single JSON line, creating the file 0600 on first
    /// write. Best-effort by contract: recording history must NEVER fail a backup,
    /// so callers invoke this as `try?` — a full disk or a permission glitch costs
    /// a log line, not the run.
    static func append(_ record: RunRecord) throws {
        var data = try encoder().encode(record)
        data.append(0x0A)   // newline — one record per line (NDJSON)
        let fm = FileManager.default
        try fm.createDirectory(at: CredentialFiles.dir, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        if !fm.fileExists(atPath: file.path) {
            fm.createFile(atPath: file.path, contents: nil,
                          attributes: [.posixPermissions: 0o600])
        }
        // O_APPEND makes the kernel seek-to-end and write atomically per write(2),
        // so two concurrent runs (rare — restic repo-locks anyway) can't seek to
        // the same offset and clobber each other's line. The record is one short
        // NDJSON line written in a single write call, which preserves that
        // atomicity (a partial write split could interleave with another writer).
        let fd = open(file.path, O_WRONLY | O_APPEND)
        guard fd >= 0 else { throw RunHistoryError.cannotOpen(String(cString: strerror(errno))) }
        defer { close(fd) }

        // Capture the pre-write size so a partial/failed write can be rolled back.
        // A single write(2) may return fewer bytes than requested (a near-full disk,
        // a signal), leaving a newline-less fragment; the NEXT O_APPEND record would
        // then concatenate onto it, merging two JSON objects into one undecodable
        // line and losing BOTH. So we loop until every byte lands and, on any error,
        // ftruncate the fragment back off — the file stays a clean sequence of whole
        // NDJSON lines (recent() only tolerates a truncated TRAILING line, not a
        // fragment in the middle).
        var st = stat()
        let preSize: off_t = fstat(fd, &st) == 0 ? st.st_size : -1

        let count = data.count
        var total = 0
        let ok = data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            while total < count {
                let n = write(fd, base + total, count - total)
                if n > 0 { total += n; continue }
                if n < 0 && errno == EINTR { continue }   // interrupted — retry
                return false                               // real error — give up
            }
            return true
        }
        guard ok && total == count else {
            if preSize >= 0 { ftruncate(fd, preSize) }
            throw RunHistoryError.shortWrite(written: total, expected: count)
        }
    }

    /// Every record in file order (oldest → newest). Tolerant of a corrupt line
    /// ANYWHERE (a crash mid-write, an O_APPEND interleaving): that line is dropped
    /// rather than failing the whole read.
    private static func allRecords() -> [RunRecord] {
        guard let data = FileManager.default.contents(atPath: file.path),
              let text = String(data: data, encoding: .utf8) else { return [] }
        let dec = decoder()
        return text.split(separator: "\n").compactMap { line -> RunRecord? in
            guard let d = line.data(using: .utf8) else { return nil }
            return try? dec.decode(RunRecord.self, from: d)
        }
    }

    /// The last `limit` records, newest first, for the dashboard.
    static func recent(_ limit: Int) -> [RunRecord] {
        Array(allRecords().suffix(limit).reversed())
    }

    /// The newest restore-drill record, or nil if none has run — the source for
    /// the dashboard's "last verified restore" line and doctor's drill verdict.
    /// Scans the whole history: a drill is monthly, so it can sit far behind the
    /// daily backup records `recent()` returns.
    static func lastDrill() -> RunRecord? {
        allRecords().last { $0.isDrill }
    }

    /// How many restore drills have been recorded — the rotation cursor the drill
    /// uses to advance its sampled source across successive runs.
    static func drillCount() -> Int {
        allRecords().reduce(0) { $0 + ($1.isDrill ? 1 : 0) }
    }
}
