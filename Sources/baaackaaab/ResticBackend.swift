import Foundation

enum ResticError: Error, CustomStringConvertible {
    case notFound
    case failed(command: String, code: Int32)
    case timedOut(command: String, seconds: Int)
    case locked
    case wrongPassword

    var description: String {
        switch self {
        case .notFound:
            return "restic executable not found in PATH — install it (`brew install restic`) and re-run"
        case .failed(let cmd, let code):
            return "restic \(cmd) exited with code \(code) — see restic output above"
        case .timedOut(let cmd, let secs):
            return "restic \(cmd) did not respond within \(secs)s — the destination is unreachable or wedged. It is skipped this run; it is NOT treated as a missing repo, so nothing is re-initialized."
        case .locked:
            return "repository is locked by another restic operation (a backup/prune is running) — retry once it finishes, or clear a stale lock with `--unlock`. The repo is NOT re-initialized."
        case .wrongPassword:
            return "repository password is wrong — this destination's stored key cannot decrypt the repo. Check the key; the repo is NOT re-initialized."
        }
    }
}

/// The outcome of the read-only `cat config` existence probe, mapped from restic's
/// typed exit codes (restic 0.17+): 0 present, 10 absent, 11 locked, 12 wrong
/// password. Anything else (a transport error, a timeout, or an older restic that
/// only returns 1) is `.unreachable` — a state we can't classify further.
enum RepoProbe: Equatable {
    case present
    case absent
    case locked
    case wrongPassword
    case unreachable
}

/// Thin wrapper around the `restic` CLI.
///
/// The Mac stays strictly write-only towards the store: this only ever runs
/// `init`/`backup`/`cat config`, never `forget`/`prune` (those run server-side
/// on the append-only host). Both secrets reach restic through the environment,
/// never argv (argv is world-readable via `ps`): the encryption password via
/// `RESTIC_PASSWORD[_FILE]`, the repository URL via `RESTIC_REPOSITORY[_FILE]`.
/// The URL embeds the rest-server endpoint password, so it is just as sensitive
/// as the password — hence we never pass `-r` on the command line.
///
/// A `Destination` decides which env vars carry the secrets (file store vs.
/// explicit vs. legacy Keychain); the backend builds a private per-instance
/// environment from it and hands that to every restic child. So `repository`
/// here is only the URL string we keep for the redacted log line — restic itself
/// reads the repository + password from the environment of its own process.
final class ResticBackend {
    /// The repo URL for redacted display/logging (never used to reach restic —
    /// restic reads the repository from the environment we hand the child).
    let repository: String
    /// The destination this backend targets, for per-destination labelling.
    let destinationName: String
    /// Absolute path to the restic binary, resolved once at init. nil when it
    /// could not be found anywhere — every run then throws `ResticError.notFound`.
    private let executablePath: String?
    /// The exact environment handed to every restic child: the parent env with
    /// all RESTIC_* repo/password vars stripped, plus this destination's overlay.
    /// Carried per-instance (not via process-global setenv) so backing up to two
    /// destinations in one run can never cross-contaminate their secrets.
    private let environment: [String: String]

    init(destination: Destination, executable: String = "restic") {
        self.repository = destination.displayURL ?? destination.name
        self.destinationName = destination.name
        self.executablePath = Self.resolveExecutable(executable)
        self.environment = Self.childEnvironment(overlay: destination.envOverlay)
    }

    /// Build the environment for a restic child: the parent environment with ALL
    /// four RESTIC_* repo/password vars stripped, then exactly this destination's
    /// overlay applied. Stripping first guarantees restic never sees a stale
    /// RESTIC_REPOSITORY next to a RESTIC_REPOSITORY_FILE (it aborts on the pair),
    /// and that one destination's secret can never bleed into another's run.
    private static func childEnvironment(overlay: [String: String]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        for key in ["RESTIC_REPOSITORY", "RESTIC_REPOSITORY_FILE",
                    "RESTIC_PASSWORD", "RESTIC_PASSWORD_FILE"] {
            env.removeValue(forKey: key)
        }
        env.merge(overlay) { _, new in new }
        return env
    }

