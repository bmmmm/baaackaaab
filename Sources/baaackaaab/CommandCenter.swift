import Foundation
#if canImport(Darwin)
import Darwin
#endif

extension ConfigTUI {
    /// Home screen (the command center). Routes the action keys; returns false to
    /// quit the whole app.
    func handleHome(_ key: Key) -> Bool {
        // The help overlay is modal: while it is up, esc / ? just dismiss it (no
        // quit prompt), and any action key dismisses it BEFORE acting — otherwise
        // the overlay stays painted over the dashboard and the user appears stuck
        // in help. Only q / Ctrl-C still quit (with confirmation), as the overlay
        // itself advertises.
        if showHelp {
            switch key {
            case .char("?"), .esc: showHelp = false; return true
            case .char("q"), .ctrlC: return confirmQuit() ? false : true
            case .eof: return false
            default: showHelp = false   // fall through to run the action below
            }
        }
        switch key {
        case .char("e"), .enter, .right, .tab: screen = .editor
        case .char("s"): syncNow()
        case .char("p"): dryRunNow()
        case .char("r"): refreshRemote()
        case .char("u"): checkUpdatesNow()
        case .char("R"): enterRestore()
        case .char("t"): enterTimer()
        case .char("H"): enterRuns()
        case .char("?"): showHelp = true
        case .char("q"), .esc, .ctrlC: if confirmQuit() { return false }
        case .eof: return false
        default: break
        }
        return true
    }

    // MARK: - Home screen (command center)

    /// The landing dashboard: the backup set and the remote status, with the
    /// action keys. Built as exactly `rows` lines, like render(), so the footer
    /// pins to the bottom.
    func renderHome() {
        let (rows, cols) = terminalSize()
        var lines: [String] = []
        lines.append(bold(fit("baaackaaab \u{2014} command center", cols)))
        lines.append(cyan(fit("one-way iCloud \u{2192} restic backup", cols)))
        lines.append("")

        let helpLines = wrapHelp(homeHelpLine(), cols)
        let footerH = 2 + helpLines.count           // blank + status + help(N)
        let contentH = max(1, rows - 3 - footerH)   // minus header(3)

        var body: [String] = []
        body.append(divider("backup set", cols))
        if set.isEmpty {
            body.append(dim(fit("  empty \u{2014} press e to add folders / albums", cols)))
        } else {
            for f in set.driveFolders { body.append(green(fit("  [drive] " + f, cols))) }
            for a in set.photoAlbums { body.append(green(fit("  [album] " + a, cols))) }
            if let q = set.quotaBytes {
                body.append(dim(fit(String(format: "  [quota] %.1f GB", Double(q) / 1_000_000_000), cols)))
            }
        }
        body.append("")
        body.append(divider("destinations", cols))
        if !repoResolved {
            body.append(dim(fit("  press r to query the remotes (snapshots + size)", cols)))
        } else if destinations.isEmpty {
            body.append(yellow(fit("  no repository configured \u{2014} run baaackaaab --init-credentials", cols)))
        } else {
            for (i, dest) in destinations.enumerated() {
                let status = (remoteQueried && i < remotes.count) ? remotes[i] : nil
                body += homeDestinationLines(dest, status: status, cols: cols)
            }
        }

        body.append("")
        body.append(divider("recent runs", cols))
        // Summary line first: age of the newest successful backup, OVERDUE when it
        // has slipped past 1.5× the installed schedule's cadence.
        body.append(homeBackupLine(cols))
        // Drills and integrity checks live in the same history but are shown on
        // their own lines below, so keep the recent-runs list to actual backups.
        let runs = loadRecentRuns().filter { $0.isBackup }
        if runs.isEmpty {
            body.append(dim(fit("  no runs recorded yet \u{2014} press s to back up now", cols)))
        } else {
            for rec in runs.prefix(4) { body.append(homeRunLine(rec, cols)) }
        }

        // What runs unattended sits right under what already ran — "when is the next
        // one" is the question the recent-runs list raises.
        body.append("")
        body.append(divider("schedules", cols))
        for row in loadScheduleRows() { body.append(homeScheduleLine(row, cols)) }

        body.append("")
        body.append(divider("verification", cols))
        body.append(homeDrillLine(cols))
        body.append(homeCheckLine(cols))

        body.append("")
        body.append(divider("updates", cols))
        if !updatesChecked {
            body.append(dim(fit("  press u to check restic + the REST server against the latest releases", cols)))
        } else {
            for f in updateFindings { body.append(homeUpdateLine(f, cols)) }
        }

        if showHelp { body = helpOverlayLines(contentH, cols) }
        else if body.count < contentH { body += Array(repeating: "", count: contentH - body.count) }
        lines += clipBody(body, to: contentH, cols: cols)

        lines.append("")
        lines.append(dim(fit(statusLine(), cols)))
        for hl in helpLines { lines.append(dim(fit(hl, cols))) }
        draw(lines)
    }

