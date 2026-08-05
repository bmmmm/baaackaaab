import Foundation

// The command center's Schedules screen, split out of CommandCenter.swift to match
// the per-screen file convention the Restore browser already follows.
//
// It edits all three scheduled jobs — backup, integrity check, restore drill — one
// at a time: tab cycles the job, the fields below reflect whatever that job's
// installed plist says, and i / u install (or rewrite) and remove it. o pauses or
// resumes the job without touching its configured schedule (on/off, distinct from
// i/u which write or delete it). Every write goes through the tested CLI flags
// rather than a second plist writer here, so the TUI and `--install-*-timer` can
// never drift apart.
//
// Two safety nets sit on top of that: the first ↑/↓ press after landing on the
// screen (or switching jobs) only "arms" adjustment instead of applying it — the
// natural first move of poking around with the arrow keys can't silently bump a
// real schedule. And any edit that hasn't been installed yet (d discards it) is
// tracked, so leaving the screen with one pending prompts install-or-discard
// instead of quietly throwing it away.
extension ConfigTUI {
    // MARK: - Schedules screen

    /// Open the schedules editor on the backup job, with its fields pre-filled from
    /// whatever is installed.
    func enterTimer() {
        timerKind = .backup
        loadTimerFields()
        screen = .timer
    }

    /// Refresh the cached install state + installed schedule for the SELECTED job.
    /// Spawns launchctl, so it is called only on enter, on job switch, and after an
    /// install/uninstall — never per render.
    func refreshTimerState() {
        timerState = LaunchdTimer.state(timerKind)
        timerCurrent = LaunchdTimer.installedSchedule(timerKind)
    }

    /// Point the editor at `kind` and pre-fill its fields from that job's installed
    /// schedule, falling back to the job's own install defaults when it is not
    /// scheduled yet. Also picks a starting field the job actually has.
    func loadTimerFields() {
        refreshTimerState()
        let fallback = timerKind.defaultTime
        timerHour = fallback.hour; timerMinute = fallback.minute
        timerWeekdays = []
        timerDayOfMonth = 1
        if let s = timerCurrent {
            if let first = s.times.first { timerHour = first.hour; timerMinute = first.minute }
            timerWeekdays = Set(s.weekdays)
            if let d = s.dayOfMonth { timerDayOfMonth = d }
        }
        if timerField == .day && !timerKind.isMonthly { timerField = .hour }
        // Fields now mirror what's on disk, so there is nothing pending — and
        // any arrow-key press from before this (re)load must not carry over.
        timerTouched = false
        timerArmed = false
    }

    /// Move to the next job in the cycle and reload the editor from its plist.
    /// Guarded like leaving the screen: an unapplied edit on the CURRENT job
    /// would otherwise be silently thrown away by the reload.
    func cycleTimerKind() {
        guard confirmDiscardTimerEdits() else { return }
        let all = LaunchdTimer.Kind.allCases
        let i = all.firstIndex(of: timerKind) ?? 0
        timerKind = all[(i + 1) % all.count]
        loadTimerFields()
    }

    /// The schedule the editor would install for the selected job: the single
    /// edited time, plus either a day-of-month (monthly jobs) or the chosen
    /// weekdays (empty = every day).
    func previewSchedule() -> Schedule {
        if timerKind.isMonthly {
            return Schedule(times: [(timerHour, timerMinute)], weekdays: [], dayOfMonth: timerDayOfMonth)
        }
        return Schedule(times: [(timerHour, timerMinute)], weekdays: timerWeekdays.sorted())
    }

