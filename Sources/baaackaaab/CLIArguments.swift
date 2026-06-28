import Foundation

/// A parsed view over the process command-line tokens. Built once from
/// `CommandLine.arguments` (the module-global `cli`, below); every flag lookup
/// goes through an instance instead of reading the global directly. That gives
/// one source of truth for "what was on argv" AND makes the parsing unit-
/// testable — a test constructs `CLIArguments(tokens: ["--at", "09:00"])` and
/// checks the result without touching the real process arguments.
///
/// argv[0] (the binary path) is deliberately NOT modelled here: it is not a
/// flag, and `selfPath()` in the TUI / Timer reads it directly for re-exec.
struct CLIArguments {
    let tokens: [String]

    /// The first value after `name`, or `fallback` when the flag is absent or
    /// is the final token (nothing follows it).
    func value(_ name: String, default fallback: String? = nil) -> String? {
        if let i = tokens.firstIndex(of: name), i + 1 < tokens.count {
            return tokens[i + 1]
        }
        return fallback
    }

    /// Every value of a repeatable flag, e.g. `--drive-folder a --drive-folder b`.
    func values(_ name: String) -> [String] {
        var out: [String] = []
        var i = 0
        while i < tokens.count {
            if tokens[i] == name, i + 1 < tokens.count {
                out.append(tokens[i + 1])
                i += 2
            } else {
                i += 1
            }
        }
        return out
    }

    /// The two tokens after a flag, e.g. `--diff <a> <b>`. nil if fewer than two
    /// follow it. Used by the two-argument snapshot diff.
    func pair(_ name: String) -> (String, String)? {
        guard let i = tokens.firstIndex(of: name), i + 2 < tokens.count else { return nil }
        return (tokens[i + 1], tokens[i + 2])
    }

    /// Whether a (boolean) flag is present at all.
    func has(_ name: String) -> Bool { tokens.contains(name) }

    /// Whether ANY of `names` is present (replaces `.contains(where:contains)`).
    func hasAny(_ names: [String]) -> Bool { names.contains(where: tokens.contains) }

    /// The token count. A bare invocation is exactly 1 (just the binary path).
    var count: Int { tokens.count }

    /// A numeric flag that must be a positive integer when present. Returns
    /// `fallback` when the flag is absent; exits with an actionable error when it
    /// is present but not a positive integer — so a typo or a negative/zero value
    /// fails loudly instead of silently degrading the run (e.g. `--max-bytes -1`
    /// collapsing a sample to one file). `unit` is woven into the error, e.g. "KiB/s".
    func positiveInt(_ name: String, default fallback: Int, unit: String? = nil) -> Int {
        guard let raw = value(name) else { return fallback }
        guard let n = Int(raw), n > 0 else {
            let u = unit.map { " (\($0))" } ?? ""
            Console.error("\(name) needs a positive integer\(u) — got '\(raw)'")
            exit(1)
        }
        return n
    }

    /// Build the timer Schedule from `--at` (repeatable; default 12:00 when
    /// absent) and `--days` (csv of weekdays; absent = every day). Exits with an
    /// actionable error on any malformed `--at` or unrecognized `--days` token,
    /// so an install never silently lands on the wrong time or the wrong (daily)
    /// cadence.
    func schedule() -> Schedule {
        var times: [(hour: Int, minute: Int)] = []
        for raw in values("--at") {
            guard let t = Self.parseAtTime(raw) else {
                Console.error("--at needs HH:MM in 24-hour form — got '\(raw)' (e.g. --at 09:00 --at 18:30)")
                exit(1)
            }
            times.append(t)
        }
        let (days, unknown) = Self.parseDays(value("--days"))
        if !unknown.isEmpty {
            Console.error("--days has unrecognized weekday(s): \(unknown.joined(separator: ", ")) — use mon,tue,wed,thu,fri,sat,sun")
            exit(1)
        }
        return Schedule(times: times.isEmpty ? [(hour: 12, minute: 0)] : times, weekdays: days)
    }

    /// Parse an `--at HH:MM` value (24-hour) into (hour, minute). nil when
    /// malformed, so the caller can reject an explicitly-supplied bad value
    /// rather than silently substituting a wrong time. Pure (no argv access) —
    /// directly unit-testable.
    static func parseAtTime(_ s: String) -> (hour: Int, minute: Int)? {
        guard let colon = s.firstIndex(of: ":"),
              let h = Int(s[s.startIndex..<colon]),
              let m = Int(s[s.index(after: colon)...]),
              (0...23).contains(h), (0...59).contains(m) else { return nil }
        return (h, m)
    }

