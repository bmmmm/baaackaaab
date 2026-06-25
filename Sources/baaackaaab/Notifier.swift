import Foundation

// A macOS notification banner via osascript. The whole point is the unattended
// timer run: its stdout/stderr go to a log nobody watches, so when a scheduled
// backup fails a banner is the only signal a human actually sees. Best-effort and
// silent — posting a notification must never disturb the backup's own exit.
enum Notifier {
    /// Post a notification with `title` and `message` (optional `subtitle`). No-op
    /// if osascript is missing; never throws. The message is escaped for the
    /// AppleScript string literal, and passed as a single `-e` argument (no shell,
    /// so only AppleScript escaping is needed — no shell-quoting hazard, and the
    /// text never reaches a command line a `ps` could read in a sensitive way).
    static func notify(title: String, message: String, subtitle: String? = nil) {
        let osa = "/usr/bin/osascript"
        guard FileManager.default.isExecutableFile(atPath: osa) else { return }
        var script = "display notification \"\(escape(message))\" with title \"\(escape(title))\""
        if let subtitle { script += " subtitle \"\(escape(subtitle))\"" }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: osa)
        proc.arguments = ["-e", script]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return }
        proc.waitUntilExit()
    }

    /// Escape a string for embedding inside an AppleScript double-quoted literal:
    /// backslash first (so we don't double-escape the quote escapes), then quote.
    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
