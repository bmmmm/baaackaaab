import Foundation
#if canImport(Darwin)
import Darwin
#endif

// Machine-readable status export: a stable, DOCUMENTED JSON snapshot
// (status.json), plus an optional Prometheus node_exporter textfile
// (baaackaaab.prom). Written after every REAL backup run (never a dry run —
// it acquired and uploaded nothing worth reporting).
//
// Unlike runs.ndjson (RunHistory's internal black box, free to change shape
// at will), this IS a public contract: other local tools — a monitoring
// dashboard, node_exporter, a homegrown script — may parse it, so its keys
// are additive-only from here on. Contains no secrets and no repo URL, only
// counts/booleans/byte figures — but the file may still be read by other
// local processes, so treat it as world-visible content even though it is
// written 0600.

/// The public status.json shape. Every field is documented in the README
/// ("Machine-readable status"); changing a key's meaning (not just adding a
/// new one) would break a consumer, so `StatusSnapshotTests` pins the exact
/// key set.
struct StatusSnapshot: Codable, Equatable {
    let schemaVersion: Int
    let generatedAt: Date
    /// nil only when no backup run has ever been recorded.
    let lastRun: LastRun?
    /// Per-destination outcome of `lastRun`. Empty when `lastRun` is nil.
    let destinations: [DestStatus]
    /// nil when the repo size was never sampled (e.g. no --repo-quota probe
    /// happened to run and `--status-export` wasn't invoked to force one).
    let repo: RepoStatus?
    /// nil when no restore drill has run yet.
    let lastDrill: DrillStatus?
    /// nil when no rotating integrity check has run yet.
    let lastCheck: CheckStatus?

    struct LastRun: Codable, Equatable {
        let tag: String
        let start: Date
        let end: Date
        let exitCode: Int
        /// "ok" | "partial" | "failed" | "cancelled" — see
        /// `StatusExport.outcome(exitCode:)`.
        let outcome: String
        let verified: Int
        let total: Int
        let sourceFailures: Int

        enum CodingKeys: String, CodingKey {
            case tag, start, end
            case exitCode = "exit_code"
            case outcome, verified, total
            case sourceFailures = "source_failures"
        }
    }

    /// Churn metrics are omitted (not null) when the run has none — a dry
    /// run's destinations never reach here, but a destination whose backups
    /// were all skipped still can.
    struct DestStatus: Codable, Equatable {
        let name: String
        let ok: Bool
        let dataAdded: Int64?
        let bytesProcessed: Int64?

        enum CodingKeys: String, CodingKey {
            case name, ok
            case dataAdded = "data_added"
            case bytesProcessed = "bytes_processed"
        }
    }

    struct RepoStatus: Codable, Equatable {
        let sizeBytes: Int64
        let quotaBytes: Int64?
        /// sizeBytes / quotaBytes, present only when a quota is configured.
        let quotaFraction: Double?

        enum CodingKeys: String, CodingKey {
            case sizeBytes = "size_bytes"
            case quotaBytes = "quota_bytes"
            case quotaFraction = "quota_fraction"
        }
    }

    struct DrillStatus: Codable, Equatable {
        let time: Date
        let ok: Bool
        let bytes: Int64?
        /// How many snapshots the drill sampled (not their ids — this is a
        /// status summary, not a browse of the run history).
        let snapshotCount: Int?

        enum CodingKeys: String, CodingKey {
            case time, ok, bytes
            case snapshotCount = "snapshots"
        }
    }

    struct CheckStatus: Codable, Equatable {
        let time: Date
        let ok: Bool
        /// The 1-based rotating `--read-data-subset` slice this check covered,
        /// out of `of` (after `of` checks every pack has been re-read once).
        let slice: Int?
        let of: Int

        enum CodingKeys: String, CodingKey {
            case time, ok, slice, of
        }
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case generatedAt = "generated_at"
        case lastRun = "last_run"
        case destinations
        case repo
        case lastDrill = "last_drill"
        case lastCheck = "last_check"
    }
}

enum StatusExportError: Error, CustomStringConvertible {
    case writeFailed(String)
    var description: String {
        switch self {
        case .writeFailed(let path): return "could not write status export at \(path)"
        }
    }
}

enum StatusExport {
    static let schemaVersion = 1

    /// How many recent RunHistory records to scan for the newest non-drill one
    /// — generous headroom over the (rare) case of consecutive drill records.
    static let historyLookback = 20

