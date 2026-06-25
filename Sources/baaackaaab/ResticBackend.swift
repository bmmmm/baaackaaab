import Foundation

enum ResticError: Error, CustomStringConvertible {
    case notFound
    case failed(command: String, code: Int32)
    case timedOut(command: String, seconds: Int)

    var description: String {
        switch self {
        case .notFound:
            return "restic executable not found in PATH — install it (`brew install restic`) and re-run"
        case .failed(let cmd, let code):
            return "restic \(cmd) exited with code \(code) — see restic output above"
        case .timedOut(let cmd, let secs):
            return "restic \(cmd) did not respond within \(secs)s — the destination is unreachable or wedged. It is skipped this run; it is NOT treated as a missing repo, so nothing is re-initialized."
        }
    }
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
        if try run(["cat", "config"], quiet: true, timeout: Self.probeTimeout) == 0 { return }
        Console.step("restic: initializing repository (format v2) at \(Credentials.redact(repository))")
        let code = try run(["init", "--repository-version", "2"])
        if code != 0 { throw ResticError.failed(command: "init", code: code) }
    }

    /// Back up the given paths into a single snapshot. restic output streams
    /// live to the terminal so progress is visible.
    func backup(paths: [URL], tags: [String], host: String?) throws {
        var args = ["backup", "--compression", "auto"]
        if let host { args += ["--host", host] }
        for tag in tags { args += ["--tag", tag] }
        args += paths.map { $0.path }

        let names = paths.map { $0.lastPathComponent }.joined(separator: ", ")
        Console.step("restic: backup [\(names)] tags=\(tags.joined(separator: ","))")
        let code = try run(args)
        if code != 0 { throw ResticError.failed(command: "backup", code: code) }
    }

    /// Best-effort current repo data size in bytes, via
    /// `restic stats --mode raw-data --json`. This is the deduplicated blob
    /// size — a close, slightly low approximation of what the server's
    /// `--max-size` quota counts (which also includes index/metadata overhead).
    /// Returns nil if stats can't be read (e.g. a fresh repo with no snapshots,
    /// or the query failed), so the caller treats usage as unknown rather than
    /// failing the run over a missing gauge reading.
    func repoSizeBytes() -> Int? {
        // `--quiet` suppresses restic's progress counter, which it otherwise
        // prints on stdout *before* the JSON (e.g. "[0:00] 100.00% 1/1 ...").
        guard let out = try? runCapturing(["stats", "--quiet", "--mode", "raw-data", "--json"], command: "stats")
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
            let snaps = try snapshotsJSON()
            status.reachable = true
            status.snapshotCount = snaps.count
            // restic lists snapshots oldest → newest, so the last one is latest.
            if let latest = snaps.last {
                status.latestTime = latest["time"] as? String
                status.latestTags = (latest["tags"] as? [String]) ?? []
            }
            status.sources = Self.sourceBreakdown(snaps)
            status.sizeBytes = repoSizeBytes()
        } catch {
            status.error = "\(error)"
        }
        return status
    }

    /// Parse `restic snapshots --json` into an array of dictionaries. In --json
    /// mode restic emits a single JSON array; we still slice from the first '['
    /// in case a stray line precedes it.
    private func snapshotsJSON() throws -> [[String: Any]] {
        let out = try runCapturing(["snapshots", "--json"], command: "snapshots")
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
    /// payload can't deadlock on a full pipe buffer.
    private func runCapturing(_ args: [String], command: String) throws -> String {
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
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        if proc.terminationStatus != 0 {
            throw ResticError.failed(command: command, code: proc.terminationStatus)
        }
        return String(data: data, encoding: .utf8) ?? ""
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

        guard let timeout else {
            proc.waitUntilExit()
            return proc.terminationStatus
        }
        // Bounded wait: a background thread reaps the child and signals; if the
        // deadline passes first we terminate the (read-only) probe and report it.
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async { proc.waitUntilExit(); sem.signal() }
        if sem.wait(timeout: .now() + timeout) == .timedOut {
            proc.terminate()
            _ = sem.wait(timeout: .now() + 5)   // let SIGTERM land before returning
            throw ResticError.timedOut(command: args.first ?? "restic", seconds: Int(timeout))
        }
        return proc.terminationStatus
    }
}
