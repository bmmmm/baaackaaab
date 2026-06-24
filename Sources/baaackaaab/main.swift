import Foundation

// baaackaaab acquisition prototype.
//
// One direction only: read iCloud Drive + Photos originals, verify the real
// bytes landed, stage them. Never writes back to the user's data. A separate
// shell step then hands the verified staging tree to restic.

func argValue(_ name: String, default fallback: String? = nil) -> String? {
    let args = CommandLine.arguments
    if let i = args.firstIndex(of: name), i + 1 < args.count {
        return args[i + 1]
    }
    return fallback
}

/// Collect every value of a repeatable flag, e.g. `--drive-folder a --drive-folder b`.
func argValues(_ name: String) -> [String] {
    let args = CommandLine.arguments
    var out: [String] = []
    var i = 0
    while i < args.count {
        if args[i] == name, i + 1 < args.count {
            out.append(args[i + 1])
            i += 2
        } else {
            i += 1
        }
    }
    return out
}

/// Usage / help screen. Printed on `--help`/`-h` and when invoked with no
/// arguments at all. Styled through Console so it matches the run output.
func printUsage() {
    Console.banner("baaackaaab", tagline: "one-way iCloud → restic backup")
    Console.section("Usage")
    Console.note("baaackaaab --restic-repo <repo> [--drive-folder <dir> ...] [--photo-album <name>] [options]")

    Console.section("Sources")
    Console.info([
        ("--drive-folder <dir>", "iCloud Drive folder to back up (repeatable)"),
        ("--photo-album <name>", "iCloud Photos album to back up"),
        ("--photo-batch-bytes <n>", "byte budget per photo batch (default 3000000000)"),
        ("--staging <dir>", "scratch dir for photo batches (default ./tmp/staging)"),
    ])

    Console.section("Restic target")
    Console.info([
        ("--restic-repo <repo>", "restic repository (or set RESTIC_REPOSITORY)"),
        ("--host <name>", "host tag for snapshots (default: this machine)"),
        ("--run-tag <tag>", "tag for this run (default: run-<timestamp>)"),
    ])
    Console.note("Password is read from the RESTIC_PASSWORD env var, never an argument.")

    Console.section("Quota (soft pre-flight gauge)")
    Console.info([
        ("--repo-quota-bytes <n>", "configured server quota, to warn before it fills"),
        ("--quota-warn-fraction <f>", "warn at this fraction of quota (default 0.85)"),
    ])

    Console.section("Diagnostics")
    Console.info([
        ("--materialize-test <file>", "prove a dataless stub re-materializes, then exit"),
        ("--evict-test <file>", "prove the evict/re-download round-trip, then exit"),
        ("-h, --help", "show this help and exit"),
    ])

    Console.section("Examples")
    Console.note("baaackaaab --restic-repo rest:https://host/repo \\\n             --drive-folder ~/Documents --photo-album \"Backup\"")
    Console.note("RESTIC_REPOSITORY=rest:https://host/repo baaackaaab \\\n             --drive-folder ~/Documents --repo-quota-bytes 50000000000")
    print("")
}

// Line-buffer stdout so our logs interleave in the right order with restic's
// child-process output. Without this, our print() output buffers and surfaces
// only after the subprocess has already written (and a file redirect would be
// block-buffered, scrambling the order entirely).
setvbuf(stdout, nil, _IOLBF, 0)

// Navigation: usage on --help/-h, and on a bare invocation with no arguments
// (arguments[0] is the program path, so count == 1 means "no args").
if CommandLine.arguments.contains("--help") || CommandLine.arguments.contains("-h")
    || CommandLine.arguments.count == 1 {
    printUsage()
    exit(0)
}

// Standalone diagnostic: prove the evict/dataless round-trip on one file.
// Runs in isolation and exits — never touches staging or the normal flow.
if let evictTarget = argValue("--evict-test") {
    do {
        try DriveAcquirer().evictRoundTripTest(URL(fileURLWithPath: evictTarget))
        exit(0)
    } catch {
        Console.error("\(error)")
        exit(1)
    }
}

if let matTarget = argValue("--materialize-test") {
    do {
        try DriveAcquirer().materializeTest(URL(fileURLWithPath: matTarget))
        exit(0)
    } catch {
        Console.error("\(error)")
        exit(1)
    }
}

let driveFolders = argValues("--drive-folder")
let photoAlbum = argValue("--photo-album")
let stagingURL = URL(fileURLWithPath: argValue("--staging", default: "./tmp/staging")!, isDirectory: true)
let photoBatchBytes = argValue("--photo-batch-bytes").flatMap { Int($0) } ?? 3_000_000_000
let host = argValue("--host") ?? ProcessInfo.processInfo.hostName
// Optional remote-quota pre-flight. The rest-server's `--max-size` is a hard
// server-side stop; this is a soft client-side gauge that warns BEFORE a run
// when the repo is filling up, so the cap can be raised in time. We can't query
// the server's configured quota, so the operator passes it in here.
let repoQuotaBytes = argValue("--repo-quota-bytes").flatMap { Int($0) }
let quotaWarnFraction = argValue("--quota-warn-fraction").flatMap { Double($0) } ?? 0.85