    /// Two lines for one destination on the home dashboard: an identity line
    /// (name + link label + redacted URL) and a status line (per-source latest +
    /// size when reachable, the failure otherwise, the query hint before first
    /// `r`). The name leads the identity line so it survives fit() truncation.
    func homeDestinationLines(_ dest: Destination, status: ResticBackend.RemoteStatus?, cols: Int) -> [String] {
        let url = dest.displayURL.map { Credentials.redact($0) } ?? "(url unreadable)"
        let linkTag = dest.link == "default" ? "" : " [" + dest.link + "]"
        var out = [dim(fit("  " + dest.name + linkTag + "  " + url, cols))]
        guard let status = status else {
            out.append(dim(fit("    press r to query snapshots + size", cols)))
            return out
        }
        if let err = status.error {
            out.append(yellow(fit("    \u{2717} " + err, cols)))
        } else {
            out.append(green(fit("    \u{2713} " + homeStatusSummary(status), cols)))
            if let used = status.sizeBytes, let quota = set.quotaBytes {
                out.append(quotaBar(usedBytes: used, quotaBytes: quota, cols: cols))
            }
        }
        return out
    }

    /// The reachable-destination one-liner: total snapshots, repo size, and the
    /// latest snapshot time per source (drive / photos), so the dashboard reads as
    /// (source × destination). A source with no snapshots yet shows an em-dash.
    func homeStatusSummary(_ r: ResticBackend.RemoteStatus) -> String {
        var parts = ["\(r.snapshotCount) snap(s)"]
        if let s = r.sizeBytes { parts.append(String(format: "%.2f GB", Double(s) / 1_000_000_000)) }
        for src in r.sources {
            parts.append(src.source + " " + (src.latestTime.map(shortTime) ?? "\u{2014}"))
        }
        if let oldest = r.oldestTime, let date = parseResticTime(oldest) {
            parts.append("oldest " + relativeTime(from: date))
        }
        return parts.joined(separator: "  \u{2022}  ")
    }

    /// The last few run-history records, newest first. Loaded once and cached;
    /// dropped after a sync so the run just finished appears on return. No
    /// credentials involved — the history file holds only tags/times/counts. A
    /// slightly deeper window than the four rows shown, so a stray interleaved
    /// drill record doesn't push a real backup out of view.
    func loadRecentRuns() -> [RunRecord] {
        if let r = recentRuns { return r }
        let r = RunHistory.recent(12)
        recentRuns = r
        return r
    }

    /// The newest restore-drill record, cached once (see `lastDrillRecord`).
    func loadLastDrill() -> RunRecord? {
        if let cached = lastDrillRecord { return cached }
        let d = RunHistory.lastDrill()
        lastDrillRecord = .some(d)
        return d
    }

    /// The newest integrity-check record, cached once (see `lastCheckRecord`).
    func loadLastCheck() -> RunRecord? {
        if let cached = lastCheckRecord { return cached }
        let c = RunHistory.lastCheck()
        lastCheckRecord = .some(c)
        return c
    }

    /// The newest SUCCESSFUL backup record, cached once — the anchor for the
    /// "last backup" overdue line. Dropped after a sync so a fresh run shows up.
    func loadLastSuccessfulBackup() -> RunRecord? {
        if let cached = lastSuccessfulBackupRecord { return cached }
        let r = RunHistory.lastSuccessfulBackup()
        lastSuccessfulBackupRecord = .some(r)
        return r
    }

