import Foundation
#if canImport(Darwin)
import Darwin
#endif

// The scheduled integrity check institutionalizes bit-rot detection. Each run
// re-reads one fixed fraction (1/t) of the pack data with `restic check
// --read-data-subset i/t`, advancing the slice `i` every run so that after `t`
// runs every pack has been re-read once. This is the on-disk corruption detector
// the restore drill cannot be: the drill proves a SAMPLE decrypts + restores, the
// rotating check re-hashes ALL bytes over time. Strictly read-only — `restic
// check` never writes, prunes, or repairs — so it preserves the append-only
// invariant.

/// Pure rotation arithmetic for the read-data slice. Kept free of I/O so the
/// advance/wrap/first-run behaviour is unit-testable.
enum RotatingCheck {
    /// Number of read-data slices. After this many rotating checks every pack has
    /// been re-read once. Fixed (not configurable) so the rotation cursor stored in
    /// the history stays meaningful across runs.
    static let slices = 8

    /// The 1-based slice the next rotating check should cover, advancing from the
    /// last recorded slice and wrapping at `slices`. No prior check (nil) starts at
    /// slice 1; an out-of-range stored value is clamped back into 1…slices first,
    /// so a hand-mangled history can never produce an invalid restic subset.
    static func nextSlice(lastSlice: Int?, slices: Int = slices) -> Int {
        guard slices > 0 else { return 1 }
        guard let last = lastSlice else { return 1 }
        let clamped = ((last - 1) % slices + slices) % slices + 1   // fold last into 1…slices
        return clamped % slices + 1
    }

    /// The restic `--read-data-subset` spec for a 1-based slice (e.g. "3/8").
    static func subsetSpec(slice: Int, slices: Int = slices) -> String {
        "\(slice)/\(slices)"
    }
}

/// Pure rendering decision for the dashboard's "last integrity check" line: the
/// verdict level (red on a failed check, dim otherwise) and the age + slice
/// position text. Age display only — no overdue judgment (a rotating check has no
/// single cadence to violate; the slice position already shows coverage progress).
enum CheckDashboard {
    enum Level: Equatable { case none, ok, failed }

    static func line(lastCheck: RunRecord?, now: Date) -> (level: Level, text: String) {
        guard let c = lastCheck else {
            return (.none, "no integrity check yet — install one with `baaackaaab --install-check-timer`")
        }
        let days = Int(now.timeIntervalSince(c.end) / 86_400)
        let age = days <= 0 ? "today" : "\(days)d ago"
        let pos = c.slice.map { RotatingCheck.subsetSpec(slice: $0) } ?? "?/\(RotatingCheck.slices)"
        if !c.clean {
            return (.failed, "integrity check \(pos) FAILED \(age) — run `baaackaaab --verify-repo` to inspect")
        }
        return (.ok, "integrity check \(pos) \u{00B7} \(age)")
    }
}

/// The rotating integrity-check run (`--verify-repo --rotate-read-data`, what the
/// check timer invokes). Advances the read-data slice from the last recorded
/// check, runs `restic check --read-data-subset i/t` per destination, records a
/// "check" history record carrying the slice + per-destination outcome, and
/// banners only on failure (the unattended log goes unread). Exits the process.
func rotatingCheckCommand() {
    Console.banner("baaackaaab", tagline: "integrity check — rotating read-data")
    let runStart = Date()
    let slice = RotatingCheck.nextSlice(lastSlice: RunHistory.lastCheck()?.slice)
    let subset = RotatingCheck.subsetSpec(slice: slice)
    let dests = destinationsForCommand()

    // Hold off IDLE system sleep for the duration of the re-read (it can be long).
    // A lid close still sleeps the machine; released on scope exit / process exit.
    let sleepHold = SleepHold(reason: "baaackaaab backup in progress")
    defer { sleepHold.release() }

    Console.step("rotating read-data slice \(subset) — re-reads 1/\(RotatingCheck.slices) of pack data this run; full coverage every \(RotatingCheck.slices) runs")

    var destResults: [RunRecord.Dest] = []
    var failures = 0
    for dest in dests {
        Console.section("Destination", detail: "\(dest.name) [\(dest.link)]")
        guard dest.passwordAvailable else {
            Console.failure(noPasswordNote(for: dest.name))
            destResults.append(RunRecord.Dest(name: dest.name, ok: false, error: "no encryption password"))
            failures += 1
            continue
        }
        Console.step("checking structure + re-reading \(subset) of pack data — reads from the repo, can take a while")
        let result = ResticBackend(destination: dest).checkRepo(readDataSubset: subset)
        if result.clean {
            Console.success("no errors found — slice \(subset) re-read OK")
            destResults.append(RunRecord.Dest(name: dest.name, ok: true, error: nil))
        } else if result.lockedOut {
            // Healthy but busy — a non-pass, but not a damage verdict.
            Console.warn("could not check '\(dest.name)' — the repository is locked (a backup or prune is in progress). NOT a damage verdict; the next scheduled slice retries. Clear a stale lock with `--unlock --destination \(dest.name)`.")
            destResults.append(RunRecord.Dest(name: dest.name, ok: false, error: "locked — the check could not run"))
            failures += 1
        } else {
            Console.failure("restic check reported problems:")
            let lines = result.errorLines.isEmpty
                ? result.output.split(separator: "\n").map(String.init).suffix(10).map { $0 }
                : Array(result.errorLines.prefix(20))
            for line in lines { Console.detail(Credentials.redact(line)) }
            Console.note("a damaged repo is fixed SERVER-side (restic prune/repair with a delete-capable key on the host) — never from this Mac, which has no delete right.")
            let firstError = result.errorLines.first.map { Credentials.redact($0) } ?? "restic check reported problems"
            destResults.append(RunRecord.Dest(name: dest.name, ok: false, error: firstError))
            failures += 1
        }
    }

    let ok = failures == 0
    // Record the check with a distinct kind so it never counts as a backup run,
    // carrying the slice so the next run advances the rotation and the dashboard
    // shows the coverage position.
    let record = RunRecord(
        runTag: "check", start: runStart, end: Date(),
        exitCode: ok ? 0 : 2, verified: dests.count - failures, total: dests.count,
        sourceFailures: 0, destinations: destResults, kind: "check", slice: slice)
    try? RunHistory.append(record)

    if ok {
        Console.success("all \(dests.count) destination(s) passed the rotating integrity check (slice \(subset))")
        exit(0)
    }
    // Unattended failure banner, same gate the drill / backup failure path uses:
    // fire ONLY when our output is invisible (launchd / piped).
    if isatty(STDERR_FILENO) == 0 {
        Notifier.notify(title: "baaackaaab \u{2014} integrity check failed",
                        message: "\(failures)/\(dests.count) destination(s) failed slice \(subset) — run `baaackaaab --verify-repo`",
                        subtitle: "integrity check")
    }
    Console.error("\(failures)/\(dests.count) destination(s) failed the rotating integrity check (slice \(subset)) — see above")
    exit(1)
}
