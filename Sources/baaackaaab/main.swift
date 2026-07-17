import Foundation
#if canImport(Darwin)
import Darwin
#endif

// baaackaaab acquisition prototype.
//
// One direction only: read iCloud Drive + Photos originals, verify the real
// bytes landed, stage them. Never writes back to the user's data. A separate
// shell step then hands the verified staging tree to restic.

/// Reject an unrecognized token before it can fall through to a backup. The
/// dispatch below matches specific flags and, finding none, backs up the set — so
/// a typo'd command (`--snapshtos`, or a bare `check` for `--check`) would
/// otherwise silently start a full backup instead of failing. The classification
/// is in `CLIArguments.unknownArgument` (pure + unit-tested); this wraps it with
/// the process exit.
func rejectUnknownFlags() {
    if let err = CLIArguments.unknownArgument(in: cli.tokens) {
        Console.error(err)
        exit(1)
    }
}

// Line-buffer stdout so our logs interleave in the right order with restic's
// child-process output. Without this, our print() output buffers and surfaces
// only after the subprocess has already written (and a file redirect would be
// block-buffered, scrambling the order entirely).
setvbuf(stdout, nil, _IOLBF, 0)

// Navigation: usage on --help/-h. A bare invocation (no args) drops into the
// interactive command center when on a real terminal, but still prints usage
// when piped / under launchd (no TTY) — the launchd timer always passes
// --run-tag, so it never lands here. The center launch itself happens below,
// after the config path is resolved.
let bareInteractive = cli.count == 1
    && isatty(STDIN_FILENO) != 0 && isatty(STDOUT_FILENO) != 0
if cli.has("--help") || cli.has("-h")
    || (cli.count == 1 && !bareInteractive) {
    printUsage()
    exit(0)
}

// Reject an unknown flag up front, before any dispatch — a typo must fail loudly,
// never fall through to a backup of the set.
rejectUnknownFlags()

// Standalone diagnostic: prove the evict/dataless round-trip on one file.
// Runs in isolation and exits — never touches staging or the normal flow.
if let evictTarget = cli.value("--evict-test") {
    do {
        try DriveAcquirer().evictRoundTripTest(URL(fileURLWithPath: evictTarget))
        exit(0)
    } catch {
        Console.error("\(error)")
        exit(1)
    }
}

if let matTarget = cli.value("--materialize-test") {
    do {
        try DriveAcquirer().materializeTest(URL(fileURLWithPath: matTarget))
        exit(0)
    } catch {
        Console.error("\(error)")
        exit(1)
    }
}

// First-run setup: generate + store both secrets, print the server hash.
if cli.has("--init-credentials") {
    do { try initCredentials(); exit(0) }
    catch { Console.error("\(error)"); exit(1) }
}

// One-time migration: move existing Keychain secrets into the 0600 file store.
if cli.has("--migrate-credentials") {
    do { try migrateCredentials(); exit(0) }
    catch { Console.error("\(error)"); exit(1) }
}

// Connectivity + auth + repo-init check, then exit.
if cli.has("--check") {
    checkRemote()
    exit(0)
}

// --read-data-subset / --rotate-read-data only have meaning with --verify-repo; on
// their own they would be silently ignored and the run would fall through to a
// backup. Fail loudly.
if cli.value("--read-data-subset") != nil && !cli.has("--verify-repo") {
    Console.error("--read-data-subset only applies to --verify-repo — re-run as `baaackaaab --verify-repo --read-data-subset <n%|n/t|nM>`")
    exit(1)
}
if cli.has("--rotate-read-data") && !cli.has("--verify-repo") {
    Console.error("--rotate-read-data only applies to --verify-repo — re-run as `baaackaaab --verify-repo --rotate-read-data` (this is what the integrity-check timer runs)")
    exit(1)
}

// Repository integrity check (`restic check`), read-only. With --rotate-read-data
// it advances a read-data slice (1/8 of the pack data per run) and records a
// "check" history entry — the scheduled bit-rot detector. Otherwise it is the
// manual structural check (plus an optional --read-data-subset), unchanged.
if cli.has("--verify-repo") {
    if cli.has("--rotate-read-data") { rotatingCheckCommand() }
    else { verifyRepoCommand() }
    exit(0)
}

// Remove repository locks (the only delete op). Lists locks, confirms, then runs
// `restic unlock` (stale only, or --remove-all). Removes lock files only.
if cli.has("--unlock") {
    unlockCommand()
    exit(0)
}

// Consolidated read-only health check (restic, destinations, disk, Photos, timer).
if cli.has("--doctor") {
    doctorCommand()
    exit(0)
}

