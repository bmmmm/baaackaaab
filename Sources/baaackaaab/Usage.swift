import Foundation
#if canImport(Darwin)
import Darwin
#endif

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
        ("--add-exclude <glob>", "exclude a restic pattern on top of the macOS-junk defaults (repeatable)"),
        ("--remove-exclude <glob>", "drop a previously-added exclude pattern (repeatable)"),
        ("--add-exclude-file <path>", "add a restic exclude-file (one pattern per line; must exist; repeatable)"),
        ("--remove-exclude-file <path>", "drop a previously-added exclude-file (repeatable)"),
        ("--limit-upload <n>", "persist an upload throttle of n KiB/s (applies to the timer too)"),
        ("--clear-limit-upload", "remove the upload throttle"),
        ("--pack-size <mib>", "persist a restic target pack size in MiB (4…128; fewer round-trips on a network store)"),
        ("--clear-pack-size", "restore restic's default pack size (16 MiB target)"),
        ("--repo-quota <bytes>", "persist the server quota for the pre-flight gauge (the timer warns too)"),
        ("--clear-repo-quota", "remove the persisted quota gauge"),
        ("--config <path>", "backup-set file (default ~/.config/baaackaaab/backup-set.json)"),
    ])
    Console.note("A bare `baaackaaab` (no source flags) backs up the set; the launchd timer runs exactly that. Explicit --drive-folder/--photo-album override the set for ad-hoc runs. Add --dry-run to preview a backup (reports what would upload, writes nothing; Photos are skipped in a dry run). On a terminal a real backup shows a live progress bar (percent, bytes, ETA); piped or under the timer it logs restic's plain output.")
    Console.note("Every backup already excludes macOS junk (.DS_Store, .Trashes, .Spotlight-V100, …) and CACHEDIR.TAG-tagged caches — important on an append-only store the Mac can never prune. --add-exclude / --add-exclude-file add your own patterns on top.")

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
        ("--repo-quota-bytes <n>", "server quota for THIS run only — persist it with --repo-quota so the timer warns too"),
        ("--quota-warn-fraction <f>", "warn at this fraction of quota (default 0.85)"),
    ])

    Console.section("Diagnostics")
    Console.info([
        ("--doctor", "consolidated health check: restic, destinations, disk, Photos, timer, updates"),
        ("--check-updates", "compare restic + the REST server against the latest releases (contacts GitHub), then exit"),
        ("--materialize-test <file>", "prove a dataless stub re-materializes, then exit"),
        ("--evict-test <file>", "prove the evict/re-download round-trip, then exit"),
        ("-h, --help", "show this help and exit"),
    ])
    Console.note("--doctor also checks restic + the REST server against the versions baaackaaab is tested against (offline, no GitHub); --check-updates additionally asks GitHub for the newest releases. The unattended timer posts a banner when restic / the server has fallen behind the tested baseline.")

    Console.section("Examples")
    Console.note("baaackaaab --restic-repo rest:https://host/repo \\\n             --drive-folder ~/Documents --photo-album \"Backup\"")
    Console.note("RESTIC_REPOSITORY=rest:https://host/repo baaackaaab \\\n             --drive-folder ~/Documents --repo-quota-bytes 50000000000")
    print("")
}
