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

enum Screen { case home, editor, restore, fileBrowser, timer }

final class ConfigTUI {
    let configPath: URL
    let home = FileManager.default.homeDirectoryForCurrentUser

    var set: BackupSet
    var existed = false
    var loadFailed = false

    // The home screen (dashboard + actions) is the landing screen for a bare
    // launch; the editor is its own screen. `hasHome` records whether home is the
    // root, so esc in the editor backs out to it instead of quitting. Both share
    // the one raw terminal — no nesting.
    var screen: Screen = .editor
    var hasHome = false

    // Remote dashboard state, resolved lazily on first `r` so an edit-only
    // session never touches the credential store. `destinations` is every enabled
    // target; `remotes` is the per-destination status (parallel array) filled in
    // by a remote query. The dashboard shows one block per destination.
    var destinations: [Destination] = []
    var repoResolved = false
    var remotes: [ResticBackend.RemoteStatus] = []
    var remoteQueried = false

    // restic + REST-server currency, shown on the home dashboard. Lazy like the
    // remote status: nothing is checked until the user presses `u`, so opening the
    // dashboard never contacts GitHub or the server (the offline-by-default rule).
    var updateFindings: [UpdateCheck.Finding] = []
    var updatesChecked = false

    // The tail of the run history (no credentials — just tags/times/counts), shown
    // on the home dashboard. Loaded lazily and dropped after a sync so a fresh run
    // shows up on return.
    var recentRuns: [RunRecord]?

    // The newest restore-drill record, for the "last verified restore" line. A
    // double optional: nil = not loaded yet, .some(nil) = loaded, no drill on
    // record. Scanned from the whole history (a monthly drill sits far behind the
    // recent daily backups), so cached separately and only computed once.
    var lastDrillRecord: RunRecord??

    // The newest integrity-check record, for the "last integrity check" line. Same
    // double-optional caching as lastDrillRecord (nil = not loaded, .some(nil) =
    // loaded, none on record) — a rotating check may sit far behind recent backups.
    var lastCheckRecord: RunRecord??

    // Local-time stamp for run rows: the record stores an absolute Date, shown in
    // the operator's timezone (unlike the remote's already-formatted ISO string).
    let runStampFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    // Restore screen: a snapshot browser over one source destination (cycle with
    // d when several are configured). Picking a snapshot re-execs the tested CLI
    // restore (`--restore … --yes`) so the actual write goes through the same
    // safe-by-construction engine — full restore into a fresh dir, revealed after.
    var restoreDestIndex = 0
    var restoreSnaps: [ResticBackend.Snapshot]?
    var restoreLoadError: String?
    var restoreCursor = 0, restoreTop = 0

    // Timer screen: edit one time-of-day + an optional weekday set, then install /
    // uninstall the launchd schedule via the tested CLI. Loaded from the installed
    // plist on enter. The (installed, loaded) state is cached so a render never
    // spawns launchctl — it is refreshed only on enter and after install/uninstall.
    var timerHour = 12, timerMinute = 0
    var timerWeekdays = Set<Int>()      // launchd weekday numbers; empty = daily
    var timerFieldMinute = false        // which time field up/down adjusts
    var timerState: (installed: Bool, loaded: Bool) = (false, false)
    var timerCurrent: Schedule?

    // File browser screen: in-TUI navigation of a snapshot's directory tree.
    // `lsEntries` holds ALL entries from `restic ls` (flat depth-first list), loaded
    // once on enter; navigation filters by parent path so browsing is instant.
    var lsSnap: ResticBackend.Snapshot?
    var lsEntries: [ResticBackend.LsEntry]?
    var lsLoadError: String?
    var lsCursor = 0, lsTop = 0
    var lsCurrentPath = "/"
    // The level the browser opens on after auto-descending the single-child
    // wrapper directories (see initialBrowsePath). Left/esc at this path exits
    // back to the snapshot list instead of walking up into the empty wrappers.
    var lsRootPath = "/"

    // The selected-set panel is always visible under the folder browser once
    // anything is picked. Navigation stays on the folder browser by default;
    // `v` moves focus DOWN into the panel to prune entries, esc/v hands it back.
    var panelFocused = false
    var showHelp = false
    // The album picker (a) takes over the content area with the user's Photos
    // albums. It's loaded lazily on first open (triggers the Photos prompt).
    var pickAlbums = false
    var albumChoices: [PhotoAlbumInfo] = []
    var cwd: URL

    var browseCursor = 0, browseTop = 0
    var reviewCursor = 0, reviewTop = 0
    var albumCursor = 0, albumTop = 0
    var showHidden = false
    var dirty = false
    var statusMsg = ""

    var cachedRows: [BrowseRow]?
    var term: RawTerminal!

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

    // Pending input bytes. read(2) can hand back a whole burst (a held key, a
    // paste, scripted input); we parse one key per call and keep the rest, so no
    // keystroke is dropped. An escape sequence within one burst is contiguous.
    var inbuf: [UInt8] = []
    var inpos = 0

    // How long to wait for the rest of an escape sequence after a lone ESC at a
    // read() boundary, before deciding it really was a back/quit ESC. A single
    // keypress's 3 bytes almost always arrive together; this only matters on a
    // slow/loaded PTY where ESC and "[A" land in separate reads. Short enough to
    // be imperceptible on a real ESC.
    let escSequenceGraceMs: Int32 = 30

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
        // SIGWINCH must INTERRUPT the blocking read (no SA_RESTART) so the loop
        // wakes on a resize and re-renders; signal() would install it with
        // SA_RESTART and the read would silently resume, redrawing only on the
        // next keypress.
        winchPending = 0
        var winchAction = sigaction()
        winchAction.__sigaction_u.__sa_handler = winchSignalHandler
        sigemptyset(&winchAction.sa_mask)
        winchAction.sa_flags = 0
        sigaction(SIGWINCH, &winchAction, nil)
        defer {
            term.restore()                 // always hand the terminal back cooked
            cookedTermValid = false
            signal(SIGHUP, SIG_DFL)
            signal(SIGTERM, SIG_DFL)
            signal(SIGINT, SIG_DFL)
            signal(SIGWINCH, SIG_DFL)
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
            if case .resize = key { continue }   // re-render at the loop top, new size
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

    // MARK: - Persistence

    func save() {
        do { try set.save(to: configPath); dirty = false; statusMsg = "saved" }
        catch { statusMsg = "save failed: \(error)" }
    }

    /// Returns true if the editor should quit. Prompts on unsaved changes.
    func confirmQuit() -> Bool {
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
    func printExitHint() {
        let onDisk = (try? BackupSet.load(from: configPath)) ?? BackupSet()
        guard !onDisk.isEmpty else { return }
        let bin = CommandLine.arguments.first ?? "baaackaaab"
        Console.section("Next")
        Console.step("run a backup:  \(bin) --run-tag smoke-live")
        Console.note("a bare run backs up this set; --run-tag just labels the snapshots. Run it in Terminal.app — it needs the Keychain + Photos access.")
    }
}
