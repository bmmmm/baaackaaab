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

private enum Screen { case home, editor }

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
    // session never touches the credential store.
    private var repo: String?
    private var repoResolved = false
    private var remote: ResticBackend.RemoteStatus?
    private var remoteQueried = false

    // The selected-set panel is always visible under the folder browser once
    // anything is picked. Navigation stays on the folder browser by default;
    // `v` moves focus DOWN into the panel to prune entries, esc/v hands it back.
    private var panelFocused = false
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
            if screen == .home { renderHome() } else { render() }
            let key = readKey()
            statusMsg = ""
            let keepGoing: Bool
            if screen == .home { keepGoing = handleHome(key) }
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
        case .char("e"), .enter, .right, .tab: screen = .editor
        case .char("s"): syncNow()
        case .char("r"): refreshRemote()
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
        drawPrompt("unsaved changes — y: save & quit   n: discard & quit   esc: cancel")
        while true {
            switch readKey() {
            case .char("y"), .char("Y"): save(); return true
            case .char("n"), .char("N"): return true
            case .esc, .ctrlC: return false
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
        body.append(divider("remote", cols))
        if let repo = repo {
            body.append(dim(fit("  repo  " + Credentials.redact(repo), cols)))
            body.append(homeRemoteLine(cols))
        } else if repoResolved {
            body.append(yellow(fit("  no repository configured \u{2014} run baaackaaab --init-credentials", cols)))
        } else {
            body.append(dim(fit("  press r to query the remote (snapshots + size)", cols)))
        }

        if body.count < contentH { body += Array(repeating: "", count: contentH - body.count) }
        else if body.count > contentH { body = Array(body.prefix(contentH)) }
        lines += body

        lines.append("")
        lines.append(dim(fit(statusLine(), cols)))
        for hl in helpLines { lines.append(dim(fit(hl, cols))) }
        draw(lines)
    }

    private func homeRemoteLine(_ cols: Int) -> String {
        guard remoteQueried else { return dim(fit("  press r to query snapshots + size", cols)) }
        guard let r = remote else { return dim(fit("  (no data)", cols)) }
        if let err = r.error { return yellow(fit("  unreachable: " + err, cols)) }
        var parts = ["\(r.snapshotCount) snapshot(s)"]
        if let t = r.latestTime {
            let tags = r.latestTags.isEmpty ? "" : " [" + r.latestTags.joined(separator: ",") + "]"
            parts.append("latest " + shortTime(t) + tags)
        }
        if let s = r.sizeBytes { parts.append(String(format: "%.2f GB", Double(s) / 1_000_000_000)) }
        return green(fit("  \u{2713} " + parts.joined(separator: "  \u{2022}  "), cols))
    }

    private func homeHelpLine() -> String {
        "e edit set \u{2022} s sync now \u{2022} r remote \u{2022} q quit"
    }

    // MARK: - Home actions

    /// Run the real backup by re-execing this binary. We leave the alternate
    /// screen + raw mode first so restic streams to the normal screen with proper
    /// newlines, then re-enter after a keypress — a clean shell-out, never a
    /// nested TUI.
    private func syncNow() {
        guard !set.isEmpty else { statusMsg = "backup set is empty \u{2014} press e to add folders / albums"; return }
        if dirty { save() }   // back up exactly what's on screen
        // Resolve + export credentials in this process so the re-exec'd child
        // inherits the repo + password source from the environment. In file mode
        // only the *_FILE paths are inherited — no secret value, no Keychain.
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
        remote = nil; remoteQueried = false  // repo changed — drop the cached status
        statusMsg = code == 0 ? "sync finished \u{2014} press r to refresh remote" : "sync failed (code \(code))"
    }

    private func runSyncChild() -> Int32 {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: selfPath())
        proc.arguments = syncArgs()
        do { try proc.run() } catch {
            FileHandle.standardOutput.write(Data("could not launch backup: \(error)\n".utf8))
            return -1
        }
        proc.waitUntilExit()
        return proc.terminationStatus
    }

    /// Read-only refresh of the remote panel. Resolves the repo (+ loads the
    /// Keychain password) lazily on first use, queries snapshots + size, redraws.
    private func refreshRemote() {
        ensureRepoResolved()
        guard let repo = repo else { statusMsg = "no repository \u{2014} run baaackaaab --init-credentials (or --migrate-credentials) first"; return }
        guard resticPasswordAvailable() else { statusMsg = "no encryption password \u{2014} run baaackaaab --migrate-credentials or --init-credentials"; return }
        statusMsg = "querying remote\u{2026}"; renderHome()
        remote = ResticBackend(repository: repo).remoteStatus()
        remoteQueried = true
        reclaimForeground()   // the restic child may have grabbed the tty foreground
        statusMsg = ""
    }

    /// Resolve the repo and export both secrets (file store preferred, then the
    /// legacy Keychain) so the in-process restic query AND a re-exec'd sync child
    /// inherit them. Resolved at most once. With the file store this is silent —
    /// no Keychain prompt at all. See `Credentials.resolveAndExport`.
    private func ensureRepoResolved() {
        if repoResolved { return }
        repoResolved = true
        repo = Credentials.resolveAndExport(explicitRepo: argValue("--restic-repo"))
    }

    private func syncArgs() -> [String] {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyyMMdd-HHmmss"
        var args = ["--run-tag", "tui-\(fmt.string(from: Date()))"]
        // Preserve a non-default config so the child backs up the same set.
        if configPath.path != BackupSet.defaultPath().path { args += ["--config", configPath.path] }
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
