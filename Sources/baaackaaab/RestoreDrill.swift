import Foundation
#if canImport(Darwin)
import Darwin
#endif

// The restore drill institutionalizes restore verification: a scheduled,
// deterministic-but-rotating restore-verify of a small sample, recorded in
// RunHistory so the dashboard can show "last verified restore". A backup that is
// never restore-tested is hope, not a backup.
//
// Strictly read-only against the store (like --test-restore): it restores into a
// throwaway temp dir the caller deletes, and never writes to the repo — so it
// preserves the read + append-only invariant.

/// One snapshot the drill will sample-and-verify this run, with a human label for
/// the summary and (on failure) the "re-run this one by hand" hint.
struct DrillTarget: Equatable {
    let snapshotID: String   // short id to restore
    let kind: String         // "drive" | "photos"
    let label: String        // the covered folder path (drive) or batch tag (photos)
}

/// Pure sample-selection: which snapshots a drill exercises, rotating across
/// runs to sample the sources with variety. This is sampling, NOT a coverage
/// guarantee: candidates are ordered newest-first, so daily backups permute the
/// order between drills while the cursor advances by one — a reorder can
/// re-sample one source and delay another. Kept free of I/O so the rotation is
/// unit-testable.
enum DrillPlan {
    /// Deterministic rotating pick from `items`, advancing by the count of
    /// prior drills. Full coverage only holds while the candidate order is
    /// stable between drills (see type comment). nil when empty (that source
    /// type isn't configured / has no snapshots yet).
    static func rotate<T>(_ items: [T], priorDrills: Int) -> T? {
        guard !items.isEmpty else { return nil }
        return items[((priorDrills % items.count) + items.count) % items.count]
    }

    /// Derive the rotating candidates from a repo's snapshots (NEWEST-FIRST, as
    /// `listSnapshots()` returns). Drive: the latest snapshot per distinct covered
    /// path — one drill unit per backed-up folder. Photos: each photo-batch
    /// snapshot, labelled by its batch tag. Order is stable so the rotation cursor
    /// is meaningful.
    static func candidates(from snapshots: [ResticBackend.Snapshot])
        -> (drive: [DrillTarget], photos: [DrillTarget]) {
        var drive: [DrillTarget] = []
        var seenPaths = Set<String>()
        var photos: [DrillTarget] = []
        for s in snapshots {
            if s.tags.contains("drive") {
                for p in s.paths where !seenPaths.contains(p) {
                    seenPaths.insert(p)
                    drive.append(DrillTarget(snapshotID: s.shortID, kind: "drive", label: p))
                }
            } else if s.tags.contains("photos") {
                let batch = s.tags.first { $0.hasPrefix("batch-") }
                photos.append(DrillTarget(snapshotID: s.shortID, kind: "photos",
                                          label: batch.map { "photos \($0)" } ?? "photos \(s.shortID)"))
            }
        }
        return (drive, photos)
    }

    /// The sample for one drill: one drive folder + one photo batch (whichever
    /// exist), rotated by `priorDrills`. Empty when the repo has no snapshots yet.
    static func select(from snapshots: [ResticBackend.Snapshot], priorDrills: Int) -> [DrillTarget] {
        let c = candidates(from: snapshots)
        var out: [DrillTarget] = []
        if let d = rotate(c.drive, priorDrills: priorDrills) { out.append(d) }
        if let p = rotate(c.photos, priorDrills: priorDrills) { out.append(p) }
        return out
    }

    /// Throwaway restore target under the user cache dir — sibling of the staging
    /// scratch, on the roomy home volume rather than a small $TMPDIR. The caller's
    /// defer removes it even on failure.
    static func tempTarget(stamp: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/baaackaaab/drill-\(stamp)", isDirectory: true)
    }
}

/// Pure rendering decision for the dashboard's "last verified restore" line: the
/// verdict level (which drives red/yellow/dim styling at the call site) and the
/// age-bearing text, derived from the newest drill record. Never hardcoded — a
/// failed drill is red regardless of age, an old pass goes yellow (overdue), a
/// fresh pass is dim, and "never run" is dim.
enum DrillDashboard {
    enum Level: Equatable { case none, ok, stale, failed }

    /// A monthly drill plus a grace window: past this many days a passing drill is
    /// "overdue" (yellow).
    static let overdueDays = 45

