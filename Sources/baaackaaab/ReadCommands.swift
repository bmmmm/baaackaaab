import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// List snapshots (read-only restore browser, CLI form). For each destination —
/// all, or just `--destination <name>` — its snapshots newest-first with the short
/// id, time, host, tags, and covered paths. The short id is what `--restore` takes.
func listSnapshotsCommand() {
    Console.banner("baaackaaab", tagline: "snapshots")
    let dests = destinationsForCommand()
    let failures = forEachDestination(dests) { dest in
        let snaps = try ResticBackend(destination: dest).listSnapshots()
        if snaps.isEmpty {
            Console.note("no snapshots yet")
            return true
        }
        for s in snaps {
            let when = String(s.time.prefix(16)).replacingOccurrences(of: "T", with: " ")
            let tags = s.tags.isEmpty ? "" : "  [" + s.tags.joined(separator: ",") + "]"
            Console.step("\(s.shortID)  \(when)  \(s.hostname)\(tags)")
            Console.detail(s.paths.joined(separator: ", "))
        }
        return true
    }
    if failures > 0 {
        Console.error("\(failures)/\(dests.count) destination(s) could not be listed — see above")
        exit(1)
    }
}

/// Locate files inside a snapshot by name/glob (read-only) — the discovery step
/// of a single-file restore. Lists each match's full snapshot path (exactly what
/// `--restore --include` then takes) and size, per destination.
func findCommand() {
    Console.banner("baaackaaab", tagline: "find")
    guard let pattern = cli.value("--find"), !pattern.isEmpty else {
        Console.error("--find needs a pattern, e.g. --find note.txt or --find '*.pdf'")
        exit(1)
    }
    let snapshot = cli.value("--snapshot") ?? "latest"
    let dests = destinationsForCommand()
    var anyHits = false
    let failures = forEachDestination(dests) { dest in
        let hits = try ResticBackend(destination: dest).find(pattern: pattern, snapshot: snapshot)
        if hits.isEmpty {
            Console.note("no match for '\(pattern)' in snapshot \(snapshot)")
            return true
        }
        anyHits = true
        for h in hits {
            let size = h.size.map { " (" + ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) + ")" } ?? ""
            let kind = h.type == "dir" ? "/" : ""
            Console.step("\(h.path)\(kind)\(size)")
        }
        return true
    }
    if anyHits {
        let destFlag = dests.count > 1 ? " --destination <name>" : ""
        Console.note("restore one with:  baaackaaab --restore --include <path above>\(destFlag)")
    }
    if failures > 0 {
        Console.error("\(failures)/\(dests.count) destination(s) could not be searched — see above")
        exit(1)
    }
}

/// One version of a file as it appeared in one snapshot: which snapshot, its
/// size, and its mtime there. The `--history` command's building block.
struct FileVersion {
    let snapshot: String
    let size: Int?
    let mtime: String?
}

/// Group `find`-results for a single file into one FileVersion per snapshot,
/// newest mtime first. `restic find` on a literal path yields at most one match
/// per snapshot, so this is really a re-sort; grouping is explicit so a future
/// glob pattern that DID match more than one path in a snapshot degrades to
/// "first match wins" instead of duplicate rows for that snapshot. Compares the
/// raw ISO8601 mtime strings restic emits rather than parsing them into Date —
/// same-host backups share the same format and UTC offset, so lexicographic
/// order is chronological order, and nothing else in this command needs a real
/// Date. Pure (no restic/argv access) — directly unit-testable.
func groupHistoryBySnapshot(_ found: [ResticBackend.Found]) -> [FileVersion] {
    var bySnapshot: [String: ResticBackend.Found] = [:]
    for f in found where bySnapshot[f.snapshot] == nil {
        bySnapshot[f.snapshot] = f
    }
    return bySnapshot.values
        .map { FileVersion(snapshot: $0.snapshot, size: $0.size, mtime: $0.mtime) }
        .sorted { ($0.mtime ?? "") > ($1.mtime ?? "") }
}

