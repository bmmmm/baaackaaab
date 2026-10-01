import Foundation

/// Pure rendering decision for the command center's "last backup" line: the age of
/// the newest successful backup, and whether it has gone OVERDUE relative to the
/// installed schedule's cadence. Never hardcoded — the interval comes from the
/// installed schedule, so the judgment tracks whatever the operator scheduled.
///
/// `interval` is nil when no backup timer is installed: with no intended cadence
/// there is nothing to be overdue against, so the line shows the age only (never an
/// overdue warning). With an interval, "overdue" is 1.5× it — enough slack that a
/// backup that merely slipped a few hours past its slot isn't cried wolf over.
enum BackupDashboard {
    enum Level: Equatable { case none, ok, overdue }

    /// Grace multiple: a successful backup older than this × the interval is overdue.
    static let overdueFactor = 1.5

    static func line(lastSuccess: RunRecord?, interval: TimeInterval?, now: Date,
                     overdueFactor: Double = overdueFactor) -> (level: Level, text: String) {
        guard let last = lastSuccess else {
            return (.none, "no successful backup recorded yet — press s to back up now")
        }
        let age = now.timeIntervalSince(last.end)
        let days = Int(age / 86_400)
        let ageText = days <= 0 ? "today" : "\(days)d ago"
        if let interval, interval > 0, age > overdueFactor * interval {
            let cadence = max(1, Int((interval / 86_400).rounded()))
            return (.overdue, "last backup \(ageText) — OVERDUE (expected within \(cadence)d; check the timer + logs)")
        }
        return (.ok, "last backup \(ageText)")
    }
}
