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
        ("--export-recovery-kit <path>", "write an OFFLINE recovery sheet (every destination's repo URL + password), AES-256 encrypted, then exit"),
        ("--export-recovery-kit-plain <path>", "same, but UNENCRYPTED (extra-loud warning) — for when you'll encrypt it yourself"),
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
        ("--rest-connections <n>", "persist a cap on the REST backend's parallel connections (restic's default is 5)"),
        ("--clear-rest-connections", "restore restic's default connection count"),
        ("--read-concurrency <n>", "persist how many files restic reads concurrently while backing up, 1…64 (restic's default is 2)"),
        ("--clear-read-concurrency", "restore restic's default read concurrency"),
        ("--defer-on-battery", "scheduled/catch-up runs skip while on battery power (interactive runs always proceed)"),
        ("--no-defer-on-battery", "restore the default — scheduled runs proceed on battery too"),
        ("--repo-quota <bytes>", "persist the server quota for the pre-flight gauge (the timer warns too)"),
        ("--clear-repo-quota", "remove the persisted quota gauge"),
        ("--large-file-warn-mib <n>", "persist a warn-only large-file threshold in MiB (default 4096; 0 disables)"),
        ("--clear-large-file-warn-mib", "reset the large-file warning threshold to the default"),
        ("--set-heartbeat <url>", "persist a dead-man's-switch heartbeat URL, pinged at run start/success/fail"),
        ("--clear-heartbeat", "remove the heartbeat URL"),
        ("--add-ntfy <url>", "persist an ntfy topic URL to push the run outcome to (repeatable)"),
        ("--add-webhook <url>", "persist a webhook URL to POST the run outcome to as JSON (repeatable)"),
        ("--remove-notify <url>", "drop a previously-added ntfy/webhook channel by its URL"),
        ("--set-prom-textfile <dir>", "persist a node_exporter textfile-collector dir; every real run writes <dir>/baaackaaab.prom"),
        ("--clear-prom-textfile", "stop writing the Prometheus textfile"),
        ("--config <path>", "backup-set file (default ~/.config/baaackaaab/backup-set.json)"),
    ])
    Console.note("A bare `baaackaaab` (no source flags) backs up the set; the launchd timer runs exactly that. Any explicit --drive-folder/--photo-album REPLACES the whole set for that run (folders AND albums), it does not add to it. Add --dry-run to preview a backup (reports what would upload, writes nothing; Photos are skipped in a dry run). On a terminal a real backup shows a live progress bar (percent, bytes, ETA); piped or under the timer it logs one concise tally line per backup (a dry run keeps restic's plain file-list output).")
    Console.note("Every backup already excludes macOS junk (.DS_Store, .Trashes, .Spotlight-V100, …) and CACHEDIR.TAG-tagged caches — important on an append-only store the Mac can never prune. --add-exclude / --add-exclude-file add your own patterns on top.")
    Console.note("--large-file-warn-mib is WARN-ONLY: it never excludes anything or changes a run's outcome. Any acquired Drive/Photos file over the threshold prints a warning after acquisition so you can decide whether to --add-exclude it — once a file is snapshotted, the append-only store can never shed it.")

    Console.section("Monitoring & notifications", detail: "outbound heartbeat + push — a macOS banner is invisible when you're away")
    Console.info([
        ("--test-notify", "fire a sample message through every configured channel + a heartbeat ping, report delivered/failed, then exit"),
        ("--status-export", "rebuild status.json (+ the Prometheus textfile, if configured) on demand, print its path, then exit"),
    ])
    Console.note("The heartbeat is a Healthchecks-style dead-man's switch: GET <url>/start at run begin, GET <url> on success, GET <url>/fail on failure. The alarm fires on the MONITOR side when a ping goes missing — the only way to catch a run that stopped happening entirely (crashed, unplugged, timer disabled), not just one that failed while running. Push channels (ntfy/webhook) additionally deliver the outcome away from the Mac. Both are best-effort: a delivery failure never changes a run's exit code. --test-notify proves the whole path before you rely on it.")
    Console.note("Every REAL run (never a dry run) also writes status.json under the support dir — a stable, documented machine-readable snapshot (last run, per-destination churn, repo size/quota, last restore drill) for scripts/dashboards that would rather poll a file than parse console output. --set-prom-textfile additionally writes a node_exporter textfile-collector file alongside it. Both are best-effort like the heartbeat/push channels above.")

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
        ("--history <path>", "show a file's version history across ALL snapshots (size + mtime per version), then exit"),
        ("--restore", "restore a snapshot into a fresh directory (preview → confirm → verify)"),
        ("--test-restore", "restore a random file sample into a temp dir + verify (proves restorability), then exit"),
        ("--restore-drill", "scheduled drill: restore-verify a rotating sample (one drive folder + one photo batch) into a temp dir, record the outcome, then exit"),
        ("--sample <n>", "with --test-restore / --restore-drill, how many files to sample (default 10 / 5)"),
        ("--max-bytes <n>", "with --test-restore / --restore-drill, byte budget for the sample (default 1000000000 / 500000000)"),
        ("--destination <name>", "source destination (required when several are configured)"),
        ("--snapshot <id>", "which snapshot to find/restore (short id; default 'latest')"),
        ("--target <dir>", "restore into this dir (default: ~/baaackaaab-restore/<snap>-<stamp>)"),
        ("--include <path>", "restore only this subpath — a folder (subtree) or one file"),
        ("--dry-run", "preview what would be restored, write nothing"),
        ("--yes", "skip the confirm prompt (required for a non-interactive restore)"),
        ("--no-verify", "skip the post-restore re-read verification (on by default)"),
    ])
    Console.note("Three restore modes: full (--restore), subtree (--restore --include <folder>), single-file (--find <name> to locate, then --restore --include <path>). Restore never writes back into iCloud Drive or Photos — it lands in a fresh directory you then move things back from.")

    Console.section("Maintenance & diagnostics (repo health; read-only except --unlock)")
    Console.info([
        ("--verify-repo", "run `restic check` per destination (structure; read-only), then exit"),
        ("--read-data-subset <s>", "with --verify-repo, also re-read this fraction of pack data (5%, 1/10, 10M)"),
        ("--rotate-read-data", "with --verify-repo, re-read the NEXT rotating 1/8 slice of pack data + record it (what the check timer runs); full coverage every 8 runs"),
        ("--unlock", "remove STALE locks for --destination — the only delete op (lock files only)"),
        ("--remove-all", "with --unlock, remove ALL locks (only when no backup is running)"),
        ("--repo-usage", "what fills the permanent store: aggregated sizes from the latest snapshot, per destination"),
    ])
    Console.note("--verify-repo only READS the repo. A damaged repo is repaired SERVER-side (the Mac has no delete/prune right). --unlock is the single exception: it deletes lock files only (never snapshots/data), removes stale locks by default, and needs --destination + a confirm (or --yes).")

    Console.section("Schedule (launchd timer)")
    Console.info([
        ("--install-timer", "install a LaunchAgent that backs up the set on a schedule, then exit"),
        ("--at <HH:MM>", "time of day (repeatable for several runs/day; default 12:00)"),
        ("--days <list>", "restrict to weekdays, e.g. mon,wed,fri (default: every day)"),
        ("--uninstall-timer", "remove the LaunchAgent, then exit"),
        ("--timer-status", "show whether the timer is installed + loaded, then exit"),
        ("--install-drill-timer", "install a LaunchAgent that runs a MONTHLY restore drill, then exit"),
        ("--day <n>", "with --install-drill-timer, day-of-month 1…28 (default 1; --at sets the time, default 03:00)"),
        ("--uninstall-drill-timer", "remove the restore-drill LaunchAgent, then exit"),
        ("--install-check-timer", "install a LaunchAgent that runs a rotating integrity check (--at / --days, like the backup timer), then exit"),
        ("--uninstall-check-timer", "remove the integrity-check LaunchAgent, then exit"),
    ])
    Console.note("The timer runs `baaackaaab --run-tag scheduled` (backs up the set). restic reads the credential files directly, so the unattended run needs no Keychain prompt — only a one-time Photos grant (`make release` + one manual backup, so a stable signature keeps the TCC grant across rebuilds).")
    Console.note("The backup timer also runs at login/boot (RunAtLoad) with a --catch-up marker: that run backs up only if the last successful backup is older than the schedule's interval (catching up a slot missed while the Mac was off), and exits quietly otherwise. Existing installs pick this up on the next --install-timer.")
    Console.note("The monthly restore-drill timer runs `baaackaaab --restore-drill`: it restore-verifies a rotating sample into a temp dir (read-only on the store), records the result in the run history, and posts a banner ONLY on failure. The command center shows the last verified restore; --doctor reports it too.")
    Console.note("The integrity-check timer runs `baaackaaab --verify-repo --rotate-read-data`: each run re-hashes the next rotating 1/8 of the pack data with `restic check` (read-only), records it, and banners only on failure — after 8 runs every pack has been re-read once (on-disk bit-rot detection the restore drill can't be). The command center and --doctor show the last check + slice position.")

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
