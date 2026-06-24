import Foundation
#if canImport(Darwin)
import Darwin
#endif

// The command center: the interactive home you drop into when you run
// `baaackaaab` on a terminal with no arguments. It ties the whole workflow
// together — see the backup set, see the remote, edit the set, run a sync —
// without remembering flags.
//
// This is a line-oriented (cooked-mode) menu on purpose. The folder/album
// editor (ConfigTUI) is a full-screen raw-mode TUI; launching it from a cooked
// menu is exactly like running `--configure` from the shell, which is robust.
// Nesting one raw-mode TUI inside another over the same tty is not — the inner
// editor's termios teardown leaves the outer reader unable to see input — so we
// deliberately keep the home cooked and let ConfigTUI own the screen alone.
//
//   edit set (e)  -> ConfigTUI (folder browser + album picker), then return
//   sync now (s)  -> re-execs this binary with --run-tag; the real backup output
//                    streams live, then we come back
//   remote (r)    -> read-only `restic snapshots`/`stats` for the dashboard
final class CommandCenter {
    private let configPath: URL
    private let repo: String?
    private var remote: ResticBackend.RemoteStatus?

    init(configPath: URL) {
        self.configPath = configPath
        // Resolve the repo (and load the Keychain password into our env) without
        // exiting — a missing repo just disables the remote panel.
        self.repo = CommandCenter.resolveRepoNonFatal()
    }

    // MARK: - Run loop