/// Show a file's version history across ALL snapshots (read-only): one line per
/// snapshot it appears in, newest first, with that version's size + mtime, per
/// destination. Complements `--find` (which locates a file within ONE
/// snapshot); `--history` spans every snapshot at once, so you can pick which
/// past version to restore.
func historyCommand() {
    Console.banner("baaackaaab", tagline: "history — file versions across snapshots")
    guard let path = cli.value("--history"), !path.isEmpty else {
        Console.error("--history needs a path, e.g. --history report.pdf or --history notes/todo.txt")
        exit(1)
    }
    let dests = destinationsForCommand()
    var anyVersions = false
    let failures = forEachDestination(dests) { dest in
        let hits = try ResticBackend(destination: dest).find(pattern: path, snapshot: nil)
        let versions = groupHistoryBySnapshot(hits)
        if versions.isEmpty {
            Console.note("no match for '\(path)' in any snapshot")
            return true
        }
        anyVersions = true
        for v in versions {
            let when = v.mtime.map { String($0.prefix(16)).replacingOccurrences(of: "T", with: " ") } ?? "unknown time"
            let size = v.size.map { " (" + ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) + ")" } ?? ""
            Console.step("\(v.snapshot.prefix(8))  \(when)\(size)")
        }
        return true
    }
    if anyVersions {
        let destFlag = dests.count > 1 ? " --destination <name>" : ""
        Console.note("restore a specific version with:  baaackaaab --restore --include \(path) --snapshot <id>\(destFlag)")
    }
    if failures > 0 {
        Console.error("\(failures)/\(dests.count) destination(s) could not be searched — see above")
        exit(1)
    }
}

/// Browse a snapshot's contents with `restic ls` (read-only), per destination
/// (or just `--destination <name>`). `--ls <id>` picks the snapshot (default
/// 'latest'); `--include <subpath>` limits to a subtree. The printed path is
/// exactly what `--restore --include` takes, so this doubles as restore discovery.
func lsCommand() {
    Console.banner("baaackaaab", tagline: "ls — browse a snapshot")
    let snapshot = cli.value("--ls") ?? "latest"
    let subpath = cli.value("--include")
    let dests = destinationsForCommand()
    let failures = forEachDestination(dests) { dest in
        let entries = try ResticBackend(destination: dest).ls(snapshot: snapshot, path: subpath)
        if entries.isEmpty {
            Console.note("nothing in snapshot \(snapshot)\(subpath.map { " under \($0)" } ?? "")")
            return true
        }
        // Cap the dump so a huge snapshot doesn't flood the terminal; say so
        // explicitly (never a silent truncation) and point at how to narrow it.
        let cap = 500
        for e in entries.prefix(cap) {
            let kind = e.type == "dir" ? "/" : ""
            let size = e.size.map { " (" + ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) + ")" } ?? ""
            Console.detail("\(e.path)\(kind)\(size)")
        }
        if entries.count > cap {
            Console.note("… and \(entries.count - cap) more (\(entries.count) entries total) — narrow with --include <subpath>")
        }
        return true
    }
    if failures > 0 {
        Console.error("\(failures)/\(dests.count) destination(s) could not be listed — see above")
        exit(1)
    }
}

/// Compare two snapshots with `restic diff` (read-only): what changed going from
/// the first id to the second. Acts on ONE repository, so it requires a single
/// `--destination <name>` when several are configured. Prints the changed paths
/// (+ added, - removed, M content, T type, U metadata) and the byte/file totals.
func diffCommand() {
    Console.banner("baaackaaab", tagline: "diff — compare two snapshots")
    guard let (a, b) = cli.pair("--diff"), !a.isEmpty, !b.isEmpty,
          !a.hasPrefix("-"), !b.hasPrefix("-") else {
        Console.error("--diff needs two snapshot ids: baaackaaab --diff <olderID> <newerID> (list ids with --snapshots)")
        exit(1)
    }
    let dest = requireSingleDestination(action: "diff compares two snapshots in a single repository")
    do {
        let r = try ResticBackend(destination: dest).diff(snapshotA: a, snapshotB: b)
        Console.step("\(a) → \(b)")
        if r.changes.isEmpty {
            Console.note("no path-level changes between these snapshots")
        } else {
            let cap = 1000
            for c in r.changes.prefix(cap) { Console.detail("\(c.modifier)  \(c.path)") }
            if r.changes.count > cap {
                Console.note("… and \(r.changes.count - cap) more (\(r.changes.count) changes total)")
            }
        }
        let added = ByteCountFormatter.string(fromByteCount: Int64(r.addedBytes), countStyle: .file)
        let removed = ByteCountFormatter.string(fromByteCount: Int64(r.removedBytes), countStyle: .file)
        Console.info([
            ("added", "\(r.addedFiles) file(s), \(added)"),
            ("removed", "\(r.removedFiles) file(s), \(removed)"),
            ("changed", "\(r.changedFiles) file(s)"),
        ])
    } catch {
        Console.error("\(error)")
        exit(1)
    }
}