    /// Parse a `--days` csv ("mon,wed,fri") into launchd weekday numbers
    /// (Sun=0 … Sat=6), plus any tokens that did not resolve to a weekday. An
    /// empty/absent value yields ([], []) (which means "every day"). Unrecognized
    /// tokens are returned so the caller can reject them instead of silently
    /// dropping them (a typo'd `--days saturdy` must not become a daily timer).
    /// Pure (no argv access) — directly unit-testable.
    static func parseDays(_ csv: String?) -> (days: [Int], unknown: [String]) {
        guard let csv, !csv.isEmpty else { return ([], []) }
        let map: [String: Int] = ["sun": 0, "mon": 1, "tue": 2, "wed": 3, "thu": 4, "fri": 5, "sat": 6]
        var days = Set<Int>()
        var unknown: [String] = []
        for tok in csv.lowercased().split(whereSeparator: { $0 == "," || $0 == " " }) {
            if let d = map[String(tok.prefix(3))] { days.insert(d) } else { unknown.append(String(tok)) }
        }
        return (days.sorted(), unknown)
    }

    /// Flags that consume the FOLLOWING token as their value (that token is a
    /// value, never checked as a flag — a value may legitimately start with '-',
    /// e.g. `--find -x`). `--diff` consumes two (a snapshot pair).
    static let valueFlags: Set<String> = [
        "--drive-folder", "--photo-album", "--photo-batch-bytes", "--staging",
        "--add-folder", "--remove-folder", "--add-album", "--remove-album",
        "--limit-upload", "--config", "--restic-repo", "--host", "--run-tag",
        "--add-destination", "--repo-url", "--repo-password-file", "--link",
        "--order", "--remove-destination", "--ls", "--find", "--snapshot",
        "--target", "--include", "--sample", "--max-bytes", "--destination",
        "--read-data-subset", "--at", "--days", "--repo-quota-bytes",
        "--quota-warn-fraction", "--materialize-test", "--evict-test",
    ]
    /// Flags that stand alone (no value).
    static let boolFlags: Set<String> = [
        "--init-credentials", "--migrate-credentials", "--force", "--check",
        "--list", "--configure", "--clear-limit-upload", "--list-destinations",
        "--disabled", "--snapshots", "--restore", "--test-restore", "--dry-run",
        "--yes", "--no-verify", "--verify-repo", "--unlock", "--remove-all",
        "--install-timer", "--uninstall-timer", "--timer-status", "--doctor",
        "--center", "--help", "-h",
    ]

    /// Find the first token that is neither a known flag nor a consumed flag
    /// value, returning an actionable error message for it (or nil when every
    /// token is accounted for). The dispatch matches specific flags and, finding
    /// none, backs up the set — so any unrecognized token must be caught here or
    /// it falls through to a full backup. Two failure modes:
    ///   * a `--flag` typo (`--snapshtos`) — an unknown flag;
    ///   * a bare word (`check` for `--check`) — baaackaaab has NO positional
    ///     commands, every operation is a flag, so a stray positional is always a
    ///     mistyped command and must fail loudly too.
    /// Pure (no argv access, no exit/IO) — directly unit-testable; the process
    /// wrapper `rejectUnknownFlags()` adds the exit.
    static func unknownArgument(in tokens: [String]) -> String? {
        var i = 1   // skip argv[0]
        while i < tokens.count {
            let tok = tokens[i]
            if tok == "--diff" { i += 3; continue }           // flag + two snapshot ids
            if valueFlags.contains(tok) { i += 2; continue }  // flag + its value
            if boolFlags.contains(tok) { i += 1; continue }
            if tok.hasPrefix("-") && tok != "-" {
                return "unknown flag '\(tok)' — see `baaackaaab --help` for the accepted flags. (Refusing to continue: an unrecognized flag would otherwise fall through to a full backup of the set.)"
            }
            // A token that is neither a known flag nor a consumed flag value is a
            // stray positional argument. Suggest the flag form when one exists.
            let suggestion = boolFlags.contains("--\(tok)") || valueFlags.contains("--\(tok)")
                ? " (did you mean '--\(tok)'?)" : ""
            return "unexpected argument '\(tok)'\(suggestion) — baaackaaab has no positional commands; every operation is a flag. See `baaackaaab --help`. (Refusing to continue: it would otherwise fall through to a full backup of the set.)"
        }
        return nil
    }
}

/// The process command line, parsed once. Module-global so the dispatch script
/// and the command helpers share one source of truth instead of each re-reading
/// `CommandLine.arguments`. Lazily initialized on first access.
let cli = CLIArguments(tokens: CommandLine.arguments)