    /// ~/Library/Application Support/baaackaaab/status.json (honors
    /// BAAACKAAAB_SUPPORT_DIR like RunHistory, so tests never touch the real store).
    static var file: URL { CredentialFiles.dir.appendingPathComponent("status.json") }

    /// Map a recorded exit code to the stable outcome word. Mirrors the
    /// convention documented on `RunRecord.exitCode` (0 ok, 2 partial/failed, 1
    /// crashed early, 130 cancelled); anything else (there is no other producer
    /// today) falls back to "failed" rather than a code a consumer can't switch on.
    static func outcome(exitCode: Int) -> String {
        switch exitCode {
        case 0: return "ok"
        case 2: return "partial"
        case 130: return "cancelled"
        default: return "failed"
        }
    }

    /// Pure builder — no I/O, directly unit-testable. `records` should be
    /// RunHistory.recent(historyLookback) (newest first); the first non-drill
    /// entry becomes `lastRun`. `repoSizeBytes`/`quotaBytes` are already-resolved
    /// inputs (the caller decides whether/how to fetch them), so this never
    /// touches the network.
    static func build(records: [RunRecord], lastDrill: RunRecord?,
                       repoSizeBytes: Int64?, quotaBytes: Int64?,
                       lastCheck: RunRecord? = nil,
                       now: Date = Date()) -> StatusSnapshot {
        // Backup-kind records only: drill AND integrity-check records share the
        // same history file and must never masquerade as `last_run`.
        let last = records.first { $0.isBackup }
        let lastRun = last.map { rec in
            StatusSnapshot.LastRun(
                tag: rec.runTag, start: rec.start, end: rec.end, exitCode: rec.exitCode,
                outcome: outcome(exitCode: rec.exitCode),
                verified: rec.verified, total: rec.total, sourceFailures: rec.sourceFailures)
        }
        let destinations = (last?.destinations ?? []).map { d in
            StatusSnapshot.DestStatus(name: d.name, ok: d.ok,
                                      dataAdded: d.dataAdded, bytesProcessed: d.bytesProcessed)
        }
        let repo: StatusSnapshot.RepoStatus? = repoSizeBytes.map { size in
            let fraction: Double? = quotaBytes.flatMap { $0 > 0 ? Double(size) / Double($0) : nil }
            return StatusSnapshot.RepoStatus(sizeBytes: size, quotaBytes: quotaBytes, quotaFraction: fraction)
        }
        let drill: StatusSnapshot.DrillStatus? = lastDrill.map { d in
            StatusSnapshot.DrillStatus(time: d.end, ok: d.clean,
                                       bytes: d.bytes.map(Int64.init), snapshotCount: d.snapshots?.count)
        }
        let check: StatusSnapshot.CheckStatus? = lastCheck.map { c in
            StatusSnapshot.CheckStatus(time: c.end, ok: c.exitCode == 0,
                                       slice: c.slice, of: RotatingCheck.slices)
        }
        return StatusSnapshot(schemaVersion: schemaVersion, generatedAt: now,
                              lastRun: lastRun, destinations: destinations, repo: repo,
                              lastDrill: drill, lastCheck: check)
    }

    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }

    /// Atomic write: a sibling temp file created 0600 from the start (no
    /// world-readable window), then rename(2)d over status.json — a reader never
    /// observes a partial file, and an interrupted write leaves the previous
    /// snapshot intact rather than a corrupt one. Same pattern as
    /// DestinationStore.write0600 / CredentialFiles.write.
    static func write(_ snapshot: StatusSnapshot) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: CredentialFiles.dir, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        var data = try encoder().encode(snapshot)
        data.append(0x0A)
        let tmp = CredentialFiles.dir.appendingPathComponent(".status.json.tmp-\(ProcessInfo.processInfo.processIdentifier)")
        if fm.fileExists(atPath: tmp.path) { try? fm.removeItem(at: tmp) }
        guard fm.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw StatusExportError.writeFailed(file.path)
        }
        guard rename(tmp.path, file.path) == 0 else {
            try? fm.removeItem(at: tmp)
            throw StatusExportError.writeFailed(file.path)
        }
    }

    /// Rebuild + write status.json (and, if configured, the Prometheus textfile)
    /// from what RunHistory already has on disk — never from in-memory run
    /// state — so the real-run call site and the standalone `--status-export`
    /// command can never drift from each other. Best-effort by contract, same as
    /// RunHistory.append: a write failure here must NEVER fail the backup run.
    /// The Prometheus write additionally warns on failure (its own contract —
    /// the directory is operator-configured and a typo/unmounted volume should
    /// be visible), but still never affects the exit code.
    @discardableResult
    static func exportAfterRun(repoSizeBytes: Int64?, quotaBytes: Int64?,
                               promTextfileDir: String?) -> StatusSnapshot? {
        let records = RunHistory.recent(historyLookback)
        let snapshot = build(records: records, lastDrill: RunHistory.lastDrill(),
                            repoSizeBytes: repoSizeBytes, quotaBytes: quotaBytes,
                            lastCheck: RunHistory.lastCheck())
        try? write(snapshot)
        if let dir = promTextfileDir, !dir.isEmpty {
            do {
                try PrometheusTextfile.write(PrometheusTextfile.render(snapshot), to: dir)
            } catch {
                Console.warn("could not write the Prometheus textfile to \(dir): \(error) — check the directory exists and is writable (see --set-prom-textfile <dir>, --clear-prom-textfile to stop trying)")
            }
        }
        return snapshot
    }
}