    func renderTimer() {
        let (rows, cols) = terminalSize()
        var lines: [String] = []
        lines.append(bold(fit("baaackaaab \u{2014} schedules", cols)))
        lines.append(cyan(fit("what runs unattended, and when", cols)))
        lines.append("")

        let helpLines = wrapHelp(timerHelpLine(), cols)
        let footerH = 2 + helpLines.count
        let contentH = max(1, rows - 3 - footerH)

        var body: [String] = []

        // Every job at a glance first — the point of the screen is answering "what
        // is scheduled", not just "edit this one".
        body.append(divider("scheduled jobs", cols))
        for row in loadScheduleRows() {
            let selected = row.kind == timerKind
            let (level, text) = ScheduleDashboard.row(kind: row.kind, installed: row.installed,
                                                      loaded: row.loaded, paused: row.paused,
                                                      schedule: row.schedule, now: Date())
            let marker = selected ? "\u{25B8} " : "  "
            let line = fit(marker + text, cols)
            switch level {
            case .ok:     body.append(selected ? green(line) : dim(line))
            case .none:   body.append(dim(line))
            case .off:    body.append(selected ? cyan(line) : dim(line))
            case .broken: body.append(yellow(line))
            }
        }
        body.append("")

        body.append(divider("edit \(timerKind.title)", cols))
        let hh = String(format: "%02d", timerHour), mm = String(format: "%02d", timerMinute)
        let timeStr = "\(field(hh, .hour)):\(field(mm, .minute))"
        body.append(fit("  time:  \(timeStr)", cols))
        if timerKind.isMonthly {
            body.append(fit("  day:   \(field(String(timerDayOfMonth), .day)) of each month", cols))
        } else {
            // Mon…Sun (launchd numbers 1…6, 0), selected ones bracketed.
            let order = [1, 2, 3, 4, 5, 6, 0]
            let dayStr = order.map { timerWeekdays.contains($0) ? "[\(Schedule.weekdayName($0))]" : " \(Schedule.weekdayName($0)) " }.joined()
            body.append(fit("  days:  \(timerWeekdays.isEmpty ? "every day" : dayStr)", cols))
        }
        // The editor handles a single time; warn before it silently collapses a
        // multi-time CLI schedule down to the one edited here on install.
        if (timerCurrent?.times.count ?? 0) > 1 {
            body.append(yellow(fit("  note: this job has several times; the editor sets one \u{2014} installing replaces all with it (use --at repeatedly on the CLI for several)", cols)))
        }
        body.append("")
        body.append(dim(fit("  i installs: " + previewSchedule().describe(), cols)))
        if let next = previewSchedule().nextFireDate(after: Date()) {
            body.append(dim(fit("  first run:  " + timerStampFmt.string(from: next)
                                + " (" + ScheduleDashboard.countdown(from: Date(), to: next) + ")", cols)))
        }
        if timerTouched {
            body.append(yellow(fit("  unapplied edit \u{2014} i installs it, d discards it", cols)))
        }

        if body.count < contentH { body += Array(repeating: "", count: contentH - body.count) }
        lines += clipBody(body, to: contentH, cols: cols)

        lines.append("")
        lines.append(dim(fit(statusLine(), cols)))
        for hl in helpLines { lines.append(dim(fit(hl, cols))) }
        draw(lines)
    }

    /// Bracket a field's value when it has focus, pad it out when it doesn't, so
    /// the row keeps its width as focus moves.
    func field(_ value: String, _ which: TimerField) -> String {
        timerField == which ? "[\(value)]" : " \(value) "
    }

    func timerHelpLine() -> String {
        let dayKeys = timerKind.isMonthly ? "" : " \u{2022} 1-7 weekday \u{2022} 0 every day"
        return "tab job \u{2022} \u{2191}/\u{2193} adjust (1st press arms) \u{2022} \u{2190}/\u{2192} field\(dayKeys) \u{2022} i install \u{2022} o on/off \u{2022} d discard \u{2022} u delete \u{2022} esc back"
    }

    func handleTimer(_ key: Key) -> Bool {
        switch key {
        case .up: armOrAdjust(1)
        case .down: armOrAdjust(-1)
        case .tab: cycleTimerKind()
        case .left: moveTimerField(by: -1)
        case .right: moveTimerField(by: 1)
        case .char("1"): toggleWeekday(1)
        case .char("2"): toggleWeekday(2)
        case .char("3"): toggleWeekday(3)
        case .char("4"): toggleWeekday(4)
        case .char("5"): toggleWeekday(5)
        case .char("6"): toggleWeekday(6)
        case .char("7"): toggleWeekday(0)   // 7 = Sunday (launchd weekday 0)
        case .char("0"): clearTimerWeekdays()
        case .char("i"): installTimerNow()
        case .char("o"): toggleTimerOnOff()
        case .char("d"):
            let hadEdit = timerTouched
            loadTimerFields()
            if hadEdit { statusMsg = "edit discarded" }
        case .char("u"): uninstallTimerNow()
        case .esc, .char("h"): if confirmDiscardTimerEdits() { screen = .home }
        case .char("q"), .ctrlC: if confirmDiscardTimerEdits() && confirmQuit() { return false }
        case .eof: return false
        default: break
        }
        return true
    }

    /// The fields the selected job actually has: hour and minute always, plus a
    /// day-of-month for a monthly job (whose weekdays launchd would ignore).
    func timerFields() -> [TimerField] {
        timerKind.isMonthly ? [.hour, .minute, .day] : [.hour, .minute]
    }

    func moveTimerField(by delta: Int) {
        let fields = timerFields()
        let i = fields.firstIndex(of: timerField) ?? 0
        timerField = fields[((i + delta) % fields.count + fields.count) % fields.count]
    }

