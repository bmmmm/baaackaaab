import Foundation

/// `--log-tail [n]`: print the last n lines of the unattended run log.
///
/// The log is where restic's own output for a scheduled run lands — the detail the
/// structured run history deliberately does not keep. Reading it needs no repo, no
/// credentials and no network, so it stays available exactly when a backup is
/// broken. The command center shells out to this rather than re-implementing a
/// pager, so the TUI and a headless operator read the same thing.
enum LogTail {
    static let defaultLines = 200

    static var logURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/baaackaaab.log")
    }

    /// The last `lines` lines of `text`. Pure — split out so the tail arithmetic is
    /// unit-testable without a log file on disk.
    static func tail(_ text: String, lines: Int) -> [String] {
        guard lines > 0 else { return [] }
        // A trailing newline must not count as a final empty line, or `--log-tail 1`
        // prints nothing at all on a well-formed log.
        var all = text.components(separatedBy: "\n")
        if all.last == "" { all.removeLast() }
        return Array(all.suffix(lines))
    }

    static func run(lines: Int) {
        Console.banner("baaackaaab", tagline: "run log")
        let url = logURL
        Console.section("Log", detail: url.path)

        guard let data = FileManager.default.contents(atPath: url.path),
              let text = String(data: data, encoding: .utf8) else {
            Console.note("no log yet at \(url.path) — it is written by the scheduled runs (the LaunchAgents' StandardOutPath). An interactive run prints to the terminal instead.")
            return
        }
        let rows = tail(text, lines: lines)
        guard !rows.isEmpty else {
            Console.note("the log is empty")
            return
        }
        let size = Double(data.count) / 1_000_000
        Console.info([
            ("size", String(format: "%.1f MB", size)),
            ("showing", "last \(rows.count) line(s)"),
        ])
        Console.section("Tail")
        for row in rows { print(row) }
        Console.note("full log: less \(url.path)")
    }
}
