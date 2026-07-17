import Foundation
#if canImport(Darwin)
import Darwin
#endif

// Catch-up on boot/login. The backup LaunchAgent carries RunAtLoad + a `--catch-up`
// marker, so it also fires once when launchd loads it (login/boot). A `--catch-up`
// invocation first passes a pure staleness gate: if a recent-enough successful
// backup is on record it exits quietly (also swallowing the duplicate fire right
// after a normal calendar run); if the backup is overdue — or there is no history
// at all — it announces the catch-up, posts an unattended banner, and proceeds.

enum CatchUp {
    enum Decision: Equatable {
        /// A successful backup within the interval — nothing to catch up.
        case fresh(ageDays: Int)
        /// The last success is at/older than the interval — back up now.
        case overdue(ageDays: Int)
        /// No successful backup ever recorded — always counts as overdue.
        case noHistory
    }

    /// Decide whether a catch-up (RunAtLoad / boot) invocation should proceed.
    /// `lastSuccess` is the newest successful backup's anchor time (nil = none
    /// ever). Fresh iff it is STRICTLY younger than `interval`; exactly-at or older
    /// is overdue, so a due scheduled run is never skipped. No history is overdue —
    /// a backup that has never proven itself must run. Pure — unit-testable.
    static func decide(lastSuccess: Date?, interval: TimeInterval, now: Date) -> Decision {
        guard let last = lastSuccess else { return .noHistory }
        let age = now.timeIntervalSince(last)
        let ageDays = max(0, Int(age / 86_400))
        return age < interval ? .fresh(ageDays: ageDays) : .overdue(ageDays: ageDays)
    }
}

/// The runtime `--catch-up` gate, invoked before a backup run. When the marker is
/// absent it is a no-op. When present it derives the interval from the installed
/// schedule, reads the newest successful backup, and either exits 0 (fresh) or
/// announces the catch-up (overdue / no history) and returns so the backup runs.
/// The last success is anchored on the run's START time (schedule-aligned), so a
/// backup's own duration doesn't shift a due daily run into the "fresh" window.
func catchUpGateOrProceed() {
    guard cli.has("--catch-up") else { return }

    // No installed schedule (manual --catch-up, or the timer was removed) → assume
    // the daily cadence, the most conservative non-zero interval.
    let schedule = LaunchdTimer.installedSchedule() ?? Schedule(times: [(hour: 12, minute: 0)], weekdays: [])
    let interval = schedule.intendedInterval()
    let last = RunHistory.lastSuccessfulBackup()

    switch CatchUp.decide(lastSuccess: last?.start, interval: interval, now: Date()) {
    case .fresh(let ageDays):
        // One quiet line — this is the common boot/login and duplicate-fire case.
        Console.note("catch-up: last successful backup \(ageDays)d ago, within the \(Int(interval / 86_400))d schedule — nothing to catch up, skipping this run")
        exit(0)
    case .overdue(let ageDays):
        announceCatchUp("backup is \(ageDays) day(s) overdue — catching up now")
    case .noHistory:
        announceCatchUp("no successful backup on record — catching up now")
    }
}

/// Print the actionable catch-up line and, when our output is invisible (launchd /
/// piped — the same unattended gate the failure banner uses), post a macOS banner.
/// The backup itself then proceeds in the caller.
private func announceCatchUp(_ message: String) {
    Console.warn(message)
    if isatty(STDERR_FILENO) == 0 {
        Notifier.notify(title: "baaackaaab \u{2014} catching up a missed backup",
                        message: message, subtitle: "catch-up")
    }
}