    /// The first ↑/↓ press after entering the screen or switching jobs only
    /// arms adjustment (a status-line hint, nothing else); the SAME direction
    /// or the opposite one both count, since the point is just "you've now
    /// deliberately touched the arrow keys here." Every press after that
    /// adjusts normally.
    func armOrAdjust(_ delta: Int) {
        guard timerArmed else {
            timerArmed = true
            statusMsg = "\u{2191}/\u{2193} armed \u{2014} press again to change the value"
            return
        }
        adjustTimer(by: delta)
    }

    /// Adjust the focused field: minute by 5 (wrapping 0–59), hour by 1 (wrapping
    /// 0–23), day-of-month by 1 (wrapping 1–28, the cap that makes a monthly job
    /// fire in February too). Five-minute steps are plenty for a daily backup.
    func adjustTimer(by delta: Int) {
        switch timerField {
        case .minute: timerMinute = ((timerMinute + delta * 5) % 60 + 60) % 60
        case .hour:   timerHour = ((timerHour + delta) % 24 + 24) % 24
        case .day:    timerDayOfMonth = ((timerDayOfMonth - 1 + delta) % 28 + 28) % 28 + 1
        }
        timerTouched = true
    }

    func toggleWeekday(_ wd: Int) {
        guard !timerKind.isMonthly else { return }
        if timerWeekdays.contains(wd) { timerWeekdays.remove(wd) } else { timerWeekdays.insert(wd) }
        timerTouched = true
    }

    func clearTimerWeekdays() {
        guard !timerKind.isMonthly, !timerWeekdays.isEmpty else { return }
        timerWeekdays.removeAll()
        timerTouched = true
    }

    /// Install the edited schedule by shelling out to the tested CLI (writes the
    /// plist + bootstraps launchd), then refresh the cached state. Installing over
    /// an existing job rewrites it, so this is also the "change it" path. Returns
    /// the child's exit code so callers (e.g. the leave-confirmation prompt) can
    /// tell whether the install actually landed.
    @discardableResult
    func installTimerNow() -> Int32 {
        var args = [timerKind.installFlag, "--at", String(format: "%02d:%02d", timerHour, timerMinute)]
        if timerKind.isMonthly {
            args += ["--day", String(timerDayOfMonth)]
        } else if !timerWeekdays.isEmpty {
            let names = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]
            args += ["--days", timerWeekdays.sorted().map { names[$0] }.joined(separator: ",")]
        }
        // Only the backup timer runs the backup set, so only it needs the config
        // path forwarded — the check and drill read their destinations from the store.
        if timerKind == .backup && configPath.path != BackupSet.defaultPath().path {
            args += ["--config", configPath.path]
        }
        let code = runChildAndWait(args, label: "install \(timerKind.title) schedule")
        invalidateScheduleRows()
        refreshTimerState()
        if code == 0 {
            statusMsg = "\(timerKind.title): " + previewSchedule().describe()
            timerTouched = false
        }
        // on failure runChildAndWait already set an actionable "exited with code N"
        return code
    }

    /// Flip the selected job between on (loaded) and off (paused, plist kept) —
    /// distinct from i/u, which write or delete the schedule itself. A no-op
    /// when nothing is installed yet, since there is nothing to pause.
    func toggleTimerOnOff() {
        guard timerState.installed else { statusMsg = "nothing installed yet \u{2014} press i first"; return }
        let pausing = timerState.loaded
        let flag = pausing ? timerKind.pauseFlag : timerKind.resumeFlag
        let code = runChildAndWait([flag], label: "\(pausing ? "pause" : "resume") \(timerKind.title) schedule")
        invalidateScheduleRows()
        refreshTimerState()
        if code == 0 { statusMsg = "\(timerKind.title): " + (timerState.loaded ? "on" : "off") }
    }

    /// Leaving the editor (esc, switching jobs, or quitting) while an edit
    /// hasn't been installed would otherwise silently throw it away. Mirrors
    /// confirmQuit()'s shape: install-or-discard, cancel by default. Returns
    /// true when it's fine to proceed (nothing pending, installed, or discarded).
    func confirmDiscardTimerEdits() -> Bool {
        guard timerTouched else { return true }
        drawPrompt("unapplied schedule edit \u{2014} i: install & continue   d: discard & continue   esc/enter: stay")
        while true {
            switch readKey() {
            case .char("i"), .char("I"):
                return installTimerNow() == 0
            case .char("d"), .char("D"):
                loadTimerFields()
                return true
            case .enter, .esc, .ctrlC: return false
            case .eof: return true
            default: break
            }
        }
    }

    /// Remove the selected job's launchd schedule via the tested CLI, then refresh
    /// cached state. Idempotent — removing a job that is not installed is a no-op.
    func uninstallTimerNow() {
        let code = runChildAndWait([timerKind.uninstallFlag], label: "delete \(timerKind.title) schedule")
        invalidateScheduleRows()
        refreshTimerState()
        if code == 0 { statusMsg = "\(timerKind.title) schedule removed" }
    }
}
