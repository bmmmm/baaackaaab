import Foundation
#if canImport(Darwin)
import Darwin
#endif

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

/// The two tokens after a flag, e.g. `--diff <a> <b>`. nil if fewer than two
/// follow it. Used by the two-argument snapshot diff.
func argPair(_ name: String) -> (String, String)? {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: name), i + 2 < args.count else { return nil }
    return (args[i + 1], args[i + 2])
}

/// A numeric flag that must be a positive integer when present. Returns
/// `fallback` when the flag is absent; exits with an actionable error when it is
/// present but not a positive integer — so a typo or a negative/zero value fails
/// loudly instead of silently degrading the run (e.g. `--max-bytes -1` collapsing
/// a sample to one file). `unit` is woven into the error, e.g. "KiB/s".
func positiveIntArg(_ name: String, default fallback: Int, unit: String? = nil) -> Int {
    guard let raw = argValue(name) else { return fallback }
    guard let n = Int(raw), n > 0 else {
        let u = unit.map { " (\($0))" } ?? ""
        Console.error("\(name) needs a positive integer\(u) — got '\(raw)'")
        exit(1)
    }
    return n
}

/// Parse an `--at HH:MM` value (24-hour) into (hour, minute). nil when malformed,
/// so the caller can reject an explicitly-supplied bad value rather than silently
/// substituting a wrong time. A wholly absent `--at` is handled by parseSchedule.
func parseAtTime(_ s: String) -> (hour: Int, minute: Int)? {
    guard let colon = s.firstIndex(of: ":"),
          let h = Int(s[s.startIndex..<colon]),
          let m = Int(s[s.index(after: colon)...]),
          (0...23).contains(h), (0...59).contains(m) else { return nil }
    return (h, m)
}

/// Parse a `--days` csv ("mon,wed,fri") into launchd weekday numbers
/// (Sun=0 … Sat=6), plus any tokens that did not resolve to a weekday. An
/// empty/absent value yields ([], []) (which means "every day"). Unrecognized
/// tokens are returned so the caller can reject them instead of silently
/// dropping them (a typo'd `--days saturdy` must not become a daily timer).
func parseDays(_ csv: String?) -> (days: [Int], unknown: [String]) {
    guard let csv, !csv.isEmpty else { return ([], []) }
    let map: [String: Int] = ["sun": 0, "mon": 1, "tue": 2, "wed": 3, "thu": 4, "fri": 5, "sat": 6]
    var days = Set<Int>()
    var unknown: [String] = []
    for tok in csv.lowercased().split(whereSeparator: { $0 == "," || $0 == " " }) {
        if let d = map[String(tok.prefix(3))] { days.insert(d) } else { unknown.append(String(tok)) }
    }
    return (days.sorted(), unknown)
}

