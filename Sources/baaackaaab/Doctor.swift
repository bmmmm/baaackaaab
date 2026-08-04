import Foundation
#if canImport(Darwin)
import Darwin
#endif

// `--doctor`: the consolidated health check, extracted verbatim from
// ReadCommands.swift (its section order and problem/warning accumulation are
// the observable contract — the exit code is `problems > 0`). `freeBytes`
// lives here because doctor's disk-space section is its only caller.

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
        // The operator writes transport-env by hand (unlike the url/password
        // files this tool creates 0600 itself), so doctor is where a too-open
        // copy gets caught. Checked before reachability — a loose credential
        // file matters even while the destination is down.
        let transportEnvFile = DestinationStore.transportEnvFile(dest.name)
        if let attrs = try? FileManager.default.attributesOfItem(atPath: transportEnvFile.path),
           let perms = attrs[.posixPermissions] as? NSNumber, perms.uint16Value & 0o077 != 0 {
            Console.warn("\(dest.name): transport-env is group/world-readable — it holds backend credentials; tighten it with `chmod 600 \(transportEnvFile.path)`")
            warnings += 1
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

    Console.section("Append-only enforcement")
    Console.note("actively probes each rest: destination — the single most on-point safety check, since a server accidentally started WITHOUT --append-only looks identical to a correct one to every other check above")
    let enabledDests = dests.filter { $0.enabled }
    if enabledDests.isEmpty {
        Console.note("no enabled destinations to probe")
    }
    for dest in enabledDests {
        guard let repoURL = dest.displayURL else {
            Console.warn("\(dest.name): repo URL unreadable — cannot determine the backend, skipping the append-only probe")
            warnings += 1
            continue
        }
        guard let target = AppendOnlyProbe.target(from: repoURL) else {
            // Mechanism named per backend (verified 2026-08, issue #20): AWS S3
            // can enforce append-only via IAM; Cloudflare R2 tokens have no
            // action-level scoping (Object Read & Write includes DeleteObject,
            // no Object Lock), so there the honest story is credential
            // separation only — mirror that instead of implying enforcement.
            Console.note("\(dest.name): not a rest: destination — append-only cannot be verified at the protocol level here; enforce immutability at the storage layer. AWS S3: IAM policy denying s3:DeleteObject except locks/* (keeps --unlock working). Cloudflare R2: tokens cannot deny deletes — protection is credential separation only, keep delete-capable keys off this Mac.")
            continue
        }
        let verdict = AppendOnlyProbe.probe(target)
        switch verdict {
        case .enforced:
            Console.success("\(dest.name): \(verdict.message)")
        case .notEnforced:
            Console.failure("\(dest.name): \(verdict.message)")
            problems += 1
        case .authProblem, .inconclusive:
            Console.warn("\(dest.name): \(verdict.message)")
            warnings += 1
        case .unreachable:
            Console.note("\(dest.name): \(verdict.message)")
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
    let checkTimer = LaunchdTimer.checkState()
    if checkTimer.installed && checkTimer.loaded {
        Console.success("integrity-check timer: installed and loaded")
    } else if checkTimer.installed {
        Console.warn("integrity-check timer: installed but not loaded — re-run `--install-check-timer` to (re)load it")
        warnings += 1
    } else {
        Console.note("integrity-check timer: not installed (optional) — `--install-check-timer` schedules a rotating read-data check")
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

    Console.section("Integrity check")
    if let lastCheck = RunHistory.lastCheck() {
        let (level, text) = CheckDashboard.line(
            lastCheck: lastCheck, now: Date(),
            interval: LaunchdTimer.installedCheckSchedule()?.intendedInterval())
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
        Console.note("no integrity check has run yet — `--install-check-timer` schedules a rotating read-data check that re-hashes 1/8 of the pack data per run (bit-rot detection)")
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
