import Foundation
#if canImport(Darwin)
import Darwin
#endif

extension ConfigTUI {
    // MARK: - Restore screen (snapshot browser → safe CLI restore)

    /// The destination currently selected on the restore screen.
    var restoreDest: Destination? {
        guard restoreDestIndex < destinations.count else { return nil }
        return destinations[restoreDestIndex]
    }

    /// Enter the restore browser: resolve destinations, then load the first one's
    /// snapshots. Refuses (with a status message) when nothing is configured.
    func enterRestore() {
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
    func loadRestoreSnaps() {
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

    func renderRestore() {
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

    func renderSnapshotRow(_ s: ResticBackend.Snapshot, cursor: Bool, cols: Int) -> String {
        let tags = s.tags.isEmpty ? "" : s.tags.joined(separator: ",")
        let text = "  \(s.shortID)  \(shortTime(s.time))  \(tags)"
        var plain = fit(text, cols)
        if cursor {
            plain = padToWidth(plain, cols)
            return rev(plain)
        }
        return plain
    }

    func restoreHelpLine() -> String {
        "up/dn move \u{2022} enter/\u{2192} browse \u{2022} r restore (full) \u{2022} c diff prev \u{2022} d switch dest \u{2022} esc back \u{2022} q quit"
    }

    func handleRestore(_ key: Key) -> Bool {
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
                if let r = cli.value("--restic-repo") { args += ["--restic-repo", r] }
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
    func restoreSelected(_ snap: ResticBackend.Snapshot) {
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

    func runRestoreChild(dest: Destination, snapshot: String, target: URL, include: String? = nil) -> Int32 {
        var args = ["--restore", "--destination", dest.name, "--snapshot", snapshot,
                    "--target", target.path, "--yes"]
        if let include { args += ["--include", include] }
        // Forward an explicit ad-hoc target repo so the child resolves the same one.
        if let r = cli.value("--restic-repo") { args += ["--restic-repo", r] }
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
    func revealInFinder(_ url: URL) {
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
    func enterFileBrowser(snap: ResticBackend.Snapshot) {
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
    func initialBrowsePath(_ entries: [ResticBackend.LsEntry]) -> String {
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
    func lsCurrentChildren() -> [ResticBackend.LsEntry] {
        guard let entries = lsEntries else { return [] }
        return entries
            .filter { URL(fileURLWithPath: $0.path).deletingLastPathComponent().path == lsCurrentPath }
            .sorted {
                if $0.type != $1.type { return $0.type == "dir" }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
    }

    func renderFileBrowser() {
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

    func renderLsRow(_ e: ResticBackend.LsEntry, cursor: Bool, cols: Int) -> String {
        let tag = e.type == "dir" ? "[dir] " : "[file]"
        let name = e.type == "dir" ? e.name + "/" : e.name
        let sizeStr = e.type == "file" ? "  " + formatBytes(e.size) : ""
        let text = "  \(tag) \(name)\(sizeStr)"
        var plain = fit(text, cols)
        if cursor {
            plain = padToWidth(plain, cols)
            return rev(plain)
        }
        return e.type == "dir" ? cyan(plain) : plain
    }

    func lsBrowserStatusLine() -> String {
        var parts: [String] = []
        if let snap = lsSnap { parts.append("snap \(snap.shortID)") }
        parts.append(lsCurrentPath)
        if let entries = lsEntries { parts.append("\(lsCurrentChildren().count)/\(entries.count)") }
        if !statusMsg.isEmpty { parts.append(statusMsg) }
        return parts.joined(separator: "  \u{2022}  ")
    }

    func fileBrowserHelpLine() -> String {
        "up/dn move \u{2022} enter/\u{2192} into dir \u{2022} r restore \u{2022} left/esc back \u{2022} q quit"
    }

    func handleFileBrowser(_ key: Key) -> Bool {
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
    func lsRestoreTargeted(snap: ResticBackend.Snapshot, includePath: String) {
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
}