    /// The installed backup timer's intended interval, or nil when no timer is
    /// installed (no cadence to be overdue against). Reads the plist once, cached.
    func loadBackupInterval() -> TimeInterval? {
        if backupIntervalLoaded { return backupIntervalValue }
        backupIntervalValue = LaunchdTimer.installedSchedule()?.intendedInterval()
        backupIntervalLoaded = true
        return backupIntervalValue
    }

    /// The "last verified restore" line: age since the newest recorded drill,
    /// styled like the other status lines — red on a failed drill, yellow when
    /// overdue, dim when fresh or never run. Derived from RunHistory, never
    /// hardcoded (the threshold + text come from the pure `DrillDashboard`).
    func homeDrillLine(_ cols: Int) -> String {
        let (level, text) = DrillDashboard.line(lastDrill: loadLastDrill(), now: Date())
        switch level {
        case .none:   return dim(fit("  " + text, cols))
        // Green, not dim: a passing drill is the most expensive evidence this
        // tool produces — an actual restore, verified byte for byte. Rendering
        // it in the same grey as "nothing here yet" understated the one line
        // that answers "is the backup real". Matches the run and destination
        // rows, which have always been green when clean.
        case .ok:     return green(fit("  \u{2713} " + text, cols))
        case .stale:  return yellow(fit("  \u{2717} " + text, cols))
        case .failed: return red(fit("  \u{2717} " + text, cols))
        }
    }

    /// The "last integrity check" line: age + rotating slice position (e.g.
    /// "integrity check 3/8 · 2d ago"), styled dim when passing, yellow when the
    /// timer looks dead (no check for several intervals), red on a failed check.
    /// Derived from RunHistory via the pure `CheckDashboard`; the staleness
    /// interval comes from the installed check timer's own plist.
    func homeCheckLine(_ cols: Int) -> String {
        let (level, text) = CheckDashboard.line(
            lastCheck: loadLastCheck(), now: Date(),
            interval: LaunchdTimer.installedCheckSchedule()?.intendedInterval())
        switch level {
        case .none:   return dim(fit("  " + text, cols))
        case .ok:     return green(fit("  \u{2713} " + text, cols))
        case .stale:  return yellow(fit("  ! " + text, cols))
        case .failed: return red(fit("  \u{2717} " + text, cols))
        }
    }

    /// Cut a rendered body down to the content area. A short window silently
    /// dropping the panels below the fold reads as "there is nothing there" — the
    /// last visible line says how much was cut and what to do about it instead.
    func clipBody(_ body: [String], to contentH: Int, cols: Int) -> [String] {
        guard body.count > contentH else { return body }
        // Every hidden line, plus the one this notice displaces.
        let hidden = body.count - contentH + 1
        return Array(body.prefix(contentH - 1))
             + [yellow(fit("  \u{2026} \(hidden) more line(s) below \u{2014} make the window taller", cols))]
    }

    /// Probe all three scheduled jobs (plist on disk + loaded into launchd + the
    /// schedule it encodes), cached like the run history: each job costs a launchctl
    /// spawn, so this runs once per session and is dropped after any install or
    /// uninstall rather than on every render.
    func loadScheduleRows() -> [ScheduleRowState] {
        if let rows = scheduleRows { return rows }
        let rows = LaunchdTimer.Kind.allCases.map { kind -> ScheduleRowState in
            let st = LaunchdTimer.state(kind)
            return ScheduleRowState(kind: kind, installed: st.installed, loaded: st.loaded,
                                    paused: LaunchdTimer.isPaused(kind),
                                    schedule: LaunchdTimer.installedSchedule(kind))
        }
        scheduleRows = rows
        return rows
    }

    /// Drop the cached probe so the next render re-reads launchd — called after the
    /// schedules editor installs or removes a job.
    func invalidateScheduleRows() {
        scheduleRows = nil
        // The backup line's overdue judgment is anchored on the installed backup
        // schedule's interval, so a schedule change invalidates it too.
        backupIntervalLoaded = false
        backupIntervalValue = nil
    }

