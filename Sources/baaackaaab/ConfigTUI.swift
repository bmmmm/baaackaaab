import Foundation
#if canImport(Darwin)
import Darwin
#endif

// Interactive full-screen TUI: the command center AND the backup-set editor, in
// one raw-mode loop. Launched bare (`baaackaaab`) it opens on the home screen;
// `--configure` jumps straight to the editor.
//
// The CLI (--add-folder/--add-album) is the headless path; the editor is the
// same edit, but you browse the real filesystem and toggle folders instead of
// typing paths. It writes the identical BackupSet JSON, so the two are
// interchangeable.
//
// Pure Foundation + termios — no curses, no dependency. Everything lives in ONE
// raw terminal so screens never nest (nesting two raw TUIs over one tty breaks
// input on return — the whole reason this is a single class). Screens:
//   home    — dashboard (backup set + remote status) with the action keys
//             e edit / s sync / r remote / q quit; the landing screen
//   browse  — walk the directory tree, toggle folders in/out of the set;
//             esc backs out to home (when launched there)
//   review  — the selected-set panel under the folder list, shown as soon as
//             anything is picked; navigation stays up top, `v` drops focus into
//             it to remove entries, esc/v hands focus back
//   albums  — a Photos album picker (a) that lists your iCloud albums with
//             counts so you toggle them like folders, instead of typing names
//
// sync (s) drops out of the alternate screen + raw mode, re-execs this binary
// so restic streams live to the normal screen, then re-enters — a clean shell-
// out, not a nested TUI.
//
// Needs a real TTY (main.swift guards that). Off a terminal it refuses to run.

private enum BrowseRow {
    case parent
    case dir(URL)
}

private enum SetRow {
    case folder(String)
    case album(String)
}

// A directory's relation to the backup set, for the browse marker:
//   selected — this exact folder is in the set            → [x]
//   partial  — a descendant is in the set, this one isn't → [~]
//   none     — neither                                    → [ ]
private enum DirState { case selected, partial, none }

private enum Key: Equatable {
    case up, down, left, right
    case enter, space, backspace, tab, esc, ctrlC, eof, other
    case char(Character)
}

// Signal-safe terminal restore. A killed TUI (closing the terminal window sends
// SIGHUP, `kill` sends SIGTERM) must not leave the terminal in raw mode with the
// cursor hidden and the alternate screen still up — the next shell prompt would
// be unusable. The normal-exit path restores via `defer`, but a signal bypasses
// it, so we stash the cooked termios when raw mode is entered and install
// async-signal-safe handlers (tcsetattr / write / signal / raise are all
// async-signal-safe) that restore it and then re-raise with the default
// disposition so the exit status still reflects the signal.
private var cookedTermForSignal = termios()
private var cookedTermValid = false
private let ttyRestoreBytes: [UInt8] = Array("\u{1B}[?25h\u{1B}[?1049l".utf8)   // show cursor + leave alt screen

private func ttyRestoreSignalHandler(_ signo: Int32) {
    if cookedTermValid {
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &cookedTermForSignal)
    }
    ttyRestoreBytes.withUnsafeBytes { raw in
        _ = write(STDOUT_FILENO, raw.baseAddress, raw.count)
    }
    signal(signo, SIG_DFL)
    raise(signo)
}

/// RAII wrapper around the terminal's raw mode. cfmakeraw() turns off echo,
/// canonical line buffering, signal generation (so Ctrl-C arrives as a byte we
/// handle) and output post-processing — we position the cursor absolutely, so
/// we never depend on newline translation.
private final class RawTerminal {
    private var original = termios()
    private var raw = termios()

    init?() {
        guard isatty(STDIN_FILENO) != 0 else { return nil }
        guard tcgetattr(STDIN_FILENO, &original) == 0 else { return nil }
        raw = original
        cfmakeraw(&raw)
        // Make the cooked state reachable from the async signal handlers.
        cookedTermForSignal = original
        cookedTermValid = true
        enable()
    }

    func enable() { var r = raw; tcsetattr(STDIN_FILENO, TCSAFLUSH, &r) }
    func restore() { var o = original; tcsetattr(STDIN_FILENO, TCSAFLUSH, &o) }
}

private enum Screen { case home, editor, restore, fileBrowser, timer }

final class ConfigTUI {
    private let configPath: URL
    private let home = FileManager.default.homeDirectoryForCurrentUser

    private var set: BackupSet
    private var existed = false
    private var loadFailed = false

    // The home screen (dashboard + actions) is the landing screen for a bare
    // launch; the editor is its own screen. `hasHome` records whether home is the
    // root, so esc in the editor backs out to it instead of quitting. Both share
    // the one raw terminal — no nesting.
    private var screen: Screen = .editor
    private var hasHome = false

    // Remote dashboard state, resolved lazily on first `r` so an edit-only
    // session never touches the credential store. `destinations` is every enabled
    // target; `remotes` is the per-destination status (parallel array) filled in
    // by a remote query. The dashboard shows one block per destination.
    private var destinations: [Destination] = []
    private var repoResolved = false
    private var remotes: [ResticBackend.RemoteStatus] = []
    private var remoteQueried = false

    // The tail of the run history (no credentials — just tags/times/counts), shown
    // on the home dashboard. Loaded lazily and dropped after a sync so a fresh run
    // shows up on return.
    private var recentRuns: [RunRecord]?

    // Local-time stamp for run rows: the record stores an absolute Date, shown in
    // the operator's timezone (unlike the remote's already-formatted ISO string).
    private let runStampFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    // Restore screen: a snapshot browser over one source destination (cycle with
    // d when several are configured). Picking a snapshot re-execs the tested CLI
    // restore (`--restore … --yes`) so the actual write goes through the same
    // safe-by-construction engine — full restore into a fresh dir, revealed after.
    private var restoreDestIndex = 0
    private var restoreSnaps: [ResticBackend.Snapshot]?
    private var restoreLoadError: String?
    private var restoreCursor = 0, restoreTop = 0

    // Timer screen: edit one time-of-day + an optional weekday set, then install /
    // uninstall the launchd schedule via the tested CLI. Loaded from the installed
    // plist on enter. The (installed, loaded) state is cached so a render never
    // spawns launchctl — it is refreshed only on enter and after install/uninstall.
    private var timerHour = 12, timerMinute = 0
    private var timerWeekdays = Set<Int>()      // launchd weekday numbers; empty = daily
    private var timerFieldMinute = false        // which time field up/down adjusts
    private var timerState: (installed: Bool, loaded: Bool) = (false, false)
    private var timerCurrent: Schedule?

    // File browser screen: in-TUI navigation of a snapshot's directory tree.
    // `lsEntries` holds ALL entries from `restic ls` (flat depth-first list), loaded
    // once on enter; navigation filters by parent path so browsing is instant.
    private var lsSnap: ResticBackend.Snapshot?
    private var lsEntries: [ResticBackend.LsEntry]?
    private var lsLoadError: String?
    private var lsCursor = 0, lsTop = 0
    private var lsCurrentPath = "/"
    // The level the browser opens on after auto-descending the single-child
    // wrapper directories (see initialBrowsePath). Left/esc at this path exits
    // back to the snapshot list instead of walking up into the empty wrappers.
    private var lsRootPath = "/"

    // The selected-set panel is always visible under the folder browser once
    // anything is picked. Navigation stays on the folder browser by default;
    // `v` moves focus DOWN into the panel to prune entries, esc/v hands it back.
    private var panelFocused = false
    private var showHelp = false
    // The album picker (a) takes over the content area with the user's Photos
    // albums. It's loaded lazily on first open (triggers the Photos prompt).
    private var pickAlbums = false
    private var albumChoices: [PhotoAlbumInfo] = []
    private var cwd: URL

