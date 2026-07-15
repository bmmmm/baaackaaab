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

/// A backup schedule: one or more times of day, optionally restricted to specific
/// weekdays. An empty `weekdays` means every day. Weekday numbers follow launchd's
/// StartCalendarInterval convention: 0 (or 7) = Sunday, 1 = Monday … 6 = Saturday.
/// The launchd job fires once per (weekday × time) combination.
struct Schedule {
    var times: [(hour: Int, minute: Int)]
    var weekdays: [Int]   // empty = daily

    /// Short three-letter weekday name (Sun…Sat) for a launchd weekday number.
    static func weekdayName(_ wd: Int) -> String {
        let names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        return names[((wd % 7) + 7) % 7]
    }

    /// Human-readable summary, e.g. "daily at 12:00" or "Mon, Wed, Fri at 09:00, 18:00".
    func describe() -> String {
        let t = times.map { String(format: "%02d:%02d", $0.hour, $0.minute) }.joined(separator: ", ")
        if weekdays.isEmpty { return "daily at \(t)" }
        let days = weekdays.sorted().map { Self.weekdayName($0) }.joined(separator: ", ")
        return "\(days) at \(t)"
    }
}

/// The scheduled-backup LaunchAgent. Installs a per-user launchd job that runs
/// this binary daily with `--run-tag scheduled` — which is non-bare, so under
/// launchd (no TTY) it goes straight to the backup of the declarative set
/// instead of opening the TUI or printing usage.
///
/// The job runs in the user's GUI (aqua) session, so it can reach Photos (with a
/// granted TCC entitlement) — same identity as an interactive run. The restic
/// secrets come from the 0600 credential files (read directly by restic), so the
/// run needs no Keychain and no live login session for the secrets. The one
/// thing still keyed on code identity is the Photos TCC grant: build with a
/// stable signing identity (`make release` re-signs after each build), otherwise
/// an ad-hoc binary's identity churns on every rebuild and resets that grant.
/// With a stable identity, grant Photos once and it persists.
enum LaunchdTimer {
    static let label = "io.baaackaaab.backup"

    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    private static var plistURL: URL { home.appendingPathComponent("Library/LaunchAgents/\(label).plist") }
    private static var logURL: URL { home.appendingPathComponent("Library/Logs/baaackaaab.log") }
    private static var domain: String { "gui/\(getuid())" }

    // MARK: - Install / uninstall / status