    /// One scheduled job on the dashboard: cadence + next fire time when it is
    /// healthy, yellow when a plist is present but launchd never loaded it (looks
    /// scheduled, never fires), dim-paused when the operator turned it off on
    /// purpose (o), dim when the job is not scheduled at all.
    func homeScheduleLine(_ row: ScheduleRowState, _ cols: Int) -> String {
        let (level, text) = ScheduleDashboard.row(kind: row.kind, installed: row.installed,
                                                  loaded: row.loaded, paused: row.paused,
                                                  schedule: row.schedule, now: Date())
        switch level {
        case .ok:     return green(fit("  \u{2713} " + text, cols))
        case .none:   return dim(fit("    " + text + " \u{2014} press t to schedule it", cols))
        case .off:    return dim(fit("  \u{23F8} " + text, cols))
        case .broken: return yellow(fit("  ! " + text, cols))
        }
    }

    /// The "last backup" line: age of the newest successful backup, turning into an
    /// OVERDUE warning (yellow, like the drill-staleness line) when it has slipped
    /// past 1.5× the installed schedule's cadence. With no timer installed there is
    /// no cadence to violate, so it shows the age only. Pure logic in BackupDashboard.
    func homeBackupLine(_ cols: Int) -> String {
        let (level, text) = BackupDashboard.line(
            lastSuccess: loadLastSuccessfulBackup(), interval: loadBackupInterval(), now: Date())
        switch level {
        case .none:    return dim(fit("  " + text, cols))
        // Carries the tick the other status lines have, so the healthy states
        // read as one column rather than as three different conventions.
        case .ok:      return green(fit("  \u{2713} " + text, cols))
        case .overdue: return yellow(fit("  \u{2717} " + text, cols))
        }
    }

    /// One run on the dashboard: outcome mark, end time, run tag, verified/total,
    /// and the count of unhappy destinations if any. Green when clean, yellow not.
    func homeRunLine(_ r: RunRecord, _ cols: Int) -> String {
        let mark = r.clean ? "\u{2713}" : "\u{2717}"
        let when = relativeTime(from: r.end)
        var parts = ["\(r.verified)/\(r.total)"]
        let bad = r.destinations.filter { !$0.ok }.count
        if bad > 0 { parts.append("\(bad) dest failed") }
        if r.sourceFailures > 0 { parts.append("\(r.sourceFailures) src failed") }
        let line = "  \(mark) \(when)  \(r.runTag)  \(parts.joined(separator: "  \u{2022}  "))"
        let plain = fit(line, cols)
        return r.clean ? green(plain) : yellow(plain)
    }

    /// One update finding on the dashboard, coloured like the run lines: green when
    /// current, yellow when behind, dim when a side is unreadable. Mirrors
    /// Finding.emit() but renders into the TUI buffer instead of printing to stdout
    /// (which would tear the alternate screen).
    func homeUpdateLine(_ f: UpdateCheck.Finding, _ cols: Int) -> String {
        let refLabel = f.referenceKind == .latest ? "latest" : "baseline"
        switch f.verdict {
        case .upToDate(let inst, let ref):
            return green(fit("  \u{2713} \(f.component) \(inst) \u{2014} current (\(refLabel) \(ref))", cols))
        case .behind(let inst, let ref):
            return yellow(fit("  \u{2717} \(f.component) \(inst) \u{2014} update available: \(ref) (\(refLabel))", cols))
        case .unknownInstalled:
            // The installed version is unreadable (the usual rest-server case), so the
            // reference IS the line's value — lead with it so a narrow dashboard
            // truncates the explanatory tail, not the version the user came to see.
            if let ref = f.reference {
                return dim(fit("  \(f.component): \(refLabel) \(ref) \u{2014} installed version not readable here", cols))
            }
            return dim(fit("  \(f.component): \(f.unavailableNote)", cols))
        case .unknownReference:
            let inst = f.installed.map { "\($0)" } ?? "?"
            return dim(fit("  \(f.component) \(inst): \(refLabel) version unknown (offline?)", cols))
        }
    }

