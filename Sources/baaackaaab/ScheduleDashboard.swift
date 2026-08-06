import Foundation

/// Pure rendering decision for the command center's "schedules" section: one row
/// per scheduled job (backup, integrity check, restore drill) showing whether it
/// is scheduled at all, on what cadence, and when it fires next.
///
/// "Installed" and "loaded" are deliberately separate inputs. A plist on disk that
/// launchd has NOT loaded looks scheduled in every listing but never fires — the
/// exact failure mode a dashboard exists to catch, so it gets its own level rather
/// than being folded into `ok`.
enum ScheduleDashboard {
    /// `off` is a job the OPERATOR deliberately paused (o) — the schedule is
    /// intact and a resume brings it straight back. `broken` is everything
    /// else that looks scheduled but will not fire, which needs a reinstall
    /// instead of a resume.
    enum Level: Equatable { case none, ok, off, broken }

    /// Width the job titles are padded to, so the cadence column lines up.
    /// Derived from the longest title rather than hardcoded.
    static var titleWidth: Int {
        LaunchdTimer.Kind.allCases.map { $0.title.count }.max() ?? 0
    }

    static func row(kind: LaunchdTimer.Kind, installed: Bool, loaded: Bool, paused: Bool = false,
                    schedule: Schedule?, now: Date) -> (level: Level, text: String) {
        let name = kind.title.padding(toLength: max(titleWidth, kind.title.count),
                                      withPad: " ", startingAt: 0)
        guard installed else {
            return (.none, "\(name)  not scheduled")
        }
        guard let schedule else {
            return (.broken, "\(name)  installed, but its schedule is unreadable — reinstall it (w)")
        }
        if paused {
            return (.off, "\(name)  \(schedule.describe())  ·  off — turn it back on (o)")
        }
        guard loaded else {
            return (.broken, "\(name)  \(schedule.describe()) — plist present but NOT loaded, so it never fires; reinstall it (w)")
        }
        guard let next = schedule.nextFireDate(after: now) else {
            return (.broken, "\(name)  \(schedule.describe()) — no fire time; reinstall it (w)")
        }
        return (.ok, "\(name)  \(schedule.describe())  ·  next \(countdown(from: now, to: next))")
    }

    /// "in 12m" / "in 6h" / "in 27d" — the wait until the next run, at the coarsest
    /// unit that still says something useful. A time already past (a schedule the
    /// clock has overtaken) reads "now".
    static func countdown(from now: Date, to next: Date) -> String {
        let secs = Int(next.timeIntervalSince(now))
        if secs <= 0 { return "now" }
        if secs < 3600 { return "in \(max(1, secs / 60))m" }
        if secs < 86_400 { return "in \(secs / 3600)h" }
        return "in \(secs / 86_400)d"
    }
}
