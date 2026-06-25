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

/// Parse an `--at HH:MM` value into (hour, minute), defaulting to 12:00 when
/// absent or malformed. Used by the launchd timer install.
func parseAtTime(_ s: String?) -> (hour: Int, minute: Int) {
    guard let s = s, let colon = s.firstIndex(of: ":"),
          let h = Int(s[s.startIndex..<colon]),
          let m = Int(s[s.index(after: colon)...]),
          (0...23).contains(h), (0...59).contains(m) else { return (12, 0) }
    return (h, m)
}

/// Usage / help screen. Printed on `--help`/`-h` and when invoked with no
/// arguments at all. Styled through Console so it matches the run output.
func printUsage() {
    Console.banner("baaackaaab", tagline: "one-way iCloud → restic backup")
    Console.section("Usage")
    Console.note("baaackaaab --restic-repo <repo> [--drive-folder <dir> ...] [--photo-album <name>] [options]")
    Console.note("Run `baaackaaab` with no arguments in a terminal to open the interactive command center (set + remote dashboard, edit, sync). --center forces it (e.g. with a custom --config).")

    Console.section("Setup (first run)")
    Console.info([
        ("--init-credentials", "generate + store both secrets in 0600 files, print the server hash (refuses if files exist; --force overwrites + ORPHANS the repo)"),
        ("--migrate-credentials", "move existing Keychain secrets into 0600 files (one last Keychain prompt)"),
        ("--check", "verify the server is reachable, init the repo, then exit"),
    ])

    Console.section("Sources")
    Console.info([
        ("--drive-folder <dir>", "iCloud Drive folder to back up (repeatable; overrides the set)"),
        ("--photo-album <name>", "iCloud Photos album to back up (repeatable; overrides the set)"),
        ("--photo-batch-bytes <n>", "byte budget per photo batch (default 3000000000)"),
        ("--staging <dir>", "scratch dir for photo batches (default ./tmp/staging)"),
    ])

    Console.section("Backup set", detail: "declarative source list — what a bare run backs up")
    Console.info([
        ("--list", "show the backup set and exit"),
        ("--configure", "interactive TUI: browse folders + edit the set"),
        ("--add-folder <dir>", "add a Drive folder to the set, then list (repeatable)"),
        ("--remove-folder <dir>", "remove a Drive folder from the set (repeatable)"),
        ("--add-album <name>", "add a Photos album to the set (repeatable)"),
        ("--remove-album <name>", "remove a Photos album from the set (repeatable)"),
        ("--config <path>", "backup-set file (default ~/.config/baaackaaab/backup-set.json)"),
    ])
    Console.note("A bare `baaackaaab` (no source flags) backs up the set; the launchd timer runs exactly that. Explicit --drive-folder/--photo-album override the set for ad-hoc runs.")

    Console.section("Restic target")
    Console.info([
        ("--restic-repo <repo>", "restic repo (else RESTIC_REPOSITORY, else the credential files / Keychain)"),
        ("--host <name>", "host tag for snapshots (default: this machine)"),
        ("--run-tag <tag>", "tag for this run (default: run-<timestamp>)"),
    ])
    Console.note("Password comes from RESTIC_PASSWORD / RESTIC_PASSWORD_FILE or the credential files, never an argument.")

    Console.section("Schedule (launchd timer)")
    Console.info([
        ("--install-timer", "install a daily LaunchAgent that backs up the set, then exit"),
        ("--at <HH:MM>", "time of day for the timer (default 12:00)"),
        ("--uninstall-timer", "remove the LaunchAgent, then exit"),
        ("--timer-status", "show whether the timer is installed + loaded, then exit"),
    ])
    Console.note("The timer runs `baaackaaab --run-tag scheduled` (backs up the set). restic reads the credential files directly, so the unattended run needs no Keychain prompt — only a one-time Photos grant (`make release` + one manual backup, so a stable signature keeps the TCC grant across rebuilds).")

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

/// First-run credential setup. Generates both secrets, stores them in two
/// `0600` files, and prints the one-way bcrypt line plus the command to create
/// the endpoint user on the server. The cleartext endpoint password never leaves
/// the file store; only its hash is printed. restic reads the files directly, so
/// neither secret ever reaches argv, our environment, or a Keychain prompt.
func initCredentials() throws {
    Console.banner("baaackaaab", tagline: "credential setup")

    // Refuse to clobber an existing credential file store. Re-running this
    // generates a NEW encryption password; overwriting the only copy of the key
    // orphans the existing repository — every snapshot becomes permanently
    // unreadable. Only --force (a deliberate fresh start) gets past this guard.
    if CredentialFiles.present && !CommandLine.arguments.contains("--force") {
        Console.error("credential files already exist at \(CredentialFiles.dir.path) — re-running --init-credentials generates a NEW encryption password and would ORPHAN the existing repository (its snapshots become permanently unreadable). To start a fresh repo on purpose, re-run with --force. To move existing Keychain secrets into the files WITHOUT regenerating, use --migrate-credentials.")
        exit(1)
    }

    let endpointPW = Credentials.randomURLSafe(byteCount: 24)   // ~192 bits, endpoint auth
    let repoPW = Credentials.randomURLSafe(byteCount: 32)       // ~256 bits, encryption key
    let repoURL = Credentials.repoURL(password: endpointPW)

    try CredentialFiles.write(repoURL, to: CredentialFiles.repoURLFile)
    try CredentialFiles.write(repoPW, to: CredentialFiles.repoPasswordFile)

    Console.section("Credential files")
    Console.success("stored endpoint URL + encryption password (0600, \(CredentialFiles.dir.path))")
    Console.info([("repo", Credentials.redact(repoURL))])
    Console.warn("The encryption password lives ONLY in this 0600 file — the server never has it. Lose it and the backups are unrecoverable. It is protected by FileVault at rest; back it up to your password manager.")

    let line = try Credentials.htpasswdLine(user: Credentials.endpointUser, password: endpointPW)
    Console.section("Server", detail: "create the endpoint user on garage")
    Console.note("One-way bcrypt hash (safe to paste); the cleartext password is not shown. It sets /data/.htpasswd to exactly user '\(Credentials.endpointUser)' — re-running rotates the password (overwrite, so this single-user tool stays at one endpoint user):")
    print("")
    print("    printf '%s\\n' '\(line)' \\")
    print("      | ssh bmadmin@10.0.10.2 'docker exec -i restic-rest-server sh -c \"cat > /data/.htpasswd\"'")
    print("")
    Console.section("Verify")
    Console.step("then run:  baaackaaab --check")
    Console.note("reaches the server with the stored credentials and initializes the repository.")
    Console.note("If --check returns 401, the server cached the old .htpasswd — run `ssh bmadmin@10.0.10.2 docker restart restic-rest-server`, then retry.")
}

/// One-time migration of an existing setup from the Keychain to the `0600` file
/// store. Reads both items from the Keychain once (the last Keychain prompt this
/// tool ever triggers) and writes them verbatim to the files — the encryption
/// password is NOT regenerated, so the existing repository stays intact. Prints
/// the commands to drop the now-unused Keychain items (kept, not auto-deleted,
/// so the user decides when to remove the fallback).
func migrateCredentials() throws {
    Console.banner("baaackaaab", tagline: "migrate credentials → files")

    if CredentialFiles.present {
        Console.warn("credential files already exist at \(CredentialFiles.dir.path) — they will be overwritten with the current Keychain values")
    }
    guard let url = (try? Keychain.get(account: Credentials.repoURLAccount)) ?? nil else {
        Console.error("no repo URL in the Keychain (item '\(Credentials.repoURLAccount)') — nothing to migrate; run `baaackaaab --init-credentials` to set up the file store directly")
        exit(1)
    }
    guard let pw = (try? Keychain.get(account: Credentials.repoPasswordAccount)) ?? nil else {
        Console.error("no encryption password in the Keychain (item '\(Credentials.repoPasswordAccount)') — nothing to migrate")
        exit(1)
    }

    try CredentialFiles.write(url, to: CredentialFiles.repoURLFile)
    try CredentialFiles.write(pw, to: CredentialFiles.repoPasswordFile)

    Console.section("Credential files")
    Console.success("wrote repo URL + encryption password to 0600 files (password unchanged — repo intact)")
    Console.info([
        ("dir", CredentialFiles.dir.path),
        ("repo", Credentials.redact(url)),
    ])
    Console.note("restic now reads these via RESTIC_REPOSITORY_FILE / RESTIC_PASSWORD_FILE — no Keychain prompt, interactive or under launchd.")

    Console.section("Cleanup", detail: "optional — drop the now-unused Keychain items")
    Console.note("the file store is authoritative from here; remove the Keychain items when ready:")
    print("")
    print("    security delete-generic-password -s \(Keychain.service) -a \(Credentials.repoURLAccount)")
    print("    security delete-generic-password -s \(Keychain.service) -a \(Credentials.repoPasswordAccount)")
    print("")
    Console.step("verify:  baaackaaab --check")
}

/// Resolve the restic repo URL and export both secrets into our environment so
/// the restic child inherits exactly one repo source and one password source
/// (file store preferred, then the legacy Keychain). Exits with an actionable
/// message if no repo can be found. See `Credentials.resolveAndExport`.
func resolveRepoOrExit() -> String {
    if let repo = Credentials.resolveAndExport(explicitRepo: argValue("--restic-repo")) {
        return repo
    }
    Console.error("no repository — pass --restic-repo, set RESTIC_REPOSITORY, run `baaackaaab --migrate-credentials` (Keychain→files), or `--init-credentials` first")
    exit(1)
}

/// Whether the encryption password is available to the restic child — either a
/// non-empty RESTIC_PASSWORD or a RESTIC_PASSWORD_FILE pointing at a non-empty
/// file. Read via getenv so it reflects a prior resolveAndExport.
func resticPasswordAvailable() -> Bool {
    if let v = getenv("RESTIC_PASSWORD"), strlen(v) > 0 { return true }
    if let f = getenv("RESTIC_PASSWORD_FILE") {
        let path = String(cString: f)
        if let data = FileManager.default.contents(atPath: path), !data.isEmpty { return true }
    }
    return false
}

/// Reach the server with the stored credentials and ensure the repo exists.
/// A fast end-to-end check of DNS + Traefik + htpasswd auth + restic init.
func checkRemote() {
    Console.banner("baaackaaab", tagline: "remote check")
    let repo = resolveRepoOrExit()
    Console.info([("repo", Credentials.redact(repo))])
    guard resticPasswordAvailable() else {
        Console.error("no encryption password — run `baaackaaab --migrate-credentials` (Keychain→files) or `--init-credentials`; the credential files / Keychain item are missing or unreadable")
        exit(1)
    }
    do {
        try ResticBackend(repository: repo).ensureInitialized()
        Console.success("server reachable, authentication OK, repository ready")
    } catch {
        Console.error("\(error)")
        exit(1)
    }
}

/// Print the backup set as the aligned key/value overview. `existed` separates
/// "no set yet" (first-run hint) from "set exists but is empty".
func listBackupSet(_ set: BackupSet, path: URL, existed: Bool) {
    Console.section("Backup set", detail: path.path)
    if !existed {
        Console.note("no backup set yet — add folders with --add-folder <dir>, albums with --add-album <name>")
        return
    }
    if set.isEmpty {
        Console.note("empty — add folders with --add-folder <dir>, albums with --add-album <name>")
        return
    }
    var pairs: [(String, String)] = []
    for f in set.driveFolders { pairs.append(("drive", f)) }
    for a in set.photoAlbums { pairs.append(("photo", "album \"\(a)\"")) }
    if let q = set.quotaBytes {
        pairs.append(("quota", String(format: "%.2f GB", Double(q) / 1_000_000_000)))
    }
    Console.info(pairs)
}

/// Handle the backup-set management flags (--list / --add-* / --remove-*). Loads
/// the set, applies every add/remove flag, saves only when something changed,
/// and prints the resulting set. No network, no Keychain — pure file editing.
func manageBackupSet(configPath: URL) {
    Console.banner("baaackaaab", tagline: "backup set")
    let existed = FileManager.default.fileExists(atPath: configPath.path)
    var set: BackupSet
    if existed {
        do { set = try BackupSet.load(from: configPath) }
        catch {
            Console.error("backup set at \(configPath.path) is unreadable — fix or delete it: \(error)")
            exit(1)
        }
    } else {
        set = BackupSet()
    }

    var changed = false
    for f in argValues("--add-folder") {
        if set.addFolder(f) { changed = true; Console.success("added drive folder  \(f)") }
        else { Console.note("drive folder already in set: \(f)") }
    }
    for f in argValues("--remove-folder") {
        if set.removeFolder(f) { changed = true; Console.success("removed drive folder  \(f)") }
        else { Console.note("drive folder not in set: \(f)") }
    }
    for a in argValues("--add-album") {
        if set.addAlbum(a) { changed = true; Console.success("added photo album  \(a)") }
        else { Console.note("photo album already in set: \(a)") }
    }
    for a in argValues("--remove-album") {
        if set.removeAlbum(a) { changed = true; Console.success("removed photo album  \(a)") }
        else { Console.note("photo album not in set: \(a)") }
    }

    if changed {
        do { try set.save(to: configPath) }
        catch {
            Console.error("could not write backup set to \(configPath.path): \(error)")
            exit(1)
        }
    }
    listBackupSet(set, path: configPath, existed: existed || changed)
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
let bareInteractive = CommandLine.arguments.count == 1
    && isatty(STDIN_FILENO) != 0 && isatty(STDOUT_FILENO) != 0
if CommandLine.arguments.contains("--help") || CommandLine.arguments.contains("-h")
    || (CommandLine.arguments.count == 1 && !bareInteractive) {
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

// First-run setup: generate + store both secrets, print the server hash.
if CommandLine.arguments.contains("--init-credentials") {
    do { try initCredentials(); exit(0) }
    catch { Console.error("\(error)"); exit(1) }
}

// One-time migration: move existing Keychain secrets into the 0600 file store.
if CommandLine.arguments.contains("--migrate-credentials") {
    do { try migrateCredentials(); exit(0) }
    catch { Console.error("\(error)"); exit(1) }
}

// Connectivity + auth + repo-init check, then exit.
if CommandLine.arguments.contains("--check") {
    checkRemote()
    exit(0)
}

// Resolve the backup-set config path (override with --config, e.g. for tests).
let configPath: URL = argValue("--config").map {
    URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath)
} ?? BackupSet.defaultPath()

// Scheduled-backup launchd timer. Installs/removes a per-user LaunchAgent that
// runs `baaackaaab --run-tag scheduled` (non-bare, so it backs up the set under
// launchd without a TTY). These touch the user's launchd, not the repo.
if CommandLine.arguments.contains("--install-timer") {
    let at = parseAtTime(argValue("--at"))
    do { try LaunchdTimer.install(hour: at.hour, minute: at.minute, configPath: configPath); exit(0) }
    catch { Console.error("\(error)"); exit(1) }
}
if CommandLine.arguments.contains("--uninstall-timer") {
    do { try LaunchdTimer.uninstall(); exit(0) }
    catch { Console.error("\(error)"); exit(1) }
}
if CommandLine.arguments.contains("--timer-status") {
    LaunchdTimer.status()
    exit(0)
}

// Bare `baaackaaab` on a real terminal → the interactive command center: the
// full-screen TUI opens on its home dashboard (backup set + remote status) and
// ties set-editing, sync, and the remote dashboard together in one raw loop. The
// explicit --center flag forces it (e.g. with a custom --config).
if bareInteractive || CommandLine.arguments.contains("--center") {
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
if CommandLine.arguments.contains("--configure") {
    guard isatty(STDIN_FILENO) != 0, isatty(STDOUT_FILENO) != 0 else {
        Console.error("--configure needs an interactive terminal — run it directly in Terminal.app")
        exit(1)
    }
    ConfigTUI(configPath: configPath).run()
    exit(0)
}

// Backup-set management (--list / --add-* / --remove-*): edit the set and exit.
if ["--list", "--add-folder", "--remove-folder", "--add-album", "--remove-album"]
    .contains(where: CommandLine.arguments.contains) {
    manageBackupSet(configPath: configPath)
    exit(0)
}

// Sources: explicit --drive-folder/--photo-album flags take precedence (ad-hoc /
// test runs). With NO source flag at all, fall back to the declarative backup
// set — so the launchd timer runs `baaackaaab` with no arguments.
var driveFolders = argValues("--drive-folder")
var photoAlbums = argValues("--photo-album")
var configQuotaBytes: Int? = nil
if driveFolders.isEmpty && photoAlbums.isEmpty
    && FileManager.default.fileExists(atPath: configPath.path) {
    do {
        let set = try BackupSet.load(from: configPath)
        driveFolders = set.driveFolders
        photoAlbums = set.photoAlbums
        configQuotaBytes = set.quotaBytes
    } catch {
        Console.error("backup set at \(configPath.path) is unreadable — fix or delete it: \(error)")
        exit(1)
    }
}

let stagingURL = URL(fileURLWithPath: argValue("--staging", default: "./tmp/staging")!, isDirectory: true)
let photoBatchBytes = argValue("--photo-batch-bytes").flatMap { Int($0) } ?? 3_000_000_000
let host = argValue("--host") ?? ProcessInfo.processInfo.hostName
// Optional remote-quota pre-flight. The rest-server's `--max-size` is a hard
// server-side stop; this is a soft client-side gauge that warns BEFORE a run
// when the repo is filling up, so the cap can be raised in time. We can't query
// the server's configured quota, so it comes from --repo-quota-bytes or the set.
let repoQuotaBytes = argValue("--repo-quota-bytes").flatMap { Int($0) } ?? configQuotaBytes
let quotaWarnFraction = argValue("--quota-warn-fraction").flatMap { Double($0) } ?? 0.85

let repo = resolveRepoOrExit()

let runFmt = DateFormatter()
runFmt.locale = Locale(identifier: "en_US_POSIX")
runFmt.dateFormat = "yyyyMMdd-HHmmss"
let runTag = argValue("--run-tag") ?? "run-\(runFmt.string(from: Date()))"

do {
    let staging = try Staging(root: stagingURL)
    let restic = ResticBackend(repository: repo)
    Console.banner("baaackaaab", tagline: "one-way iCloud → restic backup")
    Console.info([
        ("repo", Credentials.redact(repo)),
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
    if photoAlbums.isEmpty {
        Console.section("iCloud Photos")
        Console.note("no photo album configured, skipping Photos")
    } else {
        // Batch indices run globally across albums so each photo snapshot in a
        // run gets a distinct batch-N tag, even with more than one album.
        var photoBatchBase = 0
        for album in photoAlbums {
            Console.section("iCloud Photos", detail: "album '\(album)' (batch budget \(photoBatchBytes) bytes)")
            var lastIdx = 0
            try PhotosAcquirer().acquireBatched(
                albumTitle: album,
                byteBudget: photoBatchBytes,
                into: staging
            ) { batchDir, idx in
                lastIdx = idx
                try restic.backup(
                    paths: [batchDir],
                    tags: [runTag, "photos", "batch-\(photoBatchBase + idx)"],
                    host: host
                )
            }
            photoBatchBase += lastIdx + 1
        }
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
