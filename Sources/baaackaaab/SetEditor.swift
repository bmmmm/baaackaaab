import Foundation
#if canImport(Darwin)
import Darwin
#endif

enum BrowseRow {
    case parent
    case dir(URL)
}

enum SetRow {
    case folder(String)
    case album(String)
}

// A directory's relation to the backup set, for the browse marker:
//   selected — this exact folder is in the set            → [x]
//   partial  — a descendant is in the set, this one isn't → [~]
//   none     — neither                                    → [ ]
enum DirState { case selected, partial, none }

extension ConfigTUI {
    // MARK: - Input handling

    /// Returns false to quit the editor.
    func handleBrowse(_ key: Key) -> Bool {
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

    func handleReview(_ key: Key) -> Bool {
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

    func handleAlbumPicker(_ key: Key) -> Bool {
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
    func openAlbumPicker() {
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

    func goUp() {
        let parent = cwd.deletingLastPathComponent()
        if parent.path != cwd.path { cwd = parent; invalidate(); browseCursor = 0; browseTop = 0 }
    }

    func enter(_ url: URL) {
        if listDirs(url) == nil { statusMsg = "cannot open \(url.lastPathComponent)"; return }
        cwd = url; invalidate(); browseCursor = 0; browseTop = 0
    }

    func jumpICloud() {
        let icloud = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        if FileManager.default.fileExists(atPath: icloud.path) {
            cwd = icloud; invalidate(); browseCursor = 0; browseTop = 0
        } else {
            statusMsg = "iCloud Drive folder not found"
        }
    }

    func jumpHome() {
        cwd = home; invalidate(); browseCursor = 0; browseTop = 0
    }

    // MARK: - Selection

    /// A browsed URL's storage key: tilde-relative under home (portable,
    /// hand-editable), absolute otherwise — matching how the CLI stores paths.
    func tildePath(of url: URL) -> String {
        let p = url.path
        if p == home.path { return "~" }
        if p.hasPrefix(home.path + "/") { return "~" + p.dropFirst(home.path.count) }
        return p
    }

    /// Inverse of tildePath: expand a stored entry (tilde or absolute) to an
    /// absolute filesystem path, so we can compare it against a browsed URL.
    func expandPath(_ folder: String) -> String {
        if folder == "~" { return home.path }
        if folder.hasPrefix("~/") { return home.path + folder.dropFirst(1) }
        return folder
    }

    func isSelected(_ url: URL) -> Bool {
        // Through the set's own normalized lookup — a raw `contains` on the
        // array would silently drift the moment normalizeFolder gains a real
        // transform (the add path already normalizes).
        let t = tildePath(of: url)
        return set.containsFolder(t) || set.containsFolder(url.path)
    }

    /// Where `url` stands relative to the set: itself selected, an ancestor of a
    /// selected folder (partial), or neither. The partial state lets the marker
    /// bubble up the tree so a selection deep in a branch is visible from above.
    func dirState(_ url: URL) -> DirState {
        if isSelected(url) { return .selected }
        let prefix = url.path + "/"
        for f in set.driveFolders where expandPath(f).hasPrefix(prefix) { return .partial }
        return .none
    }

    func toggle(_ url: URL) {
        let t = tildePath(of: url)
        if set.removeFolder(t) || set.removeFolder(url.path) {
            dirty = true; statusMsg = "removed \(t)"
        } else {
            _ = set.addFolder(t)
            dirty = true; statusMsg = "added \(t)"
        }
    }

    // MARK: - Directory listing (cached per cwd)

    func currentBrowseRows() -> [BrowseRow] {
        if cachedRows == nil { rebuild() }
        return cachedRows ?? []
    }

    func invalidate() { cachedRows = nil }

    func rebuild() {
        var rows: [BrowseRow] = []
        if cwd.deletingLastPathComponent().path != cwd.path { rows.append(.parent) }
        if let dirs = listDirs(cwd) { rows.append(contentsOf: dirs.map(BrowseRow.dir)) }
        cachedRows = rows
    }

    /// Subdirectories of `url`, name-sorted, or nil if unreadable. Listing never
    /// materializes file contents — directory enumeration leaves iCloud stubs as
    /// stubs, so browsing stays read-only and cheap.
    func listDirs(_ url: URL) -> [URL]? {
        let opts: FileManager.DirectoryEnumerationOptions = showHidden ? [] : [.skipsHiddenFiles]
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey], options: opts) else { return nil }
        return items
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
    }

    func setRows() -> [SetRow] {
        set.driveFolders.map(SetRow.folder) + set.photoAlbums.map(SetRow.album)
    }

    // MARK: - Rendering

    // Layout is built as exactly `rows` lines so the footer pins to the bottom.
    //   header: title + dir + blank              (3)
    //   folder list                              (folderH)
    //   [panel only] divider + review list       (1 + reviewH)
    //   footer: blank + status + help            (3)
    func render() {
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

    func appendAlbumRows(_ lines: inout [String], height: Int, cols: Int) {
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

    func renderAlbumRow(_ a: PhotoAlbumInfo, cursor: Bool, cols: Int) -> String {
        let box = set.photoAlbums.contains(a.title) ? "[x] " : "[ ] "
        var plain = fit(box + a.title + "  (\(a.count))", cols)
        if cursor {
            plain = padToWidth(plain, cols)
            return rev(plain)
        }
        return set.photoAlbums.contains(a.title) ? green(plain) : plain
    }

    /// Break the shortcut line on its " • " separators, packing as many groups
    /// per row as fit `cols`. Groups stay intact — we never split mid-shortcut.
    func wrapHelp(_ s: String, _ cols: Int) -> [String] {
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

    func appendFolderRows(_ lines: inout [String], height: Int, cols: Int, focused: Bool) {
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

    func appendReviewRows(_ lines: inout [String], height: Int, cols: Int, focused: Bool) {
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

    func renderBrowseRow(_ row: BrowseRow, cursor: Bool, cols: Int) -> String {
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
            plain = padToWidth(plain, cols)
            return rev(plain)
        }
        switch state {
        case .selected: return green(plain)
        case .partial:  return yellow(plain)
        case .none:     return plain
        }
    }

    func renderSetRow(_ row: SetRow, cursor: Bool, cols: Int) -> String {
        let text: String
        switch row {
        case .folder(let f): text = "  [drive] " + f
        case .album(let a): text = "  [album] " + a
        }
        var plain = fit(text, cols)
        if cursor {
            plain = padToWidth(plain, cols)
            return rev(plain)
        }
        return plain
    }

    func statusLine() -> String {
        var parts = ["\(set.driveFolders.count) folders", "\(set.photoAlbums.count) albums"]
        if let q = set.quotaBytes { parts.append(String(format: "quota %.1f GB", Double(q) / 1_000_000_000)) }
        if dirty { parts.append("UNSAVED") }
        if !statusMsg.isEmpty { parts.append(statusMsg) }
        return parts.joined(separator: "  \u{2022}  ")
    }

    func helpLine() -> String {
        if pickAlbums {
            return "up/dn move \u{2022} space toggle \u{2022} a/esc back \u{2022} s save \u{2022} q quit"
        }
        if panelFocused && !setRows().isEmpty {
            return "up/dn move \u{2022} space remove \u{2022} a albums \u{2022} v/esc back \u{2022} s save \u{2022} q quit"
        }
        return "up/dn move \u{2022} right open \u{2022} left/\u{232B} back \u{2022} space pick \u{2022} c pick-dir \u{2022} a albums \u{2022} v prune \u{2022} . hidden \u{2022} g iCloud \u{2022} ~ home \u{2022} s save \u{2022} q quit"
    }
}
