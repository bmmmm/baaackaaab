import Foundation
#if canImport(Darwin)
import Darwin
#endif

enum TimerError: Error, CustomStringConvertible {
    case launchctl(Int32)

    var description: String {
        switch self {
        case .launchctl(let code):
            return "launchctl failed (code \(code)) — inspect `launchctl print gui/$(id -u)/\(LaunchdTimer.label)`"
        }
    }
}

/// The scheduled-backup LaunchAgent. Installs a per-user launchd job that runs
/// this binary daily with `--run-tag scheduled` — which is non-bare, so under
/// launchd (no TTY) it goes straight to the backup of the declarative set
/// instead of opening the TUI or printing usage.
///
/// The job runs in the user's GUI (aqua) session, so it can read the Keychain
/// and (with a granted TCC entitlement) Photos — same identity as an interactive
/// run. The catch: an ad-hoc-signed binary's code identity changes on every
/// rebuild, which resets its TCC grant and can re-lock the Keychain ACL. After a
/// rebuild, prime it once interactively (see the install hint).
enum LaunchdTimer {
    static let label = "io.baaackaaab.backup"

    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    private static var plistURL: URL { home.appendingPathComponent("Library/LaunchAgents/\(label).plist") }
    private static var logURL: URL { home.appendingPathComponent("Library/Logs/baaackaaab.log") }
    private static var domain: String { "gui/\(getuid())" }

    // MARK: - Install / uninstall / status

    /// Write (or rewrite) the LaunchAgent and load it. `configPath` is passed to
    /// the scheduled run only when it differs from the default, so the timer backs
    /// up the same set the user edits.
    static func install(hour: Int, minute: Int, configPath: URL) throws {
        Console.banner("baaackaaab", tagline: "scheduled backup")

        let exe = executablePath()
        try ensureDir(plistURL.deletingLastPathComponent())
        try ensureDir(logURL.deletingLastPathComponent())

        var program = [exe, "--run-tag", "scheduled"]
        if configPath.path != BackupSet.defaultPath().path {
            program += ["--config", configPath.path]
        }

        let xml = plistXML(program: program, hour: hour, minute: minute, log: logURL.path)
        try xml.write(to: plistURL, atomically: true, encoding: .utf8)

        Console.section("LaunchAgent", detail: plistURL.path)
        Console.info([
            ("binary", exe),
            ("schedule", String(format: "daily at %02d:%02d (runs at next wake if asleep)", hour, minute)),
            ("run-tag", "scheduled"),
            ("log", logURL.path),
        ])

        let set = (try? BackupSet.load(from: configPath)) ?? BackupSet()
        if set.isEmpty {
            Console.warn("the backup set is empty — the scheduled run backs up nothing until you add folders (`baaackaaab --configure`)")
        }

        // Reload cleanly: bootout any prior instance (ignore "not loaded"), then
        // bootstrap the fresh plist. Fall back to the legacy load/unload verbs on
        // systems where bootstrap is unavailable.
        _ = launchctl(["bootout", "\(domain)/\(label)"])
        if launchctl(["bootstrap", domain, plistURL.path]) != 0 {
            _ = launchctl(["unload", plistURL.path])
            let legacy = launchctl(["load", "-w", plistURL.path])
            if legacy != 0 { throw TimerError.launchctl(legacy) }
        }

        Console.success("timer installed and loaded")
        Console.warn("After every rebuild the binary's code identity changes, which resets its Photos (TCC) grant and can re-lock the Keychain ACL. Prime it once interactively after a rebuild: run `baaackaaab --check` (Keychain) and one manual backup with a Photos album (TCC), so the unattended run isn't blocked on a prompt it can't answer.")
        Console.note("verify:  launchctl print \(domain)/\(label)\nlogs:    tail -f \(logURL.path)\nremove:  baaackaaab --uninstall-timer")
    }

    /// Unload the job and delete the plist. Idempotent.
    static func uninstall() throws {
        Console.banner("baaackaaab", tagline: "scheduled backup")
        _ = launchctl(["bootout", "\(domain)/\(label)"])
        if FileManager.default.fileExists(atPath: plistURL.path) {
            try FileManager.default.removeItem(at: plistURL)
            Console.success("timer removed (\(plistURL.path))")
        } else {
            Console.note("no timer plist found — nothing to remove")
        }
    }

    /// Show whether the plist is present and what launchd knows about the job.
    static func status() {
        Console.banner("baaackaaab", tagline: "scheduled backup")
        Console.section("LaunchAgent", detail: plistURL.path)
        guard FileManager.default.fileExists(atPath: plistURL.path) else {
            Console.note("not installed — run `baaackaaab --install-timer` (optionally `--at HH:MM`)")
            return
        }
        Console.info([("plist", "present"), ("log", logURL.path)])
        Console.step("launchctl print \(domain)/\(label):")
        _ = launchctl(["print", "\(domain)/\(label)"])   // inherits stdout, shows live state
    }

    // MARK: - Helpers

    /// The real (symlink-resolved) path to this executable, embedded into the
    /// plist so launchd invokes a stable absolute path.
    private static func executablePath() -> String {
        if let p = Bundle.main.executablePath {
            return URL(fileURLWithPath: p).resolvingSymlinksInPath().path
        }
        return CommandLine.arguments.first ?? "baaackaaab"
    }

    private static func ensureDir(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    @discardableResult
    private static func launchctl(_ args: [String]) -> Int32 {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        proc.arguments = args
        do { try proc.run() } catch { return -1 }
        proc.waitUntilExit()
        return proc.terminationStatus
    }

    private static func plistXML(program: [String], hour: Int, minute: Int, log: String) -> String {
        let args = program.map { "        <string>\(xmlEscape($0))</string>" }.joined(separator: "\n")
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
        \(args)
            </array>
            <key>StartCalendarInterval</key>
            <dict>
                <key>Hour</key>
                <integer>\(hour)</integer>
                <key>Minute</key>
                <integer>\(minute)</integer>
            </dict>
            <key>StandardOutPath</key>
            <string>\(xmlEscape(log))</string>
            <key>StandardErrorPath</key>
            <string>\(xmlEscape(log))</string>
            <key>ProcessType</key>
            <string>Background</string>
            <key>LowPriorityIO</key>
            <true/>
        </dict>
        </plist>
        """
    }

    private static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
    }
}
