import Foundation

// The read-only query surface of ResticBackend — snapshots, ls, find, diff,
// stats, lock READS, and the dashboard aggregate — split out of
// ResticBackend.swift (which keeps init/backup/restore/check, `unlock`, and
// the process core). Everything here only ever reads the repository. The one
// lock WRITE (`unlock`) deliberately stays in ResticBackend.swift so this
// file's name keeps its promise. Extracted verbatim; the runners it calls
// (`runCapturing` / `runCapturingResult`) became internal for exactly this
// file — the private child env and the spawn core itself stay confined to
// ResticBackend.swift.

extension ResticBackend {
    /// One repository lock, read from `restic cat lock <id>`. Identifies who holds
    /// the lock (host/user/pid), when it was taken, and whether it is exclusive —
    /// enough for an operator to judge whether it is stale before removing it.
    struct LockInfo {
        let id: String
        let time: String
        let hostname: String
        let username: String
        let pid: Int?
        let exclusive: Bool
    }

    /// List the repository's lock IDs (`restic list locks`), read-only. Returns the
    /// exit code and the ids; a non-zero code means the repo was unreachable / the
    /// credentials were wrong, which the caller reports rather than treating as
    /// "no locks". Filters to hex-looking lines so a stray stderr warning can't
    /// masquerade as a lock id.
    func listLockIDs() -> (code: Int32, ids: [String]) {
        let (code, out) = runCapturingResult(["list", "locks"])
        let ids = out.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0.count >= 8 && $0.allSatisfy(\.isHexDigit) }
        return (code, ids)
    }

    /// Read one lock's metadata (`restic cat lock <id>`), read-only. nil if the
    /// lock could not be read (it may have just been released).
    func lockInfo(id: String) -> LockInfo? {
        let (code, out) = runCapturingResult(["cat", "lock", id])
        guard code == 0, let start = out.firstIndex(of: "{"),
              let data = String(out[start...]).data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return LockInfo(
            id: id,
            time: (o["time"] as? String) ?? "",
            hostname: (o["hostname"] as? String) ?? "",
            username: (o["username"] as? String) ?? "",
            pid: (o["pid"] as? NSNumber)?.intValue,
            exclusive: (o["exclusive"] as? Bool) ?? false)
    }

    /// Best-effort current repo data size in bytes, via
    /// `restic stats --mode raw-data --json`. This is the deduplicated blob
    /// size — a close, slightly low approximation of what the server's
    /// `--max-size` quota counts (which also includes index/metadata overhead).
    /// Returns nil if stats can't be read (e.g. a fresh repo with no snapshots,
    /// or the query failed), so the caller treats usage as unknown rather than
    /// failing the run over a missing gauge reading.
    /// Always bounded: the default is the probe timeout, because the quota
    /// pre-flight runs this BEFORE any backup — an unbounded `stats` against a
    /// wedged destination would stall the whole scheduled run indefinitely.
    func repoSizeBytes(timeout: TimeInterval = ResticBackend.probeTimeout) -> Int? {
        // `--quiet` suppresses restic's progress counter, which it otherwise
        // prints on stdout *before* the JSON (e.g. "[0:00] 100.00% 1/1 ...").
        guard let out = try? runCapturing(["stats", "--quiet", "--mode", "raw-data", "--json"], command: "stats", timeout: timeout)
        else { return nil }
        // Belt and braces: even if a stray line slips onto stdout, the JSON is a
        // single object on its own line — take the last line that starts with
        // '{' rather than parsing the whole blob.
        let lines = out.split(separator: "\n", omittingEmptySubsequences: true)
        guard let jsonLine = lines.last(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("{") }),
              let data = jsonLine.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let size = (obj["total_size"] as? NSNumber)?.intValue
        else { return nil }
        return size
    }

    /// A read-only snapshot of the remote, for the command-center dashboard.
    /// Never throws — failures land in `error` so the TUI can show them inline.
    struct RemoteStatus {
        var reachable = false
        var snapshotCount = 0
        var latestTime: String?
        var latestTags: [String] = []
        /// The oldest snapshot's time, for the dashboard's "oldest <age>" line —
        /// how far back this destination's history actually reaches.
        var oldestTime: String?
        var sizeBytes: Int?
        var error: String?
        /// Per-source breakdown (drive / photos), so the dashboard can show one
        /// row per (source × destination). Empty until a successful query.
        var sources: [SourceStatus] = []
    }

    /// The newest snapshot carrying a given source tag, plus how many snapshots
    /// that source has on this destination. `latestTime` is nil when the source
    /// has never been backed up here — the dashboard shows that as a gap.
    struct SourceStatus {
        let source: String
        let count: Int
        let latestTime: String?
    }

    /// The source tags the dashboard groups by — these mirror the tags the run
    /// applies: drive folders get "drive", photo batches get "photos". A snapshot
    /// can have neither (an ad-hoc restic backup) and then it counts only in the
    /// total, not under a source.
    private static let knownSources = ["drive", "photos"]

    /// Group snapshots by source tag, newest-per-source. restic lists snapshots
    /// oldest → newest, and filtering preserves that order, so `.last` is latest.
    private static func sourceBreakdown(_ snaps: [[String: Any]]) -> [SourceStatus] {
        knownSources.map { source in
            let matching = snaps.filter { (($0["tags"] as? [String]) ?? []).contains(source) }
            return SourceStatus(source: source, count: matching.count,
                                latestTime: matching.last?["time"] as? String)
        }
    }

    /// Query `restic snapshots --json` (+ a size stat) for the dashboard. This is
    /// strictly read-only — it never runs forget/prune. Reachability == the
    /// snapshots query returned; a transport/auth failure is captured in `error`.
    func remoteStatus() -> RemoteStatus {
        var status = RemoteStatus()
        do {
            let snaps = try snapshotsJSON(timeout: Self.probeTimeout)
            status.reachable = true
            status.snapshotCount = snaps.count
            // restic lists snapshots oldest → newest (verified against `restic
            // snapshots --json`), so the first one is oldest, the last is latest.
            if let latest = snaps.last {
                status.latestTime = latest["time"] as? String
                status.latestTags = (latest["tags"] as? [String]) ?? []
            }
            status.oldestTime = snaps.first?["time"] as? String
            status.sources = Self.sourceBreakdown(snaps)
            status.sizeBytes = repoSizeBytes(timeout: Self.probeTimeout)
        } catch {
            status.error = "\(error)"
        }
        return status
    }

    /// One restic snapshot's metadata, for the restore browser. The short id is
    /// enough to address the snapshot on a restore command line; `paths` is what
    /// the snapshot covers, `tags` carries our run/source labels (drive/photos).
    struct Snapshot {
        let shortID: String
        let id: String
        let time: String
        let hostname: String
        let tags: [String]
        let paths: [String]
    }

    /// One file found by `restic find`, for the single-file restore flow: its
    /// full path inside the snapshot (which is exactly what `--include` then takes),
    /// its type, size, which snapshot it was found in, and its mtime there (the
    /// `--history` command's per-version timestamp; restic's ISO8601 string, kept
    /// raw rather than parsed — every other display path in this tool truncates
    /// the same raw string instead of round-tripping through Date).
    struct Found {
        let path: String
        let type: String
        let size: Int?
        let snapshot: String
        let mtime: String?
    }

    /// Search `snapshot` (default: all snapshots when nil) for files matching
    /// `pattern` via `restic find --json`. Read-only. Returns one Found per match.
    /// The returned `path` is the full snapshot path to hand back to `--include`.
    func find(pattern: String, snapshot: String?) throws -> [Found] {
        var args = ["find", "--json"]
        if let snapshot, !snapshot.isEmpty { args += ["--snapshot", snapshot] }
        // `--` so a pattern starting with '-' is a pattern, not an option; the
        // timeout matches every other bounded read-only query (a wedged repo
        // otherwise stalls through restic's full retry backoff).
        args += ["--", pattern]
        let out = try runCapturing(args, command: "find", timeout: Self.probeTimeout)
        guard let start = out.firstIndex(of: "[") else { return [] }
        guard let data = String(out[start...]).data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        var found: [Found] = []
        for el in arr {
            let snap = (el["snapshot"] as? String) ?? ""
            for m in (el["matches"] as? [[String: Any]]) ?? [] {
                found.append(Found(
                    path: (m["path"] as? String) ?? "",
                    type: (m["type"] as? String) ?? "",
                    size: (m["size"] as? NSNumber)?.intValue,
                    snapshot: snap,
                    mtime: m["mtime"] as? String
                ))
            }
        }
        return found
    }

    /// One entry from `restic ls`: a file or directory inside a snapshot, with its
    /// full snapshot path and (for files) size. The path is exactly what
    /// `--restore --include` takes, so the browser doubles as restore discovery.
    struct LsEntry {
        let name: String
        let path: String
        let type: String   // "file" / "dir"
        let size: Int?
    }

    /// List the contents of `snapshot` via `restic ls --json`, optionally limited
    /// to the subtree under `path`. Read-only. restic emits a snapshot header line
    /// then one node line per entry (depth-first); we keep the nodes in that order.
    func ls(snapshot: String, path: String?) throws -> [LsEntry] {
        var args = ["ls", "--json", "--", snapshot]
        if let path, !path.isEmpty { args.append(path) }
        let out = try runCapturing(args, command: "ls", timeout: Self.probeTimeout)
        var entries: [LsEntry] = []
        for line in out.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (o["struct_type"] as? String) == "node" || (o["message_type"] as? String) == "node"
            else { continue }
            entries.append(LsEntry(
                name: (o["name"] as? String) ?? "",
                path: (o["path"] as? String) ?? "",
                type: (o["type"] as? String) ?? "",
                size: (o["size"] as? NSNumber)?.intValue))
        }
        return entries
    }

    /// List every entry in `snapshot` via `restic ls -l --json`, for the
    /// `--repo-usage` size aggregation. Distinct from `ls(snapshot:path:)` (the
    /// restore-discovery browser) so a future change to either one's shape
    /// doesn't have to worry about the other's callers, even though today they
    /// parse the same node JSON. `-l` (long) is restic's flag for including
    /// full file metadata in the listing; read-only like every other query here.
    func lsDetailed(snapshot: String) throws -> [LsEntry] {
        let out = try runCapturing(["ls", "-l", "--json", "--", snapshot], command: "ls", timeout: Self.probeTimeout)
        var entries: [LsEntry] = []
        for line in out.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (o["struct_type"] as? String) == "node" || (o["message_type"] as? String) == "node"
            else { continue }
            entries.append(LsEntry(
                name: (o["name"] as? String) ?? "",
                path: (o["path"] as? String) ?? "",
                type: (o["type"] as? String) ?? "",
                size: (o["size"] as? NSNumber)?.intValue))
        }
        return entries
    }

    /// One changed path from `restic diff`. `modifier` is restic's single-char
    /// code: `+` added, `-` removed, `M` content changed, `T` type changed,
    /// `U` metadata-only.
    struct DiffChange {
        let path: String
        let modifier: String
    }

    /// The result of diffing two snapshots: the per-path changes plus the
    /// added/removed/changed totals restic reports in its statistics line.
    struct DiffResult {
        let changes: [DiffChange]
        let addedFiles: Int
        let removedFiles: Int
        let changedFiles: Int
        let addedBytes: Int
        let removedBytes: Int
    }

    /// Diff two snapshots via `restic diff --json` (read-only): what changed going
    /// from `snapshotA` to `snapshotB`. Returns the changed paths and the summary
    /// statistics. Never modifies either snapshot.
    func diff(snapshotA: String, snapshotB: String) throws -> DiffResult {
        let out = try runCapturing(["diff", "--json", "--", snapshotA, snapshotB],
                                   command: "diff", timeout: Self.probeTimeout)
        var changes: [DiffChange] = []
        var addedFiles = 0, removedFiles = 0, changedFiles = 0, addedBytes = 0, removedBytes = 0
        for line in out.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = o["message_type"] as? String else { continue }
            switch type {
            case "change":
                changes.append(DiffChange(path: (o["path"] as? String) ?? "",
                                          modifier: (o["modifier"] as? String) ?? "?"))
            case "statistics":
                changedFiles = (o["changed_files"] as? NSNumber)?.intValue ?? 0
                if let added = o["added"] as? [String: Any] {
                    addedFiles = (added["files"] as? NSNumber)?.intValue ?? 0
                    addedBytes = (added["bytes"] as? NSNumber)?.intValue ?? 0
                }
                if let removed = o["removed"] as? [String: Any] {
                    removedFiles = (removed["files"] as? NSNumber)?.intValue ?? 0
                    removedBytes = (removed["bytes"] as? NSNumber)?.intValue ?? 0
                }
            default:
                break
            }
        }
        return DiffResult(changes: changes, addedFiles: addedFiles, removedFiles: removedFiles,
                          changedFiles: changedFiles, addedBytes: addedBytes, removedBytes: removedBytes)
    }

    /// The destination's snapshots, NEWEST FIRST (restic emits oldest→newest).
    /// Strictly read-only. Throws on a transport/auth failure so the caller can
    /// report it per destination rather than treating the repo as empty.
    func listSnapshots() throws -> [Snapshot] {
        let arr = try snapshotsJSON(timeout: Self.probeTimeout)
        let snaps = arr.map { o -> Snapshot in
            let id = (o["id"] as? String) ?? ""
            return Snapshot(
                shortID: (o["short_id"] as? String) ?? String(id.prefix(8)),
                id: id,
                time: (o["time"] as? String) ?? "",
                hostname: (o["hostname"] as? String) ?? "",
                tags: (o["tags"] as? [String]) ?? [],
                paths: (o["paths"] as? [String]) ?? []
            )
        }
        return snaps.reversed()
    }

    /// Parse `restic snapshots --json` into an array of dictionaries. In --json
    /// mode restic emits a single JSON array; we still slice from the first '['
    /// in case a stray line precedes it.
    private func snapshotsJSON(timeout: TimeInterval? = nil) throws -> [[String: Any]] {
        let out = try runCapturing(["snapshots", "--json"], command: "snapshots", timeout: timeout)
        guard let start = out.firstIndex(of: "[") else { return [] }
        let json = String(out[start...])
        guard let data = json.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return arr
    }
}