    static func line(lastDrill: RunRecord?, now: Date, overdueDays: Int = overdueDays)
        -> (level: Level, text: String) {
        guard let d = lastDrill else {
            return (.none, "no restore drill yet — run `baaackaaab --restore-drill` to prove a backup restores")
        }
        let days = Int(now.timeIntervalSince(d.end) / 86_400)
        let age = days <= 0 ? "today" : "\(days)d ago"
        if !d.clean {
            return (.failed, "restore drill FAILED \(age) — a backup that won't restore is not a backup; run `--restore-drill`")
        }
        if days >= overdueDays {
            return (.stale, "last restore drill \(age) — overdue (monthly); run `--restore-drill`")
        }
        return (.ok, "last restore drill \(age) — verified restorable")
    }
}

/// Scheduled restore drill (CLI wrapper — exits the process, so the testable
/// logic lives in the pure `DrillPlan` / `DrillDashboard` above). Picks a
/// rotating sample, restore-verifies it into a throwaway temp dir, records the
/// outcome in RunHistory with a distinct `kind`, and banners only on failure.
func restoreDrillCommand() {
    Console.banner("baaackaaab", tagline: "restore drill — scheduled proof a backup restores")
    let sampleCount = cli.positiveInt("--sample", default: 5)
    let budget = cli.positiveInt("--max-bytes", default: 500_000_000, unit: "bytes")

    // One destination: the named --destination, else the primary. Under launchd
    // (no --destination) this drills the primary copy rather than failing on a
    // multi-destination setup.
    let all = resolveDestinationsOrExit()
    let dest: Destination
    if let name = cli.value("--destination") {
        guard let match = all.first(where: { $0.name == name }) else {
            Console.error("no enabled destination named '\(name)' — configured: \(all.map { $0.name }.joined(separator: ", "))")
            exit(1)
        }
        dest = match
    } else {
        dest = all[0]
        if all.count > 1 {
            Console.note("several destinations configured — drilling the primary '\(dest.name)'; pass --destination to pick another")
        }
    }
    Console.section("Destination", detail: "\(dest.name) [\(dest.link)]")
    guard dest.passwordAvailable else { Console.error(noPasswordNote(for: dest.name)); exit(1) }
    let backend = ResticBackend(destination: dest)

    // Rotating sample: one drive folder + one photo batch, advancing across runs.
    let snaps: [ResticBackend.Snapshot]
    do { snaps = try backend.listSnapshots() }
    catch { Console.error("could not list snapshots for the drill: \(error)"); exit(1) }
    let priorDrills = RunHistory.drillCount()
    let targets = DrillPlan.select(from: snaps, priorDrills: priorDrills)
    guard !targets.isEmpty else {
        // Nothing to restore yet is not a drill failure — report and exit 0 without
        // recording a run (there was no restore to verify).
        Console.summary(headline: "no snapshots to drill yet — run a backup first, then the drill has something to restore",
                        state: .warn, details: [("destination", dest.name)])
        exit(0)
    }

    let stampFmt = DateFormatter()
    stampFmt.locale = Locale(identifier: "en_US_POSIX")
    stampFmt.dateFormat = "yyyyMMdd-HHmmss"
    let runStart = Date()
    let tempRoot = DrillPlan.tempTarget(stamp: stampFmt.string(from: runStart))
    do { try RestoreEngine.validateTarget(tempRoot); try RestoreEngine.ensureTargetDir(tempRoot) }
    catch { Console.error("\(error)"); exit(1) }
    // Cleanup on the normal return path. The failure path below exits the
    // process — exit() does NOT unwind, so defer alone would leak the temp dir
    // there; the failure branch removes it explicitly before exit(1).
    defer { try? FileManager.default.removeItem(at: tempRoot) }

    Console.step("drilling \(targets.count) sampled snapshot(s) into a throwaway temp dir (rotation #\(priorDrills + 1))")
    var verifiedFiles = 0, sampledFiles = 0, totalBytes = 0
    var testedSnapshots: [String] = []
    var failures: [(target: DrillTarget, detail: String)] = []
    for target in targets {
        testedSnapshots.append(target.snapshotID)
        let sub = tempRoot.appendingPathComponent(target.snapshotID, isDirectory: true)
        let r = drillVerify(backend: backend, target: target, sampleCount: sampleCount, budget: budget, into: sub)
        sampledFiles += r.sampled; verifiedFiles += r.present; totalBytes += r.bytes
        if r.ok {
            Console.success("\(target.kind) [\(target.label)] @ \(target.snapshotID): \(r.detail)")
        } else {
            Console.failure("\(target.kind) [\(target.label)] @ \(target.snapshotID): \(r.detail)")
            failures.append((target, r.detail))
        }
    }

    let ok = failures.isEmpty
    let sampledHuman = ByteCountFormatter.string(fromByteCount: Int64(totalBytes), countStyle: .file)

    // Actionable "what next": name the failing snapshot and the exact manual re-run.
    let firstFail = failures.first?.target
    let next = ok
        ? "next drill rotates to the following source automatically"
        : "re-run this snapshot by hand: `baaackaaab --test-restore --snapshot \(firstFail?.snapshotID ?? "<id>") --destination \(dest.name)`; if it fails again the copy may be damaged — check with `baaackaaab --verify-repo --destination \(dest.name)` (repairs are server-side)"

    // Record the drill with a distinct kind so it never counts as a backup run.
    let record = RunRecord(
        runTag: "drill", start: runStart, end: Date(),
        exitCode: ok ? 0 : 2, verified: verifiedFiles, total: sampledFiles, sourceFailures: 0,
        destinations: [RunRecord.Dest(
            name: dest.name, ok: ok,
            error: ok ? nil : failures.map { "\($0.target.kind) [\($0.target.label)]: \($0.detail)" }.joined(separator: "; "))],
        kind: "drill", bytes: totalBytes, snapshots: testedSnapshots)
    try? RunHistory.append(record)

    if ok {
        Console.summary(
            headline: "restore drill PASSED — \(verifiedFiles)/\(sampledFiles) sampled file(s) restored and verified from \(dest.name)",
            state: .ok,
            details: [("snapshots", testedSnapshots.joined(separator: ", ")),
                      ("sampled", sampledHuman), ("temp", "removed"), ("next", next)])
    } else {
        Console.summary(
            headline: "restore drill FAILED — \(verifiedFiles)/\(sampledFiles) verified; \(failures.count) sampled snapshot(s) did not restore cleanly",
            state: .fail,
            details: [("snapshots", testedSnapshots.joined(separator: ", ")), ("next", next)])
        // Reuse the unattended failure-banner path: fire ONLY when our output is
        // invisible (launchd / piped), the same gate BackupRun uses — an
        // interactive run already shows the summary on screen.
        if isatty(STDERR_FILENO) == 0 {
            Notifier.notify(title: "baaackaaab \u{2014} restore drill failed",
                            message: "\(failures.count) sampled snapshot(s) did not restore — \(next)",
                            subtitle: "restore drill")
        }
        // exit() skips defer — remove the (up to 500 MB) sample explicitly, or
        // every failed unattended drill would pile it up under Caches.
        try? FileManager.default.removeItem(at: tempRoot)
        exit(1)
    }
}