// Compare the installed restic CLI + REST server against the latest upstream
// releases (the one path that contacts GitHub; falls back to the pinned baseline
// when offline). Read-only, never writes; always exits 0.
if cli.has("--check-updates") {
    updateCheckCommand()
    exit(0)
}

// Read-only snapshot browser (restore starts here: pick a snapshot's short id).
if cli.has("--snapshots") {
    listSnapshotsCommand()
    exit(0)
}

// Locate a file inside a snapshot by name/glob (single-file restore discovery).
// Dispatch on the flag's PRESENCE, not on a non-nil value: `--find` with no
// pattern (a forgotten argument) must route into findCommand and fail loudly
// there, never fall through the dispatch chain to a full backup of the set.
if cli.has("--find") {
    findCommand()
    exit(0)
}

// Browse a snapshot's contents (read-only). The listed paths feed --restore --include.
// `--ls` with no id is valid (defaults to the latest snapshot); dispatch on
// presence so a bare `--ls` browses latest instead of falling through to a backup.
if cli.has("--ls") {
    lsCommand()
    exit(0)
}

// Compare two snapshots (read-only): what changed between them.
if cli.has("--diff") {
    diffCommand()
    exit(0)
}

// Restore a snapshot into a fresh directory (safe by construction). Previews,
// confirms, restores, verifies. Never writes into live iCloud Drive / Photos.
if cli.has("--restore") {
    restoreCommand()
    exit(0)
}

// Sampled test-restore: prove a backup is restorable by restoring a random
// sample into a throwaway temp dir + verify, then deleting it. Read-only on the repo.
if cli.has("--test-restore") {
    testRestoreCommand()
    exit(0)
}

// Scheduled restore drill: restore-verify a deterministic-but-rotating sample
// into a throwaway temp dir, record the outcome (distinct kind), banner only on
// failure. Read-only on the repo — the monthly drill timer invokes exactly this.
if cli.has("--restore-drill") {
    restoreDrillCommand()
    exit(0)
}

// Destination management (read-only list / add / remove), then exit. These edit
// only the local store; remove never touches remote data.
if cli.has("--list-destinations") {
    listDestinations()
    exit(0)
}
// Dispatch on presence and validate the value inside: `--add-destination` /
// `--remove-destination` with a missing name must fail loudly here, never skip
// the dispatch and fall through to a backup of the set.
if cli.has("--add-destination") {
    guard let name = cli.value("--add-destination"), !name.isEmpty else {
        Console.error("--add-destination needs a name, e.g. --add-destination offsite")
        exit(1)
    }
    addDestination(name: name)
    exit(0)
}
if cli.has("--remove-destination") {
    guard let name = cli.value("--remove-destination"), !name.isEmpty else {
        Console.error("--remove-destination needs a name — list the configured ones with --list-destinations")
        exit(1)
    }
    removeDestination(name: name)
    exit(0)
}

// Resolve the backup-set config path (override with --config, e.g. for tests).
let configPath: URL = cli.value("--config").map {
    URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath)
} ?? BackupSet.defaultPath()

// Scheduled-backup launchd timer. Installs/removes a per-user LaunchAgent that
// runs `baaackaaab --run-tag scheduled` (non-bare, so it backs up the set under
// launchd without a TTY). These touch the user's launchd, not the repo.
if cli.has("--install-timer") {
    do { try LaunchdTimer.install(schedule: cli.schedule(), configPath: configPath); exit(0) }
    catch { Console.error("\(error)"); exit(1) }
}
if cli.has("--uninstall-timer") {
    do { try LaunchdTimer.uninstall(); exit(0) }
    catch { Console.error("\(error)"); exit(1) }
}
if cli.has("--timer-status") {
    LaunchdTimer.status()
    exit(0)
}

// Monthly restore-drill launchd timer. Installs/removes a per-user LaunchAgent
// that runs `baaackaaab --restore-drill` on the configured day-of-month. Separate
// from the backup timer (own label + plist), so the two schedules are independent.
if cli.has("--install-drill-timer") {
    do { try LaunchdTimer.installDrill(schedule: cli.drillSchedule()); exit(0) }
    catch { Console.error("\(error)"); exit(1) }
}
if cli.has("--uninstall-drill-timer") {
    do { try LaunchdTimer.uninstallDrill(); exit(0) }
    catch { Console.error("\(error)"); exit(1) }
}

// Rotating integrity-check launchd timer. Installs/removes a per-user LaunchAgent
// that runs `baaackaaab --verify-repo --rotate-read-data` on a daily/weekly
// schedule (--at / --days). Separate label + plist, independent of the backup and
// drill timers.
if cli.has("--install-check-timer") {
    do { try LaunchdTimer.installCheck(schedule: cli.schedule()); exit(0) }
    catch { Console.error("\(error)"); exit(1) }
}
if cli.has("--uninstall-check-timer") {
    do { try LaunchdTimer.uninstallCheck(); exit(0) }
    catch { Console.error("\(error)"); exit(1) }
}