    func run() {
        Console.banner("baaackaaab", tagline: "command center")
        loop: while true {
            reclaimForeground()   // a child (restic, the editor, a sync) may have taken the tty's foreground group
            printDashboard()
            FileHandle.standardOutput.write(Data("\nchoose [e/s/r/q] > ".utf8))
            guard let raw = readLineRaw() else { break loop }   // EOF (Ctrl-D) → quit
            switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "e", "edit":   editSet()
            case "s", "sync":   syncNow()
            case "r", "remote": refreshRemote()
            case "q", "quit", "exit": break loop
            case "": break   // bare Enter just redraws
            default: Console.note("unknown choice — pick e (edit), s (sync), r (remote) or q (quit)")
            }
        }
        Console.note("bye")
    }

    // MARK: - Dashboard

    private func printDashboard() {
        let set = (try? BackupSet.load(from: configPath)) ?? BackupSet()
        Console.section("Backup set", detail: configPath.path)
        if set.isEmpty {
            Console.note("empty — choose e to add folders / albums")
        } else {
            var pairs: [(String, String)] = []
            for f in set.driveFolders { pairs.append(("drive", f)) }
            for a in set.photoAlbums { pairs.append(("album", a)) }
            if let q = set.quotaBytes { pairs.append(("quota", String(format: "%.1f GB", Double(q) / 1_000_000_000))) }
            Console.info(pairs)
        }

        Console.section("Remote")
        if let repo = repo {
            Console.info([("repo", Credentials.redact(repo))])
            printRemoteStatus()
        } else {
            Console.note("no repository configured — run `baaackaaab --init-credentials` first")
        }

        Console.section("Actions")
        Console.info([
            ("e", "edit the backup set (folders + Photos albums)"),
            ("s", "sync now — back up the set to the remote"),
            ("r", "refresh the remote status below"),
            ("q", "quit"),
        ])
    }

    private func printRemoteStatus() {
        guard let r = remote else {
            Console.note("status not queried yet — choose r to read snapshots + size")
            return
        }
        if let err = r.error {
            Console.warn("unreachable: \(err)")
            return
        }
        var parts = ["\(r.snapshotCount) snapshot(s)"]
        if let t = r.latestTime {
            let tags = r.latestTags.isEmpty ? "" : " [" + r.latestTags.joined(separator: ",") + "]"
            parts.append("latest " + shortTime(t) + tags)
        }
        if let s = r.sizeBytes { parts.append(String(format: "%.2f GB", Double(s) / 1_000_000_000)) }
        Console.success(parts.joined(separator: "  \u{2022}  "))
    }

    // MARK: - Actions

    /// Hand off to the full-screen folder/album editor, then return. ConfigTUI
    /// fully owns the terminal while it runs and restores it on exit.
    private func editSet() {
        ConfigTUI(configPath: configPath).run(embedded: true)   // suppress the exit hint; the menu shows its own actions
    }

    /// Run the real backup by re-execing this binary, streaming its output just
    /// like a manual run. The set must be non-empty.
    private func syncNow() {
        let set = (try? BackupSet.load(from: configPath)) ?? BackupSet()
        guard !set.isEmpty else {
            Console.warn("backup set is empty — choose e to add folders / albums first")
            return
        }
        Console.step("starting sync of \(set.driveFolders.count) folder(s) + \(set.photoAlbums.count) album(s)\u{2026}")
        let code = execSelf(args: syncArgs())
        if code == 0 {
            Console.success("sync finished")
            remote = nil   // the repo changed — drop the cached status
        } else {
            Console.error("sync exited with code \(code) — see the output above")
        }
    }

    /// Read-only refresh of the remote dashboard. Needs the repo + password.
    private func refreshRemote() {
        guard let repo = repo else {
            Console.warn("no repository — run `baaackaaab --init-credentials` first")
            return
        }
        guard resticPasswordAvailable() else {
            Console.warn("no encryption password in the Keychain — run --init-credentials")
            return
        }
        Console.step("querying remote\u{2026}")
        remote = ResticBackend(repository: repo).remoteStatus()
    }

    /// Read one line from the tty at the fd level (terminal stays in cooked
    /// mode, so the kernel echoes and returns a whole line per Enter). We avoid
    /// Swift's readLine(), whose buffered FILE* stdin gets out of sync with the
    /// raw fd-level reads ConfigTUI does while editing — after the editor, the
    /// FILE* buffer would swallow the next keystrokes. Returns nil on EOF.
    private func readLineRaw() -> String? {
        var buf = [UInt8](repeating: 0, count: 1024)
        var n = read(STDIN_FILENO, &buf, buf.count)
        while n < 0 && errno == EINTR { n = read(STDIN_FILENO, &buf, buf.count) }  // e.g. SIGWINCH on resize
        if n <= 0 { return nil }   // 0 == EOF (Ctrl-D)
        var s = String(decoding: buf[0..<n], as: UTF8.self)
        while s.hasSuffix("\n") || s.hasSuffix("\r") { s.removeLast() }
        return s
    }

    /// Reclaim the controlling tty's foreground process group for ourselves.
    /// A spawned child can leave us in the background; a background read then
    /// raises SIGTTIN and stops the process, so the menu would appear to hang.
    /// SIGTTOU is ignored because tcsetpgrp from the background would itself stop
    /// us. A no-op when we already own the foreground.
    private func reclaimForeground() {
        guard isatty(STDIN_FILENO) != 0 else { return }
        signal(SIGTTOU, SIG_IGN)
        _ = tcsetpgrp(STDIN_FILENO, getpgrp())
    }

    // MARK: - Credentials / self-exec

    /// Repo from --restic-repo, then RESTIC_REPOSITORY, then the Keychain. Loads
    /// the encryption password into our environment as a side effect (so an
    /// in-process restic query inherits it). Never exits — returns nil on miss.
    private static func resolveRepoNonFatal() -> String? {
        let env = ProcessInfo.processInfo.environment
        let repo = argValue("--restic-repo") ?? env["RESTIC_REPOSITORY"]
            ?? ((try? Keychain.get(account: Credentials.repoURLAccount)) ?? nil)
        if getenv("RESTIC_PASSWORD") == nil,
           let pw = (try? Keychain.get(account: Credentials.repoPasswordAccount)) ?? nil {
            setenv("RESTIC_PASSWORD", pw, 1)
        }
        return repo
    }

    private func syncArgs() -> [String] {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyyMMdd-HHmmss"
        var args = ["--run-tag", "tui-\(fmt.string(from: Date()))"]
        // Preserve a non-default config so the child backs up the same set.
        if configPath.path != BackupSet.defaultPath().path {
            args += ["--config", configPath.path]
        }
        return args
    }

    private func execSelf(args: [String]) -> Int32 {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: CommandCenter.selfPath())
        proc.arguments = args
        do { try proc.run() } catch {
            Console.error("could not launch backup: \(error)")
            return -1
        }
        proc.waitUntilExit()
        return proc.terminationStatus
    }

    private static func selfPath() -> String {
        if let p = Bundle.main.executablePath { return p }
        let arg0 = CommandLine.arguments.first ?? "baaackaaab"
        if arg0.hasPrefix("/") { return arg0 }
        return FileManager.default.currentDirectoryPath + "/" + arg0
    }

    /// "2026-06-24T17:30:32.1+02:00" -> "2026-06-24 17:30".
    private func shortTime(_ iso: String) -> String {
        String(iso.prefix(16)).replacingOccurrences(of: "T", with: " ")
    }
}