// MARK: - Prometheus textfile-collector emitter

enum PrometheusTextfileError: Error, CustomStringConvertible {
    case dirNotFound(String)
    case writeFailed(String)
    var description: String {
        switch self {
        case .dirNotFound(let d): return "directory does not exist: \(d)"
        case .writeFailed(let p): return "write failed at \(p)"
        }
    }
}

/// Renders a `StatusSnapshot` as node_exporter textfile-collector content
/// (https://github.com/prometheus/node_exporter#textfile-collector) and writes
/// it atomically. Pure rendering is separate from the write so the format is
/// directly unit-testable without touching a filesystem.
enum PrometheusTextfile {
    /// Escape a label value per the Prometheus exposition format: backslash and
    /// double-quote are escaped, a literal newline becomes the two-character
    /// `\n` — label values are single-line by the format's own rule.
    static func escapeLabel(_ s: String) -> String {
        var out = s.replacingOccurrences(of: "\\", with: "\\\\")
        out = out.replacingOccurrences(of: "\"", with: "\\\"")
        out = out.replacingOccurrences(of: "\n", with: "\\n")
        return out
    }

    /// Render `snapshot` as exposition-format text. A metric whose underlying
    /// value is unknown (e.g. the repo size was never sampled) is OMITTED
    /// entirely — the Prometheus convention is "absent" over a fabricated 0/NaN,
    /// so a dashboard can tell "never measured" from "measured as zero".
    static func render(_ snapshot: StatusSnapshot) -> String {
        var lines: [String] = []
        func gauge(_ name: String, help: String, value: String?) {
            guard let value else { return }
            lines.append("# HELP \(name) \(help)")
            lines.append("# TYPE \(name) gauge")
            lines.append("\(name) \(value)")
        }

        if let run = snapshot.lastRun {
            gauge("baaackaaab_last_run_timestamp_seconds",
                  help: "Unix timestamp the last backup run finished.",
                  value: String(Int(run.end.timeIntervalSince1970)))
            gauge("baaackaaab_last_run_success",
                  help: "1 if the last backup run exited 0 (ok), else 0.",
                  value: run.exitCode == 0 ? "1" : "0")
            gauge("baaackaaab_last_run_exit_code",
                  help: "Exit code of the last backup run.",
                  value: String(run.exitCode))
            gauge("baaackaaab_verified_files",
                  help: "Files verified in the last backup run.",
                  value: String(run.verified))
            gauge("baaackaaab_total_files",
                  help: "Files acquired in the last backup run.",
                  value: String(run.total))
        }

        if !snapshot.destinations.isEmpty {
            lines.append("# HELP baaackaaab_dest_ok 1 if the destination's last backup run succeeded, else 0.")
            lines.append("# TYPE baaackaaab_dest_ok gauge")
            for d in snapshot.destinations {
                lines.append("baaackaaab_dest_ok{dest=\"\(escapeLabel(d.name))\"} \(d.ok ? "1" : "0")")
            }
            let withData = snapshot.destinations.filter { $0.dataAdded != nil }
            if !withData.isEmpty {
                lines.append("# HELP baaackaaab_dest_data_added_bytes Data added to the destination in the last backup run.")
                lines.append("# TYPE baaackaaab_dest_data_added_bytes gauge")
                for d in withData {
                    lines.append("baaackaaab_dest_data_added_bytes{dest=\"\(escapeLabel(d.name))\"} \(d.dataAdded!)")
                }
            }
        }

        if let repo = snapshot.repo {
            gauge("baaackaaab_repo_size_bytes",
                  help: "Deduplicated repo size in bytes (primary destination).",
                  value: String(repo.sizeBytes))
            gauge("baaackaaab_repo_quota_bytes",
                  help: "Configured repo quota in bytes.",
                  value: repo.quotaBytes.map(String.init))
        }

        if let drill = snapshot.lastDrill {
            gauge("baaackaaab_last_drill_timestamp_seconds",
                  help: "Unix timestamp of the last restore drill.",
                  value: String(Int(drill.time.timeIntervalSince1970)))
        }

        if let check = snapshot.lastCheck {
            gauge("baaackaaab_last_check_timestamp_seconds",
                  help: "Unix timestamp of the last rotating integrity check.",
                  value: String(Int(check.time.timeIntervalSince1970)))
        }

        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    /// Atomic write into `dir`: the temp file is created IN THE SAME DIRECTORY
    /// (not a system temp dir) so the final `rename(2)` stays on one filesystem
    /// — a cross-filesystem rename can't be atomic (some platforms even refuse
    /// it outright), which would let node_exporter's textfile collector observe
    /// a partial file. No 0600: unlike status.json this file is meant to be read
    /// by a different process/user (node_exporter), so it keeps the directory's
    /// default permissions.
    static func write(_ text: String, to dir: String) throws {
        let expanded = (dir as NSString).expandingTildeInPath
        let dirURL = URL(fileURLWithPath: expanded, isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dirURL.path, isDirectory: &isDir), isDir.boolValue else {
            throw PrometheusTextfileError.dirNotFound(expanded)
        }
        let target = dirURL.appendingPathComponent("baaackaaab.prom")
        let tmp = dirURL.appendingPathComponent(".baaackaaab.prom.tmp-\(ProcessInfo.processInfo.processIdentifier)")
        let fm = FileManager.default
        if fm.fileExists(atPath: tmp.path) { try? fm.removeItem(at: tmp) }
        guard fm.createFile(atPath: tmp.path, contents: Data(text.utf8)) else {
            throw PrometheusTextfileError.writeFailed(target.path)
        }
        guard rename(tmp.path, target.path) == 0 else {
            try? fm.removeItem(at: tmp)
            throw PrometheusTextfileError.writeFailed(target.path)
        }
    }
}

// MARK: - --status-export

/// Rebuild status.json (and the Prometheus textfile, if configured) on demand,
/// without waiting for the next scheduled run — e.g. right after wiring up
/// node_exporter, to see the file before the next backup. Probes the primary
/// destination's repo size the same bounded way `--doctor` does (read-only).
func statusExportCommand(configPath: URL) {
    Console.banner("baaackaaab", tagline: "status export")
    let dests = resolveDestinationsOrExit()

    var quotaBytes: Int64? = nil
    var promTextfileDir: String? = nil
    if FileManager.default.fileExists(atPath: configPath.path) {
        do {
            let set = try BackupSet.load(from: configPath)
            quotaBytes = set.quotaBytes.map(Int64.init)
            promTextfileDir = set.promTextfileDir
        } catch {
            Console.error("backup set at \(configPath.path) is unreadable — fix or delete it: \(error)")
            exit(1)
        }
    }

    Console.step("sampling \(dests[0].name)'s repo size (bounded, read-only)")
    let repoSizeBytes = ResticBackend(destination: dests[0]).remoteStatus().sizeBytes.map(Int64.init)

    guard let snapshot = StatusExport.exportAfterRun(
        repoSizeBytes: repoSizeBytes, quotaBytes: quotaBytes, promTextfileDir: promTextfileDir) else {
        Console.error("could not build the status export")
        exit(1)
    }

    Console.summary(
        headline: "status export written",
        state: .ok,
        details: [
            ("status.json", StatusExport.file.path),
            ("prom-textfile", promTextfileDir.map { "\($0)/baaackaaab.prom" } ?? "not configured — --set-prom-textfile <dir>"),
            ("last run", snapshot.lastRun.map { "\($0.tag) (\($0.outcome))" } ?? "none recorded yet"),
        ])
}