// Bare `baaackaaab` on a real terminal → the interactive command center: the
// full-screen TUI opens on its home dashboard (backup set + remote status) and
// ties set-editing, sync, and the remote dashboard together in one raw loop. The
// explicit --center flag forces it (e.g. with a custom --config).
if bareInteractive || cli.has("--center") {
    guard isatty(STDIN_FILENO) != 0, isatty(STDOUT_FILENO) != 0 else {
        Console.error("the command center needs an interactive terminal — run it directly in Terminal.app")
        exit(1)
    }
    ConfigTUI(configPath: configPath).run(home: true)
    exit(0)
}

// Interactive editor for the backup set, jumping straight past the home screen.
// Needs a real terminal (the raw-mode TUI can't run in a pipe or a launchd log);
// guard before touching termios.
if cli.has("--configure") {
    guard isatty(STDIN_FILENO) != 0, isatty(STDOUT_FILENO) != 0 else {
        Console.error("--configure needs an interactive terminal — run it directly in Terminal.app")
        exit(1)
    }
    ConfigTUI(configPath: configPath).run()
    exit(0)
}

// --limit-upload / --clear-limit-upload change the backup set's PERSISTENT
// upload throttle (the launchd timer and a bare run read it from the set); they
// are NOT per-run flags — there is no ad-hoc throttle. Combined with the ad-hoc
// source flags they would silently win the set-management dispatch below (edit
// the set and exit), so a user expecting a throttled one-off backup would get
// none. Reject the ambiguous combination loudly instead of quietly skipping it.
if cli.has("--limit-upload")
    || cli.has("--clear-limit-upload")
    || cli.has("--pack-size")
    || cli.has("--clear-pack-size")
    || cli.has("--rest-connections")
    || cli.has("--clear-rest-connections")
    || cli.has("--repo-quota")
    || cli.has("--clear-repo-quota")
    || cli.has("--defer-on-battery")
    || cli.has("--no-defer-on-battery") {
    if !cli.values("--drive-folder").isEmpty || !cli.values("--photo-album").isEmpty {
        Console.error("--limit-upload / --pack-size / --rest-connections / --repo-quota / --defer-on-battery (and their --clear-* / --no-* forms) change the backup set's PERSISTENT tuning; they are not per-run flags (a run reads them from the set — there is no ad-hoc form). Set them on their own first (e.g. `baaackaaab --pack-size 64`), then run the backup separately. Combined with --drive-folder/--photo-album they would silently edit the set and skip the backup.")
        exit(1)
    }
}

// Backup-set management (--list / --add-* / --remove-* / --limit-upload /
// --pack-size / --rest-connections): edit the set and exit. These are
// PERSISTENT knobs (like --add-folder), not per-run flags — a backup reads
// them from the set, never argv.
if cli.hasAny(["--list", "--add-folder", "--remove-folder", "--add-album", "--remove-album",
               "--limit-upload", "--clear-limit-upload", "--pack-size", "--clear-pack-size",
               "--rest-connections", "--clear-rest-connections",
               "--repo-quota", "--clear-repo-quota",
               "--defer-on-battery", "--no-defer-on-battery",
               "--add-exclude", "--remove-exclude", "--add-exclude-file", "--remove-exclude-file"]) {
    manageBackupSet(configPath: configPath)
    exit(0)
}

// Sources: explicit --drive-folder/--photo-album flags take precedence (ad-hoc /
// test runs). With NO source flag at all, fall back to the declarative backup
// set — so the launchd timer runs `baaackaaab` with no arguments.
var driveFolders = cli.values("--drive-folder")
var photoAlbums = cli.values("--photo-album")
var configQuotaBytes: Int? = nil
var configLimitUploadKiBps: Int? = nil
var configPackSizeMiB: Int? = nil
var configRestConnections: Int? = nil
var configExcludes: [String] = []
var configExcludeFiles: [String] = []
var configDeferOnBattery = false
if driveFolders.isEmpty && photoAlbums.isEmpty
    && FileManager.default.fileExists(atPath: configPath.path) {
    do {
        let set = try BackupSet.load(from: configPath)
        driveFolders = set.driveFolders
        photoAlbums = set.photoAlbums
        configQuotaBytes = set.quotaBytes
        configLimitUploadKiBps = set.limitUploadKiBps
        configPackSizeMiB = set.packSizeMiB
        configRestConnections = set.restConnections
        configExcludes = set.excludes
        configExcludeFiles = set.excludeFiles
        configDeferOnBattery = set.deferOnBattery
    } catch {
        Console.error("backup set at \(configPath.path) is unreadable — fix or delete it: \(error)")
        exit(1)
    }
}