    func homeHelpLine() -> String {
        "e edit \u{2022} s sync \u{2022} p preview \u{2022} r remote \u{2022} u updates \u{2022} R restore \u{2022} t schedules \u{2022} H runs \u{2022} ? help \u{2022} q quit"
    }

    /// Help overlay content: replaces the body area when showHelp is toggled.
    func helpOverlayLines(_ height: Int, _ cols: Int) -> [String] {
        let entries: [(String, String)] = [
            ("e", "open backup-set editor"),
            ("s", "run backup now"),
            ("p", "dry-run preview (reads repo, uploads nothing)"),
            ("r", "refresh remote status"),
            ("u", "check restic / server updates (contacts GitHub)"),
            ("R", "open restore browser"),
            ("t", "schedules: see / change / pause / delete the backup, check + drill timers"),
            ("H", "runs: coverage calendar, full history + why a run failed"),
            ("esc / ?", "close this help"),
            ("q", "quit"),
        ]
        var lines: [String] = [dim(fit("  keyboard shortcuts", cols))]
        for (key, desc) in entries {
            let pad = String(repeating: " ", count: max(0, 9 - key.count))
            lines.append(fit("  \(key)\(pad)\(desc)", cols))
        }
        while lines.count < height { lines.append("") }
        return Array(lines.prefix(height))
    }

    /// Visual quota bar: `[████████░░] 4.2/5.0 GB (84%)`.
    func quotaBar(usedBytes: Int, quotaBytes: Int, cols: Int) -> String {
        // A hand-edited `quota_bytes: 0` would make 0/0 a NaN ratio (rendering
        // a nonsense 100% bar); no quota means no bar.
        guard quotaBytes > 0 else { return "" }
        let ratio = min(1.0, Double(usedBytes) / Double(quotaBytes))
        let trackW = max(4, min(20, cols - 32))
        let filled = Int(ratio * Double(trackW))
        let track = String(repeating: "\u{2588}", count: filled)
                  + String(repeating: "\u{2591}", count: trackW - filled)
        let usedGB  = Double(usedBytes)  / 1_000_000_000
        let quotaGB = Double(quotaBytes) / 1_000_000_000
        return dim(fit(String(format: "    [%@] %.1f/%.1f GB (%d%%)", track, usedGB, quotaGB, Int(ratio * 100)), cols))
    }

    // MARK: - Home actions

    /// Run the real backup by re-execing this binary. We leave the alternate
    /// screen + raw mode first so restic streams to the normal screen with proper
    /// newlines, then re-enter after a keypress — a clean shell-out, never a
    /// nested TUI.
    func syncNow() {
        guard !set.isEmpty else { statusMsg = "backup set is empty \u{2014} press e to add folders / albums"; return }
        if dirty { save() }   // back up exactly what's on screen
        // The re-exec'd child resolves its own destinations from the store (it
        // reads the 0600 files directly), so we export nothing here — we only
        // refresh our cached primary for the post-sync display. An explicit
        // --restic-repo is forwarded via syncArgs so an ad-hoc target carries
        // through to the child.
        ensureRepoResolved()
        emit("\u{1B}[?25h\u{1B}[?1049l")   // show cursor, leave the alternate screen
        term.restore()                      // cooked, so the child's output behaves
        let code = runSyncChild()
        let tail = code == 0 ? "sync finished" : "sync exited with code \(code)"
        FileHandle.standardOutput.write(Data("\n\(tail) \u{2014} press any key to return\n".utf8))
        term.enable()                       // raw again, to catch a single keypress
        // Reclaim BEFORE the blocking read: the just-exited restic child may have
        // taken the tty foreground pgroup; reading while backgrounded raises
        // SIGTTIN (not ignored) and stops the whole app — looks like a hang.
        reclaimForeground()
        _ = readKey()
        emit("\u{1B}[?1049h\u{1B}[?25l")    // back into the alternate screen
        remotes = []; remoteQueried = false  // repos changed — drop the cached status
        recentRuns = nil                     // the run we just did appended a record
        runsRecords = nil                    // so does the runs screen's window
        lastSuccessfulBackupRecord = nil     // and it may be the new newest success
        statusMsg = code == 0 ? "sync finished \u{2014} press r to refresh remote" : "sync failed (code \(code))"
    }