    private var browseCursor = 0, browseTop = 0
    private var reviewCursor = 0, reviewTop = 0
    private var albumCursor = 0, albumTop = 0
    private var showHidden = false
    private var dirty = false
    private var statusMsg = ""

    private var cachedRows: [BrowseRow]?
    private var term: RawTerminal!

    init(configPath: URL) {
        self.configPath = configPath
        self.cwd = FileManager.default.homeDirectoryForCurrentUser
        if FileManager.default.fileExists(atPath: configPath.path) {
            do { set = try BackupSet.load(from: configPath); existed = true }
            catch { set = BackupSet(); loadFailed = true }
        } else {
            set = BackupSet()
        }
    }

    // MARK: - Run loop

    /// `home: true` opens on the command-center dashboard (the bare-launch home);
    /// otherwise it jumps straight to the editor (the `--configure` path).
    func run(home: Bool = false) {
        if loadFailed {
            Console.error("backup set at \(configPath.path) is unreadable — fix or delete it, then re-run --configure")
            return
        }
        guard let term = RawTerminal() else {
            Console.error("the interactive TUI needs a terminal")
            return
        }
        self.term = term
        self.hasHome = home
        self.screen = home ? .home : .editor
        emit("\u{1B}[?1049h\u{1B}[?25l")   // alternate screen + hide cursor
        // Restore the terminal on SIGHUP/SIGTERM/SIGINT too, not just normal exit.
        signal(SIGHUP, ttyRestoreSignalHandler)
        signal(SIGTERM, ttyRestoreSignalHandler)
        signal(SIGINT, ttyRestoreSignalHandler)
        defer {
            term.restore()                 // always hand the terminal back cooked
            cookedTermValid = false
            signal(SIGHUP, SIG_DFL)
            signal(SIGTERM, SIG_DFL)
            signal(SIGINT, SIG_DFL)
        }

        loop: while true {
            switch screen {
            case .home: renderHome()
            case .restore: renderRestore()
            case .fileBrowser: renderFileBrowser()
            case .timer: renderTimer()
            case .editor: render()
            }
            let key = readKey()
            statusMsg = ""
            let keepGoing: Bool
            if screen == .home { keepGoing = handleHome(key) }
            else if screen == .restore { keepGoing = handleRestore(key) }
            else if screen == .fileBrowser { keepGoing = handleFileBrowser(key) }
            else if screen == .timer { keepGoing = handleTimer(key) }
            else if pickAlbums { keepGoing = handleAlbumPicker(key) }
            else if panelFocused && !setRows().isEmpty { keepGoing = handleReview(key) }
            else { keepGoing = handleBrowse(key) }
            if !keepGoing { break loop }
        }

        emit("\u{1B}[?25h\u{1B}[?1049l")   // show cursor + leave alternate screen
        if !hasHome { printExitHint() }    // the home dashboard already shows next steps
    }

    // MARK: - Input handling

    /// Returns false to quit the editor.
    private func handleBrowse(_ key: Key) -> Bool {
        let rows = currentBrowseRows()
        switch key {
        case .up, .char("k"): browseCursor = max(0, browseCursor - 1)
        case .down, .char("j"): browseCursor = min(max(0, rows.count - 1), browseCursor + 1)
        case .right, .enter, .char("l"):
            if browseCursor < rows.count {
                switch rows[browseCursor] {
                case .parent: goUp()
                case .dir(let url): enter(url)
                }
            }
        case .left, .backspace, .char("h"): goUp()
        case .space:
            if browseCursor < rows.count, case .dir(let url) = rows[browseCursor] { toggle(url) }
        case .char("c"): toggle(cwd)
        case .char("a"): openAlbumPicker()
        case .char("v"), .tab:
            if !setRows().isEmpty { panelFocused = true; reviewCursor = 0; reviewTop = 0 }
            else { statusMsg = "nothing selected yet" }
        case .char("."): showHidden.toggle(); invalidate(); browseCursor = 0; browseTop = 0
        case .char("g"): jumpICloud()
        case .char("~"): jumpHome()
        case .char("s"): save()
        // esc backs out to the home dashboard when that is the root; standalone
        // (--configure) it quits. q / Ctrl-C always quit the app (with prompt).
        case .esc:
            if hasHome { screen = .home } else if confirmQuit() { return false }
        case .char("q"), .ctrlC: if confirmQuit() { return false }
        case .eof: return false
        default: break
        }
        return true
    }

    /// Home screen (the command center). Routes the action keys; returns false to
    /// quit the whole app.
    private func handleHome(_ key: Key) -> Bool {
        switch key {
        case .char("e"), .enter, .right, .tab: screen = .editor; showHelp = false
        case .char("s"): syncNow()
        case .char("p"): dryRunNow()
        case .char("r"): refreshRemote()
        case .char("R"): enterRestore()
        case .char("t"): enterTimer()
        case .char("?"): showHelp.toggle()
        case .char("q"), .esc, .ctrlC: if confirmQuit() { return false }
        case .eof: return false
        default: break
        }
        return true
    }

    private func handleReview(_ key: Key) -> Bool {
        let rows = setRows()
        switch key {
        case .up, .char("k"): reviewCursor = max(0, reviewCursor - 1)
        case .down, .char("j"): reviewCursor = min(max(0, rows.count - 1), reviewCursor + 1)
        case .space:
            if reviewCursor < rows.count {
                switch rows[reviewCursor] {
                case .folder(let f): set.driveFolders.removeAll { $0 == f }; dirty = true; statusMsg = "removed \(f)"
                case .album(let a): set.photoAlbums.removeAll { $0 == a }; dirty = true; statusMsg = "removed album \(a)"
                }
                reviewCursor = max(0, min(reviewCursor, setRows().count - 1))
                if setRows().isEmpty { panelFocused = false }   // nothing left to prune
            }
        case .char("a"): openAlbumPicker()
        // v/esc/left hand focus back UP to the folder browser; the panel stays
        // visible. The whole editor only quits on q / Ctrl-C.
        case .char("v"), .tab, .esc, .left, .char("h"): panelFocused = false
        case .char("s"): save()
        case .char("q"), .ctrlC: if confirmQuit() { return false }
        case .eof: return false
        default: break
        }
        return true
    }

    private func handleAlbumPicker(_ key: Key) -> Bool {
        switch key {
        case .up, .char("k"): albumCursor = max(0, albumCursor - 1)
        case .down, .char("j"): albumCursor = min(max(0, albumChoices.count - 1), albumCursor + 1)
        case .space, .enter, .right:
            if albumCursor < albumChoices.count {
                let title = albumChoices[albumCursor].title
                if set.photoAlbums.contains(title) {
                    set.photoAlbums.removeAll { $0 == title }; dirty = true; statusMsg = "removed album \(title)"
                } else {
                    _ = set.addAlbum(title); dirty = true; statusMsg = "added album \(title)"
                }
            }
        // a/esc/left hand focus back to the folder browser; q / Ctrl-C still quits.
        case .char("a"), .tab, .esc, .left, .char("h"): pickAlbums = false
        case .char("s"): save()
        case .char("q"), .ctrlC: if confirmQuit() { return false }
        case .eof: return false
        default: break
        }
        return true
    }

