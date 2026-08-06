import Foundation

// The command center's Schedules screen, split out of CommandCenter.swift to match
// the per-screen file convention the Restore browser already follows.
//
// It edits all three scheduled jobs — backup, integrity check, restore drill —
// through a vi-style split (TimerMode), and the split is strict, because a
// half-modal screen is worse than none:
//
//   Normal (vi's normal mode) — up/down walk the job list, and every command
//     lives here: i/e edit, w write, u undo, o on/off, x delete. Nothing here
//     touches a field value, so landing on the screen and reaching for the
//     arrows cannot bump a real schedule. No key here changes the mode except
//     the explicit i/e/enter — an arrow that opened Edit would defeat the point.
//   Edit (vi's insert mode) — field editing (left/right pick a field, up/down
//     change its value, digits toggle weekdays), plus the two commands that
//     RESOLVE the edit: w writes it, u undoes it. esc leaves it pending.
//
// The line between the modes is what a key does to the EDIT, not tidiness:
// w and u resolve it and always return to Normal, so the mode can never
// outlive the edit it belonged to. That outliving was the original bug —
// discarding from inside Edit reset the fields but left the mode alone, so a
// screen that looked finished still had the arrows editing values instead of
// selecting the next job. The whole-JOB commands (x delete, o on/off) are
// about the schedule rather than the edit, so they stay in Normal, and pressing
// one in Edit says where it lives instead of being silently swallowed.
//
// w writes (installs or rewrites) and x deletes a job; o pauses or resumes it
// without touching its configured schedule (on/off, distinct from w/x which
// write or delete it). Every write goes through the tested CLI flags rather
// than a second plist writer here, so the TUI and `--install-*-timer` can
// never drift apart.
//
// An unwritten edit is tracked (the yellow "unapplied edit" note) and survives
// a mode switch untouched. It is only confirmed — write or undo — where it
// would actually be LOST: switching jobs, leaving the screen, or quitting.
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
        // No mode split in these hints: w and u resolve the edit from either
        // mode, so both keys are always true. They needed a mode-specific
        // wording only while Edit rejected them — a hint naming a key that does
        // nothing right now is what made the screen feel stuck.
        body.append(dim(fit("  w installs: " + previewSchedule().describe(), cols)))
        if let next = previewSchedule().nextFireDate(after: Date()) {
            body.append(dim(fit("  first run:  " + timerStampFmt.string(from: next)
                                + " (" + ScheduleDashboard.countdown(from: Date(), to: next) + ")", cols)))
        }
        if timerTouched {
            body.append(yellow(fit("  unapplied edit \u{2014} w writes it, u undoes it", cols)))
        }

        if body.count < contentH { body += Array(repeating: "", count: contentH - body.count) }
        lines += clipBody(body, to: contentH, cols: cols)

        lines.append("")
        lines.append(timerStatusLine(cols))
        for hl in helpLines { lines.append(dim(fit(hl, cols))) }
        draw(lines)
    }

    /// The status line with ONLY its message lit up. This screen's guidance
    /// ("press i to edit …", "x is a normal-mode command …") rides that line,
    /// where dim grey buried it in the permanently-dim footer — but colouring
    /// the whole line lights the standing "N folders • M albums" prefix too,
    /// which never changes and so draws the eye away from what did.
    ///
    /// Colour is applied AFTER fit() and only to the trailing message, because
    /// fit() measures display width and would count escape bytes as content —
    /// which is also why a message that fit() truncated is left dim: there is
    /// no longer a whole message in there to highlight.
    func timerStatusLine(_ cols: Int) -> String {
        let line = fit(statusLine(), cols)
        guard !statusMsg.isEmpty,
              // statusLine() appends the message last, so the LAST occurrence is
              // it — a message that happens to repeat a prefix word ("albums")
              // must not match the prefix instead.
              let msg = line.range(of: statusMsg, options: .backwards)
        else { return dim(line) }
        return dim(String(line[line.startIndex..<msg.lowerBound]))
             + bold(cyan(String(line[msg.lowerBound...])))
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
            return "\u{2191}/\u{2193} select job \u{2022} i edit \u{2022} w write \u{2022} u undo \u{2022} y yank \u{2022} p put \u{2022} o on/off \u{2022} x delete \u{2022} esc back"
        case .edit:
            let dayKeys = timerKind.isMonthly ? "" : " \u{2022} 1-7 weekday \u{2022} 0 every day"
            return "\u{2190}/\u{2192} field \u{2022} \u{2191}/\u{2193} adjust\(dayKeys) \u{2022} enter/w write \u{2022} u undo \u{2022} esc normal"
        }
    }

    func handleTimer(_ key: Key) -> Bool {
        switch timerMode {
        case .normal: return handleTimerNormal(key)
        case .edit:   return handleTimerEdit(key)
        }
    }

    /// Normal mode — vi's normal mode: EVERY command lives here, and nothing
    /// here touches a field value. Keeping the whole-job commands out of Edit
    /// mode is what makes the split mean something: when a command works in
    /// both modes, the mode is decoration, and "which does the arrow key do"
    /// becomes unanswerable again.
    func handleTimerNormal(_ key: Key) -> Bool {
        switch key {
        case .up, .char("k"): selectTimerJob(by: -1)
        case .down, .char("j"), .tab: selectTimerJob(by: 1)
        case .char("i"), .char("e"), .enter: timerMode = .edit
        // Left/right are Edit-mode field motions and do NOT enter it. Right used
        // to, which meant an arrow key silently started editing a live schedule —
        // exactly what the mode split exists to prevent. Say where the door is
        // instead of doing nothing.
        case .left, .right: statusMsg = "press i to edit \(timerKind.title)"
        case .char("w"): installTimerNow()
        case .char("u"): discardTimerEdit()      // vi's undo: revert to what's installed
        case .char("x"): uninstallTimerNow()     // delete the schedule itself
        case .char("o"): toggleTimerOnOff()
        case .char("y"): yankTimerSchedule()     // vi's yank
        case .char("p"): putTimerSchedule()      // vi's put
        case .esc, .char("h"): if confirmDiscardTimerEdits() { screen = .home }
        case .char("q"), .ctrlC: if confirmDiscardTimerEdits() && confirmQuit() { return false }
        case .eof: return false
        default: break
        }
        return true
    }

    /// Edit mode — vi's insert mode: ONLY field editing. esc returns to Normal
    /// and leaves the edit pending, exactly like leaving vi's insert mode,
    /// which neither writes nor discards; w and u in Normal do that. No prompt
    /// on the way out, because nothing is lost by the mode switch itself.
    ///
    /// Deliberately no whole-job commands here. When `d` (discard) lived in
    /// this mode it reset the fields but left the mode alone: the screen went
    /// clean, read as "done", and the arrows silently kept editing values
    /// instead of moving to the next job.
    ///
    /// The corollary the first cut missed: a mode that rejects keys has to SAY
    /// so, and every hint has to name a key that works in the CURRENT mode.
    /// Otherwise the strictness reads as breakage — the note advertised "u
    /// undoes it" while u did nothing here, which felt like being trapped in
    /// the edit with only esc as a way out.
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
        // Write-and-leave: the "set the value, hit enter, done" shortcut. It
        // exits to Normal, so it cannot strand anyone in Edit mode.
        // Resolving the edit works from here too, and both paths land in Normal.
        // THAT is what makes it safe — the mode never outlives the edit it
        // belonged to, which was the whole defect. Requiring esc first was a
        // keystroke that bought nothing: after u there is no edit left to guard.
        case .enter, .char("w"): installTimerNow(); timerMode = .normal
        case .char("u"): discardTimerEdit(); timerMode = .normal
        case .esc: timerMode = .normal
        // Ctrl-C stays an escape hatch from every mode; plain q is a Normal-mode
        // command, so it does not fire mid-edit.
        case .ctrlC: if confirmDiscardTimerEdits() && confirmQuit() { return false }
        case .eof: return false
        // What is left in Normal is the whole-JOB commands, which are about the
        // schedule rather than the edit. Swallowing them silently reads as a
        // dead keyboard, so point at the door instead.
        case .char(let c) where "xoqyp".contains(c):
            statusMsg = "\(c) is a normal-mode command \u{2014} press esc first"
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
        guard timerState.installed else { statusMsg = "nothing installed yet \u{2014} press w to write it first"; return }
        let pausing = timerState.loaded
        let flag = pausing ? timerKind.pauseFlag : timerKind.resumeFlag
        let code = runChildAndWait([flag], label: "\(pausing ? "pause" : "resume") \(timerKind.title) schedule")
        invalidateScheduleRows()
        refreshTimerState()
        if code == 0 { statusMsg = "\(timerKind.title): " + (timerState.loaded ? "on" : "off") }
    }

    /// Yank the schedule as DISPLAYED — an unwritten edit included, so what you
    /// see is what you copy — into the session clipboard.
    func yankTimerSchedule() {
        let copied = previewSchedule()
        timerClipboard = (timerKind, copied)
        statusMsg = "yanked \(timerKind.title): " + copied.describe()
    }

    /// Put the yanked schedule onto the selected job by filling its editor
    /// fields. It deliberately does NOT write: the paste lands as an ordinary
    /// unapplied edit, so nothing reaches launchd without an explicit w, and a
    /// paste onto the wrong job costs a u rather than a reinstall.
    func putTimerSchedule() {
        guard let clip = timerClipboard else {
            statusMsg = "nothing yanked yet \u{2014} press y on a job first"
            return
        }
        let before = (timerHour, timerMinute, timerWeekdays, timerDayOfMonth)
        let put = Schedule.paste(clip.schedule, onto: timerKind,
                                 target: (hour: timerHour, minute: timerMinute,
                                          weekdays: timerWeekdays.sorted(), dayOfMonth: timerDayOfMonth))
        timerHour = put.hour
        timerMinute = put.minute
        timerWeekdays = Set(put.weekdays)
        timerDayOfMonth = put.dayOfMonth
        // Only a paste that MOVED something is an edit. Putting a job onto
        // itself would otherwise raise an "unapplied edit" over no change at all.
        if (timerHour, timerMinute, timerWeekdays, timerDayOfMonth) != before { timerTouched = true }

        // What was dropped leads, because it is the part only this message can
        // tell you. The "w installs it / u undoes it" guidance is deliberately
        // NOT repeated here — the unapplied-edit note right above already says
        // it, and a status line long enough to carry both gets truncated on a
        // narrow terminal exactly where the actionable half sits.
        var msg = "put \(clip.kind.title) onto \(timerKind.title)"
        if !put.dropped.isEmpty { msg += " \u{2014} dropped " + put.dropped.joined(separator: " + ") }
        if !timerTouched { msg += " \u{2014} no change" }
        statusMsg = msg
    }

    /// Immediately revert the fields to what's installed on disk — no prompt,
    /// available from either mode. The explicit "abbrechen" a leave-confirm
    /// prompt also offers, without needing to trigger one first.
    func discardTimerEdit() {
        let hadEdit = timerTouched
        loadTimerFields()
        if hadEdit { statusMsg = "edit discarded" }
    }

    /// Prompts only where an unapplied edit would actually be LOST: switching
    /// jobs (the reload wipes it) and leaving the screen or quitting. Moving
    /// between Edit and Normal never asks, because the edit survives that.
    /// Mirrors confirmQuit()'s shape: write-or-undo, cancel (stay) by default.
    /// Returns true when it's fine to proceed.
    func confirmDiscardTimerEdits() -> Bool {
        guard timerTouched else { return true }
        drawPrompt("unapplied schedule edit \u{2014} w: write & continue   u: undo & continue   esc/enter: stay")
        while true {
            switch readKey() {
            case .char("w"), .char("W"):
                return installTimerNow() == 0
            case .char("u"), .char("U"):
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
