import Foundation

// The command center's Schedules screen, split out of CommandCenter.swift to match
// the per-screen file convention the Restore browser already follows.
//
// It edits all three scheduled jobs — backup, integrity check, restore drill —
// through a vi-style split (TimerMode): Normal mode's up/down arrows walk the
// job list and nothing else moves; `e` drops into Edit mode for the selected
// job, where left/right pick a field and up/down change its value. Keeping
// "which job" and "what value" on separate modes means the arrow keys never
// do two different things depending on where you happen to be — landing on
// the screen and reaching for the arrows can no longer silently bump a real
// schedule, because Normal mode's arrows don't touch values at all.
//
// i / u install (or rewrite) and remove a job; o pauses or resumes it without
// touching its configured schedule (on/off, distinct from i/u which write or
// delete it). Every write goes through the tested CLI flags rather than a
// second plist writer here, so the TUI and `--install-*-timer` can never
// drift apart.
//
// An edit not yet installed is tracked (the yellow "unapplied edit" note) and
// confirmed — install or discard — before it would otherwise be silently
// thrown away by leaving Edit mode, switching jobs, or quitting; d discards
// it immediately, no prompt needed, from either mode.
extension ConfigTUI {
    // MARK: - Schedules screen

    /// Open the schedules editor on the backup job, in Normal mode, with its
    /// fields pre-filled from whatever is installed.
    func enterTimer() {
        timerKind = .backup
        timerMode = .normal
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
        // Fields now mirror what's on disk, so there is nothing pending.
        timerTouched = false
    }

    /// Normal-mode list navigation: move the highlighted job by `delta` (±1,
    /// wrapping) and reload the editor from its plist. Guarded like leaving
    /// the screen — normally nothing is pending here (an Edit-mode edit is
    /// always resolved, one way or another, before Edit mode is left), but
    /// the check is a free safety net either way.
    func selectTimerJob(by delta: Int) {
        guard confirmDiscardTimerEdits() else { return }
        let all = LaunchdTimer.Kind.allCases
        let i = all.firstIndex(of: timerKind) ?? 0
        timerKind = all[((i + delta) % all.count + all.count) % all.count]
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
        // The vi-style mode indicator: bold green + the job name while editing
        // (this is where the arrow keys change real values), muted cyan
        // otherwise (arrow keys are just moving the selection).
        switch timerMode {
        case .normal: lines.append(cyan(fit("-- NORMAL --", cols)))
        case .edit:   lines.append(bold(green(fit("-- EDIT: \(timerKind.title) --", cols))))
        }
        lines.append("")

        let helpLines = wrapHelp(timerHelpLine(), cols)
        let footerH = 2 + helpLines.count
        let contentH = max(1, rows - 4 - footerH)

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

        let sectionTitle = timerMode == .edit ? "editing \(timerKind.title)" : "\(timerKind.title) \u{2014} e to edit"
        body.append(divider(sectionTitle, cols))
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

    /// Bracket a field's value when Edit mode has it focused, pad it out
    /// otherwise (including all of Normal mode, where nothing is focused), so
    /// the row keeps its width as focus moves.
    func field(_ value: String, _ which: TimerField) -> String {
        (timerMode == .edit && timerField == which) ? "[\(value)]" : " \(value) "
    }

    func timerHelpLine() -> String {
        switch timerMode {
        case .normal:
            return "\u{2191}/\u{2193} select job \u{2022} e edit \u{2022} i install \u{2022} o on/off \u{2022} d discard \u{2022} u delete \u{2022} esc back"
        case .edit:
            let dayKeys = timerKind.isMonthly ? "" : " \u{2022} 1-7 weekday \u{2022} 0 every day"
            return "\u{2190}/\u{2192} field \u{2022} \u{2191}/\u{2193} adjust\(dayKeys) \u{2022} enter save+done \u{2022} i install \u{2022} o on/off \u{2022} d discard \u{2022} u delete \u{2022} esc done"
        }
    }

    func handleTimer(_ key: Key) -> Bool {
        switch timerMode {
        case .normal: return handleTimerNormal(key)
        case .edit:   return handleTimerEdit(key)
        }
    }

    /// Normal mode: navigate the job list and issue whole-job commands.
    /// Nothing here touches a field value — that only happens in Edit mode.
    func handleTimerNormal(_ key: Key) -> Bool {
        switch key {
        case .up: selectTimerJob(by: -1)
        case .down, .tab: selectTimerJob(by: 1)
        case .char("e"), .enter, .right: timerMode = .edit
        case .char("i"): installTimerNow()
        case .char("o"): toggleTimerOnOff()
        case .char("d"): discardTimerEdit()
        case .char("u"): uninstallTimerNow()
        case .esc, .char("h"): if confirmDiscardTimerEdits() { screen = .home }
        case .char("q"), .ctrlC: if confirmDiscardTimerEdits() && confirmQuit() { return false }
        case .eof: return false
        default: break
        }
        return true
    }

    /// Edit mode: change the selected job's fields. esc/h leaves back to
    /// Normal — confirmed first if there's an unapplied edit, so a reflex
    /// esc can't silently discard it. enter is a shortcut that installs AND
    /// leaves, for "type the value, hit enter, done".
    func handleTimerEdit(_ key: Key) -> Bool {
        switch key {
        case .up: adjustTimer(by: 1)
        case .down: adjustTimer(by: -1)
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
        case .char("d"): discardTimerEdit()
        case .char("u"): uninstallTimerNow()
        case .enter: installTimerNow(); timerMode = .normal
        case .esc, .char("h"): if confirmDiscardTimerEdits() { timerMode = .normal }
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

    /// Immediately revert the fields to what's installed on disk — no prompt,
    /// available from either mode. The explicit "abbrechen" a leave-confirm
    /// prompt also offers, without needing to trigger one first.
    func discardTimerEdit() {
        let hadEdit = timerTouched
        loadTimerFields()
        if hadEdit { statusMsg = "edit discarded" }
    }

    /// Leaving an unapplied edit behind — via Edit mode's esc/h, switching
    /// jobs, or quitting — would otherwise silently throw it away. Mirrors
    /// confirmQuit()'s shape: install-or-discard, cancel (stay) by default.
    /// Returns true when it's fine to proceed (nothing pending, installed, or
    /// discarded).
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