    func runSyncChild(extraArgs: [String] = []) -> Int32 {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: selfPath())
        proc.arguments = syncArgs() + extraArgs
        do { try proc.run() } catch {
            FileHandle.standardOutput.write(Data("could not launch backup: \(error)\n".utf8))
            return -1
        }
        proc.waitUntilExit()
        return proc.terminationStatus
    }

    /// Dry-run preview: re-execs this binary with --dry-run so restic reports what
    /// would be uploaded without writing anything. Same shell-out / re-enter pattern
    /// as syncNow(); the repo is read-only during a dry run.
    func dryRunNow() {
        guard !set.isEmpty else { statusMsg = "backup set is empty \u{2014} press e to add folders / albums"; return }
        // Same rule as syncNow: the child re-reads the set from disk, so unsaved
        // edits must be saved first or the preview reports the STALE set — the
        // opposite of what a user pressing `p` after editing wants to see.
        // (Saving the local config file is not a repo write; the dry run's
        // "writes nothing" contract is about the store.)
        if dirty { save() }
        ensureRepoResolved()
        emit("\u{1B}[?25h\u{1B}[?1049l")
        term.restore()
        let code = runSyncChild(extraArgs: ["--dry-run"])
        let tail = code == 0 ? "dry run finished" : "dry run exited with code \(code)"
        FileHandle.standardOutput.write(Data("\n\(tail) \u{2014} press any key to return\n".utf8))
        term.enable()
        reclaimForeground()   // before the blocking read — see syncNow()
        _ = readKey()
        emit("\u{1B}[?1049h\u{1B}[?25l")
        statusMsg = code == 0 ? "dry run complete \u{2014} nothing uploaded" : "dry run failed (code \(code))"
    }

    /// Shell out to a child invocation of this binary (a read-only browse like
    /// `--ls` / `--diff`, or a timer install/uninstall) and page its output, then
    /// wait for a key and return to the current screen. Same screen dance as
    /// dryRunNow(). `label` names the action in the "press any key" footer and any
    /// non-zero status line.
    @discardableResult
    func runChildAndWait(_ args: [String], label: String) -> Int32 {
        emit("\u{1B}[?25h\u{1B}[?1049l")   // show cursor, leave the alternate screen
        term.restore()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: selfPath())
        proc.arguments = args
        var code: Int32 = -1
        do { try proc.run(); proc.waitUntilExit(); code = proc.terminationStatus }
        catch { FileHandle.standardOutput.write(Data("could not launch \(label): \(error)\n".utf8)) }
        FileHandle.standardOutput.write(Data("\n\(label) done \u{2014} press any key to return\n".utf8))
        term.enable()
        reclaimForeground()   // before the blocking read — see syncNow()
        _ = readKey()
        emit("\u{1B}[?1049h\u{1B}[?25l")   // back into the alternate screen
        statusMsg = code == 0 ? "" : "\(label) exited with code \(code)"
        return code
    }

    /// Read-only refresh of the remote panel: query EVERY enabled destination so
    /// the dashboard shows one row per (source × destination). Resolves the
    /// destinations lazily on first use. A destination missing its key is reported
    /// inline (synthetic status) instead of silently skipped, so the gap is
    /// visible. Each query is read-only — never forget/prune.
    func refreshRemote() {
        ensureRepoResolved()
        guard !destinations.isEmpty else {
            statusMsg = "no repository \u{2014} run baaackaaab --init-credentials (or --migrate-credentials) first"; return
        }
        statusMsg = "querying \(destinations.count) destination(s)\u{2026}"; renderHome()
        remotes = destinations.map { dest in
            guard dest.passwordAvailable else {
                return ResticBackend.RemoteStatus(error: "no encryption password \u{2014} run --migrate-credentials or --init-credentials")
            }
            return ResticBackend(destination: dest).remoteStatus()
        }
        remoteQueried = true
        reclaimForeground()   // a restic child may have grabbed the tty foreground
        statusMsg = ""
    }

    /// Check restic + the REST server against the latest upstream releases. Online
    /// (contacts GitHub) — the opt-in network path, run only on demand like the
    /// remote query. `resticInstalled()` shells out to `restic version`, so reclaim
    /// the tty foreground afterwards just as refreshRemote does.
    func checkUpdatesNow() {
        statusMsg = "checking restic + the REST server against the latest releases\u{2026}"; renderHome()
        ensureRepoResolved()
        updateFindings = UpdateCheck.findings(primaryRepoURL: destinations.first?.displayURL, online: true)
        updatesChecked = true
        reclaimForeground()
        // Don't claim "up to date" when a component's installed version was
        // unreadable (the usual rest-server case) — we only verified what we could
        // actually read. Honest summary over a reassuring one.
        let behind = updateFindings.contains { if case .behind = $0.verdict { return true } else { return false } }
        let unreadable = updateFindings.contains { if case .unknownInstalled = $0.verdict { return true } else { return false } }
        statusMsg = behind ? "update(s) available \u{2014} see the updates panel"
                  : unreadable ? "checked \u{2014} some installed versions couldn't be read (see the panel)"
                  : "restic + the REST server are up to date"
    }

    /// Resolve every enabled destination for the in-process remote query and the
    /// dashboard. Resolved at most once. Reads no Keychain when the file store is
    /// present, so this is silent — no prompt. The re-exec'd sync child resolves
    /// its own destinations from the store (it reads the 0600 files directly), so
    /// nothing is exported here.
    func ensureRepoResolved() {
        if repoResolved { return }
        repoResolved = true
        destinations = DestinationStore.resolveEnabled(explicitRepo: cli.value("--restic-repo"))
    }

    func syncArgs() -> [String] {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyyMMdd-HHmmss"
        var args = ["--run-tag", "tui-\(fmt.string(from: Date()))"]
        // Preserve a non-default config so the child backs up the same set.
        if configPath.path != BackupSet.defaultPath().path { args += ["--config", configPath.path] }
        // Forward an explicit ad-hoc target so the child hits the same repo.
        if let r = cli.value("--restic-repo") { args += ["--restic-repo", r] }
        return args
    }

    func selfPath() -> String {
        if let p = Bundle.main.executablePath { return p }
        let arg0 = CommandLine.arguments.first ?? "baaackaaab"
        return arg0.hasPrefix("/") ? arg0 : FileManager.default.currentDirectoryPath + "/" + arg0
    }

    /// "2026-06-24T17:30:32.1+02:00" -> "2026-06-24 17:30".
    func shortTime(_ iso: String) -> String {
        String(iso.prefix(16)).replacingOccurrences(of: "T", with: " ")
    }

    /// Parse restic's ISO8601 time string down to whole-second precision — its
    /// fractional seconds are variable-length (up to nanoseconds), which
    /// `ISO8601DateFormatter` cannot parse directly; sub-second precision buys
    /// nothing for a relative-age display anyway. nil on anything unparseable.
    func parseResticTime(_ iso: String) -> Date? {
        guard iso.count >= 19 else { return nil }
        let secondsPart = iso.prefix(19)   // "yyyy-MM-ddTHH:mm:ss"
        let offset = iso.dropFirst(19).drop { $0 == "." || $0.isNumber }
        return ISO8601DateFormatter().date(from: String(secondsPart + offset))
    }

    /// Human-friendly age: "just now", "5m ago", "3h ago", "2d ago";
    /// falls back to the absolute stamp for dates older than a week.
    func relativeTime(from date: Date) -> String {
        let secs = Int(-date.timeIntervalSinceNow)
        if secs < 60 { return "just now" }
        if secs < 3600 { return "\(secs / 60)m ago" }
        if secs < 86400 { return "\(secs / 3600)h ago" }
        if secs < 7 * 86400 { return "\(secs / 86400)d ago" }
        return runStampFmt.string(from: date)
    }
}