// `--dry-run` on a backup → preview only: it writes NOTHING and downloads
// nothing. Drive folders are previewed by a metadata-only walk that reports how
// many files are still cloud-only (a real run would materialize them); we
// deliberately do NOT run restic against the live Drive tree on a dry run,
// because restic would read file contents and fault the whole set in from iCloud.
// Photos are likewise SKIPPED (a real preview there would export every original
// to staging, costing as much as a real backup).
let backupDryRun = cli.has("--dry-run")

// Scratch dir for photo batches + the manifest (Drive is backed up in place, so
// it is not copied here). Default to an ABSOLUTE path under Caches: a relative
// `./tmp/staging` would resolve against the launchd run's CWD (/), writing to
// /tmp/staging or failing — the scheduled backup must not depend on CWD.
let stagingURL: URL = {
    if let s = cli.value("--staging") {
        return URL(fileURLWithPath: (s as NSString).expandingTildeInPath, isDirectory: true)
    }
    return FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Caches/baaackaaab/staging", isDirectory: true)
}()
let photoBatchBytes = cli.positiveInt("--photo-batch-bytes", default: 3_000_000_000, unit: "bytes")
let host = cli.value("--host") ?? ProcessInfo.processInfo.hostName
// Optional remote-quota pre-flight. The rest-server's `--max-size` is a hard
// server-side stop; this is a soft client-side gauge that warns BEFORE a run
// when the repo is filling up, so the cap can be raised in time. We can't query
// the server's configured quota, so it comes from --repo-quota-bytes or the set.
let repoQuotaBytes: Int? = {
    guard let raw = cli.value("--repo-quota-bytes") else { return configQuotaBytes }
    guard let n = Int(raw), n > 0 else {
        Console.error("--repo-quota-bytes needs a positive integer (bytes) — got '\(raw)'")
        exit(1)
    }
    return n
}()
let quotaWarnFraction: Double = {
    guard let raw = cli.value("--quota-warn-fraction") else { return 0.85 }
    guard let f = Double(raw), f > 0, f <= 1 else {
        Console.error("--quota-warn-fraction needs a number in (0, 1] — got '\(raw)' (e.g. 0.85)")
        exit(1)
    }
    return f
}()

// Resolve the destination set (already enabled + primary-first). We back up to
// every one of them: each is an independent repo, so this yields N full copies.
let destinations = resolveDestinationsOrExit()
let primaryRepo = destinations[0].displayURL ?? destinations[0].name

let runFmt = DateFormatter()
runFmt.locale = Locale(identifier: "en_US_POSIX")
runFmt.dateFormat = "yyyyMMdd-HHmmss"
let runTag = cli.value("--run-tag") ?? "run-\(runFmt.string(from: Date()))"
let runStart = Date()

// Catch-up gate (RunAtLoad / boot). With `--catch-up`, exit quietly when a recent
// successful backup is already on record; otherwise announce the catch-up (and
// banner it unattended) and fall through to the normal backup below. A no-op
// without the marker. Evaluated here, before any backup work begins.
catchUpGateOrProceed()

// Battery-defer gate (opt-in). ONLY for scheduled / catch-up invocations — an
// interactive run always proceeds. When the knob is set and we are on battery,
// exit 0 without backing up (and BEFORE any backup work / heartbeat begins): a
// deferred run deliberately looks like a missed run, and the next scheduled fire
// (or the catch-up on AC) picks it up.
let isScheduledRun = runTag == "scheduled" || cli.has("--catch-up")
if !backupDryRun,
   ScheduledBackup.shouldDeferOnBattery(isScheduled: isScheduledRun,
                                        deferConfigured: configDeferOnBattery,
                                        onBattery: PowerSource.onBattery()) {
    Console.note("on battery — deferring scheduled backup (defer-on-battery is on); it will run on the next scheduled slot on wall power")
    exit(0)
}

// Hand off to the extracted orchestrator: it runs init, quota, Drive, Photos,
// manifest, summary, run-history and exit codes, then exits the process.
BackupRun(
    destinations: destinations,
    primaryRepo: primaryRepo,
    runTag: runTag,
    runStart: runStart,
    host: host,
    backupDryRun: backupDryRun,
    configLimitUploadKiBps: configLimitUploadKiBps,
    configPackSizeMiB: configPackSizeMiB,
    configRestConnections: configRestConnections,
    configExcludes: configExcludes,
    configExcludeFiles: configExcludeFiles,
    repoQuotaBytes: repoQuotaBytes,
    quotaWarnFraction: quotaWarnFraction,
    driveFolders: driveFolders,
    photoAlbums: photoAlbums,
    stagingURL: stagingURL,
    photoBatchBytes: photoBatchBytes
).execute()