    /// The resolved restic binary path, or nil if not found anywhere. Static so a
    /// diagnostic (doctor) can report restic availability with no destination
    /// configured. Mirrors the per-instance resolution exactly.
    static func locateExecutable() -> String? { resolveExecutable("restic") }

    /// The restic version line (`restic version` → "restic 0.18.0 ..."), or nil if
    /// restic is missing / the call failed. Read-only, no repo touched. For doctor.
    static func resticVersion() -> String? {
        guard let exe = locateExecutable() else { return nil }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: exe)
        proc.arguments = ["version"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        proc.standardInput = FileHandle.nullDevice
        do { try proc.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?
            .split(separator: "\n").first.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Resolve the restic binary to an absolute path.
    ///
    /// We must NOT rely on `/usr/bin/env restic` / a bare PATH lookup: under
    /// launchd the inherited PATH is the minimal `/usr/bin:/bin:/usr/sbin:/sbin`,
    /// which does not include Homebrew — so the lookup fails with exit 127 and the
    /// scheduled backup would silently never run. Resolving an absolute path here,
    /// independent of the inherited PATH, is what makes the timer actually work.
    ///
    /// Order: an explicit absolute path (trusted if executable) → the `RESTIC_BIN`
    /// override → the common install locations (Homebrew arm64 + Intel, manual
    /// /usr/local, system) → finally a PATH walk for bespoke installs.
    private static func resolveExecutable(_ name: String) -> String? {
        let fm = FileManager.default
        if name.hasPrefix("/") {
            return fm.isExecutableFile(atPath: name) ? name : nil
        }
        if let override = ProcessInfo.processInfo.environment["RESTIC_BIN"],
           !override.isEmpty, fm.isExecutableFile(atPath: override) {
            return override
        }
        let candidates = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)",
        ]
        for path in candidates where fm.isExecutableFile(atPath: path) { return path }
        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            for dir in pathEnv.split(separator: ":") {
                let full = String(dir) + "/" + name
                if fm.isExecutableFile(atPath: full) { return full }
            }
        }
        return nil
    }

    /// Initialize the repo if it does not exist yet. Uses repository format v2
    /// so zstd compression is available (helps text/PDF; photos won't shrink).
    ///
    /// The existence probe is `cat config`: exit 0 means the repo is present, any
    /// other exit means "try to init". A missing restic binary no longer slips
    /// through here as a false "repo absent" — `run` throws `notFound` (resolved
    /// path nil), which propagates instead of triggering a bogus init. `init`
    /// itself refuses to clobber an existing repo, so a misread transient failure
    /// cannot destroy data — it just surfaces init's own error.
    func ensureInitialized() throws {
        // Bound the existence probe: on an unreachable/wedged destination restic
        // retries the failing backend request ~10× with exponential backoff,
        // which can stall for minutes. With several destinations that would make
        // one dead repo hold up the whole run, so we cap the probe — a timeout
        // throws `timedOut` (destination skipped), never a false "repo absent".
        let code = try run(["cat", "config"], quiet: true, timeout: Self.probeTimeout)
        switch code {
        case 0:
            return                              // repo present and readable
        case 11:
            throw ResticError.locked            // repo EXISTS but is locked — never init
        case 12:
            throw ResticError.wrongPassword     // repo EXISTS, key is wrong — never init
        default:
            break                               // 10 (absent) / 1 (older restic) / other → init
        }
        // Reached only for exit 10 (repo absent, restic 0.17+) or a generic
        // non-zero from an older restic. `init` refuses to clobber an existing
        // repo, so even a misclassified probe cannot destroy data — it just
        // surfaces init's own "already initialized" error.
        Console.step("restic: initializing repository (format v2) at \(Credentials.redact(repository))")
        let initCode = try run(["init", "--repository-version", "2"])
        if initCode != 0 { throw ResticError.failed(command: "init", code: initCode) }
    }

    /// Back up the given paths into a single snapshot. `dryRun` passes
    /// `--dry-run --verbose` so restic reports what WOULD be backed up (new /
    /// changed bytes) and uploads nothing — a true preview that touches the repo
    /// read-only. `limitUploadKiBps`, when > 0, throttles the upload via
    /// `--limit-upload` (KiB/s); it is irrelevant on a dry run (nothing uploads).
    /// `restConnections`, when > 0, caps the REST backend's connection pool via
    /// the global `-o rest.connections=N` option, applied on a dry run too since
    /// it bounds the backend's concurrency, not the upload itself.
    ///
    /// `showProgress` (a real backup on a TTY) switches restic to `--json` and
    /// renders a parsed, self-rewriting progress bar; otherwise restic's own
    /// output streams straight to the terminal. The dry-run path always keeps the
    /// plain `--verbose` output — there its value is the file list, not a bar — and
    /// off a TTY (launchd / a pipe) we never use --json so the log stays readable.
    /// macOS filesystem junk that appears in every iCloud Drive folder and carries
    /// no user data — Finder/Spotlight indexes, trash + revision metadata, temp
    /// scratch. Excluded on EVERY backup: on the append-only store the Mac can
    /// never prune, so anything snapshotted is permanent. Keeping this junk out is
    /// therefore not just tidiness — once in, it can never be removed. Slash-less
    /// patterns match the base name at any depth (restic matches on path
    /// components), so these catch the files/dirs wherever they appear in the tree.
    static let junkExcludes = [
        ".DS_Store", ".Trashes", ".Spotlight-V100",
        ".fseventsd", ".DocumentRevisions-V100", ".TemporaryItems",
    ]

    func backup(paths: [URL], tags: [String], host: String?,
                dryRun: Bool = false, limitUploadKiBps: Int? = nil,
                packSizeMiB: Int? = nil, restConnections: Int? = nil,
                excludes: [String] = [], excludeFiles: [String] = [],
                showProgress: Bool = false) throws {
        // `--skip-if-unchanged`: when a source is byte-for-byte identical to its
        // parent snapshot, restic creates NO new snapshot. On the append-only
        // store — which the Mac can never prune — this stops every scheduled run
        // from piling up an identical snapshot per unchanged folder. Data is never
        // lost: an unchanged tree is already fully captured by the parent.
        var args = ["backup", "--compression", "auto", "--skip-if-unchanged"]
        // Excludes: the always-on macOS-junk defaults + `--exclude-caches` (drops
        // any directory tagged with CACHEDIR.TAG), then the user's own set globs
        // and exclude-files. Applied on every run so the un-prunable store never
        // accumulates junk it can never shed. The caller has already dropped any
        // missing exclude-file, so restic never fails the run over a stale path.
        args += ["--exclude-caches"]
        for pattern in Self.junkExcludes { args += ["--exclude", pattern] }
        for pattern in excludes where !pattern.isEmpty { args += ["--exclude", pattern] }
        for file in excludeFiles where !file.isEmpty { args += ["--exclude-file", file] }
        if let limitUploadKiBps, limitUploadKiBps > 0, !dryRun {
            args += ["--limit-upload", String(limitUploadKiBps)]
        }
        // Larger target pack size ⇒ fewer, bigger objects on the backend ⇒ fewer
        // round-trips over a network REST/S3 store (at the cost of more RAM and
        // more re-upload on an interrupted transfer). Optional; restic's default
        // target is 16 MiB when unset.
        if let packSizeMiB, packSizeMiB > 0 {
            args += ["--pack-size", String(packSizeMiB)]
        }
        if dryRun { args += ["--dry-run", "--verbose"] }
        if let host { args += ["--host", host] }
        for tag in tags { args += ["--tag", tag] }
        args += paths.map { $0.path }
        // REST-backend connection cap: restic parses `-o key=value` as a GLOBAL
        // option, so it must precede the subcommand — prepended to the whole
        // argument list rather than appended like the flags above. restic's own
        // default is 5 parallel connections; a small store host can 502 under
        // that much concurrency on pack uploads (see issue #6). This is
        // backend-specific (restic ignores it for a non-REST repo, e.g. the
        // local-filesystem repos the integration tests use), so it is safe to
        // pass unconditionally whenever configured. Only wired into `backup` —
        // the read-only commands (check, restore, snapshots, ls, find, diff,
        // stats) were not observed to trigger the 502s and stay unthrottled.
        if let restConnections, restConnections > 0 {
            args = ["-o", "rest.connections=\(restConnections)"] + args
        }

        let names = paths.map { $0.lastPathComponent }.joined(separator: ", ")
        let mode = dryRun ? " (dry run — nothing uploaded)" : ""
        Console.step("restic: backup [\(names)] tags=\(tags.joined(separator: ","))\(mode)")

        if showProgress && !dryRun {
            let bar = BackupProgressBar(label: destinationName)
            let code = try runBackupJSON(args + ["--json"],
                                         onStatus: { bar.update($0) },
                                         onSummary: { bar.finish($0) })
            bar.clear()   // wipe a half-drawn bar if no summary arrived (cancel/fail)
            try finishBackup(code: code)
            return
        }

        let code = try run(args)
        try finishBackup(code: code)
    }

    /// Interpret a `restic backup` exit code. 0 is a clean success. Exit 3 means
    /// restic created a VALID but incomplete snapshot because some source files
    /// could not be read — they changed or vanished mid-backup, which is routine
    /// against a live iCloud FileProvider / Photos tree. The snapshot landed and
    /// is restorable, so this is a warning, not a destination failure: returning
    /// (instead of throwing) keeps the destination marked ok. Any other non-zero
    /// code is a real failure. A cancel surfaces as 130 here and IS thrown, so the
    /// caller's isCancelled check turns it into a clean RunCancelled.
    private func finishBackup(code: Int32) throws {
        switch code {
        case 0:
            return
        case 3:
            Console.warn("\(destinationName): restic finished with warnings (exit 3) — a valid snapshot was created, but some source files could not be read (changed or vanished mid-backup). They will be picked up next run.")
        case 11:
            // Same typed codes the probe maps: a mid-run lock (a server-side
            // prune, a concurrent restic) or a wrong key deserve their precise
            // message here too, not a generic "exited with code 11".
            throw ResticError.locked
        case 12:
            throw ResticError.wrongPassword
        default:
            throw ResticError.failed(command: "backup", code: code)
        }
    }

    /// Run `restic backup --json`, parsing the newline-delimited JSON stream and
    /// forwarding status / summary messages to the caller (which renders the bar).
    /// Returns restic's exit code. stderr is left inherited so restic's warnings /
    /// errors stay visible alongside the bar. The child is registered with
    /// BackupCancellation exactly like `run`, so Ctrl-C interrupts restic (exit
    /// 130) instead of hard-killing us; the pipe then hits EOF and the loop ends.
    private func runBackupJSON(_ args: [String],
                               onStatus: (ResticStatus) -> Void,
                               onSummary: (ResticSummary) -> Void) throws -> Int32 {
        guard let exe = executablePath else { throw ResticError.notFound }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: exe)
        proc.arguments = args
        proc.environment = environment   // this destination's repo + password
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = FileHandle.standardError   // keep restic's diagnostics visible
        proc.standardInput = FileHandle.nullDevice      // never block on a password prompt
        do { try proc.run() } catch { throw ResticError.notFound }
        BackupCancellation.shared.setCurrent(proc)
        defer { BackupCancellation.shared.clearCurrent(proc) }

        // Read stdout line by line. `availableData` blocks until data arrives or
        // returns empty at EOF; we split the rolling buffer on '\n' so a JSON
        // object spanning two reads is still decoded once it completes.
        let reader = outPipe.fileHandleForReading
        var buffer = Data()
        while true {
            let chunk = reader.availableData
            if chunk.isEmpty { break }   // EOF — restic exited and closed the pipe
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<nl)
                buffer.removeSubrange(buffer.startIndex...nl)
                Self.dispatchJSONLine(line, onStatus: onStatus, onSummary: onSummary)
            }
        }
        if !buffer.isEmpty {
            Self.dispatchJSONLine(buffer, onStatus: onStatus, onSummary: onSummary)
        }
        proc.waitUntilExit()
        return proc.terminationStatus
    }

    /// Decode one `restic backup --json` line and dispatch it by message_type.
    /// Non-JSON lines and types we don't render (e.g. verbose_status) are ignored;
    /// `error` messages are echoed to stderr so a failure isn't swallowed.
    private static func dispatchJSONLine(_ data: Data,
                                         onStatus: (ResticStatus) -> Void,
                                         onSummary: (ResticSummary) -> Void) {
        guard !data.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["message_type"] as? String else { return }
        func int(_ k: String) -> Int { (obj[k] as? NSNumber)?.intValue ?? 0 }
        func dbl(_ k: String) -> Double { (obj[k] as? NSNumber)?.doubleValue ?? 0 }
        switch type {
        case "status":
            onStatus(ResticStatus(
                percentDone: dbl("percent_done"), totalFiles: int("total_files"),
                filesDone: int("files_done"), totalBytes: int("total_bytes"),
                bytesDone: int("bytes_done")))
        case "summary":
            onSummary(ResticSummary(
                filesNew: int("files_new"), filesChanged: int("files_changed"),
                dataAdded: int("data_added"), totalDuration: dbl("total_duration"),
                snapshotID: obj["snapshot_id"] as? String))
        case "error":
            let msg = (obj["error"] as? [String: Any])?["message"] as? String
                ?? (obj["error"] as? String) ?? "unknown error"
            FileHandle.standardError.write(Data(("\nrestic: " + msg + "\n").utf8))
        default:
            break   // verbose_status and any future types: not rendered
        }
    }

    /// Read-only existence probe: true when the repository is present and
    /// reachable (`cat config` exits 0), WITHOUT ever initializing it.
    func exists() -> Bool { probe() == .present }

    /// Classify the repository with a single read-only `cat config`, WITHOUT ever
    /// initializing it. Maps restic's typed exit codes (0.17+) to a `RepoProbe` so
    /// the dry-run preview can tell "not created yet" from "locked" / "wrong key" /
    /// "unreachable" and give a precise skip reason instead of one catch-all. A
    /// timeout or an older restic that only returns 1 lands in `.unreachable`.
    /// Bounded like the init probe so a dead destination is skipped quickly rather
    /// than stalling on restic's backend retries.
    func probe() -> RepoProbe {
        let code: Int32
        do { code = try run(["cat", "config"], quiet: true, timeout: Self.probeTimeout) }
        catch { return .unreachable }   // timedOut / notFound → can't classify
        switch code {
        case 0:  return .present
        case 10: return .absent
        case 11: return .locked
        case 12: return .wrongPassword
        default: return .unreachable
        }
    }

    /// Restore a snapshot into `target`. `dryRun` previews (writes nothing);
    /// `include` restores only that LITERAL subpath; `verify` re-reads the restored
    /// files against the repo afterward. Streams restic's output. This only READS
    /// the repository — restore never modifies or deletes a snapshot, so it keeps
    /// the read + append-only invariant. (`--verify` and `--dry-run` are mutually
    /// exclusive in restic, so verify is dropped on a dry run.)
    ///
    /// `--include` is a restic glob (filepath.Match), but every documented use of
    /// this path passes a literal path the user copied from `--ls`/`--find`. So we
    /// escape the glob metacharacters (as restoreVerify already does) — otherwise a
    /// real path like "IMG[1].jpg" would match nothing and silently restore zero
    /// files (exit 0). Folder subtrees have no metacharacters, so escaping is a
    /// no-op for them.
    func restore(snapshot: String, target: URL, include: String?, dryRun: Bool, verify: Bool) throws {
        // Flags first, the user-controlled positional after `--`: a snapshot id
        // pasted with a leading '-' must reach restic as a value, never be
        // parsed as an option.
        var args = ["restore", "--target", target.path]
        if let include, !include.isEmpty { args += ["--include", Self.escapeResticPattern(include)] }
        if dryRun {
            args += ["--dry-run", "--verbose"]
        } else if verify {
            args += ["--verify"]
        }
        args += ["--", snapshot]
        let code = try run(args)
        if code != 0 { throw ResticError.failed(command: "restore", code: code) }
    }

    /// Restore specific paths (each passed as `--include`) into `target` WITH
    /// `--verify`, capturing the exit code and combined output instead of throwing
    /// — for the sampled test-restore, where a non-zero exit IS the result to
    /// report. restic recreates each file at `target` + its original absolute path,
    /// then re-reads it against the repo. Read-only towards the repository; the
    /// caller restores into (and then deletes) a throwaway temp dir.
    func restoreVerify(snapshot: String, target: URL, includes: [String]) -> (code: Int32, output: String) {
        var args = ["restore", "--target", target.path, "--verify"]
        for inc in includes where !inc.isEmpty { args += ["--include", Self.escapeResticPattern(inc)] }
        args += ["--", snapshot]
        return runCapturingResult(args)
    }

    /// Escape restic include-pattern metacharacters so an EXACT file path matches
    /// itself literally. restic treats `--include` as a glob (filepath.Match-style:
    /// `*`, `?`, `[...]`, with `\` as the escape char), so a path containing those
    /// characters — common in Photos/iCloud exports, e.g. "IMG[1].jpg" — would
    /// otherwise match nothing and silently restore zero files (exit 0). The
    /// test-restore passes literal paths, so backslash-escape the metacharacters
    /// (and the escape char itself) to force a literal match.
    private static func escapeResticPattern(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            if ch == "\\" || ch == "*" || ch == "?" || ch == "[" || ch == "]" { out.append("\\") }
            out.append(ch)
        }
        return out
    }

    /// The outcome of a `restic check` integrity pass.
    struct CheckResult {
        /// restic exited 0 — no integrity problems were reported.
        let clean: Bool
        /// The combined restic output (progress + final verdict).
        let output: String
        /// The subset of output lines that name a concrete problem (errors,
        /// broken/damaged packs, missing blobs) — what to surface on a failure.
        let errorLines: [String]
        /// A non-zero exit caused by NOT being able to acquire the repository lock
        /// (a backup/prune is in progress), as opposed to actual damage. The repo
        /// is fine; the check just couldn't run — so it must NOT be reported as a
        /// damage verdict.
        let lockedOut: Bool
    }

    /// Verify repository integrity with `restic check`. Always checks the repo
    /// STRUCTURE (index ↔ pack consistency); when `readDataSubset` is given
    /// (e.g. "5%", "1/10", "10M") it additionally re-reads and re-hashes that
    /// fraction of the actual pack data to catch on-disk bit-rot the structural
    /// pass alone cannot see. Strictly READ-ONLY — `check` never writes to, prunes,
    /// or repairs the repo, so it preserves the read + append-only invariant. The
    /// verdict is keyed off restic's exit code (0 = no errors); the output is
    /// captured so concrete problem lines can be shown.
    func checkRepo(readDataSubset: String?) -> CheckResult {
        var args = ["check"]
        if let s = readDataSubset, !s.isEmpty { args.append("--read-data-subset=\(s)") }
        let (code, out) = runCapturingResult(args)
        let clean = code == 0
        let lower = out.lowercased()
        // A non-zero exit because the repo is locked (a concurrent backup/prune
        // holds it) is NOT damage — distinguish it so the operator isn't told to
        // repair a healthy repo. restic 0.17+ returns exit 11 specifically for a
        // lock failure; prefer that stable signal and keep the string match as a
        // fallback for older restic (whose message wording could still drift).
        let lockedOut = !clean && (code == 11
            || lower.contains("unable to create lock")
            || lower.contains("already locked")
            || lower.contains("unable to acquire"))
        let errorLines = out.split(separator: "\n").map(String.init).filter {
            let l = $0.lowercased()
            return l.contains("error") || l.contains("broken")
                || l.contains("damaged") || l.contains("does not exist")
        }
        return CheckResult(clean: clean, output: out, errorLines: errorLines, lockedOut: lockedOut)
    }

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

    /// Remove repository locks: STALE locks only (`restic unlock`) or EVERY lock
    /// (`--remove-all`). This is the ONE operation baaackaaab runs that deletes
    /// from a repo — and restic's `unlock` only ever removes lock files (it is
    /// hardcoded to the locks/ prefix), never a snapshot or a pack, so it cannot
    /// destroy backup data. On an append-only rest-server the locks/ prefix must
    /// be carved out of the append-only restriction for this to work; if it is
    /// not, the server returns 403 and unlock simply fails — which is safe (it
    /// changes nothing). Returns the exit code and combined output.
    func unlock(removeAll: Bool) -> (code: Int32, output: String) {
        var args = ["unlock"]
        if removeAll { args.append("--remove-all") }
        return runCapturingResult(args)
    }

    /// Best-effort current repo data size in bytes, via
    /// `restic stats --mode raw-data --json`. This is the deduplicated blob
    /// size — a close, slightly low approximation of what the server's
    /// `--max-size` quota counts (which also includes index/metadata overhead).
    /// Returns nil if stats can't be read (e.g. a fresh repo with no snapshots,
    /// or the query failed), so the caller treats usage as unknown rather than
    /// failing the run over a missing gauge reading.
    func repoSizeBytes(timeout: TimeInterval? = nil) -> Int? {
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
            // restic lists snapshots oldest → newest, so the last one is latest.
            if let latest = snaps.last {
                status.latestTime = latest["time"] as? String
                status.latestTags = (latest["tags"] as? [String]) ?? []
            }
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
    /// its type, size, and which snapshot it was found in.
    struct Found {
        let path: String
        let type: String
        let size: Int?
        let snapshot: String
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
                    snapshot: snap
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

    /// Run restic capturing stdout as a string (stderr discarded). Throws on a
    /// non-zero exit, labelled with `command` so the caller's subcommand surfaces
    /// in the error (not a generic one). Used for the small JSON-emitting queries,
    /// not for streaming commands. Reads the pipe to EOF before waiting so a large
    /// payload can't deadlock on a full pipe buffer. `timeout`, when set, caps the
    /// wall clock — on expiry the child is terminated and `timedOut` is thrown;
    /// only ever used for read-only queries, never for writes.
    private func runCapturing(_ args: [String], command: String, timeout: TimeInterval? = nil) throws -> String {
        guard let exe = executablePath else { throw ResticError.notFound }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: exe)
        proc.arguments = args
        proc.environment = environment   // this destination's repo + password
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        proc.standardInput = FileHandle.nullDevice   // never block on a password prompt
        do { try proc.run() } catch { throw ResticError.notFound }
        guard let timeout else {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            if proc.terminationStatus != 0 {
                throw ResticError.failed(command: command, code: proc.terminationStatus)
            }
            return String(data: data, encoding: .utf8) ?? ""
        }
        let capture = SyncBox<Data>(Data())
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            capture.value = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            sem.signal()
        }
        if sem.wait(timeout: .now() + timeout) == .timedOut {
            forceTerminate(proc, reaped: sem)
            throw ResticError.timedOut(command: args.first ?? "restic", seconds: Int(timeout))
        }
        if proc.terminationStatus != 0 {
            throw ResticError.failed(command: command, code: proc.terminationStatus)
        }
        return String(data: capture.value, encoding: .utf8) ?? ""
    }

    /// Run restic capturing stdout AND stderr together, returning the exit code and
    /// the combined output WITHOUT throwing on a non-zero exit. Used by the commands
    /// where a non-zero exit is itself the signal to report (check, unlock) rather
    /// than an error to propagate. Reads the pipe to EOF before waiting so a large
    /// payload can't deadlock on a full pipe buffer. Never used for a streaming or
    /// writing-to-user-data command — these are repo-side maintenance queries.
    private func runCapturingResult(_ args: [String]) -> (code: Int32, output: String) {
        guard let exe = executablePath else {
            return (127, "restic executable not found — install it (`brew install restic`) and re-run")
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: exe)
        proc.arguments = args
        proc.environment = environment   // this destination's repo + password
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe        // merge stderr so progress + verdict are one stream
        proc.standardInput = FileHandle.nullDevice   // never block on a password prompt
        do { try proc.run() } catch { return (127, "could not launch restic: \(error)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return (proc.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    /// Wall-clock cap for the read-only existence probe (`cat config`). Long
    /// enough that a briefly-slow but reachable server still answers; short
    /// enough that a genuinely dead destination is skipped quickly instead of
    /// stalling the whole multi-destination run on restic's backend retries.
    private static let probeTimeout: TimeInterval = 60

    /// Run restic and return its exit code. With `quiet`, output is discarded
    /// (used for the existence probe); otherwise it is inherited so the user sees
    /// live progress. `timeout`, when set, bounds the wall clock: on expiry the
    /// child is terminated (SIGTERM) and `timedOut` is thrown — only ever used
    /// for the read-only probe, never for a writing command we must not kill
    /// mid-flight. The child reads repo + password from `environment`, never argv.
    private func run(_ args: [String], quiet: Bool = false, timeout: TimeInterval? = nil) throws -> Int32 {
        guard let exe = executablePath else { throw ResticError.notFound }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: exe)
        proc.arguments = args
        proc.environment = environment   // this destination's repo + password
        // Feed /dev/null so a missing RESTIC_PASSWORD fails fast and visibly
        // instead of hanging on an interactive prompt we'd never see.
        proc.standardInput = FileHandle.nullDevice
        if quiet {
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
        }
        do { try proc.run() } catch { throw ResticError.notFound }
        // Track the child so a SIGINT/SIGTERM during a backup interrupts restic
        // (it writes its partial snapshot, exits 130) instead of hard-killing us.
        // No-op unless a run has armed BackupCancellation.
        BackupCancellation.shared.setCurrent(proc)
        defer { BackupCancellation.shared.clearCurrent(proc) }

        guard let timeout else {
            proc.waitUntilExit()
            return proc.terminationStatus
        }
        // Bounded wait: a background thread reaps the child and signals; if the
        // deadline passes first we terminate the (read-only) probe and report it.
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async { proc.waitUntilExit(); sem.signal() }
        if sem.wait(timeout: .now() + timeout) == .timedOut {
            forceTerminate(proc, reaped: sem)
            throw ResticError.timedOut(command: args.first ?? "restic", seconds: Int(timeout))
        }
        return proc.terminationStatus
    }

    /// Stop a timed-out child and make sure it actually dies. We SIGTERM it first
    /// (graceful), then wait up to 5 s for the reaper thread to observe the exit;
    /// if it is still running it is wedged ignoring SIGTERM, so escalate to SIGKILL
    /// — otherwise the child AND the blocked reaper thread leak. Only ever called
    /// for read-only probes/queries, never a writing backup we must let finish.
    private func forceTerminate(_ proc: Process, reaped sem: DispatchSemaphore) {
        proc.terminate()                                   // SIGTERM
        if sem.wait(timeout: .now() + 5) == .timedOut, proc.isRunning {
            kill(proc.processIdentifier, SIGKILL)
            _ = sem.wait(timeout: .now() + 5)              // let the reaper see the exit
        }
    }
}