    /// Load the user's Photos albums and switch to the picker. The PhotoKit
    /// fetch blocks (and may trigger the authorization prompt), so we paint a
    /// "loading" frame first and report a denied grant as an actionable status.
    private func openAlbumPicker() {
        statusMsg = "loading Photos albums\u{2026}"
        render()
        do {
            albumChoices = try PhotosAcquirer().listAlbums()
        } catch {
            statusMsg = "\(error)"
            return
        }
        guard !albumChoices.isEmpty else {
            statusMsg = "no Photos albums found — create one in Photos.app"
            return
        }
        pickAlbums = true; albumCursor = 0; albumTop = 0; statusMsg = ""
    }

    // MARK: - Navigation

    private func goUp() {
        let parent = cwd.deletingLastPathComponent()
        if parent.path != cwd.path { cwd = parent; invalidate(); browseCursor = 0; browseTop = 0 }
    }

    private func enter(_ url: URL) {
        if listDirs(url) == nil { statusMsg = "cannot open \(url.lastPathComponent)"; return }
        cwd = url; invalidate(); browseCursor = 0; browseTop = 0
    }

    private func jumpICloud() {
        let icloud = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        if FileManager.default.fileExists(atPath: icloud.path) {
            cwd = icloud; invalidate(); browseCursor = 0; browseTop = 0
        } else {
            statusMsg = "iCloud Drive folder not found"
        }
    }

    private func jumpHome() {
        cwd = home; invalidate(); browseCursor = 0; browseTop = 0
    }

    // MARK: - Selection

    /// A browsed URL's storage key: tilde-relative under home (portable,
    /// hand-editable), absolute otherwise — matching how the CLI stores paths.
    private func tildePath(of url: URL) -> String {
        let p = url.path
        if p == home.path { return "~" }
        if p.hasPrefix(home.path + "/") { return "~" + p.dropFirst(home.path.count) }
        return p
    }

    /// Inverse of tildePath: expand a stored entry (tilde or absolute) to an
    /// absolute filesystem path, so we can compare it against a browsed URL.
    private func expandPath(_ folder: String) -> String {
        if folder == "~" { return home.path }
        if folder.hasPrefix("~/") { return home.path + folder.dropFirst(1) }
        return folder
    }

    private func isSelected(_ url: URL) -> Bool {
        let t = tildePath(of: url)
        return set.driveFolders.contains(t) || set.driveFolders.contains(url.path)
    }

    /// Where `url` stands relative to the set: itself selected, an ancestor of a
    /// selected folder (partial), or neither. The partial state lets the marker
    /// bubble up the tree so a selection deep in a branch is visible from above.
    private func dirState(_ url: URL) -> DirState {
        if isSelected(url) { return .selected }
        let prefix = url.path + "/"
        for f in set.driveFolders where expandPath(f).hasPrefix(prefix) { return .partial }
        return .none
    }

    private func toggle(_ url: URL) {
        let t = tildePath(of: url)
        if let i = set.driveFolders.firstIndex(of: t) ?? set.driveFolders.firstIndex(of: url.path) {
            let removed = set.driveFolders.remove(at: i)
            dirty = true; statusMsg = "removed \(removed)"
        } else {
            _ = set.addFolder(t)
            dirty = true; statusMsg = "added \(t)"
        }
    }

    // MARK: - Persistence

    private func save() {
        do { try set.save(to: configPath); dirty = false; statusMsg = "saved" }
        catch { statusMsg = "save failed: \(error)" }
    }

    /// Returns true if the editor should quit. Prompts on unsaved changes.
    private func confirmQuit() -> Bool {
        if !dirty { return true }
        drawPrompt("unsaved changes — y: save & quit   n: discard & quit   enter/esc: cancel (default)")
        while true {
            switch readKey() {
            case .char("y"), .char("Y"): save(); return true
            case .char("n"), .char("N"): return true
            // The safe default — enter/esc keeps the editor open, never discards.
            case .enter, .esc, .ctrlC: return false
            case .eof: return true   // no more input — quit without overwriting
            default: break
            }
        }
    }

    /// After the editor closes, print the one command left to run — directly
    /// answering "now what?". Reads the file back so it reflects exactly what a
    /// bare run would back up (empty / discarded set → no hint).
    private func printExitHint() {
        let onDisk = (try? BackupSet.load(from: configPath)) ?? BackupSet()
        guard !onDisk.isEmpty else { return }
        let bin = CommandLine.arguments.first ?? "baaackaaab"
        Console.section("Next")
        Console.step("run a backup:  \(bin) --run-tag smoke-live")
        Console.note("a bare run backs up this set; --run-tag just labels the snapshots. Run it in Terminal.app — it needs the Keychain + Photos access.")
    }

    // MARK: - Home screen (command center)

    /// The landing dashboard: the backup set and the remote status, with the
    /// action keys. Built as exactly `rows` lines, like render(), so the footer
    /// pins to the bottom.
    private func renderHome() {
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
        let runs = loadRecentRuns()
        if runs.isEmpty {
            body.append(dim(fit("  no runs recorded yet \u{2014} press s to back up now", cols)))
        } else {
            for rec in runs { body.append(homeRunLine(rec, cols)) }
        }

        if showHelp { body = helpOverlayLines(contentH, cols) }
        else if body.count < contentH { body += Array(repeating: "", count: contentH - body.count) }
        if body.count > contentH { body = Array(body.prefix(contentH)) }
        lines += body

        lines.append("")
        lines.append(dim(fit(statusLine(), cols)))
        for hl in helpLines { lines.append(dim(fit(hl, cols))) }
        draw(lines)
    }

