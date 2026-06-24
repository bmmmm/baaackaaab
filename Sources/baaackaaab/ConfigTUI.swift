import Foundation
#if canImport(Darwin)
import Darwin
#endif

// Interactive full-screen editor for the declarative backup set.
//
// The CLI (--add-folder/--add-album) is the headless path; this is the same
// edit, but you browse the real filesystem and toggle folders instead of typing
// paths. It writes the identical BackupSet JSON, so the two are interchangeable.
//
// Pure Foundation + termios — no curses, no dependency. One screen:
//   browse  — walk the directory tree, toggle folders in/out of the set
//   review  — a panel that toggles in (v) directly under the folder list,
//             showing everything selected; remove entries
//   albums  — a Photos album picker (a) that lists your iCloud albums with
//             counts so you toggle them like folders, instead of typing names
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
        enable()
    }

    func enable() { var r = raw; tcsetattr(STDIN_FILENO, TCSAFLUSH, &r) }
    func restore() { var o = original; tcsetattr(STDIN_FILENO, TCSAFLUSH, &o) }
}

final class ConfigTUI {
    private let configPath: URL
    private let home = FileManager.default.homeDirectoryForCurrentUser

    private var set: BackupSet
    private var existed = false
    private var loadFailed = false

    // The review list is a panel that toggles in under the folder browser
    // (v). When shown it takes input focus; the folder list stays visible above.
    private var showReview = false
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

    func run() {
        if loadFailed {
            Console.error("backup set at \(configPath.path) is unreadable — fix or delete it, then re-run --configure")
            return
        }
        guard let term = RawTerminal() else {
            Console.error("--configure needs an interactive terminal")
            return
        }
        self.term = term
        emit("\u{1B}[?1049h\u{1B}[?25l")   // alternate screen + hide cursor
        defer { term.restore() }           // always hand the terminal back cooked

        loop: while true {
            render()
            let key = readKey()
            statusMsg = ""
            let keepGoing: Bool
            if pickAlbums { keepGoing = handleAlbumPicker(key) }
            else if showReview { keepGoing = handleReview(key) }
            else { keepGoing = handleBrowse(key) }
            if !keepGoing { break loop }
        }

        emit("\u{1B}[?25h\u{1B}[?1049l")   // show cursor + leave alternate screen
        printExitHint()
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
        case .char("v"), .tab: showReview = true; reviewCursor = 0; reviewTop = 0
        case .char("."): showHidden.toggle(); invalidate(); browseCursor = 0; browseTop = 0
        case .char("g"): jumpICloud()
        case .char("~"): jumpHome()
        case .char("s"): save()
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
            }
        case .char("a"): openAlbumPicker()
        // v/esc/left close the panel and hand focus back to the folder browser;
        // the whole editor only quits on q / Ctrl-C.
        case .char("v"), .tab, .esc, .left, .char("h"): showReview = false
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
        } else if showReview {
            let setCount = setRows().count
            var reviewH = min(max(setCount, 3), max(1, contentH / 3))
            reviewH = max(1, min(reviewH, max(1, contentH - 2)))   // leave folder + divider
            let folderH = max(1, contentH - reviewH - 1)           // -1 for the divider
            appendFolderRows(&lines, height: folderH, cols: cols, focused: false)
            lines.append(divider("selected — space remove \u{2022} v/esc back ", cols))
            appendReviewRows(&lines, height: reviewH, cols: cols, focused: true)
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
        if showReview {
            return "up/dn move \u{2022} space remove \u{2022} a albums \u{2022} v/esc back \u{2022} s save \u{2022} q quit"
        }
        return "up/dn move \u{2022} right open \u{2022} left/\u{232B} back \u{2022} space pick \u{2022} c pick-dir \u{2022} a albums \u{2022} v review \u{2022} . hidden \u{2022} g iCloud \u{2022} ~ home \u{2022} s save \u{2022} q quit"
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
