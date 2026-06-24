import Foundation

enum ResticError: Error, CustomStringConvertible {
    case notFound
    case failed(command: String, code: Int32)

    var description: String {
        switch self {
        case .notFound:
            return "restic executable not found in PATH — install it (`brew install restic`) and re-run"
        case .failed(let cmd, let code):
            return "restic \(cmd) exited with code \(code) — see restic output above"
        }
    }
}

/// Thin wrapper around the `restic` CLI.
///
/// The Mac stays strictly write-only towards the store: this only ever runs
/// `init`/`backup`/`cat config`, never `forget`/`prune` (those run server-side
/// on the append-only host). Both secrets reach restic through the environment,
/// never argv (argv is world-readable via `ps`): the encryption password as
/// `RESTIC_PASSWORD`, and the repository URL as `RESTIC_REPOSITORY`. The URL
/// embeds the rest-server endpoint password, so it is just as sensitive as the
/// password — hence we never pass `-r` on the command line.
final class ResticBackend {
    let repository: String
    private let executable: String

    init(repository: String, executable: String = "restic") {
        self.repository = repository
        self.executable = executable
        // Export the repo URL so restic reads it from the environment instead of
        // an `-r` argument — the URL embeds the endpoint password and argv is
        // world-readable via `ps`. Idempotent; mirrors how RESTIC_PASSWORD flows.
        setenv("RESTIC_REPOSITORY", repository, 1)
    }

    /// Initialize the repo if it does not exist yet. Uses repository format v2
    /// so zstd compression is available (helps text/PDF; photos won't shrink).
    func ensureInitialized() throws {
        if try run(["cat", "config"], quiet: true) == 0 { return }
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
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = [executable] + args
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

    /// Run restic and return its exit code. With `quiet`, output is discarded
    /// (used for the existence probe); otherwise it is inherited so the user
    /// sees live progress. The child inherits our environment, so
    /// `RESTIC_PASSWORD` flows through without ever touching argv.
    private func run(_ args: [String], quiet: Bool = false) throws -> Int32 {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = [executable] + args
        // Feed /dev/null so a missing RESTIC_PASSWORD fails fast and visibly
        // instead of hanging on an interactive prompt we'd never see.
        proc.standardInput = FileHandle.nullDevice
        if quiet {
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
        }
        do { try proc.run() } catch { throw ResticError.notFound }
        proc.waitUntilExit()
        return proc.terminationStatus
    }
}
