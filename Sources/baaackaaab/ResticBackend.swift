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
/// on the append-only host). The repo password is read from the environment
/// (`RESTIC_PASSWORD`) and is NEVER passed as an argument — arguments are
/// visible to other processes via `ps`. The repository location is not secret
/// and is passed with `-r`.
final class ResticBackend {
    let repository: String
    private let executable: String

    init(repository: String, executable: String = "restic") {
        self.repository = repository
        self.executable = executable
    }

    /// Initialize the repo if it does not exist yet. Uses repository format v2
    /// so zstd compression is available (helps text/PDF; photos won't shrink).
    func ensureInitialized() throws {
        if try run(["-r", repository, "cat", "config"], quiet: true) == 0 { return }
        Console.step("restic: initializing repository (format v2) at \(Credentials.redact(repository))")
        let code = try run(["-r", repository, "init", "--repository-version", "2"])
        if code != 0 { throw ResticError.failed(command: "init", code: code) }
    }

    /// Back up the given paths into a single snapshot. restic output streams
    /// live to the terminal so progress is visible.
    func backup(paths: [URL], tags: [String], host: String?) throws {
        var args = ["-r", repository, "backup", "--compression", "auto"]
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
        guard let out = try? runCapturing(["-r", repository, "stats", "--quiet", "--mode", "raw-data", "--json"])
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

    /// Run restic capturing stdout as a string (stderr discarded). Throws on a
    /// non-zero exit. Used for the small JSON-emitting `stats` query, not for
    /// streaming commands. Reads the pipe to EOF before waiting so a large
    /// payload can't deadlock on a full pipe buffer.
    private func runCapturing(_ args: [String]) throws -> String {
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
            throw ResticError.failed(command: "stats", code: proc.terminationStatus)
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
