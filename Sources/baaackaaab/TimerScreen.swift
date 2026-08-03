import Foundation

// The command center's Timer screen (schedule editor), split out of
// CommandCenter.swift to match the per-screen file convention the Restore
// browser already follows. Pure move — behavior unchanged.
extension ConfigTUI {
    // MARK: - Timer screen

    /// Open the timer editor: cache the install state and pre-fill the fields from
    /// the currently installed schedule (first time + its weekdays) if any.
    func enterTimer() {
        refreshTimerState()
        if let s = timerCurrent, let first = s.times.first {
            timerHour = first.hour; timerMinute = first.minute
            timerWeekdays = Set(s.weekdays)
        }
        screen = .timer
    }

    /// Refresh the cached install state + installed schedule. Spawns launchctl, so
    /// it is called only on enter and after install/uninstall — never per render.
    func refreshTimerState() {
        timerState = LaunchdTimer.state()
        timerCurrent = LaunchdTimer.installedSchedule()
    }

    /// The schedule the editor would install: the single edited time, plus the
    /// chosen weekdays (empty = every day).
    func previewSchedule() -> Schedule {
        Schedule(times: [(timerHour, timerMinute)], weekdays: timerWeekdays.sorted())
    }

    func renderTimer() {
        let (rows, cols) = terminalSize()
        var lines: [String] = []
        lines.append(bold(fit("baaackaaab \u{2014} timer", cols)))
        lines.append(cyan(fit("scheduled backup of the set", cols)))
        lines.append("")

        let helpLines = wrapHelp(timerHelpLine(), cols)
        let footerH = 2 + helpLines.count
        let contentH = max(1, rows - 3 - footerH)

        var body: [String] = []
        body.append(divider("status", cols))
        if timerState.installed {
            body.append(green(fit("  installed" + (timerState.loaded ? " + loaded" : " (not loaded)"), cols)))
            if let cur = timerCurrent { body.append(dim(fit("  current: " + cur.describe(), cols))) }
            // The editor handles a single time; warn before it silently collapses a
            // multi-time CLI schedule down to the one edited here on install.
            if (timerCurrent?.times.count ?? 0) > 1 {
                body.append(yellow(fit("  note: current has several times; the editor sets one — installing replaces all with it (use --at repeatedly on the CLI for several)", cols)))
            }
        } else {
            body.append(dim(fit("  not installed", cols)))
        }
        body.append("")

        body.append(divider("edit schedule", cols))
        let hh = String(format: "%02d", timerHour), mm = String(format: "%02d", timerMinute)
        let timeStr = timerFieldMinute ? "\(hh):[\(mm)]" : "[\(hh)]:\(mm)"
        body.append(fit("  time:  \(timeStr)", cols))
        // Mon…Sun (launchd numbers 1…6, 0), selected ones bracketed.
        let order = [1, 2, 3, 4, 5, 6, 0]
        let dayStr = order.map { timerWeekdays.contains($0) ? "[\(Schedule.weekdayName($0))]" : " \(Schedule.weekdayName($0)) " }.joined()
        body.append(fit("  days:  \(timerWeekdays.isEmpty ? "every day" : dayStr)", cols))
        body.append("")
        body.append(dim(fit("  will install: " + previewSchedule().describe(), cols)))

        if body.count < contentH { body += Array(repeating: "", count: contentH - body.count) }
        if body.count > contentH { body = Array(body.prefix(contentH)) }
        lines += body

        lines.append("")
        lines.append(dim(fit(statusLine(), cols)))
        for hl in helpLines { lines.append(dim(fit(hl, cols))) }
        draw(lines)
    }

    func timerHelpLine() -> String {
        "\u{2191}/\u{2193} adjust \u{2022} \u{2190}/\u{2192} hr/min \u{2022} 1-7 weekday \u{2022} 0 every day \u{2022} i install \u{2022} u uninstall \u{2022} esc back"
    }

    func handleTimer(_ key: Key) -> Bool {
        switch key {
        case .up: adjustTimer(by: 1)
        case .down: adjustTimer(by: -1)
        case .left, .right, .tab: timerFieldMinute.toggle()
        case .char("1"): toggleWeekday(1)
        case .char("2"): toggleWeekday(2)
        case .char("3"): toggleWeekday(3)
        case .char("4"): toggleWeekday(4)
        case .char("5"): toggleWeekday(5)
        case .char("6"): toggleWeekday(6)
        case .char("7"): toggleWeekday(0)   // 7 = Sunday (launchd weekday 0)
        case .char("0"): timerWeekdays.removeAll()
        case .char("i"): installTimerNow()
        case .char("u"): uninstallTimerNow()
        case .esc, .char("h"): screen = .home
        case .char("q"), .ctrlC: if confirmQuit() { return false }
        case .eof: return false
        default: break
        }
        return true
    }

    /// Adjust the focused time field: minute by 5 (wrapping 0–59), hour by 1
    /// (wrapping 0–23). Five-minute steps are plenty for a daily backup.
    func adjustTimer(by delta: Int) {
        if timerFieldMinute {
            timerMinute = ((timerMinute + delta * 5) % 60 + 60) % 60
        } else {
            timerHour = ((timerHour + delta) % 24 + 24) % 24
        }
    }

    func toggleWeekday(_ wd: Int) {
        if timerWeekdays.contains(wd) { timerWeekdays.remove(wd) } else { timerWeekdays.insert(wd) }
    }

    /// Install the edited schedule by shelling out to the tested CLI (writes the
    /// plist + bootstraps launchd), then refresh the cached state.
    func installTimerNow() {
        var args = ["--install-timer", "--at", String(format: "%02d:%02d", timerHour, timerMinute)]
        if !timerWeekdays.isEmpty {
            let names = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]
            args += ["--days", timerWeekdays.sorted().map { names[$0] }.joined(separator: ",")]
        }
        if configPath.path != BackupSet.defaultPath().path { args += ["--config", configPath.path] }
        let code = runChildAndWait(args, label: "install-timer")
        refreshTimerState()
        if code == 0 { statusMsg = "timer: " + previewSchedule().describe() }
        // on failure runChildAndWait already set an actionable "exited with code N"
    }

    /// Remove the launchd schedule via the tested CLI, then refresh cached state.
    func uninstallTimerNow() {
        let code = runChildAndWait(["--uninstall-timer"], label: "uninstall-timer")
        refreshTimerState()
        if code == 0 { statusMsg = "timer removed" }
    }
}