    /// Two lines for one destination on the home dashboard: an identity line
    /// (name + link label + redacted URL) and a status line (per-source latest +
    /// size when reachable, the failure otherwise, the query hint before first
    /// `r`). The name leads the identity line so it survives fit() truncation.
    private func homeDestinationLines(_ dest: Destination, status: ResticBackend.RemoteStatus?, cols: Int) -> [String] {
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
    private func homeStatusSummary(_ r: ResticBackend.RemoteStatus) -> String {
        var parts = ["\(r.snapshotCount) snap(s)"]
        if let s = r.sizeBytes { parts.append(String(format: "%.2f GB", Double(s) / 1_000_000_000)) }
        for src in r.sources {
            parts.append(src.source + " " + (src.latestTime.map(shortTime) ?? "\u{2014}"))
        }
        return parts.joined(separator: "  \u{2022}  ")
    }

    /// The last few run-history records, newest first. Loaded once and cached;
    /// dropped after a sync so the run just finished appears on return. No
    /// credentials involved — the history file holds only tags/times/counts.
    private func loadRecentRuns() -> [RunRecord] {
        if let r = recentRuns { return r }
        let r = RunHistory.recent(4)
        recentRuns = r
        return r
    }

    /// One run on the dashboard: outcome mark, end time, run tag, verified/total,
    /// and the count of unhappy destinations if any. Green when clean, yellow not.
    private func homeRunLine(_ r: RunRecord, _ cols: Int) -> String {
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

    private func homeHelpLine() -> String {
        "e edit \u{2022} s sync \u{2022} p preview \u{2022} r remote \u{2022} R restore \u{2022} t timer \u{2022} ? help \u{2022} q quit"
    }

    /// Help overlay content: replaces the body area when showHelp is toggled.
    private func helpOverlayLines(_ height: Int, _ cols: Int) -> [String] {
        let entries: [(String, String)] = [
            ("e", "open backup-set editor"),
            ("s", "run backup now"),
            ("p", "dry-run preview (reads repo, uploads nothing)"),
            ("r", "refresh remote status"),
            ("R", "open restore browser"),
            ("t", "edit the scheduled-backup timer"),
            ("?", "toggle this overlay"),
            ("q / esc", "quit"),
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
    private func quotaBar(usedBytes: Int, quotaBytes: Int, cols: Int) -> String {
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
    private func syncNow() {
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
        _ = readKey()
        reclaimForeground()
        emit("\u{1B}[?1049h\u{1B}[?25l")    // back into the alternate screen
        remotes = []; remoteQueried = false  // repos changed — drop the cached status
        recentRuns = nil                     // the run we just did appended a record
        statusMsg = code == 0 ? "sync finished \u{2014} press r to refresh remote" : "sync failed (code \(code))"
    }

    private func runSyncChild(extraArgs: [String] = []) -> Int32 {
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
    private func dryRunNow() {
        guard !set.isEmpty else { statusMsg = "backup set is empty \u{2014} press e to add folders / albums"; return }
        ensureRepoResolved()
        emit("\u{1B}[?25h\u{1B}[?1049l")
        term.restore()
        let code = runSyncChild(extraArgs: ["--dry-run"])
        let tail = code == 0 ? "dry run finished" : "dry run exited with code \(code)"
        FileHandle.standardOutput.write(Data("\n\(tail) \u{2014} press any key to return\n".utf8))
        term.enable()
        _ = readKey()
        reclaimForeground()
        emit("\u{1B}[?1049h\u{1B}[?25l")
        statusMsg = code == 0 ? "dry run complete \u{2014} nothing uploaded" : "dry run failed (code \(code))"
    }

    /// Shell out to a child invocation of this binary (a read-only browse like
    /// `--ls` / `--diff`, or a timer install/uninstall) and page its output, then
    /// wait for a key and return to the current screen. Same screen dance as
    /// dryRunNow(). `label` names the action in the "press any key" footer and any
    /// non-zero status line.
    @discardableResult
    private func runChildAndWait(_ args: [String], label: String) -> Int32 {
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
        _ = readKey()
        reclaimForeground()
        emit("\u{1B}[?1049h\u{1B}[?25l")   // back into the alternate screen
        statusMsg = code == 0 ? "" : "\(label) exited with code \(code)"
        return code
    }

    // MARK: - Timer screen

    /// Open the timer editor: cache the install state and pre-fill the fields from
    /// the currently installed schedule (first time + its weekdays) if any.
    private func enterTimer() {
        refreshTimerState()
        if let s = timerCurrent, let first = s.times.first {
            timerHour = first.hour; timerMinute = first.minute
            timerWeekdays = Set(s.weekdays)
        }
        screen = .timer
    }

    /// Refresh the cached install state + installed schedule. Spawns launchctl, so
    /// it is called only on enter and after install/uninstall — never per render.
    private func refreshTimerState() {
        timerState = LaunchdTimer.state()
        timerCurrent = LaunchdTimer.installedSchedule()
    }

    /// The schedule the editor would install: the single edited time, plus the
    /// chosen weekdays (empty = every day).
    private func previewSchedule() -> Schedule {
        Schedule(times: [(timerHour, timerMinute)], weekdays: timerWeekdays.sorted())
    }

    private func renderTimer() {
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

    private func timerHelpLine() -> String {
        "\u{2191}/\u{2193} adjust \u{2022} \u{2190}/\u{2192} hr/min \u{2022} 1-7 weekday \u{2022} 0 every day \u{2022} i install \u{2022} u uninstall \u{2022} esc back"
    }

    private func handleTimer(_ key: Key) -> Bool {
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
    private func adjustTimer(by delta: Int) {
        if timerFieldMinute {
            timerMinute = ((timerMinute + delta * 5) % 60 + 60) % 60
        } else {
            timerHour = ((timerHour + delta) % 24 + 24) % 24
        }
    }

    private func toggleWeekday(_ wd: Int) {
        if timerWeekdays.contains(wd) { timerWeekdays.remove(wd) } else { timerWeekdays.insert(wd) }
    }

    /// Install the edited schedule by shelling out to the tested CLI (writes the
    /// plist + bootstraps launchd), then refresh the cached state.
    private func installTimerNow() {
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
    private func uninstallTimerNow() {
        let code = runChildAndWait(["--uninstall-timer"], label: "uninstall-timer")
        refreshTimerState()
        if code == 0 { statusMsg = "timer removed" }
    }

    /// Read-only refresh of the remote panel: query EVERY enabled destination so
    /// the dashboard shows one row per (source × destination). Resolves the
    /// destinations lazily on first use. A destination missing its key is reported
    /// inline (synthetic status) instead of silently skipped, so the gap is
    /// visible. Each query is read-only — never forget/prune.
    private func refreshRemote() {
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

    /// Resolve every enabled destination for the in-process remote query and the
    /// dashboard. Resolved at most once. Reads no Keychain when the file store is
    /// present, so this is silent — no prompt. The re-exec'd sync child resolves
    /// its own destinations from the store (it reads the 0600 files directly), so
    /// nothing is exported here.
    private func ensureRepoResolved() {
        if repoResolved { return }
        repoResolved = true
        destinations = DestinationStore.resolveEnabled(explicitRepo: argValue("--restic-repo"))
    }

    private func syncArgs() -> [String] {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyyMMdd-HHmmss"
        var args = ["--run-tag", "tui-\(fmt.string(from: Date()))"]
        // Preserve a non-default config so the child backs up the same set.
        if configPath.path != BackupSet.defaultPath().path { args += ["--config", configPath.path] }
        // Forward an explicit ad-hoc target so the child hits the same repo.
        if let r = argValue("--restic-repo") { args += ["--restic-repo", r] }
        return args
    }

    private func selfPath() -> String {
        if let p = Bundle.main.executablePath { return p }
        let arg0 = CommandLine.arguments.first ?? "baaackaaab"
        return arg0.hasPrefix("/") ? arg0 : FileManager.default.currentDirectoryPath + "/" + arg0
    }

    /// Reclaim the tty's foreground process group; a spawned child can leave us in
    /// the background, where the next read would raise SIGTTIN and stop us. SIGTTOU
    /// is ignored because tcsetpgrp from the background would itself stop us.
    private func reclaimForeground() {
        guard isatty(STDIN_FILENO) != 0 else { return }
        signal(SIGTTOU, SIG_IGN)
        _ = tcsetpgrp(STDIN_FILENO, getpgrp())
    }

    /// "2026-06-24T17:30:32.1+02:00" -> "2026-06-24 17:30".
    private func shortTime(_ iso: String) -> String {
        String(iso.prefix(16)).replacingOccurrences(of: "T", with: " ")
    }

    /// Human-friendly age: "just now", "5m ago", "3h ago", "2d ago";
    /// falls back to the absolute stamp for dates older than a week.
    private func relativeTime(from date: Date) -> String {
        let secs = Int(-date.timeIntervalSinceNow)
        if secs < 60 { return "just now" }
        if secs < 3600 { return "\(secs / 60)m ago" }
        if secs < 86400 { return "\(secs / 3600)h ago" }
        if secs < 7 * 86400 { return "\(secs / 86400)d ago" }
        return runStampFmt.string(from: date)
    }

    // MARK: - Restore screen (snapshot browser → safe CLI restore)

    /// The destination currently selected on the restore screen.
    private var restoreDest: Destination? {
        guard restoreDestIndex < destinations.count else { return nil }
        return destinations[restoreDestIndex]
    }

    /// Enter the restore browser: resolve destinations, then load the first one's
    /// snapshots. Refuses (with a status message) when nothing is configured.
    private func enterRestore() {
        ensureRepoResolved()
        guard !destinations.isEmpty else {
            statusMsg = "no repository \u{2014} run baaackaaab --init-credentials first"
            return
        }
        restoreDestIndex = min(restoreDestIndex, destinations.count - 1)
        restoreSnaps = nil; restoreLoadError = nil
        restoreCursor = 0; restoreTop = 0
        screen = .restore
        loadRestoreSnaps()
    }

    /// Query the selected destination's snapshots (read-only). Caches the result;
    /// records a load error (missing key / unreachable) for the screen to show.
    private func loadRestoreSnaps() {
        guard let dest = restoreDest else { restoreLoadError = "no destination"; return }
        guard dest.passwordAvailable else {
            restoreLoadError = "no encryption password for \(dest.name)"; restoreSnaps = []; return
        }
        statusMsg = "loading snapshots from \(dest.name)\u{2026}"; renderRestore()
        do {
            restoreSnaps = try ResticBackend(destination: dest).listSnapshots()
            restoreLoadError = nil
        } catch {
            restoreSnaps = []; restoreLoadError = "\(error)"
        }
        restoreCursor = 0; restoreTop = 0
        reclaimForeground()   // the restic child may have grabbed the tty foreground
        statusMsg = ""
    }

    private func renderRestore() {
        let (rows, cols) = terminalSize()
        var lines: [String] = []
        lines.append(bold(fit("baaackaaab \u{2014} restore", cols)))
        let destLabel = restoreDest.map { "source: \($0.name) [\($0.link)]" } ?? "source: (none)"
        let switchHint = destinations.count > 1 ? "   (d: switch, \(restoreDestIndex + 1)/\(destinations.count))" : ""
        lines.append(cyan(fit(destLabel + switchHint, cols)))
        lines.append("")

        let helpLines = wrapHelp(restoreHelpLine(), cols)
        let footerH = 2 + helpLines.count
        let contentH = max(1, rows - 3 - footerH)

        var body: [String] = []
        if let err = restoreLoadError {
            body.append(yellow(fit("  cannot list snapshots: " + err, cols)))
        } else if restoreSnaps == nil {
            body.append(dim(fit("  loading\u{2026}", cols)))
        } else if let snaps = restoreSnaps, snaps.isEmpty {
            body.append(dim(fit("  no snapshots on this destination yet", cols)))
        } else if let snaps = restoreSnaps {
            body.append(dim(fit("  id        when              tags", cols)))
            clamp(&restoreCursor, snaps.count)
            let listH = max(1, contentH - 1)
            adjustTop(&restoreTop, cursor: restoreCursor, height: listH, count: snaps.count)
            for r in 0..<listH {
                let idx = restoreTop + r
                if idx < snaps.count {
                    body.append(renderSnapshotRow(snaps[idx], cursor: idx == restoreCursor, cols: cols))
                } else { body.append("") }
            }
        }
        if body.count < contentH { body += Array(repeating: "", count: contentH - body.count) }
        else if body.count > contentH { body = Array(body.prefix(contentH)) }
        lines += body

        lines.append("")
        lines.append(dim(fit(statusLine(), cols)))
        for hl in helpLines { lines.append(dim(fit(hl, cols))) }
        draw(lines)
    }

    private func renderSnapshotRow(_ s: ResticBackend.Snapshot, cursor: Bool, cols: Int) -> String {
        let tags = s.tags.isEmpty ? "" : s.tags.joined(separator: ",")
        let text = "  \(s.shortID)  \(shortTime(s.time))  \(tags)"
        var plain = fit(text, cols)
        if cursor {
            plain = plain.padding(toLength: cols, withPad: " ", startingAt: 0)
            return rev(plain)
        }
        return plain
    }

    private func restoreHelpLine() -> String {
        "up/dn move \u{2022} enter/\u{2192} browse \u{2022} r restore (full) \u{2022} c diff prev \u{2022} d switch dest \u{2022} esc back \u{2022} q quit"
    }

    private func handleRestore(_ key: Key) -> Bool {
        let count = restoreSnaps?.count ?? 0
        switch key {
        case .up, .char("k"): restoreCursor = max(0, restoreCursor - 1)
        case .down, .char("j"): restoreCursor = min(max(0, count - 1), restoreCursor + 1)
        case .char("d"):
            if destinations.count > 1 {
                restoreDestIndex = (restoreDestIndex + 1) % destinations.count
                restoreSnaps = nil; loadRestoreSnaps()
            }
        // Arrows/enter/v all DRILL IN (browse the snapshot's files); a full
        // restore is the explicit `r` key, so no stray arrow can trigger a
        // gigabyte-scale write (see TODO).
        case .enter, .right, .char("l"), .char("v"):
            if let snaps = restoreSnaps, restoreCursor < snaps.count {
                enterFileBrowser(snap: snaps[restoreCursor])
            }
        case .char("r"):
            if let snaps = restoreSnaps, restoreCursor < snaps.count {
                restoreSelected(snaps[restoreCursor])
            }
        case .char("c"):   // compare with the next-older snapshot (restic diff), read-only
            if let snaps = restoreSnaps, restoreCursor < snaps.count, let dest = restoreDest {
                // snaps is newest-first, so the next-older sits at cursor + 1.
                guard restoreCursor + 1 < snaps.count else {
                    statusMsg = "no older snapshot to compare against (this is the oldest)"; break
                }
                var args = ["--diff", snaps[restoreCursor + 1].shortID, snaps[restoreCursor].shortID,
                            "--destination", dest.name]
                if let r = argValue("--restic-repo") { args += ["--restic-repo", r] }
                runChildAndWait(args, label: "diff")
            }
        case .esc, .left, .char("h"): screen = .home
        case .char("q"), .ctrlC: if confirmQuit() { return false }
        case .eof: return false
        default: break
        }
        return true
    }

    /// Confirm, then re-exec the tested CLI restore for the chosen snapshot — a
    /// FULL restore into a fresh timestamped dir. The write goes through the same
    /// safe engine (validate target → dry-run preview → restore → verify); the TUI
    /// only picks the snapshot. Reveals the result in Finder on success.
    private func restoreSelected(_ snap: ResticBackend.Snapshot) {
        guard let dest = restoreDest else { return }
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyyMMdd-HHmmss"
        let target = RestoreEngine.defaultTarget(snapshot: snap.shortID, stamp: fmt.string(from: Date()))

        drawPrompt("restore \(snap.shortID) (full) into ~/baaackaaab-restore/\(target.lastPathComponent)?   y: restore   enter/esc: cancel (default)")
        var go = false
        confirm: while true {
            switch readKey() {
            case .char("y"), .char("Y"): go = true; break confirm
            // Cancel is the default: only an explicit y writes anything.
            case .char("n"), .char("N"), .enter, .esc, .ctrlC: go = false; break confirm
            case .eof: go = false; break confirm
            default: break
            }
        }
        guard go else { statusMsg = "restore cancelled"; return }

        emit("\u{1B}[?25h\u{1B}[?1049l")   // leave alt screen + show cursor for live output
        term.restore()
        let code = runRestoreChild(dest: dest, snapshot: snap.shortID, target: target)
        if code == 0 { revealInFinder(target) }
        let tail = code == 0 ? "restore finished \u{2014} revealed in Finder" : "restore exited with code \(code)"
        FileHandle.standardOutput.write(Data("\n\(tail) \u{2014} press any key to return\n".utf8))
        term.enable()
        _ = readKey()
        reclaimForeground()
        emit("\u{1B}[?1049h\u{1B}[?25l")   // back into the alternate screen
        statusMsg = code == 0 ? "restored into \(target.path)" : "restore failed (code \(code))"
    }

    private func runRestoreChild(dest: Destination, snapshot: String, target: URL, include: String? = nil) -> Int32 {
        var args = ["--restore", "--destination", dest.name, "--snapshot", snapshot,
                    "--target", target.path, "--yes"]
        if let include { args += ["--include", include] }
        // Forward an explicit ad-hoc target repo so the child resolves the same one.
        if let r = argValue("--restic-repo") { args += ["--restic-repo", r] }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: selfPath())
        proc.arguments = args
        do { try proc.run() } catch {
            FileHandle.standardOutput.write(Data("could not launch restore: \(error)\n".utf8))
            return -1
        }
        proc.waitUntilExit()
        return proc.terminationStatus
    }

    /// Open the restored directory in Finder (best-effort; never blocks the TUI).
    private func revealInFinder(_ url: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = [url.path]
        try? p.run()
        p.waitUntilExit()
    }

    // MARK: - File browser (in-TUI snapshot content navigation + targeted restore)

    /// Enter the file browser for `snap`: load all its entries via `restic ls`
    /// (one network call, then all navigation is local), then switch to the
    /// fileBrowser screen. Shows a loading frame while the call is in flight.
    private func enterFileBrowser(snap: ResticBackend.Snapshot) {
        guard let dest = restoreDest else { return }
        lsSnap = snap
        lsEntries = nil
        lsLoadError = nil
        lsCurrentPath = "/"; lsRootPath = "/"
        lsCursor = 0; lsTop = 0
        screen = .fileBrowser
        statusMsg = "loading snapshot \(snap.shortID)\u{2026}"; renderFileBrowser()
        do {
            let entries = try ResticBackend(destination: dest).ls(snapshot: snap.shortID, path: nil)
            lsEntries = entries
            lsLoadError = nil
            // Land on the first directory that actually branches, so iCloud's
            // deep /Users/<name>/Library/Mobile Documents/… prefix isn't a chain
            // of one-entry folders the user has to click through.
            lsRootPath = initialBrowsePath(entries)
            lsCurrentPath = lsRootPath
        } catch {
            lsEntries = []; lsLoadError = "\(error)"
        }
        reclaimForeground()
        statusMsg = ""
    }

    /// Where to open the file browser: skip past chains of single-subdirectory
    /// levels so the browser lands where the tree first branches (or holds a
    /// file), instead of making the user drill through one-entry directories.
    private func initialBrowsePath(_ entries: [ResticBackend.LsEntry]) -> String {
        var path = "/"
        while true {
            let children = entries.filter {
                URL(fileURLWithPath: $0.path).deletingLastPathComponent().path == path
            }
            guard children.count == 1, children[0].type == "dir" else { return path }
            path = children[0].path
        }
    }

    /// Direct children of `lsCurrentPath`, sorted dirs-first then alphabetically.
    private func lsCurrentChildren() -> [ResticBackend.LsEntry] {
        guard let entries = lsEntries else { return [] }
        return entries
            .filter { URL(fileURLWithPath: $0.path).deletingLastPathComponent().path == lsCurrentPath }
            .sorted {
                if $0.type != $1.type { return $0.type == "dir" }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
    }

    private func renderFileBrowser() {
        let (rows, cols) = terminalSize()
        var lines: [String] = []
        let snapLabel = lsSnap.map { "\($0.shortID)  \(shortTime($0.time))" } ?? "?"
        lines.append(bold(fit("baaackaaab \u{2014} snapshot \(snapLabel)", cols)))
        let tags = lsSnap?.tags.joined(separator: ",") ?? ""
        lines.append(cyan(fit(tags.isEmpty ? "(no tags)" : tags, cols)))
        lines.append("")

        let helpLines = wrapHelp(fileBrowserHelpLine(), cols)
        let footerH = 2 + helpLines.count
        let contentH = max(1, rows - 3 - footerH)

        var body: [String] = []
        body.append(divider(lsCurrentPath, cols))
        let listH = max(1, contentH - 1)

        if let err = lsLoadError {
            body.append(yellow(fit("  error: " + err, cols)))
        } else if lsEntries == nil {
            body.append(dim(fit("  loading\u{2026}", cols)))
        } else {
            let children = lsCurrentChildren()
            if children.isEmpty {
                body.append(dim(fit("  (empty)", cols)))
            } else {
                clamp(&lsCursor, children.count)
                adjustTop(&lsTop, cursor: lsCursor, height: listH, count: children.count)
                for r in 0..<listH {
                    let idx = lsTop + r
                    if idx < children.count {
                        body.append(renderLsRow(children[idx], cursor: idx == lsCursor, cols: cols))
                    } else { body.append("") }
                }
            }
        }
        if body.count < contentH { body += Array(repeating: "", count: contentH - body.count) }
        else if body.count > contentH { body = Array(body.prefix(contentH)) }
        lines += body

        lines.append("")
        lines.append(dim(fit(lsBrowserStatusLine(), cols)))
        for hl in helpLines { lines.append(dim(fit(hl, cols))) }
        draw(lines)
    }

    private func renderLsRow(_ e: ResticBackend.LsEntry, cursor: Bool, cols: Int) -> String {
        let tag = e.type == "dir" ? "[dir] " : "[file]"
        let name = e.type == "dir" ? e.name + "/" : e.name
        let sizeStr = e.type == "file" ? "  " + formatBytes(e.size) : ""
        let text = "  \(tag) \(name)\(sizeStr)"
        var plain = fit(text, cols)
        if cursor {
            plain = plain.padding(toLength: cols, withPad: " ", startingAt: 0)
            return rev(plain)
        }
        return e.type == "dir" ? cyan(plain) : plain
    }

    private func lsBrowserStatusLine() -> String {
        var parts: [String] = []
        if let snap = lsSnap { parts.append("snap \(snap.shortID)") }
        parts.append(lsCurrentPath)
        if let entries = lsEntries { parts.append("\(lsCurrentChildren().count)/\(entries.count)") }
        if !statusMsg.isEmpty { parts.append(statusMsg) }
        return parts.joined(separator: "  \u{2022}  ")
    }

    private func fileBrowserHelpLine() -> String {
        "up/dn move \u{2022} enter/\u{2192} into dir \u{2022} r restore \u{2022} left/esc back \u{2022} q quit"
    }

    private func handleFileBrowser(_ key: Key) -> Bool {
        let children = lsCurrentChildren()
        switch key {
        case .up, .char("k"): lsCursor = max(0, lsCursor - 1)
        case .down, .char("j"): lsCursor = min(max(0, children.count - 1), lsCursor + 1)
        // Arrows/enter only NAVIGATE: into a directory, or a hint on a file.
        // Restore is the explicit `r` key, never a stray arrow (see TODO).
        case .enter, .right, .char("l"):
            if lsCursor < children.count {
                let entry = children[lsCursor]
                if entry.type == "dir" {
                    lsCurrentPath = entry.path
                    lsCursor = 0; lsTop = 0
                } else {
                    statusMsg = "press r to restore this file"
                }
            }
        case .char("r"):
            if lsCursor < children.count, let snap = lsSnap {
                lsRestoreTargeted(snap: snap, includePath: children[lsCursor].path)
            }
        case .left, .backspace, .char("h"), .esc:
            if lsCurrentPath == lsRootPath {
                screen = .restore
            } else {
                let parent = URL(fileURLWithPath: lsCurrentPath).deletingLastPathComponent().path
                lsCurrentPath = parent.isEmpty ? "/" : parent
                lsCursor = 0; lsTop = 0
            }
        case .char("q"), .ctrlC: if confirmQuit() { return false }
        case .eof: return false
        default: break
        }
        return true
    }

    /// Targeted restore: re-exec the CLI with `--include <path>` so only the
    /// selected file or subtree is written; same safe shell-out/re-enter pattern
    /// as `restoreSelected`. `includePath` is the full snapshot path, which is
    /// exactly what `--restore --include` expects.
    private func lsRestoreTargeted(snap: ResticBackend.Snapshot, includePath: String) {
        guard let dest = restoreDest else { return }
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyyMMdd-HHmmss"
        let target = RestoreEngine.defaultTarget(snapshot: snap.shortID, stamp: fmt.string(from: Date()))

        drawPrompt("restore \(fit(includePath, 40)) from \(snap.shortID)?   y: restore   enter/esc: cancel (default)")
        var go = false
        confirm: while true {
            switch readKey() {
            case .char("y"), .char("Y"): go = true; break confirm
            // Cancel is the default: only an explicit y writes anything.
            case .char("n"), .char("N"), .enter, .esc, .ctrlC: go = false; break confirm
            case .eof: go = false; break confirm
            default: break
            }
        }
        guard go else { statusMsg = "restore cancelled"; return }

        emit("\u{1B}[?25h\u{1B}[?1049l")
        term.restore()
        let code = runRestoreChild(dest: dest, snapshot: snap.shortID, target: target, include: includePath)
        if code == 0 { revealInFinder(target) }
        let tail = code == 0 ? "restore finished \u{2014} revealed in Finder" : "restore exited with code \(code)"
        FileHandle.standardOutput.write(Data("\n\(tail) \u{2014} press any key to return\n".utf8))
        term.enable()
        _ = readKey()
        reclaimForeground()
        emit("\u{1B}[?1049h\u{1B}[?25l")
        statusMsg = code == 0 ? "restored into \(target.path)" : "restore failed (code \(code))"
    }

    // MARK: - Directory listing (cached per cwd)

    private func currentBrowseRows() -> [BrowseRow] {
        if cachedRows == nil { rebuild() }
        return cachedRows ?? []
    }

    private func invalidate() { cachedRows = nil }

    private func rebuild() {
        var rows: [BrowseRow] = []
        if cwd.deletingLastPathComponent().path != cwd.path { rows.append(.parent) }
        if let dirs = listDirs(cwd) { rows.append(contentsOf: dirs.map(BrowseRow.dir)) }
        cachedRows = rows
    }

    /// Subdirectories of `url`, name-sorted, or nil if unreadable. Listing never
    /// materializes file contents — directory enumeration leaves iCloud stubs as
    /// stubs, so browsing stays read-only and cheap.
    private func listDirs(_ url: URL) -> [URL]? {
        let opts: FileManager.DirectoryEnumerationOptions = showHidden ? [] : [.skipsHiddenFiles]
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey], options: opts) else { return nil }
        return items
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
    }

    private func setRows() -> [SetRow] {
        set.driveFolders.map(SetRow.folder) + set.photoAlbums.map(SetRow.album)
    }

    // MARK: - Rendering

    // Layout is built as exactly `rows` lines so the footer pins to the bottom.
    //   header: title + dir + blank              (3)
    //   folder list                              (folderH)
    //   [panel only] divider + review list       (1 + reviewH)
    //   footer: blank + status + help            (3)
    private func render() {
        let (rows, cols) = terminalSize()
        var lines: [String] = []
        lines.append(bold(fit("baaackaaab — configure backup set", cols)))
        let location = pickAlbums ? "source: iCloud Photos" : "dir: " + tildePath(of: cwd)
        lines.append(cyan(fit(location, cols)))
        lines.append("")

        // The footer wraps the shortcut line across as many rows as it needs, so
        // no key is hidden behind an ellipsis. Content fills whatever is left.
        let helpLines = wrapHelp(helpLine(), cols)
        let footerH = 2 + helpLines.count        // blank + status + help(N)
        let contentH = max(1, rows - 3 - footerH)  // minus header(3)

        if pickAlbums {
            appendAlbumRows(&lines, height: contentH, cols: cols)
        } else if !setRows().isEmpty {
            // Folder browser and selected-set panel are both always visible; the
            // cursor + key target sit on whichever side panelFocused points to.
            let setCount = setRows().count
            var reviewH = min(max(setCount, 3), max(1, contentH / 3))
            reviewH = max(1, min(reviewH, max(1, contentH - 2)))   // leave folder + divider
            let folderH = max(1, contentH - reviewH - 1)           // -1 for the divider
            appendFolderRows(&lines, height: folderH, cols: cols, focused: !panelFocused)
            let hint = panelFocused ? "selected — space remove \u{2022} v/esc back " : "selected — v to prune "
            lines.append(divider(hint, cols))
            appendReviewRows(&lines, height: reviewH, cols: cols, focused: panelFocused)
        } else {
            appendFolderRows(&lines, height: contentH, cols: cols, focused: true)
        }

        lines.append("")
        lines.append(dim(fit(statusLine(), cols)))
        for hl in helpLines { lines.append(dim(fit(hl, cols))) }
        draw(lines)
    }

    private func appendAlbumRows(_ lines: inout [String], height: Int, cols: Int) {
        clamp(&albumCursor, albumChoices.count)
        let listH = max(1, height - 1)
        adjustTop(&albumTop, cursor: albumCursor, height: listH, count: albumChoices.count)
        lines.append(dim(fit("iCloud Photos albums — space toggle \u{2022} a/esc back", cols)))
        for r in 0..<listH {
            let idx = albumTop + r
            if idx < albumChoices.count {
                lines.append(renderAlbumRow(albumChoices[idx], cursor: idx == albumCursor, cols: cols))
            } else {
                lines.append("")
            }
        }
    }

    private func renderAlbumRow(_ a: PhotoAlbumInfo, cursor: Bool, cols: Int) -> String {
        let box = set.photoAlbums.contains(a.title) ? "[x] " : "[ ] "
        var plain = fit(box + a.title + "  (\(a.count))", cols)
        if cursor {
            plain = plain.padding(toLength: cols, withPad: " ", startingAt: 0)
            return rev(plain)
        }
        return set.photoAlbums.contains(a.title) ? green(plain) : plain
    }

    /// Break the shortcut line on its " • " separators, packing as many groups
    /// per row as fit `cols`. Groups stay intact — we never split mid-shortcut.
    private func wrapHelp(_ s: String, _ cols: Int) -> [String] {
        let sep = " \u{2022} "
        var lines: [String] = []
        var cur = ""
        for part in s.components(separatedBy: sep) {
            if cur.isEmpty { cur = part }
            else if (cur + sep + part).count <= cols { cur += sep + part }
            else { lines.append(cur); cur = part }
        }
        if !cur.isEmpty { lines.append(cur) }
        return lines.isEmpty ? [""] : lines
    }

    private func appendFolderRows(_ lines: inout [String], height: Int, cols: Int, focused: Bool) {
        let items = currentBrowseRows()
        clamp(&browseCursor, items.count)
        adjustTop(&browseTop, cursor: browseCursor, height: height, count: items.count)
        for r in 0..<height {
            let idx = browseTop + r
            if idx < items.count {
                lines.append(renderBrowseRow(items[idx], cursor: focused && idx == browseCursor, cols: cols))
            } else {
                lines.append("")
            }
        }
    }

    private func appendReviewRows(_ lines: inout [String], height: Int, cols: Int, focused: Bool) {
        let items = setRows()
        clamp(&reviewCursor, items.count)
        adjustTop(&reviewTop, cursor: reviewCursor, height: height, count: items.count)
        if items.isEmpty {
            lines.append(dim(fit("  nothing selected yet — space-pick folders above, a to add an album", cols)))
            for _ in 1..<max(1, height) { lines.append("") }
            return
        }
        for r in 0..<height {
            let idx = reviewTop + r
            if idx < items.count {
                lines.append(renderSetRow(items[idx], cursor: focused && idx == reviewCursor, cols: cols))
            } else {
                lines.append("")
            }
        }
    }

    private func renderBrowseRow(_ row: BrowseRow, cursor: Bool, cols: Int) -> String {
        var text: String
        var state: DirState = .none
        switch row {
        case .parent:
            text = "  ..  (up)"
        case .dir(let url):
            state = dirState(url)
            let box: String
            switch state {
            case .selected: box = "[x] "
            case .partial:  box = "[~] "
            case .none:     box = "[ ] "
            }
            text = box + url.lastPathComponent + "/"
        }
        var plain = fit(text, cols)
        if cursor {
            plain = plain.padding(toLength: cols, withPad: " ", startingAt: 0)
            return rev(plain)
        }
        switch state {
        case .selected: return green(plain)
        case .partial:  return yellow(plain)
        case .none:     return plain
        }
    }

    private func renderSetRow(_ row: SetRow, cursor: Bool, cols: Int) -> String {
        let text: String
        switch row {
        case .folder(let f): text = "  [drive] " + f
        case .album(let a): text = "  [album] " + a
        }
        var plain = fit(text, cols)
        if cursor {
            plain = plain.padding(toLength: cols, withPad: " ", startingAt: 0)
            return rev(plain)
        }
        return plain
    }

    private func statusLine() -> String {
        var parts = ["\(set.driveFolders.count) folders", "\(set.photoAlbums.count) albums"]
        if let q = set.quotaBytes { parts.append(String(format: "quota %.1f GB", Double(q) / 1_000_000_000)) }
        if dirty { parts.append("UNSAVED") }
        if !statusMsg.isEmpty { parts.append(statusMsg) }
        return parts.joined(separator: "  \u{2022}  ")
    }

    private func helpLine() -> String {
        if pickAlbums {
            return "up/dn move \u{2022} space toggle \u{2022} a/esc back \u{2022} s save \u{2022} q quit"
        }
        if panelFocused && !setRows().isEmpty {
            return "up/dn move \u{2022} space remove \u{2022} a albums \u{2022} v/esc back \u{2022} s save \u{2022} q quit"
        }
        return "up/dn move \u{2022} right open \u{2022} left/\u{232B} back \u{2022} space pick \u{2022} c pick-dir \u{2022} a albums \u{2022} v prune \u{2022} . hidden \u{2022} g iCloud \u{2022} ~ home \u{2022} s save \u{2022} q quit"
    }

    // MARK: - Terminal primitives

    private func draw(_ lines: [String]) {
        var o = "\u{1B}[H"
        for (i, line) in lines.enumerated() {
            o += "\u{1B}[\(i + 1);1H\u{1B}[2K" + line
        }
        o += "\u{1B}[0m\u{1B}[J"
        emit(o)
    }

    private func drawPrompt(_ msg: String) {
        let (rows, cols) = terminalSize()
        emit("\u{1B}[\(rows);1H\u{1B}[2K" + rev(fit(msg, cols)))
    }

    /// A full-width horizontal rule with a leading label, padded to exactly
    /// `cols` so it reads as a section break (no fit() ellipsis at the end).
    private func divider(_ label: String, _ cols: Int) -> String {
        let head = "\u{2500}\u{2500} " + label
        if head.count >= cols { return dim(String(head.prefix(cols))) }
        return dim(head + String(repeating: "\u{2500}", count: cols - head.count))
    }

    // Pending input bytes. read(2) can hand back a whole burst (a held key, a
    // paste, scripted input); we parse one key per call and keep the rest, so no
    // keystroke is dropped. An escape sequence within one burst is contiguous.
    private var inbuf: [UInt8] = []
    private var inpos = 0

    private func nextByte() -> UInt8? {
        if inpos >= inbuf.count {
            var tmp = [UInt8](repeating: 0, count: 32)
            let n = read(STDIN_FILENO, &tmp, 32)
            if n <= 0 { return nil }
            inbuf = Array(tmp[0..<n]); inpos = 0
        }
        defer { inpos += 1 }
        return inbuf[inpos]
    }

    private func peekByte() -> UInt8? { inpos < inbuf.count ? inbuf[inpos] : nil }

    private func readKey() -> Key {
        guard let b0 = nextByte() else { return .eof }
        if b0 == 0x1B {
            // Arrow keys (ESC [ A/B/C/D) only when the rest of the sequence is
            // already buffered; a lone ESC at a burst boundary means quit.
            if peekByte() == 0x5B {
                _ = nextByte()
                switch nextByte() {
                case 0x41?: return .up
                case 0x42?: return .down
                case 0x43?: return .right
                case 0x44?: return .left
                default: return .other
                }
            }
            return .esc
        }
        switch b0 {
        case 0x0D, 0x0A: return .enter
        case 0x20: return .space
        case 0x7F, 0x08: return .backspace
        case 0x09: return .tab
        case 0x03: return .ctrlC
        default: return .char(Character(UnicodeScalar(b0)))
        }
    }

    private func terminalSize() -> (rows: Int, cols: Int) {
        var w = winsize()
        if ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &w) == 0, w.ws_row > 0, w.ws_col > 0 {
            return (Int(w.ws_row), Int(w.ws_col))
        }
        return (24, 80)
    }

    private func emit(_ s: String) {
        FileHandle.standardOutput.write(Data(s.utf8))
    }

    // MARK: - Small helpers

    private func formatBytes(_ bytes: Int?) -> String {
        guard let b = bytes, b > 0 else { return "" }
        if b < 1024 { return "\(b) B" }
        if b < 1_048_576 { return String(format: "%.1f KB", Double(b) / 1024) }
        if b < 1_073_741_824 { return String(format: "%.1f MB", Double(b) / 1_048_576) }
        return String(format: "%.1f GB", Double(b) / 1_073_741_824)
    }

    private func fit(_ s: String, _ width: Int) -> String {
        if s.count <= width { return s }
        if width <= 1 { return String(s.prefix(max(0, width))) }
        return String(s.prefix(width - 1)) + "\u{2026}"
    }

    private func clamp(_ v: inout Int, _ count: Int) {
        v = count == 0 ? 0 : min(max(0, v), count - 1)
    }

    private func adjustTop(_ top: inout Int, cursor: Int, height: Int, count: Int) {
        if cursor < top { top = cursor }
        else if cursor >= top + height { top = cursor - height + 1 }
        top = max(0, min(top, max(0, count - height)))
    }

    private func bold(_ s: String) -> String { "\u{1B}[1m" + s + "\u{1B}[0m" }
    private func dim(_ s: String) -> String { "\u{1B}[2m" + s + "\u{1B}[0m" }
    private func cyan(_ s: String) -> String { "\u{1B}[36m" + s + "\u{1B}[0m" }
    private func green(_ s: String) -> String { "\u{1B}[32m" + s + "\u{1B}[0m" }
    private func yellow(_ s: String) -> String { "\u{1B}[33m" + s + "\u{1B}[0m" }
    private func rev(_ s: String) -> String { "\u{1B}[7m" + s + "\u{1B}[0m" }
}
