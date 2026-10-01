import Foundation

// The command center's Runs screen: the run history the home dashboard only
// summarises — a month calendar of coverage, the runs themselves, and for the
// selected run the detail the list has no room for, including the per-destination
// error text.
//
// That error text already lives in the history (redacted at write time) but was
// previously counted and thrown away ("1 dest failed"), so the one question a
// failed backup raises — *what* failed — could only be answered by reading
// ~/Library/Logs/baaackaaab.log by hand. `l` shells out to `--log-tail` for
// restic's own output, the detail the structured record deliberately omits.
extension ConfigTUI {
    // MARK: - Enter / data

    /// How far back the calendar and the list reach. Three months is what the
    /// three-month grid can show; the list is filtered from the same window, so a
    /// run visible as a cell is always findable as a row.
    var runsWindowMonths: Int { 3 }

    func enterRuns() {
        runsCursor = 0
        runsTop = 0
        runsFailuresOnly = false
        runsRecords = nil
        screen = .runs
    }

    /// Every record in the window, newest first. Cached like the home dashboard's
    /// history; dropped after a sync so a fresh run shows up on return.
    func loadRunsRecords() -> [RunRecord] {
        if let r = runsRecords { return r }
        let cal = Calendar.current
        let since = cal.date(byAdding: .month, value: -(runsWindowMonths - 1),
                             to: cal.startOfDay(for: Date())) ?? Date.distantPast
        // From the START of the oldest displayed month, so the grid's first column
        // is backed by data rather than clipped mid-month.
        let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: since)) ?? since
        let r = RunHistory.since(monthStart)
        runsRecords = r
        return r
    }

    /// The rows the list shows: every run, or only the ones that did not end clean
    /// when the failures filter is on.
    func runsRows() -> [RunRecord] {
        let all = loadRunsRecords()
        return runsFailuresOnly ? all.filter { !$0.clean } : all
    }

    /// A run's job name, so a list mixing backups, checks and drills stays readable.
    func runsJobLabel(_ r: RunRecord) -> String {
        if r.isDrill { return "drill" }
        if r.isCheck { return "check" }
        return "backup"
    }

    // MARK: - Render

    func renderRuns() {
        let (rows, cols) = terminalSize()
        var lines: [String] = []
        lines.append(bold(fit("baaackaaab \u{2014} runs", cols)))
        lines.append(cyan(fit("history, coverage + what went wrong", cols)))
        lines.append("")

        let helpLines = wrapHelp(runsHelpLine(), cols)
        let footerH = 2 + helpLines.count
        let contentH = max(1, rows - 3 - footerH)

        var body: [String] = []
        body += runsCalendarLines(cols)
        body.append("")

        let list = runsRows()
        // The detail is rendered FIRST so the list knows how many rows are left:
        // a wrapped multi-line error would otherwise push the detail off the
        // bottom — hiding exactly the text the screen exists to show.
        let detail = runsDetailLines(list, cols)

        let title = runsFailuresOnly ? "failures (\(list.count))" : "runs (\(list.count))"
        body.append(divider(title, cols))
        if list.isEmpty {
            body.append(dim(fit(runsFailuresOnly
                ? "  no failed run in the last \(runsWindowMonths) months"
                : "  no runs recorded in the last \(runsWindowMonths) months", cols)))
        } else {
            let listH = max(3, contentH - body.count - detail.count - 2)
            clampRunsCursor(list.count, visible: listH)
            for i in runsTop..<min(list.count, runsTop + listH) {
                body.append(runsRowLine(list[i], selected: i == runsCursor, cols))
            }
        }

        body.append("")
        body.append(divider("detail", cols))
        body += detail

        if body.count < contentH { body += Array(repeating: "", count: contentH - body.count) }
        lines += clipBody(body, to: contentH, cols: cols)

        lines.append("")
        lines.append(dim(fit(statusLine(), cols)))
        for hl in helpLines { lines.append(dim(fit(hl, cols))) }
        draw(lines)
    }

    /// The three-month coverage grid, coloured per day.
    func runsCalendarLines(_ cols: Int) -> [String] {
        let cal = Calendar.current
        let records = loadRunsRecords()
        // With no history at all there is nothing to be a gap in: a full grid of
        // "no run" dots would assert three months of missed backups on a store
        // that has simply never run.
        guard !records.isEmpty else {
            return [divider("calendar", cols),
                    dim(fit("  no runs recorded yet \u{2014} the calendar fills in as runs happen", cols))]
        }
        let byDay = RunCalendar.statusByDay(records, calendar: cal)
        // Records come newest-first, so the oldest one bounds what was observed.
        // Without it the months before the history starts fill with "no run" dots
        // that read as a coverage gap rather than as an absence of records.
        let grid = RunCalendar.grid(months: runsWindowMonths, now: Date(),
                                    statusByDay: byDay, knownFrom: records.last?.end,
                                    calendar: cal)
        var out = [divider("calendar", cols)]
        out.append(dim(fit("  " + grid.monthHeader, cols)))
        out.append(dim(fit("  " + grid.weekdayHeader, cols)))
        for row in grid.rows {
            // Colour each cell on its own, then join — a row mixes good and bad days.
            let painted = row.map { cell -> String in
                switch cell.status {
                case .ok:      return green(cell.label)
                case .failed:  return red(cell.label)
                case .partial: return yellow(cell.label)
                case .none:    return dim(cell.label)
                }
            }.joined(separator: " ")
            // Not run through fit(): it measures bytes, and the per-cell colour
            // escapes would make it truncate a grid that fits. The grid's width is
            // fixed by the month count (66 columns for three), not by content.
            out.append("  " + painted)
        }
        out.append(dim(fit("  " + RunCalendar.legend, cols)))
        return out
    }

    /// One run in the list: outcome, end time, job, counts, duration.
    func runsRowLine(_ r: RunRecord, selected: Bool, _ cols: Int) -> String {
        let mark = r.clean ? "\u{2713}" : "\u{2717}"
        let when = runStampFmt.string(from: r.end)
        let job = runsJobLabel(r).padding(toLength: 7, withPad: " ", startingAt: 0)
        var parts = ["\(r.verified)/\(r.total)"]
        if r.isCheck, let slice = r.slice { parts = ["slice \(slice)"] }
        if r.isDrill, let bytes = r.bytes { parts = [String(format: "%.1f MB", Double(bytes) / 1_000_000)] }
        parts.append(runsDuration(r))
        let line = "\(selected ? "\u{25B8}" : " ") \(mark) \(when)  \(job)  \(parts.joined(separator: "  \u{2022}  "))"
        let plain = fit(line, cols)
        if selected { return r.clean ? green(plain) : yellow(plain) }
        return r.clean ? dim(plain) : yellow(plain)
    }

    func runsDuration(_ r: RunRecord) -> String {
        let secs = max(0, Int(r.end.timeIntervalSince(r.start)))
        if secs < 60 { return "\(secs)s" }
        if secs < 3600 { return "\(secs / 60)m \(secs % 60)s" }
        return "\(secs / 3600)h \((secs % 3600) / 60)m"
    }

    /// The selected run's detail: exit code, window, and — the reason this screen
    /// exists — the per-destination error text on a failure.
    func runsDetailLines(_ list: [RunRecord], _ cols: Int) -> [String] {
        guard !list.isEmpty, runsCursor < list.count else {
            return [dim(fit("  select a run to see its detail", cols))]
        }
        let r = list[runsCursor]
        var out: [String] = []
        var head = ["exit \(r.exitCode)", "tag \(r.runTag)"]
        if r.sourceFailures > 0 { head.append("\(r.sourceFailures) source failure(s)") }
        // Seconds on both ends, unlike the list: a 10-second run at minute
        // precision reads as "21:01 → 21:01", which looks like a broken record.
        let day = String(runStampFmt.string(from: r.start).prefix(10))
        let window = "\(day)  \(runClockFmt.string(from: r.start)) \u{2192} \(runClockFmt.string(from: r.end))"
        out.append(dim(fit("  \(window) (\(runsDuration(r)))  \u{2022}  "
                           + head.joined(separator: "  \u{2022}  "), cols)))
        for d in r.destinations {
            if let err = d.error, !err.isEmpty {
                // Wrapped, not truncated: the error text is the reason this screen
                // exists, and restic's messages run well past one terminal row.
                let wrapped = wrapText("\u{2717} \(d.name): \(err)", width: max(20, cols - 4))
                for line in wrapped { out.append(red(fit("  " + line, cols))) }
            } else if d.ok {
                var bits: [String] = []
                if let added = d.dataAdded { bits.append("\(byteSummary(added)) added") }
                if let new = d.filesNew, let ch = d.filesChanged { bits.append("\(new) new, \(ch) changed") }
                out.append(green(fit("  \u{2713} \(d.name)" + (bits.isEmpty ? "" : ": " + bits.joined(separator: "  \u{2022}  ")), cols)))
            } else {
                out.append(yellow(fit("  \u{2717} \(d.name): failed (no error text recorded)", cols)))
            }
        }
        if r.destinations.isEmpty {
            out.append(yellow(fit("  no destination was reached \u{2014} press l for the run log", cols)))
        }
        return out
    }

    /// Word-wrap for prose. `wrapHelp` only breaks on the " • " key separator, so
    /// it leaves a long sentence on one over-long line. Continuation lines are
    /// indented so a wrapped error reads as one block, not as several findings.
    func wrapText(_ s: String, width: Int) -> [String] {
        var lines: [String] = []
        var cur = ""
        let indent = "  "
        for word in s.split(separator: " ", omittingEmptySubsequences: true) {
            let candidate = cur.isEmpty ? String(word) : cur + " " + word
            let limit = lines.isEmpty ? width : width - indent.count
            if candidate.count <= limit { cur = candidate; continue }
            if cur.isEmpty {
                // A single word longer than the line (a path, a repo URL): give it
                // its own line rather than looping or emitting it twice.
                lines.append(lines.isEmpty ? String(word) : indent + String(word))
                continue
            }
            lines.append(lines.isEmpty ? cur : indent + cur)
            cur = String(word)
        }
        if !cur.isEmpty { lines.append(lines.isEmpty ? cur : indent + cur) }
        return lines.isEmpty ? [s] : lines
    }

    func byteSummary(_ n: Int64) -> String {
        if n < 1_000_000 { return String(format: "%.0f KB", Double(n) / 1_000) }
        if n < 1_000_000_000 { return String(format: "%.1f MB", Double(n) / 1_000_000) }
        return String(format: "%.2f GB", Double(n) / 1_000_000_000)
    }

    func runsHelpLine() -> String {
        "\u{2191}/\u{2193} select \u{2022} f failures only \u{2022} l run log \u{2022} esc back \u{2022} q quit"
    }

    // MARK: - Input

    func handleRuns(_ key: Key) -> Bool {
        let count = runsRows().count
        switch key {
        case .up: if runsCursor > 0 { runsCursor -= 1 }
        case .down: if runsCursor + 1 < count { runsCursor += 1 }
        case .char("f"):
            runsFailuresOnly.toggle()
            runsCursor = 0; runsTop = 0
            statusMsg = runsFailuresOnly ? "showing failures only" : "showing all runs"
        case .char("l"): showLogTail()
        case .esc, .char("h"): screen = .home
        case .char("q"), .ctrlC: if confirmQuit() { return false }
        case .eof: return false
        default: break
        }
        return true
    }

    /// Keep the cursor inside the list and the window around the cursor.
    func clampRunsCursor(_ count: Int, visible: Int) {
        if runsCursor >= count { runsCursor = max(0, count - 1) }
        if runsCursor < runsTop { runsTop = runsCursor }
        if runsCursor >= runsTop + visible { runsTop = runsCursor - visible + 1 }
        if runsTop > max(0, count - visible) { runsTop = max(0, count - visible) }
    }

    /// Page the unattended run log through the tested CLI — restic's own output for
    /// a scheduled run, which the structured history does not keep.
    func showLogTail() {
        runChildAndWait(["--log-tail", "200"], label: "run log")
    }
}