/// Build the timer Schedule from `--at` (repeatable; default 12:00 when absent)
/// and `--days` (csv of weekdays; absent = every day). Exits with an actionable
/// error on any malformed `--at` or unrecognized `--days` token, so an
/// install never silently lands on the wrong time or the wrong (daily) cadence.
func parseSchedule() -> Schedule {
    var times: [(hour: Int, minute: Int)] = []
    for raw in argValues("--at") {
        guard let t = parseAtTime(raw) else {
            Console.error("--at needs HH:MM in 24-hour form — got '\(raw)' (e.g. --at 09:00 --at 18:30)")
            exit(1)
        }
        times.append(t)
    }
    let (days, unknown) = parseDays(argValue("--days"))
    if !unknown.isEmpty {
        Console.error("--days has unrecognized weekday(s): \(unknown.joined(separator: ", ")) — use mon,tue,wed,thu,fri,sat,sun")
        exit(1)
    }
    return Schedule(times: times.isEmpty ? [(hour: 12, minute: 0)] : times, weekdays: days)
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
        ("--staging <dir>", "scratch dir for photo batches (default ~/Library/Caches/baaackaaab/staging)"),
    ])

    Console.section("Backup set", detail: "declarative source list — what a bare run backs up")
    Console.info([
        ("--list", "show the backup set and exit"),
        ("--configure", "interactive TUI: browse folders + edit the set"),
        ("--add-folder <dir>", "add a Drive folder to the set, then list (repeatable)"),
        ("--remove-folder <dir>", "remove a Drive folder from the set (repeatable)"),
        ("--add-album <name>", "add a Photos album to the set (repeatable)"),
        ("--remove-album <name>", "remove a Photos album from the set (repeatable)"),
        ("--limit-upload <n>", "persist an upload throttle of n KiB/s (applies to the timer too)"),
        ("--clear-limit-upload", "remove the upload throttle"),
        ("--config <path>", "backup-set file (default ~/.config/baaackaaab/backup-set.json)"),
    ])
    Console.note("A bare `baaackaaab` (no source flags) backs up the set; the launchd timer runs exactly that. Explicit --drive-folder/--photo-album override the set for ad-hoc runs. Add --dry-run to preview a backup (reports what would upload, writes nothing; Photos are skipped in a dry run). On a terminal a real backup shows a live progress bar (percent, bytes, ETA); piped or under the timer it logs restic's plain output.")

    Console.section("Restic target")
    Console.info([
        ("--restic-repo <repo>", "restic repo (else RESTIC_REPOSITORY, else the credential files / Keychain)"),
        ("--host <name>", "host tag for snapshots (default: this machine)"),
        ("--run-tag <tag>", "tag for this run (default: run-<timestamp>)"),
    ])
    Console.note("Password comes from RESTIC_PASSWORD / RESTIC_PASSWORD_FILE or the credential files, never an argument.")

    Console.section("Destinations", detail: "back up to several independent repos at once")
    Console.info([
        ("--list-destinations", "show every configured destination (redacted), then exit"),
        ("--add-destination <name>", "add a destination; needs --repo-url, generates a new key"),
        ("--repo-url <url>", "the new destination's repo (rest:https://…, a local path, sftp:…)"),
        ("--repo-password-file <f>", "re-attach an EXISTING repo with its key from a file (no new key)"),
        ("--link <label>", "concurrency group (same label = shared uplink; default 'default')"),
        ("--order <n>", "primary-first ordering (lower runs earlier)"),
        ("--disabled", "add the destination but skip it on runs until re-enabled"),
        ("--remove-destination <name>", "drop a destination's LOCAL pointer (never touches remote data)"),
    ])
    Console.note("A run backs up to every enabled destination — each is a full, independent copy with its own key. The Mac stays read + append only toward all of them. The first --add-destination migrates a legacy single repo to destinations/default automatically.")

    Console.section("Restore (read-only browse; restore writes only to a fresh dir)")
    Console.info([
        ("--snapshots", "list snapshots newest-first per destination, then exit"),
        ("--ls <id>", "list a snapshot's files (browse / restore discovery); --include limits the subtree"),
        ("--diff <a> <b>", "show what changed between two snapshots (needs one --destination), then exit"),
        ("--find <pattern>", "locate a file in a snapshot (single-file restore discovery), then exit"),
        ("--restore", "restore a snapshot into a fresh directory (preview → confirm → verify)"),
        ("--test-restore", "restore a random file sample into a temp dir + verify (proves restorability), then exit"),
        ("--sample <n>", "with --test-restore, how many files to sample (default 10)"),
        ("--max-bytes <n>", "with --test-restore, byte budget for the sample (default 1000000000)"),
        ("--destination <name>", "source destination (required when several are configured)"),
        ("--snapshot <id>", "which snapshot to find/restore (short id; default 'latest')"),
        ("--target <dir>", "restore into this dir (default: ~/baaackaaab-restore/<snap>-<stamp>)"),
        ("--include <path>", "restore only this subpath — a folder (subtree) or one file"),
        ("--dry-run", "preview what would be restored, write nothing"),
        ("--yes", "skip the confirm prompt (required for a non-interactive restore)"),
        ("--no-verify", "skip the post-restore re-read verification (on by default)"),
    ])
    Console.note("Three restore modes: full (--restore), subtree (--restore --include <folder>), single-file (--find <name> to locate, then --restore --include <path>). Restore never writes back into iCloud Drive or Photos — it lands in a fresh directory you then move things back from.")

    Console.section("Maintenance (repo health; read-only except --unlock)")
    Console.info([
        ("--verify-repo", "run `restic check` per destination (structure; read-only), then exit"),
        ("--read-data-subset <s>", "with --verify-repo, also re-read this fraction of pack data (5%, 1/10, 10M)"),
        ("--unlock", "remove STALE locks for --destination — the only delete op (lock files only)"),
        ("--remove-all", "with --unlock, remove ALL locks (only when no backup is running)"),
    ])
    Console.note("--verify-repo only READS the repo. A damaged repo is repaired SERVER-side (the Mac has no delete/prune right). --unlock is the single exception: it deletes lock files only (never snapshots/data), removes stale locks by default, and needs --destination + a confirm (or --yes).")

    Console.section("Schedule (launchd timer)")
    Console.info([
        ("--install-timer", "install a LaunchAgent that backs up the set on a schedule, then exit"),
        ("--at <HH:MM>", "time of day (repeatable for several runs/day; default 12:00)"),
        ("--days <list>", "restrict to weekdays, e.g. mon,wed,fri (default: every day)"),
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
        ("--doctor", "consolidated health check: restic, destinations, disk, Photos, timer"),
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

    // The real rest-server host is private and is NOT baked into the source. It
    // must be supplied via BAAACKAAAB_ENDPOINT_HOST (e.g. in ~/.env); refuse
    // rather than store a useless placeholder URL pointing at example.com.
    guard Credentials.endpointHost != Credentials.placeholderHost else {
        Console.error("endpoint host is unset — the real rest-server host is not baked into the binary. Export it in the shell that runs this (it must be live in the environment, not just written to ~/.env): `export BAAACKAAAB_ENDPOINT_HOST=<your rest-server host> && baaackaaab --init-credentials` (or add it to ~/.env and open a new shell). Optionally export BAAACKAAAB_ENDPOINT_USER and BAAACKAAAB_ADMIN_SSH too.")
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
    print("      | ssh \(Credentials.adminSSH) 'docker exec -i restic-rest-server sh -c \"cat > /data/.htpasswd\"'")
    print("")
    Console.section("Verify")
    Console.step("then run:  baaackaaab --check")
    Console.note("reaches the server with the stored credentials and initializes the repository.")
    Console.note("If --check returns 401, the server cached the old .htpasswd — run `ssh \(Credentials.adminSSH) docker restart restic-rest-server`, then retry.")
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

/// Resolve the destinations to back up to / query, honoring an explicit
/// `--restic-repo` / RESTIC_REPOSITORY override, or exit with an actionable
/// message when nothing is configured. Only ENABLED destinations are returned,
/// already ordered primary-first. The credential secrets never reach our argv or
/// environment — each `Destination` carries them as a per-restic-child env
/// overlay (see `ResticBackend`).
func resolveDestinationsOrExit() -> [Destination] {
    let dests = DestinationStore.resolveEnabled(explicitRepo: argValue("--restic-repo"))
    if !dests.isEmpty { return dests }
    Console.error("no repository — pass --restic-repo, set RESTIC_REPOSITORY, run `baaackaaab --migrate-credentials` (Keychain→files), or `--init-credentials` first")
    exit(1)
}

/// Reach the server with the stored credentials and ensure the repo exists.
/// A fast end-to-end check of DNS + Traefik + htpasswd auth + restic init.
func checkRemote() {
    Console.banner("baaackaaab", tagline: "remote check")
    let dests = resolveDestinationsOrExit()
    var failures = 0
    for dest in dests {
        let repo = dest.displayURL ?? dest.name
        Console.section("Destination", detail: "\(dest.name) [\(dest.link)]")
        Console.info([("repo", Credentials.redact(repo))])
        guard dest.passwordAvailable else {
            Console.failure(noPasswordNote())
            failures += 1
            continue
        }
        do {
            let backend = ResticBackend(destination: dest)
            try backend.ensureInitialized()
            Console.success("reachable, authentication OK, repository ready")
            // Read-only per-(source × destination) summary: total snapshots + size,
            // then the newest snapshot per source (drive / photos). Same data the
            // TUI dashboard shows; surfaced here so it is visible without a TTY.
            let status = backend.remoteStatus()
            if status.reachable {
                let size = status.sizeBytes.map { String(format: ", %.2f GB", Double($0) / 1_000_000_000) } ?? ""
                Console.detail("\(status.snapshotCount) snapshot(s)\(size)")
                for src in status.sources {
                    let when = src.latestTime.map { String($0.prefix(16)).replacingOccurrences(of: "T", with: " ") } ?? "never"
                    Console.detail("  \(src.source): \(src.count) snapshot(s), latest \(when)")
                }
            }
        } catch {
            Console.failure("\(error)")
            failures += 1
        }
    }
    if failures > 0 {
        Console.error("\(failures)/\(dests.count) destination(s) failed the check — see above")
        exit(1)
    }
    Console.success("all \(dests.count) destination(s) reachable and ready")
}

/// Resolve the destinations a read/restore command should act on: every enabled
/// one, or just the single `--destination <name>`. Exits with an actionable error
/// if `--destination` names something that is not configured. The restore flow
/// uses this to pick its source repository.
func destinationsForCommand() -> [Destination] {
    let all = resolveDestinationsOrExit()
    guard let name = argValue("--destination") else { return all }
    guard let match = all.first(where: { $0.name == name }) else {
        Console.error("no enabled destination named '\(name)' — configured: \(all.map { $0.name }.joined(separator: ", "))")
        exit(1)
    }
    return [match]
}

/// The repeated "missing encryption key" note, in one place so the wording stays
/// identical everywhere it can surface. `name` is woven in for the single-
/// destination commands that already know which destination failed.
func noPasswordNote(for name: String? = nil) -> String {
    let who = name.map { " for '\($0)'" } ?? ""
    return "no encryption password\(who) — the credential files are missing or unreadable"
}

/// Fan a read/verify command out over `dests`, wrapping the scaffold every one
/// of them repeats: the per-destination section header and the missing-key guard
/// (printed as a failure and counted). `body` runs only for a destination whose
/// key is present; it returns false — or throws — to mark that destination
/// failed (a thrown error is printed as the failure line). Returns the count of
/// failed destinations; the caller prints its own command-specific summary/exit.
@discardableResult
func forEachDestination(_ dests: [Destination], _ body: (Destination) throws -> Bool) -> Int {
    var failures = 0
    for dest in dests {
        Console.section("Destination", detail: "\(dest.name) [\(dest.link)]")
        guard dest.passwordAvailable else {
            Console.failure(noPasswordNote())
            failures += 1
            continue
        }
        do { if !(try body(dest)) { failures += 1 } }
        catch {
            Console.failure("\(error)")
            failures += 1
        }
    }
    return failures
}

/// Resolve exactly one destination for a single-repository command (diff,
/// test-restore, unlock), print its section header, and verify its key is
/// present — exiting with an actionable error when several/none are configured or
/// the key is missing. `action` completes the "choose ONE destination" sentence,
/// e.g. "diff compares two snapshots in a single repository".
func requireSingleDestination(action: String) -> Destination {
    let picked = destinationsForCommand()
    guard picked.count == 1 else {
        Console.error("choose ONE destination with --destination <name> — \(action) (configured: \(picked.map { $0.name }.joined(separator: ", ")))")
        exit(1)
    }
    let dest = picked[0]
    Console.section("Destination", detail: "\(dest.name) [\(dest.link)]")
    guard dest.passwordAvailable else {
        Console.error(noPasswordNote(for: dest.name))
        exit(1)
    }
    return dest
}

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
    guard let pattern = argValue("--find"), !pattern.isEmpty else {
        Console.error("--find needs a pattern, e.g. --find note.txt or --find '*.pdf'")
        exit(1)
    }
    let snapshot = argValue("--snapshot") ?? "latest"
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

/// Browse a snapshot's contents with `restic ls` (read-only), per destination
/// (or just `--destination <name>`). `--ls <id>` picks the snapshot (default
/// 'latest'); `--include <subpath>` limits to a subtree. The printed path is
/// exactly what `--restore --include` takes, so this doubles as restore discovery.
func lsCommand() {
    Console.banner("baaackaaab", tagline: "ls — browse a snapshot")
    let snapshot = argValue("--ls") ?? "latest"
    let subpath = argValue("--include")
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
    guard let (a, b) = argPair("--diff"), !a.isEmpty, !b.isEmpty,
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
    if all.count == 1 && argValue("--destination") == nil {
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

    let snapshot = argValue("--snapshot") ?? "latest"
    let include = argValue("--include")
    let dryRun = CommandLine.arguments.contains("--dry-run")
    let verify = !CommandLine.arguments.contains("--no-verify")

    // Target: an explicit --target, else a fresh timestamped dir. Validated hard.
    let stampFmt = DateFormatter()
    stampFmt.locale = Locale(identifier: "en_US_POSIX")
    stampFmt.dateFormat = "yyyyMMdd-HHmmss"
    let stamp = stampFmt.string(from: Date())
    let target = argValue("--target").map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
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
    if !CommandLine.arguments.contains("--yes") {
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
    let snapshot = argValue("--snapshot") ?? "latest"
    let sampleCount = positiveIntArg("--sample", default: 10)
    let budget = positiveIntArg("--max-bytes", default: 1_000_000_000, unit: "bytes")

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
    let subset = argValue("--read-data-subset")
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

    let removeAll = CommandLine.arguments.contains("--remove-all")
    Console.section(removeAll ? "Remove ALL locks" : "Remove stale locks")
    if removeAll {
        Console.warn("--remove-all deletes EVERY lock, including one a backup that is genuinely running right now holds. Only do this when you are certain no backup or prune is in progress against this repo.")
    } else {
        Console.note("removes only STALE locks (a dead or >30-min-old locker); a lock a live backup holds is kept.")
    }
    Console.note("This is the ONLY operation that deletes from the repo, and it removes lock files only — never snapshots or data. On an append-only server the lock prefix must be carved out for this to succeed; if it is not, the server refuses (403) and nothing changes.")

    // Confirm — unlock deletes (lock files) from the repo, so gate it like restore.
    if !CommandLine.arguments.contains("--yes") {
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
        Console.success("installed and loaded")
    } else if timer.installed {
        Console.warn("installed but not loaded — re-run `--install-timer` to (re)load it")
        warnings += 1
    } else {
        Console.note("not installed (optional) — `--install-timer` schedules a daily backup of the set")
    }

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

/// Print the configured destinations (read-only): name, link group, order,
/// enabled flag, and the redacted repo URL. Never touches the network.
func listDestinations() {
    Console.banner("baaackaaab", tagline: "destinations")
    let dests = DestinationStore.all()
    Console.section("Destinations", detail: DestinationStore.dir.path)
    if dests.isEmpty {
        Console.note("none configured — add one with `baaackaaab --add-destination <name> --repo-url <url>`, or run `--init-credentials` for the first repo")
        return
    }
    for d in dests {
        Console.step("\(d.name)  [\(d.link)]  order \(d.order)  \(d.enabled ? "enabled" : "disabled")")
        Console.detail(d.displayURL.map { Credentials.redact($0) } ?? "(url unreadable)")
    }
}

/// Add a new destination: a fresh independent repository with its own encryption
/// key. The URL is taken as-is (rest:https://…, a local path, sftp:…); the key is
/// generated locally (or imported from a file to re-attach an existing repo) and
/// never reaches argv. A legacy single repo is migrated to destinations/default
/// first so the existing backup is preserved.
func addDestination(name: String) {
    Console.banner("baaackaaab", tagline: "add destination")
    guard let url = argValue("--repo-url"), !url.isEmpty else {
        Console.error("--add-destination needs --repo-url <url> (a rest:https://… URL, a local path, sftp:…, etc.)")
        exit(1)
    }
    let link = argValue("--link") ?? "default"
    let order = argValue("--order").flatMap { Int($0) }
    let enabled = !CommandLine.arguments.contains("--disabled")

    let importing = argValue("--repo-password-file") != nil
    let password: String
    if let pwFile = argValue("--repo-password-file") {
        guard let data = FileManager.default.contents(atPath: (pwFile as NSString).expandingTildeInPath),
              let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !s.isEmpty else {
            Console.error("--repo-password-file is empty or unreadable: \(pwFile)")
            exit(1)
        }
        password = s   // re-attaching an existing repo: must be its existing key
    } else {
        password = Credentials.randomURLSafe(byteCount: 32)   // ~256-bit new key
    }

    do {
        try DestinationStore.add(name: name, repoURL: url, password: password,
                                 link: link, order: order, enabled: enabled)
    } catch {
        Console.error("\(error)")
        exit(1)
    }

    Console.section("Added")
    Console.success("destination '\(name)' stored (0600) at \(DestinationStore.destDir(name).path)")
    Console.info([("repo", Credentials.redact(url)), ("link", link)])
    if !importing {
        Console.warn("A NEW encryption key was generated and lives ONLY in the 0600 file — the server never has it. Lose it and this destination's backups are unrecoverable. It is protected by FileVault at rest; back it up to your password manager.")
    }
    Console.step("verify:  baaackaaab --check   (initializes every destination's repo if new)")
}

/// Remove a destination's LOCAL pointer (URL + key + meta). Never touches the
/// remote repository's data — the Mac has no delete right.
func removeDestination(name: String) {
    Console.banner("baaackaaab", tagline: "remove destination")
    do {
        if try DestinationStore.remove(name: name) {
            Console.success("removed local pointer for destination '\(name)'")
            Console.note("the remote repository's data was NOT touched — the Mac has no delete right. To reclaim that repo's space, prune it server-side with a separate key.")
        } else {
            Console.error("no destination named '\(name)' — see `baaackaaab --list-destinations`")
            exit(1)
        }
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
    if let l = set.limitUploadKiBps {
        pairs.append(("limit-upload", "\(l) KiB/s (\(String(format: "%.1f", Double(l) / 1024)) MiB/s)"))
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
    // Upload-throttle knob: persisted in the set so the unattended timer is
    // throttled too. `--limit-upload <n>` sets KiB/s; `--clear-limit-upload` lifts it.
    if let raw = argValue("--limit-upload") {
        guard let n = Int(raw), n > 0 else {
            Console.error("--limit-upload needs a positive integer (KiB/s), e.g. --limit-upload 2048 for ~2 MiB/s")
            exit(1)
        }
        if set.limitUploadKiBps != n { set.limitUploadKiBps = n; changed = true; Console.success("upload limit set to \(n) KiB/s") }
        else { Console.note("upload limit already \(n) KiB/s") }
    }
    if CommandLine.arguments.contains("--clear-limit-upload") {
        if set.limitUploadKiBps != nil { set.limitUploadKiBps = nil; changed = true; Console.success("upload limit cleared (unthrottled)") }
        else { Console.note("no upload limit was set") }
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

/// Reject an unrecognized `--flag` before it can fall through to a backup. The
/// dispatch below matches specific flags and, finding none, backs up the set — so
/// a typo'd command (e.g. `--restoree`, `--snapshtos`) would otherwise silently
/// start a full backup instead of failing. Every accepted flag is listed here; a
/// token that looks like a flag but is not known exits with an actionable error.
/// Flag VALUES are skipped (a value may legitimately start with '-', e.g.
/// `--find -x`), so only genuine flag tokens are checked.
func rejectUnknownFlags() {
    // Flags that consume the FOLLOWING token as their value — that token is a
    // value, never checked as a flag. `--diff` consumes two (a snapshot pair).
    let valueFlags: Set<String> = [
        "--drive-folder", "--photo-album", "--photo-batch-bytes", "--staging",
        "--add-folder", "--remove-folder", "--add-album", "--remove-album",
        "--limit-upload", "--config", "--restic-repo", "--host", "--run-tag",
        "--add-destination", "--repo-url", "--repo-password-file", "--link",
        "--order", "--remove-destination", "--ls", "--find", "--snapshot",
        "--target", "--include", "--sample", "--max-bytes", "--destination",
        "--read-data-subset", "--at", "--days", "--repo-quota-bytes",
        "--quota-warn-fraction", "--materialize-test", "--evict-test",
    ]
    // Flags that stand alone (no value).
    let boolFlags: Set<String> = [
        "--init-credentials", "--migrate-credentials", "--force", "--check",
        "--list", "--configure", "--clear-limit-upload", "--list-destinations",
        "--disabled", "--snapshots", "--restore", "--test-restore", "--dry-run",
        "--yes", "--no-verify", "--verify-repo", "--unlock", "--remove-all",
        "--install-timer", "--uninstall-timer", "--timer-status", "--doctor",
        "--center", "--help", "-h",
    ]
    let args = CommandLine.arguments
    var i = 1   // skip argv[0]
    while i < args.count {
        let tok = args[i]
        if tok == "--diff" { i += 3; continue }           // flag + two snapshot ids
        if valueFlags.contains(tok) { i += 2; continue }  // flag + its value
        if boolFlags.contains(tok) { i += 1; continue }
        if tok.hasPrefix("-") && tok != "-" {
            Console.error("unknown flag '\(tok)' — see `baaackaaab --help` for the accepted flags. (Refusing to continue: an unrecognized flag would otherwise fall through to a full backup of the set.)")
            exit(1)
        }
        i += 1   // a bare positional, or a value already accounted for above
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
let bareInteractive = CommandLine.arguments.count == 1
    && isatty(STDIN_FILENO) != 0 && isatty(STDOUT_FILENO) != 0
if CommandLine.arguments.contains("--help") || CommandLine.arguments.contains("-h")
    || (CommandLine.arguments.count == 1 && !bareInteractive) {
    printUsage()
    exit(0)
}

// Reject an unknown flag up front, before any dispatch — a typo must fail loudly,
// never fall through to a backup of the set.
rejectUnknownFlags()

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

// --read-data-subset only has meaning with --verify-repo; on its own it would be
// silently ignored and the run would fall through to a backup. Fail loudly.
if argValue("--read-data-subset") != nil && !CommandLine.arguments.contains("--verify-repo") {
    Console.error("--read-data-subset only applies to --verify-repo — re-run as `baaackaaab --verify-repo --read-data-subset <n%|n/t|nM>`")
    exit(1)
}

// Repository integrity check (`restic check`), read-only. Optional
// --read-data-subset re-reads a fraction of the pack data for bit-rot.
if CommandLine.arguments.contains("--verify-repo") {
    verifyRepoCommand()
    exit(0)
}

// Remove repository locks (the only delete op). Lists locks, confirms, then runs
// `restic unlock` (stale only, or --remove-all). Removes lock files only.
if CommandLine.arguments.contains("--unlock") {
    unlockCommand()
    exit(0)
}

// Consolidated read-only health check (restic, destinations, disk, Photos, timer).
if CommandLine.arguments.contains("--doctor") {
    doctorCommand()
    exit(0)
}

// Read-only snapshot browser (restore starts here: pick a snapshot's short id).
if CommandLine.arguments.contains("--snapshots") {
    listSnapshotsCommand()
    exit(0)
}

// Locate a file inside a snapshot by name/glob (single-file restore discovery).
if argValue("--find") != nil {
    findCommand()
    exit(0)
}

// Browse a snapshot's contents (read-only). The listed paths feed --restore --include.
if argValue("--ls") != nil {
    lsCommand()
    exit(0)
}

// Compare two snapshots (read-only): what changed between them.
if CommandLine.arguments.contains("--diff") {
    diffCommand()
    exit(0)
}

// Restore a snapshot into a fresh directory (safe by construction). Previews,
// confirms, restores, verifies. Never writes into live iCloud Drive / Photos.
if CommandLine.arguments.contains("--restore") {
    restoreCommand()
    exit(0)
}

// Sampled test-restore: prove a backup is restorable by restoring a random
// sample into a throwaway temp dir + verify, then deleting it. Read-only on the repo.
if CommandLine.arguments.contains("--test-restore") {
    testRestoreCommand()
    exit(0)
}

// Destination management (read-only list / add / remove), then exit. These edit
// only the local store; remove never touches remote data.
if CommandLine.arguments.contains("--list-destinations") {
    listDestinations()
    exit(0)
}
if let name = argValue("--add-destination") {
    addDestination(name: name)
    exit(0)
}
if let name = argValue("--remove-destination") {
    removeDestination(name: name)
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
    do { try LaunchdTimer.install(schedule: parseSchedule(), configPath: configPath); exit(0) }
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

// --limit-upload / --clear-limit-upload change the backup set's PERSISTENT
// upload throttle (the launchd timer and a bare run read it from the set); they
// are NOT per-run flags — there is no ad-hoc throttle. Combined with the ad-hoc
// source flags they would silently win the set-management dispatch below (edit
// the set and exit), so a user expecting a throttled one-off backup would get
// none. Reject the ambiguous combination loudly instead of quietly skipping it.
if CommandLine.arguments.contains("--limit-upload")
    || CommandLine.arguments.contains("--clear-limit-upload") {
    if !argValues("--drive-folder").isEmpty || !argValues("--photo-album").isEmpty {
        Console.error("--limit-upload / --clear-limit-upload change the backup set's PERSISTENT upload throttle; they are not per-run flags (a run reads the throttle from the set — there is no ad-hoc throttle). Set it on its own first (`baaackaaab --limit-upload <KiB/s>`), then run the backup separately. Combined with --drive-folder/--photo-album it would silently edit the set and skip the backup.")
        exit(1)
    }
}

// Backup-set management (--list / --add-* / --remove-* / --limit-upload): edit
// the set and exit. --limit-upload is a PERSISTENT knob (like --add-folder), not
// a per-run flag — a backup reads the throttle from the set, never from argv.
if ["--list", "--add-folder", "--remove-folder", "--add-album", "--remove-album",
    "--limit-upload", "--clear-limit-upload"]
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
var configLimitUploadKiBps: Int? = nil
if driveFolders.isEmpty && photoAlbums.isEmpty
    && FileManager.default.fileExists(atPath: configPath.path) {
    do {
        let set = try BackupSet.load(from: configPath)
        driveFolders = set.driveFolders
        photoAlbums = set.photoAlbums
        configQuotaBytes = set.quotaBytes
        configLimitUploadKiBps = set.limitUploadKiBps
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
let backupDryRun = CommandLine.arguments.contains("--dry-run")

// Scratch dir for photo batches + the manifest (Drive is backed up in place, so
// it is not copied here). Default to an ABSOLUTE path under Caches: a relative
// `./tmp/staging` would resolve against the launchd run's CWD (/), writing to
// /tmp/staging or failing — the scheduled backup must not depend on CWD.
let stagingURL: URL = {
    if let s = argValue("--staging") {
        return URL(fileURLWithPath: (s as NSString).expandingTildeInPath, isDirectory: true)
    }
    return FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Caches/baaackaaab/staging", isDirectory: true)
}()
let photoBatchBytes = positiveIntArg("--photo-batch-bytes", default: 3_000_000_000, unit: "bytes")
let host = argValue("--host") ?? ProcessInfo.processInfo.hostName
// Optional remote-quota pre-flight. The rest-server's `--max-size` is a hard
// server-side stop; this is a soft client-side gauge that warns BEFORE a run
// when the repo is filling up, so the cap can be raised in time. We can't query
// the server's configured quota, so it comes from --repo-quota-bytes or the set.
let repoQuotaBytes: Int? = {
    guard let raw = argValue("--repo-quota-bytes") else { return configQuotaBytes }
    guard let n = Int(raw), n > 0 else {
        Console.error("--repo-quota-bytes needs a positive integer (bytes) — got '\(raw)'")
        exit(1)
    }
    return n
}()
let quotaWarnFraction: Double = {
    guard let raw = argValue("--quota-warn-fraction") else { return 0.85 }
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
let runTag = argValue("--run-tag") ?? "run-\(runFmt.string(from: Date()))"
let runStart = Date()

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
    repoQuotaBytes: repoQuotaBytes,
    quotaWarnFraction: quotaWarnFraction,
    driveFolders: driveFolders,
    photoAlbums: photoAlbums,
    stagingURL: stagingURL,
    photoBatchBytes: photoBatchBytes
).execute()