/// Restore + byte-verify a random, budget-bounded sample of one snapshot into
/// `sub`. Mirrors --test-restore's machinery: ls → sample → `restic restore
/// --verify` → confirm each file landed non-empty. Read-only towards the repo;
/// the caller owns (and deletes) the enclosing temp dir.
private func drillVerify(backend: ResticBackend, target: DrillTarget,
                         sampleCount: Int, budget: Int, into sub: URL)
    -> (ok: Bool, sampled: Int, present: Int, bytes: Int, detail: String) {
    let entries: [ResticBackend.LsEntry]
    do { entries = try backend.ls(snapshot: target.snapshotID, path: nil) }
    catch { return (false, 0, 0, 0, "could not list snapshot: \(error)") }
    let files = entries.filter { $0.type == "file" && ($0.size ?? 0) > 0 }
    guard !files.isEmpty else { return (false, 0, 0, 0, "snapshot has no non-empty files to sample") }

    var sample: [ResticBackend.LsEntry] = []
    var bytes = 0
    for f in files.shuffled() {
        if sample.count >= sampleCount { break }
        let sz = f.size ?? 0
        if !sample.isEmpty && bytes + sz > budget { continue }
        sample.append(f); bytes += sz
    }

    do { try RestoreEngine.validateTarget(sub); try RestoreEngine.ensureTargetDir(sub) }
    catch { return (false, sample.count, 0, bytes, "could not create temp dir: \(error)") }

    let (code, out) = backend.restoreVerify(snapshot: target.snapshotID, target: sub, includes: sample.map { $0.path })
    if code != 0 {
        // restic can echo the repository location (which embeds the endpoint
        // password) into its diagnostics — redact before surfacing.
        let tail = out.split(separator: "\n").suffix(3).map { Credentials.redact(String($0)) }.joined(separator: " | ")
        return (false, sample.count, 0, bytes, "restic exited \(code) — \(tail)")
    }
    var present = 0
    for f in sample {
        let landed = sub.path + f.path   // f.path is absolute (leading /)
        let size = (try? FileManager.default.attributesOfItem(atPath: landed))
            .flatMap { ($0[.size] as? NSNumber)?.intValue } ?? 0
        if size > 0 { present += 1 }
    }
    let ok = present == sample.count
    return (ok, sample.count, present, bytes,
            ok ? "\(present)/\(sample.count) file(s) restored + verified"
               : "only \(present)/\(sample.count) file(s) landed non-empty after restore")
}
