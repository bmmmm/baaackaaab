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
// Pure Foundation + termios — no curses, no dependency. Two screens:
//   browse  — walk the directory tree, toggle folders in/out of the set
//   review  — flat list of everything selected; remove entries, add an album
//
// Needs a real TTY (main.swift guards that). Off a terminal it refuses to run.

private enum Screen { case browse, review }

private enum BrowseRow {
    case parent
    case dir(URL)
}

private enum SetRow {
    case folder(String)
    case album(String)
}

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

    private var screen: Screen = .browse
    private var cwd: URL

    private var browseCursor = 0, browseTop = 0
    private var reviewCursor = 0, reviewTop = 0
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
        defer {
            emit("\u{1B}[?25h\u{1B}[?1049l")
            term.restore()
        }

        loop: while true {
            render()
            let key = readKey()
            statusMsg = ""
            switch screen {
            case .browse: if !handleBrowse(key) { break loop }
            case .review: if !handleReview(key) { break loop }
            }
        }
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
        case .char("v"), .tab: screen = .review; reviewCursor = 0; reviewTop = 0
        case .char("."): showHidden.toggle(); invalidate(); browseCursor = 0; browseTop = 0
        case .char("g"): jumpICloud()
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
        case .char("a"):
            if let name = promptLine("add album: ") {
                if set.addAlbum(name) { dirty = true; statusMsg = "added album \(name)" }
                else { statusMsg = "album already in set" }
            }
        case .char("v"), .tab: screen = .browse
        case .char("s"): save()
        case .char("q"), .esc, .ctrlC: if confirmQuit() { return false }
        case .eof: return false
        default: break
        }
        return true
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

    // MARK: - Selection

    /// A browsed URL's storage key: tilde-relative under home (portable,
    /// hand-editable), absolute otherwise — matching how the CLI stores paths.
    private func tildePath(of url: URL) -> String {
        let p = url.path
        if p == home.path { return "~" }
        if p.hasPrefix(home.path + "/") { return "~" + p.dropFirst(home.path.count) }
        return p
    }

    private func isSelected(_ url: URL) -> Bool {
        let t = tildePath(of: url)
        return set.driveFolders.contains(t) || set.driveFolders.contains(url.path)
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

    private func render() {
        switch screen {
        case .browse: renderBrowse()
        case .review: renderReview()
        }
    }

    private func renderBrowse() {
        let (rows, cols) = terminalSize()
        let listH = max(1, rows - 6)
        let items = currentBrowseRows()
        clamp(&browseCursor, items.count)
        adjustTop(&browseTop, cursor: browseCursor, height: listH, count: items.count)

        var lines: [String] = []
        lines.append(bold(fit("baaackaaab — configure backup set", cols)))
        lines.append(cyan(fit("dir: " + tildePath(of: cwd), cols)))
        lines.append("")
        for r in 0..<listH {
            let idx = browseTop + r
            if idx < items.count {
                lines.append(renderBrowseRow(items[idx], cursor: idx == browseCursor, cols: cols))
            } else {
                lines.append("")
            }
        }
        lines.append("")
        lines.append(dim(fit(statusLine(), cols)))
        lines.append(dim(fit("up/dn move \u{2022} right open \u{2022} left up \u{2022} space pick \u{2022} c pick-dir \u{2022} v review \u{2022} . hidden \u{2022} s save \u{2022} q quit", cols)))
        draw(lines)
    }

    private func renderReview() {
        let (rows, cols) = terminalSize()
        let listH = max(1, rows - 6)
        let items = setRows()
        clamp(&reviewCursor, items.count)
        adjustTop(&reviewTop, cursor: reviewCursor, height: listH, count: items.count)

        var lines: [String] = []
        lines.append(bold(fit("baaackaaab — selected sources", cols)))
        lines.append(cyan(fit("file: " + tildePath(of: configPath), cols)))
        lines.append("")
        if items.isEmpty {
            lines.append(dim(fit("  nothing selected yet — press v to browse folders, a to add an album", cols)))
            for _ in 1..<listH { lines.append("") }
        } else {
            for r in 0..<listH {
                let idx = reviewTop + r
                if idx < items.count {
                    lines.append(renderSetRow(items[idx], cursor: idx == reviewCursor, cols: cols))
                } else {
                    lines.append("")
                }
            }
        }
        lines.append("")
        lines.append(dim(fit(statusLine(), cols)))
        lines.append(dim(fit("up/dn move \u{2022} space remove \u{2022} a add album \u{2022} v browse \u{2022} s save \u{2022} q quit", cols)))
        draw(lines)
    }

    private func renderBrowseRow(_ row: BrowseRow, cursor: Bool, cols: Int) -> String {
        var text: String
        var selected = false
        switch row {
        case .parent:
            text = "  ..  (up)"
        case .dir(let url):
            selected = isSelected(url)
            text = (selected ? "[x] " : "[ ] ") + url.lastPathComponent + "/"
        }
        var plain = fit(text, cols)
        if cursor {
            plain = plain.padding(toLength: cols, withPad: " ", startingAt: 0)
            return rev(plain)
        }
        return selected ? green(plain) : plain
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

    /// Drop to cooked mode for a single line of input (e.g. an album name),
    /// then restore raw mode. readLine echoes naturally while cooked.
    private func promptLine(_ label: String) -> String? {
        let (rows, cols) = terminalSize()
        term.restore()
        emit("\u{1B}[?25h\u{1B}[\(rows);1H\u{1B}[2K" + fit(label, cols))
        let line = readLine(strippingNewline: true)
        term.enable()
        emit("\u{1B}[?25l")
        guard let line = line else { return nil }
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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
    private func rev(_ s: String) -> String { "\u{1B}[7m" + s + "\u{1B}[0m" }
}
