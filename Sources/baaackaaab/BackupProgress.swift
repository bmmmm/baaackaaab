import Foundation
#if canImport(Darwin)
import Darwin
#endif

// Live backup progress, parsed from `restic backup --json`.
//
// restic emits one JSON object per line on stdout in --json mode: periodic
// "status" messages while it works and a final "summary" when the snapshot is
// written (plus "error" messages on trouble). ResticBackend decodes those lines
// into the two value types below and hands them to a BackupProgressBar, which
// draws a single self-rewriting line on a TTY. Off a TTY (launchd / a pipe) the
// backend keeps restic's plain output instead, so the bar code never runs there.

/// A decoded `status` message: how far the current backup has progressed. restic
/// does NOT report elapsed time in its status JSON (verified against 0.19.0), so
/// the ETA is derived from a clock the bar keeps itself, not from this struct.
struct ResticStatus {
    let percentDone: Double   // 0…1
    let totalFiles: Int
    let filesDone: Int
    let totalBytes: Int
    let bytesDone: Int
}

/// A decoded `summary` message: the final tally when the snapshot is written.
/// `totalBytesProcessed` is restic's `total_bytes_processed` — the whole source
/// size restic walked this run (new + unchanged), which the churn tripwire uses
/// to spot a source that suddenly shrank; `dataAdded` is only the newly-uploaded
/// delta.
struct ResticSummary {
    let filesNew: Int
    let filesChanged: Int
    let dataAdded: Int
    let totalBytesProcessed: Int
    let totalDuration: Double
    let snapshotID: String?
}

/// A single self-rewriting progress line for one backup invocation. Writes
/// directly to fd 1 (not `print`) so the carriage-return redraws appear
/// immediately despite stdout being line-buffered — a `\r` never triggers a
/// line-buffer flush. Drawing is gated on STDOUT being a TTY; constructed for a
/// non-TTY target it becomes a no-op, so the caller can always build one.
final class BackupProgressBar {
    private let label: String
    private let enabled: Bool
    /// Monotonic start, for the ETA restic's JSON does not provide.
    private let started = DispatchTime.now()
    private var drawn = false
    private var finished = false
    /// Throttle key: redraw only when the rendered state would actually change —
    /// the integer permille of progress, or the elapsed-second counter (so the ETA
    /// still ticks while a single large file uploads). restic emits status far
    /// faster than the eye needs.
    private var lastKey = -1

    init(label: String) {
        self.label = label
        self.enabled = isatty(STDOUT_FILENO) != 0
    }

    /// Redraw the bar from a status message (throttled, in place).
    func update(_ s: ResticStatus) {
        guard enabled, !finished else { return }
        let permille = Int((s.percentDone * 1000).rounded())
        let key = permille &* 100_000 &+ elapsedSeconds()
        if key == lastKey { return }
        lastKey = key
        render(s)
    }

    /// Wipe the bar and print one concise completion line from the summary.
    func finish(_ sum: ResticSummary) {
        finished = true
        guard enabled else { return }
        if drawn { write("\r\u{1B}[K") }   // erase the in-place bar line
        let added = ByteCountFormatter.string(fromByteCount: Int64(sum.dataAdded), countStyle: .file)
        let dur = Self.clock(Int(sum.totalDuration.rounded()))
        let snap = sum.snapshotID.map { " \u{2192} " + String($0.prefix(8)) } ?? ""
        let prefix = label.isEmpty ? "" : label + ": "
        Console.detail("\(prefix)\(added) new in \(dur)\(snap)")
    }

    /// Erase a half-drawn bar with no summary (e.g. a cancel/failure). Safe to call
    /// unconditionally — a no-op once `finish` has run or nothing was drawn.
    func clear() {
        guard enabled, drawn, !finished else { return }
        write("\r\u{1B}[K")
        finished = true
    }

    private func elapsedSeconds() -> Int {
        Int((DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000_000)
    }

    private func render(_ s: ResticStatus) {
        let pct = Int((s.percentDone * 100).rounded())
        let done = ByteCountFormatter.string(fromByteCount: Int64(s.bytesDone), countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: Int64(s.totalBytes), countStyle: .file)
        let elapsed = elapsedSeconds()
        let eta: String = {
            guard s.percentDone > 0.001, s.percentDone < 1, elapsed > 0 else { return "--:--" }
            let remain = Double(elapsed) * (1 - s.percentDone) / s.percentDone
            return Self.clock(Int(remain.rounded()))
        }()
        let prefix = label.isEmpty ? "" : label + " "
        let suffix = String(format: "%3d%%  %@/%@  files %d/%d  ETA %@",
                            pct, done, total, s.filesDone, s.totalFiles, eta)
        // Size the bar to whatever space is left between the prefix and the suffix.
        let cols = Self.terminalCols()
        let chrome = 2 /*indent*/ + prefix.count + 2 /*"[]"*/ + 1 /*space*/ + suffix.count
        let barWidth = max(8, min(40, cols - chrome))
        let filled = min(barWidth, max(0, Int((Double(barWidth) * s.percentDone).rounded())))
        let bar = String(repeating: "\u{2588}", count: filled)
                + String(repeating: "\u{2591}", count: barWidth - filled)
        write("\r\u{1B}[K  " + prefix + "[" + bar + "] " + suffix)
        drawn = true
    }

    private func write(_ s: String) {
        FileHandle.standardOutput.write(Data(s.utf8))
    }

    /// m:ss, or h:mm:ss past an hour.
    private static func clock(_ seconds: Int) -> String {
        let s = max(0, seconds)
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec)
                     : String(format: "%d:%02d", m, sec)
    }

    /// Current terminal width, or 80 when it can't be read. Mirrors ConfigTUI.
    private static func terminalCols() -> Int {
        var w = winsize()
        if ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &w) == 0, w.ws_col > 0 {
            return Int(w.ws_col)
        }
        return 80
    }
}