guard let repo = argValue("--restic-repo") ?? ProcessInfo.processInfo.environment["RESTIC_REPOSITORY"] else {
    Console.error("set --restic-repo or the RESTIC_REPOSITORY env var")
    exit(1)
}

let runFmt = DateFormatter()
runFmt.locale = Locale(identifier: "en_US_POSIX")
runFmt.dateFormat = "yyyyMMdd-HHmmss"
let runTag = argValue("--run-tag") ?? "run-\(runFmt.string(from: Date()))"

do {
    let staging = try Staging(root: stagingURL)
    let restic = ResticBackend(repository: repo)
    Console.banner("baaackaaab", tagline: "one-way iCloud → restic backup")
    Console.info([
        ("repo", repo),
        ("host", host),
        ("run-tag", runTag),
        ("staging", "\(stagingURL.path) (scratch for photo batches only)"),
    ])
    try restic.ensureInitialized()

    // 0) Remote-quota pre-flight (soft gauge). Reads the current repo size and,
    //    if it is past the warn fraction of the operator-supplied quota, prints
    //    an actionable warning. The server still hard-stops at 100%; this just
    //    gives lead time to raise --max-size before a run gets rejected.
    if let quota = repoQuotaBytes, quota > 0 {
        Console.section("Quota")
        if let used = restic.repoSizeBytes() {
            let frac = Double(used) / Double(quota)
            let pct = Int((frac * 100).rounded())
            let usedGB = String(format: "%.2f", Double(used) / 1_000_000_000)
            let quotaGB = String(format: "%.2f", Double(quota) / 1_000_000_000)
            Console.step("repo \(usedGB) GB / \(quotaGB) GB (\(pct)%)")
            if frac >= quotaWarnFraction {
                Console.warn("repo is at \(pct)% of the configured quota. Raise --max-size on the rest-server (edit the stack's docker-compose.yml, redeploy — no data migration) before it fills; the server hard-stops new backups at 100%.")
            }
        } else {
            Console.note("repo size unavailable (fresh repo or stats failed) — skipping quota gauge")
        }
    }

    // 1) iCloud Drive — materialize + verify in place, then restic reads the
    //    source tree directly (no full-size staging copy). Strict: a stub that
    //    refuses to materialize aborts the whole Drive backup before it runs.
    if driveFolders.isEmpty {
        Console.section("iCloud Drive")
        Console.note("no --drive-folder given, skipping Drive")
    } else {
        var verifiedFolders: [URL] = []
        for folder in driveFolders {
            let url = URL(fileURLWithPath: (folder as NSString).expandingTildeInPath, isDirectory: true)
            Console.section("iCloud Drive", detail: url.path)
            try DriveAcquirer().materializeAndVerify(folder: url, into: staging)
            verifiedFolders.append(url)
        }
        try restic.backup(paths: verifiedFolders, tags: [runTag, "drive"], host: host)
    }

    // 2) iCloud Photos — export in byte-budgeted batches; each batch is backed
    //    up and then deleted, so peak extra disk is ~one batch, not 27 GB.
    if let photoAlbum {
        Console.section("iCloud Photos", detail: "album '\(photoAlbum)' (batch budget \(photoBatchBytes) bytes)")
        try PhotosAcquirer().acquireBatched(
            albumTitle: photoAlbum,
            byteBudget: photoBatchBytes,
            into: staging
        ) { batchDir, idx in
            try restic.backup(paths: [batchDir], tags: [runTag, "photos", "batch-\(idx)"], host: host)
        }
    } else {
        Console.section("iCloud Photos")
        Console.note("no --photo-album given, skipping Photos")
    }

    try staging.writeManifest()

    let verified = staging.items.filter { $0.verified }.count
    let total = staging.items.count
    let manifestPath = stagingURL.appendingPathComponent("manifest.json").path
    let details = [
        ("run-tag", runTag),
        ("manifest", manifestPath),
    ]

    if total == 0 {
        Console.summary(
            headline: "nothing was acquired",
            state: .fail,
            details: details
        )
        exit(2)
    }
    if verified != total {
        Console.summary(
            headline: "\(verified)/\(total) verified — \(total - verified) item(s) failed verification and were skipped; review the manifest",
            state: .warn,
            details: details
        )
        exit(2)
    }
    Console.summary(
        headline: "\(verified)/\(total) verified — every acquired byte-stream backed up under tag \(runTag)",
        state: .ok,
        details: details
    )
} catch {
    Console.error("\(error)")
    exit(1)
}