/// The honest "what you actually got" note for a restored snapshot, keyed off its
/// source tag. A Photos restore returns the ORIGINAL exported files, NOT a
/// re-importable .photoslibrary; a Drive restore is a plain file tree to move
/// back. Said plainly so nobody expects a one-click reinstate.
func restoreSourceNote(_ tags: [String]) -> String {
    if tags.contains("photos") {
        return "these are your ORIGINAL photo/video files (JPEG/HEIC/MOV), not a .photoslibrary — open Photos.app and File > Import this folder to put them back"
    }
    if tags.contains("drive") {
        return "this is a fresh copy of your iCloud Drive files — move what you need back into iCloud Drive yourself; never restore in place"
    }
    return "this is a fresh copy — move what you need back into iCloud Drive / Photos yourself"
}

/// Short source label for the info block (Photos / Drive / mixed / unknown).
func restoreSourceLabel(_ tags: [String]) -> String {
    let photos = tags.contains("photos"), drive = tags.contains("drive")
    if photos && drive { return "mixed (iCloud Drive + Photos)" }
    if photos { return "iCloud Photos (original files, not a .photoslibrary)" }
    if drive { return "iCloud Drive (files)" }
    return "unknown"
}

/// Count regular files anywhere under `dir` (recursive). Distinguishes a restore
/// that actually wrote files from one that matched nothing yet still exited 0.
func regularFileCount(under dir: URL) -> Int {
    guard let en = FileManager.default.enumerator(
        at: dir, includingPropertiesForKeys: [.isRegularFileKey], options: []) else { return 0 }
    var n = 0
    for case let u as URL in en {
        if (try? u.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true { n += 1 }
    }
    return n
}

/// Restore a snapshot from ONE destination into a fresh directory. Safe by
/// construction (see RestoreEngine): the target is validated (never live iCloud
/// Drive / Photos, never an existing non-empty dir), the operation is previewed
/// with --dry-run, confirmed, and the restored files are re-read with --verify.
func restoreCommand() {
    Console.banner("baaackaaab", tagline: "restore")

    // Source = exactly one destination. With several configured we refuse to guess
    // which copy to restore from and require --destination.
    let all = resolveDestinationsOrExit()
    let dest: Destination
    if all.count == 1 && cli.value("--destination") == nil {
        dest = all[0]
    } else {
        let picked = destinationsForCommand()   // filtered by --destination, or all
        guard picked.count == 1 else {
            Console.error("several destinations configured — choose the source with --destination <name> (one of: \(all.map { $0.name }.joined(separator: ", ")))")
            exit(1)
        }
        dest = picked[0]
    }
    guard dest.passwordAvailable else {
        Console.error(noPasswordNote(for: dest.name))
        exit(1)
    }

    let snapshot = cli.value("--snapshot") ?? "latest"
    let include = cli.value("--include")
    let dryRun = cli.has("--dry-run")
    let verify = !cli.has("--no-verify")

    // Target: an explicit --target, else a fresh timestamped dir. Validated hard.
    let stampFmt = DateFormatter()
    stampFmt.locale = Locale(identifier: "en_US_POSIX")
    stampFmt.dateFormat = "yyyyMMdd-HHmmss"
    let stamp = stampFmt.string(from: Date())
    let target = cli.value("--target").map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        ?? RestoreEngine.defaultTarget(snapshot: snapshot, stamp: stamp)
    do { try RestoreEngine.validateTarget(target) }
    catch { Console.error("\(error)"); exit(1) }

    let backend = ResticBackend(destination: dest)
    // Resolve the chosen snapshot's tags (best-effort) to label the source and to
    // tailor the honest "what you got" note. For "latest" take the newest; else
    // match the short or full id.
    let restoredTags: [String] = {
        guard let snaps = try? backend.listSnapshots() else { return [] }
        if snapshot == "latest" { return snaps.first?.tags ?? [] }
        return snaps.first(where: { $0.shortID == snapshot || $0.id == snapshot || $0.id.hasPrefix(snapshot) })?.tags ?? []
    }()

    Console.info([
        ("destination", dest.name),
        ("snapshot", snapshot),
        ("source", restoreSourceLabel(restoredTags)),
        ("target", target.path),
        ("mode", include.map { "subpath \($0)" } ?? "full snapshot"),
        ("verify", verify ? "yes (re-reads restored files)" : "no"),
    ])

    // 1) Always preview with --dry-run first (shows exactly what would land). For a
    //    real --dry-run invocation, the preview IS the whole operation.
    Console.section(dryRun ? "Dry run (no files written)" : "Preview (dry run — nothing written yet)")
    do { try backend.restore(snapshot: snapshot, target: target, include: include, dryRun: true, verify: false) }
    catch { Console.error("restore preview failed: \(error)"); exit(1) }
    if dryRun {
        Console.success("dry run complete — nothing was written. Re-run without --dry-run to restore.")
        return
    }

    // 2) Confirm before writing. On a TTY, prompt; non-interactively, demand --yes
    //    so a scripted restore can't silently write gigabytes somewhere.
    if !cli.has("--yes") {
        guard isatty(STDIN_FILENO) != 0 else {
            Console.error("refusing to write a restore non-interactively without --yes — re-run with --yes, or --dry-run to preview only")
            exit(1)
        }
        FileHandle.standardOutput.write(Data("\nProceed with the restore into \(target.path)? [y/N] ".utf8))
        let answer = (readLine() ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        guard answer == "y" || answer == "yes" else {
            Console.note("restore cancelled — nothing was written")
            exit(0)
        }
    }

    // 3) Create the validated fresh dir, restore, verify.
    do {
        try RestoreEngine.ensureTargetDir(target)
        Console.section("Restoring")
        try backend.restore(snapshot: snapshot, target: target, include: include, dryRun: false, verify: verify)
    } catch {
        Console.error("restore failed: \(error)")
        exit(1)
    }

    // restic exits 0 even when an --include matched nothing — a mistyped subpath, or
    // a path whose glob metacharacters were escaped to a literal no file equals — so
    // it writes an empty tree and reports success. An empty target is a FAILED
    // restore, not a silent success: catch it and point at how to find the real path.
    if regularFileCount(under: target) == 0 {
        Console.summary(
            headline: "restore wrote no files — nothing in snapshot \(snapshot) matched\(include.map { " --include \($0)" } ?? "")",
            state: .fail,
            details: [
                ("target", target.path),
                ("next", include != nil
                    ? "copy an exact path from `baaackaaab --ls \(snapshot)` or `--find <name>` and pass it verbatim to --include"
                    : "the snapshot appears to have no files — check `baaackaaab --snapshots`"),
            ])
        exit(1)
    }

    Console.summary(
        headline: "restored \(snapshot) from \(dest.name) into a fresh directory\(verify ? " (verified)" : "")",
        state: .ok,
        details: [
            ("target", target.path),
            ("next", restoreSourceNote(restoredTags)),
        ])
}

/// Sampled test-restore: prove a destination's backup is actually RESTORABLE, not
/// just structurally intact. Restores a random, budget-bounded sample of files
/// from a snapshot into a throwaway temp dir WITH --verify (re-reads them against
/// the repo), confirms they landed non-empty, then deletes the temp dir. Stronger
/// than --verify-repo because it exercises the full read → decrypt → write →
/// re-verify path end to end. Strictly read-only towards the repository; writes
/// only to its own temp dir. Acts on ONE destination.
func testRestoreCommand() {
    Console.banner("baaackaaab", tagline: "test-restore — prove a backup is restorable")
    let snapshot = cli.value("--snapshot") ?? "latest"
    let sampleCount = cli.positiveInt("--sample", default: 10)
    let budget = cli.positiveInt("--max-bytes", default: 1_000_000_000, unit: "bytes")

    let dest = requireSingleDestination(action: "test-restore checks a single repository")
    let backend = ResticBackend(destination: dest)

    // 1) Enumerate the snapshot's files; pick a random, budget-bounded sample.
    let entries: [ResticBackend.LsEntry]
    do { entries = try backend.ls(snapshot: snapshot, path: nil) }
    catch { Console.error("could not list snapshot \(snapshot): \(error)"); exit(1) }
    let files = entries.filter { $0.type == "file" && ($0.size ?? 0) > 0 }
    guard !files.isEmpty else {
        Console.error("snapshot \(snapshot) has no non-empty files to test")
        exit(1)
    }
    var sample: [ResticBackend.LsEntry] = []
    var bytes = 0, skippedBudget = 0
    for f in files.shuffled() {
        if sample.count >= sampleCount { break }
        let sz = f.size ?? 0
        if !sample.isEmpty && bytes + sz > budget { skippedBudget += 1; continue }
        sample.append(f); bytes += sz
    }
    let sampledHuman = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    Console.step("sampling \(sample.count) of \(files.count) file(s) from snapshot \(snapshot) (\(sampledHuman))")
    if skippedBudget > 0 {
        let budgetHuman = ByteCountFormatter.string(fromByteCount: Int64(budget), countStyle: .file)
        Console.note("\(skippedBudget) file(s) skipped to stay under the \(budgetHuman) test budget (raise with --max-bytes)")
    }

    // 2) Throwaway temp target, auto-removed. Validated like any restore target
    //    (never live iCloud Drive / Photos), but it lives under the temp dir.
    let stampFmt = DateFormatter()
    stampFmt.locale = Locale(identifier: "en_US_POSIX")
    stampFmt.dateFormat = "yyyyMMdd-HHmmss"
    let target = FileManager.default.temporaryDirectory
        .appendingPathComponent("baaackaaab-test-restore-\(stampFmt.string(from: Date()))", isDirectory: true)
    do { try RestoreEngine.validateTarget(target); try RestoreEngine.ensureTargetDir(target) }
    catch { Console.error("\(error)"); exit(1) }
    // Cleanup on the normal return path. exit() does NOT unwind, so the two
    // failure exits below each remove the temp dir explicitly first (same
    // constraint as RestoreDrill).
    defer { try? FileManager.default.removeItem(at: target) }

    // 3) Restore the sample WITH --verify (restic re-reads each restored file
    //    against the repo). A non-zero exit means the backup is not cleanly
    //    restorable — that IS the test result.
    Console.step("restoring + verifying into a throwaway temp dir")
    let (code, out) = backend.restoreVerify(snapshot: snapshot, target: target, includes: sample.map { $0.path })
    if code != 0 {
        // restic can echo the repository location (which embeds the endpoint
        // password) into its diagnostics — redact before printing.
        for line in out.split(separator: "\n").suffix(8) { Console.detail(Credentials.redact(String(line))) }
        Console.summary(headline: "test-restore FAILED — restic exited \(code); the backup may not be cleanly restorable",
                        state: .fail, details: [("snapshot", snapshot), ("next", "investigate with --verify-repo; check the destination is reachable")])
        try? FileManager.default.removeItem(at: target)   // exit() skips the defer
        exit(1)
    }

    // 4) Belt-and-braces: restic recreates each file at target + its original
    //    absolute path; confirm each sampled file landed non-empty on disk.
    var present = 0
    var missing: [String] = []
    for f in sample {
        let landed = target.path + f.path   // f.path is absolute (leading /)
        let size = (try? FileManager.default.attributesOfItem(atPath: landed))
            .flatMap { ($0[.size] as? NSNumber)?.intValue } ?? 0
        if size > 0 { present += 1 } else { missing.append(f.path) }
    }
    if present == sample.count {
        Console.summary(
            headline: "test-restore PASSED — \(present)/\(sample.count) sampled file(s) restored and verified from \(dest.name)",
            state: .ok,
            details: [("snapshot", snapshot), ("sampled", sampledHuman), ("temp", "removed")])
    } else {
        for m in missing.prefix(10) { Console.detail("missing/empty after restore: \(m)") }
        Console.summary(
            headline: "test-restore FAILED — only \(present)/\(sample.count) sampled file(s) landed non-empty",
            state: .fail, details: [("snapshot", snapshot)])
        try? FileManager.default.removeItem(at: target)   // exit() skips the defer
        exit(1)
    }
}

/// Verify repository integrity with `restic check`, per destination (all, or just
/// `--destination <name>`). Structural by default; with `--read-data-subset <spec>`
/// it also re-reads that fraction of the pack data to catch on-disk bit-rot.
/// Strictly read-only — `check` never writes, prunes, or repairs. Exits non-zero
/// if any destination reports problems.
func verifyRepoCommand() {
    Console.banner("baaackaaab", tagline: "verify repository")
    let subset = cli.value("--read-data-subset")
    let dests = destinationsForCommand()
    let failures = forEachDestination(dests) { dest in
        if let subset {
            Console.step("checking structure + re-reading \(subset) of pack data — reads from the repo, can take a while")
        } else {
            Console.step("checking repository structure (add --read-data-subset <n%|n/t|nM> to also re-read pack data)")
        }
        let result = ResticBackend(destination: dest).checkRepo(readDataSubset: subset)
        if result.clean {
            Console.success("no errors found — repository is intact")
            return true
        } else if result.lockedOut {
            // Not a damage verdict — the repo is healthy but busy. Count it as a
            // non-pass (exit non-zero) but say so accurately, not "repair it".
            Console.warn("could not check '\(dest.name)' — the repository is locked (a backup or prune is in progress). This is NOT a damage verdict; retry when idle, or clear a stale lock with `--unlock --destination \(dest.name)`.")
            return false
        } else {
            Console.failure("restic check reported problems:")
            let lines = result.errorLines.isEmpty
                ? result.output.split(separator: "\n").map(String.init).suffix(10).map { $0 }
                : Array(result.errorLines.prefix(20))
            // restic may print the repository location (with the embedded
            // endpoint password) in its check output — redact each line.
            for line in lines { Console.detail(Credentials.redact(line)) }
            Console.note("a damaged repo is fixed SERVER-side (restic prune/repair runs with a delete-capable key on the host that owns the repo) — never from this Mac, which has no delete right.")
            return false
        }
    }
    if failures > 0 {
        Console.error("\(failures)/\(dests.count) destination(s) failed the integrity check — see above")
        exit(1)
    }
    Console.success("all \(dests.count) destination(s) passed the integrity check")
}

/// List and remove repository LOCKS for ONE destination — the single operation
/// baaackaaab runs that deletes from a repo. restic's `unlock` only ever removes
/// lock files (never a snapshot or pack), and by default only STALE locks (a dead
/// or >30-min-old locker); `--remove-all` clears every lock. Shows the locks, then
/// confirms before removing (or demands --yes non-interactively, since this writes).
func unlockCommand() {
    Console.banner("baaackaaab", tagline: "unlock — remove repository locks")
    let dest = requireSingleDestination(action: "unlock acts on a single repository at a time")
    let backend = ResticBackend(destination: dest)

    let (listCode, ids) = backend.listLockIDs()
    if listCode != 0 {
        Console.error("could not list locks — the repository is unreachable or the credentials are wrong (restic exit \(listCode))")
        exit(1)
    }
    if ids.isEmpty {
        Console.success("no locks present — nothing to remove")
        return
    }
    Console.step("\(ids.count) lock(s) present:")
    for id in ids {
        if let info = backend.lockInfo(id: id) {
            let when = String(info.time.prefix(19)).replacingOccurrences(of: "T", with: " ")
            let kind = info.exclusive ? "exclusive" : "shared"
            let pid = info.pid.map { " pid \($0)" } ?? ""
            Console.detail("\(id.prefix(8))  \(when)  \(info.username)@\(info.hostname)\(pid)  [\(kind)]")
        } else {
            Console.detail("\(id.prefix(8))  (lock metadata unreadable — it may have just been released)")
        }
    }

    let removeAll = cli.has("--remove-all")
    Console.section(removeAll ? "Remove ALL locks" : "Remove stale locks")
    if removeAll {
        Console.warn("--remove-all deletes EVERY lock, including one a backup that is genuinely running right now holds. Only do this when you are certain no backup or prune is in progress against this repo.")
    } else {
        Console.note("removes only STALE locks (a dead or >30-min-old locker); a lock a live backup holds is kept.")
    }
    Console.note("This is the ONLY operation that deletes from the repo, and it removes lock files only — never snapshots or data. On an append-only server the lock prefix must be carved out for this to succeed; if it is not, the server refuses (403) and nothing changes.")

    // Confirm — unlock deletes (lock files) from the repo, so gate it like restore.
    if !cli.has("--yes") {
        guard isatty(STDIN_FILENO) != 0 else {
            Console.error("refusing to remove locks non-interactively without --yes — re-run with --yes (or interactively to confirm)")
            exit(1)
        }
        FileHandle.standardOutput.write(Data("\nRemove \(removeAll ? "ALL" : "stale") lock(s) from \(dest.name)? [y/N] ".utf8))
        let answer = (readLine() ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        guard answer == "y" || answer == "yes" else {
            Console.note("cancelled — no locks were removed")
            exit(0)
        }
    }

    let (code, out) = backend.unlock(removeAll: removeAll)
    let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
    if code == 0 {
        // restic's unlock output can carry the repository location (and its
        // embedded endpoint password) — redact per line before surfacing it.
        if !trimmed.isEmpty {
            for line in trimmed.split(separator: "\n") { Console.detail(Credentials.redact(String(line))) }
        }
        Console.success(removeAll ? "unlock complete — all locks removed" : "unlock complete — stale lock(s) removed")
    } else {
        for line in trimmed.split(separator: "\n").suffix(8) { Console.detail(Credentials.redact(String(line))) }
        Console.error("unlock failed (restic exit \(code)). A 403/forbidden means the server's append-only mode does not carve out the lock prefix — locks can then only be cleared with a delete-capable key on the host. Nothing was changed.")
        exit(1)
    }
}

/// Free space (bytes) on the volume backing `url`, or nil if it can't be read.
/// Uses the plain available-capacity (≈ `df` available), NOT the "important
/// usage" capacity — the latter nets out purgeable space and routinely reports
/// ~0 on a volume that actually has tens of GB free, which would fire a false
/// "low disk" warning. Falls back to the raw statfs free size.
func freeBytes(at url: URL) -> Int64? {
    // The leaf (e.g. the staging dir) may not exist yet — walk up to the first
    // existing ancestor, which is on the same volume, so the reading still holds.
    var probe = url.standardizedFileURL
    let fm = FileManager.default
    while !fm.fileExists(atPath: probe.path) && probe.pathComponents.count > 1 {
        probe.deleteLastPathComponent()
    }
    if let v = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityKey]),
       let n = v.volumeAvailableCapacity {
        return Int64(n)
    }
    if let attrs = try? fm.attributesOfFileSystem(forPath: probe.path),
       let n = (attrs[.systemFreeSize] as? NSNumber)?.int64Value {
        return n
    }
    return nil
}

/// Consolidated, strictly read-only health check: restic binary + version, each
/// destination's reachability / snapshots / locks, free disk for staging, the
/// Photos (TCC) grant, and the scheduled-timer state. One place to answer "is
/// everything set up for the unattended backup to work?". Exits non-zero if any
/// blocking PROBLEM is found (no restic, an unreachable destination, a missing
/// key); warnings alone exit 0.
func doctorCommand() {
    Console.banner("baaackaaab", tagline: "doctor — consolidated health check")
    var problems = 0
    var warnings = 0

    Console.section("restic")
    if let version = ResticBackend.resticVersion(), let path = ResticBackend.locateExecutable() {
        Console.success(version)
        Console.detail(path)
    } else if let path = ResticBackend.locateExecutable() {
        Console.warn("found at \(path) but `restic version` failed — check the binary")
        warnings += 1
    } else {
        Console.failure("restic not found — install it (`brew install restic`); the backup cannot run without it")
        problems += 1
    }

    Console.section("Destinations")
    let dests = DestinationStore.all()
    if dests.isEmpty {
        Console.warn("none configured — run `--init-credentials` (first repo) or `--add-destination`")
        warnings += 1
    }
    for dest in dests {
        guard dest.passwordAvailable else {
            Console.failure("\(dest.name): " + noPasswordNote())
            problems += 1
            continue
        }
        let backend = ResticBackend(destination: dest)
        // Bounded existence probe first, so a dead destination is reported in ~60s
        // instead of hanging on restic's backend retries (remoteStatus is unbounded).
        guard backend.exists() else {
            Console.failure("\(dest.name): not reachable or not initialized — run `--check` (verifies DNS/auth and inits the repo)")
            problems += 1
            continue
        }
        let status = backend.remoteStatus()
        let size = status.sizeBytes.map { String(format: ", %.2f GB", Double($0) / 1_000_000_000) } ?? ""
        let latest = status.latestTime.map { String($0.prefix(16)).replacingOccurrences(of: "T", with: " ") } ?? "never"
        Console.success("\(dest.name): reachable — \(status.snapshotCount) snapshot(s)\(size), latest \(latest)")
        for src in status.sources where src.latestTime == nil {
            Console.detail("\(src.source): never backed up to this destination")
        }
        let (lockCode, lockIDs) = backend.listLockIDs()
        if lockCode == 0 && !lockIDs.isEmpty {
            Console.warn("\(dest.name): \(lockIDs.count) lock(s) present — if no backup is running, clear stale ones with `--unlock --destination \(dest.name)`")
            warnings += 1
        }
    }

    Console.section("Disk space")
    let home = FileManager.default.homeDirectoryForCurrentUser
    let stagingDefault = home.appendingPathComponent("Library/Caches/baaackaaab/staging", isDirectory: true)
    for (label, url) in [("home volume", home), ("staging", stagingDefault)] {
        guard let free = freeBytes(at: url) else {
            Console.detail("\(label): free space unknown (\(url.path))")
            continue
        }
        let gb = Double(free) / 1_000_000_000
        let line = "\(label): \(String(format: "%.1f", gb)) GB free  (\(url.path))"
        // A single photo batch needs ~3 GB of scratch; warn well above that.
        if free < 5_000_000_000 {
            Console.warn(line + " — low; a photo batch needs ~3 GB of scratch space")
            warnings += 1
        } else {
            Console.detail(line)
        }
    }

    Console.section("Photos access (TCC)")
    let photos = PhotosAcquirer.authorizationLabel()
    if photos.granted {
        Console.success("Photos: \(photos.label)")
    } else {
        Console.warn("Photos: \(photos.label)")
        warnings += 1
    }

    Console.section("Scheduled timer")
    let timer = LaunchdTimer.state()
    if timer.installed && timer.loaded {
        Console.success("backup timer: installed and loaded")
    } else if timer.installed {
        Console.warn("backup timer: installed but not loaded — re-run `--install-timer` to (re)load it")
        warnings += 1
    } else {
        Console.note("backup timer: not installed (optional) — `--install-timer` schedules a daily backup of the set")
    }
    let drillTimer = LaunchdTimer.drillState()
    if drillTimer.installed && drillTimer.loaded {
        Console.success("restore-drill timer: installed and loaded")
    } else if drillTimer.installed {
        Console.warn("restore-drill timer: installed but not loaded — re-run `--install-drill-timer` to (re)load it")
        warnings += 1
    } else {
        Console.note("restore-drill timer: not installed (optional) — `--install-drill-timer` schedules a monthly restore drill")
    }

    Console.section("Restore verification")
    if let last = RunHistory.lastDrill() {
        let (level, text) = DrillDashboard.line(lastDrill: last, now: Date())
        switch level {
        case .failed:
            Console.failure(text)
            problems += 1
        case .stale:
            Console.warn(text)
            warnings += 1
        default:
            Console.success(text)
        }
    } else {
        Console.warn("no restore drill has run yet — a backup that is never restore-tested is unproven; run `--restore-drill` (or `--install-drill-timer`)")
        warnings += 1
    }

    Console.section("Updates")
    // Offline baseline only: restic is read locally, the server via the best-effort
    // header probe against the host we already contacted above. No GitHub here —
    // `--check-updates` is the explicit online comparison.
    for finding in UpdateCheck.findings(primaryRepoURL: dests.first?.displayURL, online: false) {
        if finding.emit() { warnings += 1 }
    }
    Console.note("run `baaackaaab --check-updates` to compare against the latest upstream releases (contacts GitHub)")

    Console.section("Verdict")
    if problems > 0 {
        Console.failure("\(problems) problem(s), \(warnings) warning(s) — fix the problems above before relying on the backup")
        exit(1)
    }
    if warnings > 0 {
        Console.warn("\(warnings) warning(s), no blocking problems — review the warnings above")
        exit(0)
    }
    Console.success("all checks passed — the backup is ready to run")
}