    /// Write (or rewrite) the LaunchAgent and load it. `configPath` is passed to
    /// the scheduled run only when it differs from the default, so the timer backs
    /// up the same set the user edits. `schedule` carries one or more times and an
    /// optional weekday restriction; launchd fires once per (weekday × time).
    static func install(schedule: Schedule, configPath: URL) throws {
        Console.banner("baaackaaab", tagline: "scheduled backup")

        let exe = executablePath()
        try ensureDir(plistURL.deletingLastPathComponent())
        try ensureDir(logURL.deletingLastPathComponent())

        var program = [exe, "--run-tag", "scheduled"]
        if configPath.path != BackupSet.defaultPath().path {
            program += ["--config", configPath.path]
        }

        let xml = plistXML(program: program, schedule: schedule, log: logURL.path)
        try xml.write(to: plistURL, atomically: true, encoding: .utf8)

        Console.section("LaunchAgent", detail: plistURL.path)
        Console.info([
            ("binary", exe),
            ("schedule", "\(schedule.describe()) (runs at next wake if asleep)"),
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
        Console.warn("Build with `make release` so the binary carries a stable code-signing identity — then its Photos (TCC) grant survives rebuilds. restic reads the credential files directly, so no Keychain grant is needed; the only one-time grant is Photos: run one manual backup of a Photos album so the unattended run isn't blocked on a prompt it can't answer. Verify the path end-to-end with `baaackaaab --check`. If you ever rebuild with bare `swift build`, re-run `make sign` to restore the identity.")
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

    /// Whether the timer plist is on disk and whether launchd has it loaded, read
    /// WITHOUT printing (unlike `status()`). For the doctor diagnostic.
    static func state() -> (installed: Bool, loaded: Bool) {
        let installed = FileManager.default.fileExists(atPath: plistURL.path)
        guard installed else { return (false, false) }
        return (true, launchctlQuiet(["print", "\(domain)/\(label)"]) == 0)
    }

    /// launchctl with output discarded — for the quiet `state()` probe.
    private static func launchctlQuiet(_ args: [String]) -> Int32 {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        proc.arguments = args
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return -1 }
        proc.waitUntilExit()
        return proc.terminationStatus
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

    /// The StartCalendarInterval value for a schedule: a single `<dict>` for one
    /// (weekday × time) entry, an `<array>` of dicts for several. launchd fires the
    /// job once per entry.
    private static func calendarIntervalXML(_ schedule: Schedule) -> String {
        let days: [Int?] = schedule.weekdays.isEmpty ? [nil] : schedule.weekdays.sorted().map { Optional($0) }
        var entries: [(weekday: Int?, hour: Int, minute: Int)] = []
        for d in days { for t in schedule.times { entries.append((d, t.hour, t.minute)) } }
        if entries.isEmpty { entries = [(nil, 12, 0)] }   // never emit an empty interval

        func dict(_ e: (weekday: Int?, hour: Int, minute: Int), indent: String) -> String {
            var body = ""
            if let wd = e.weekday {
                body += "\(indent)    <key>Weekday</key>\n\(indent)    <integer>\(wd)</integer>\n"
            }
            body += "\(indent)    <key>Hour</key>\n\(indent)    <integer>\(e.hour)</integer>\n"
            body += "\(indent)    <key>Minute</key>\n\(indent)    <integer>\(e.minute)</integer>"
            return "\(indent)<dict>\n\(body)\n\(indent)</dict>"
        }

        if entries.count == 1 {
            return dict(entries[0], indent: "    ")
        }
        let dicts = entries.map { dict($0, indent: "        ") }.joined(separator: "\n")
        return "    <array>\n\(dicts)\n    </array>"
    }

    /// Read the installed plist's schedule back (times + weekdays), for the TUI to
    /// show the current state. nil when no plist is present or it can't be parsed.
    static func installedSchedule() -> Schedule? {
        guard let data = try? Data(contentsOf: plistURL) else { return nil }
        return schedule(fromPlistData: data)
    }

    /// The schedule encoded in a LaunchAgent plist. Split from
    /// `installedSchedule` (and internal, like `plistXML`) so the
    /// write→read round-trip is unit-testable without touching the real
    /// LaunchAgents directory — a wrong schedule is a silently missed backup.
    static func schedule(fromPlistData data: Data) -> Schedule? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        var raw: [[String: Any]] = []
        if let arr = plist["StartCalendarInterval"] as? [[String: Any]] { raw = arr }
        else if let one = plist["StartCalendarInterval"] as? [String: Any] { raw = [one] }
        else { return nil }

        var timeKeys = [String]()
        var times = [(hour: Int, minute: Int)]()
        var weekdays = Set<Int>()
        for e in raw {
            let h = (e["Hour"] as? NSNumber)?.intValue ?? 0
            let m = (e["Minute"] as? NSNumber)?.intValue ?? 0
            let key = "\(h):\(m)"
            if !timeKeys.contains(key) { timeKeys.append(key); times.append((h, m)) }
            if let wd = (e["Weekday"] as? NSNumber)?.intValue { weekdays.insert(wd % 7) }
        }
        return Schedule(times: times, weekdays: weekdays.sorted())
    }

    static func plistXML(program: [String], schedule: Schedule, log: String) -> String {
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
        \(calendarIntervalXML(schedule))
            <key>StandardOutPath</key>
            <string>\(xmlEscape(log))</string>
            <key>StandardErrorPath</key>
            <string>\(xmlEscape(log))</string>
            <key>EnvironmentVariables</key>
            <dict>
                <key>PATH</key>
                <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
            </dict>
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
