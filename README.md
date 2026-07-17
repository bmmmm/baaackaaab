# baaackaaab

One-way backup for iCloud Drive and iCloud Photos into an immutable
[restic](https://restic.net) repository, built to survive ransomware: the Mac can
only ever **add** to the backup store, never delete or overwrite it.

It is a single Swift command-line tool for macOS. A bare run backs up a declarative
*backup set*; an interactive terminal UI edits that set and shows a remote
dashboard; a launchd timer runs it unattended.

## Why this exists

A normal backup tool with delete/prune rights is a liability: malware (or a bug)
that controls your Mac can wipe the backups along with the originals. baaackaaab is
built around one rule — **the Mac is read + append only toward the backup store** —
so a compromised Mac can add new snapshots but can never destroy old ones.

### The safety model

```
iCloud  ──materialize──▶  verify real bytes  ──backup──▶  immutable store  ──verify──▶  (optional) evict
(source)                  (SF_DATALESS off,                (restic, append-                          from iCloud
                           size > 0)                        only server)
```

- **iCloud is the source and the evict target, never a backup target.** Data only
  flows *out* of iCloud into the store.
- **Nothing is evicted from iCloud before its backup is verified.**
- **Restore is manual, into a fresh directory** — never back over iCloud. The
  restore engine hard-rejects any target inside live iCloud Drive or Photos.
- The store runs a restic REST server in **`--append-only`** mode: the Mac holds no
  delete/prune right at all. Pruning happens server-side. The single delete
  operation the Mac may perform is `restic unlock` (lock files only, never data).

## Requirements

- macOS 13 (Ventura) or later — iCloud Drive is FileProvider-backed from Ventura on.
- A Swift 6 toolchain (Xcode or the Swift toolchain).
- [`restic`](https://restic.net) on `PATH` (developed against restic 0.19).
- A backup store. The intended Tier-1 target is a
  [restic REST server](https://github.com/restic/rest-server) running with
  `--append-only --private-repos`, but any restic backend works (a local path,
  `sftp:`, `s3:`, `b2:`, …) — see [Backends & the immutability
  caveat](#backends--the-immutability-caveat) for what that does and doesn't buy
  you on non-REST stores.

## Build & install

```sh
make sign-init      # one-time: create / pick a stable code-signing identity
make release        # release build + sign  →  .build/release/baaackaaab

# put it on PATH (the launchd timer resolves the absolute path it is installed at)
ln -sf "$PWD/.build/release/baaackaaab" ~/.local/bin/baaackaaab
```

`make` (debug) and `make release` both re-sign the binary. Stable signing matters:
an ad-hoc signature changes on every rebuild, which resets the Photos (TCC) grant
and would make the unattended timer stall on a permission prompt.

> If you change the code, rebuild **both** `make` and `make release` — the PATH
> symlink points at the release binary, but `swift build` alone only rebuilds debug.

## First-run setup

The two secrets — the endpoint (htpasswd) password embedded in the repo URL and the
restic repository encryption password — live in two `0600` files under
`~/Library/Application Support/baaackaaab/`. They never reach a process argument
list or this tool's environment; restic reads the files directly via
`RESTIC_REPOSITORY_FILE` / `RESTIC_PASSWORD_FILE`.

The real server host is private infrastructure and is **not** in the source. Supply
it at setup time via environment variables (e.g. from `~/.env`):

```sh
export BAAACKAAAB_ENDPOINT_HOST=restic.example.com   # your rest-server host
export BAAACKAAAB_ENDPOINT_USER=macbook              # htpasswd user = repo subpath

baaackaaab --init-credentials   # generates both secrets, writes the 0600 files,
                                # and prints the htpasswd line to add on the server
```

Add the printed `user:$2y$…` line to the server's htpasswd file, then:

```sh
baaackaaab --check              # reach the server, init the repo, exit
```

Migrating from an older Keychain-based install instead? `baaackaaab
--migrate-credentials` moves the existing secrets into the files (one last Keychain
prompt) without regenerating them, so the existing repo stays readable.

## Usage

`baaackaaab --help` lists every flag. The essentials:

### The backup set

What a bare run backs up lives in `~/.config/baaackaaab/backup-set.json` — a plain,
hand-editable file that is the single source of truth. Every front-end just edits it.

```sh
baaackaaab --add-folder ~/Documents      # add an iCloud Drive folder
baaackaaab --add-album "Camera Roll"     # add an iCloud Photos album
baaackaaab --list                        # show the set
baaackaaab --configure                   # interactive TUI editor (browse + toggle)
```

### Running a backup

```sh
baaackaaab                 # back up the set (this is what the timer runs)
baaackaaab --dry-run       # preview what would upload; writes nothing
```

On a terminal a real backup shows a live progress bar; piped or under the timer it
logs restic's plain output. Explicit `--drive-folder` / `--photo-album` flags
**replace the whole set for that run** — folders *and* albums; a single
`--photo-album Extra` backs up only that album, not the set plus one album. Run
`baaackaaab` with no arguments in a terminal
to open the **command center** — the set plus a remote dashboard, with keys to edit,
sync now, refresh remote status, and check restic / server updates (`u`, contacts GitHub).

Because the Mac can only stage a fraction of the data set at once, Photos are
exported and uploaded in byte-budgeted batches (each backed up, then deleted), so
one run produces several restic snapshots that share a `run-<timestamp>` tag.

### Restoring

Restore is safe by construction: it always writes to a **fresh** directory (never
back into iCloud), previews with `--dry-run`, and re-reads every file with
`--verify` afterward.

```sh
baaackaaab --snapshots                              # browse snapshots, newest first
baaackaaab --find report.pdf --snapshot latest      # locate a single file
baaackaaab --history report.pdf                     # every version of a file across ALL snapshots
baaackaaab --restore --include path/to/report.pdf   # single-file restore
baaackaaab --restore --include some/folder          # subtree restore
baaackaaab --restore                                # full restore (latest)
baaackaaab --test-restore                           # restore a random sample + verify
```

Photos restore to their **original files** (import them back via Photos > File >
Import), not a rebuilt `.photoslibrary`.

### Multiple destinations

Back up to several independent restic repositories at once — each a full copy with
its own encryption key, for blast-radius isolation (no cross-repo dedup).

```sh
baaackaaab --add-destination offsite --repo-url rest:https://other/repo --order 1
baaackaaab --list-destinations
```

A run backs up to every enabled destination, primary-first. The Mac stays read +
append only toward all of them.

### Backends & the immutability caveat

A destination is just a restic repository URL plus its own encryption key, so
baaackaaab is **backend-agnostic** — anything restic can address works:
`rest:` (the Tier-1 target), a local path, `sftp:`, `s3:` (Amazon **and** any
S3-compatible store — MinIO, Garage, Wasabi), `b2:`, `azure:`, `gs:`, or an
`rclone:` remote (which opens dozens more). See restic's
[preparing a repository](https://restic.readthedocs.io/en/stable/030_preparing_a_new_repo.html)
for the exact URL forms.

Two things do **not** come for free on those backends, though:

- **Backend credentials.** S3/B2/Azure/GCS authenticate with their own env vars
  (`AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`, `B2_ACCOUNT_ID` /
  `B2_ACCOUNT_KEY`, …). baaackaaab stores only the repo URL and the restic
  encryption key per destination — it does **not** hold backend credentials — so
  those vars must be in the process environment. An interactive run picks them up
  from your shell (e.g. `~/.env`); the **launchd timer does not inherit them** (its
  plist sets only `PATH`), so a scheduled S3/B2 backup needs them added to the
  LaunchAgent's `EnvironmentVariables`, or restic can't authenticate.
- **The append-only guarantee is REST-server-specific.** The ransomware defense —
  the Mac *physically cannot delete* — is enforced by the rest-server's
  `--append-only` mode at the protocol layer. Plain `s3:` / `b2:` / `sftp:` / a
  local path have no such restic-level enforcement: a key that can write can
  usually also delete. To approximate the guarantee there you must enforce
  immutability at the **storage** layer — S3/B2 **Object Lock** (compliance mode)
  plus an IAM policy without `DeleteObject`. Without that, such a destination is a
  valid *extra copy* but does not carry the append-only safety property, so keep
  the append-only REST server (or an object-locked bucket) as the Tier-1 store.

### Tuning

Two persistent knobs live in the backup set (so the unattended timer uses them too):

```sh
baaackaaab --limit-upload 2048         # cap upload at ~2 MiB/s (KiB/s); --clear-limit-upload lifts it
baaackaaab --pack-size 64              # restic target pack size in MiB, 4…128; --clear-pack-size resets
baaackaaab --read-concurrency 4        # files restic reads concurrently, 1…64 (restic default 2); --clear-read-concurrency resets
baaackaaab --repo-quota 50000000000    # server quota (bytes) for the pre-flight gauge; --clear-repo-quota
```

`--repo-quota` feeds the soft pre-flight gauge: each run reads the repo size
first and warns once it passes 85% (`--quota-warn-fraction`) of the configured
quota — lead time to raise the rest-server's `--max-size` before it hard-stops
backups at 100%. Persisted in the set, so the unattended timer warns too
(`--repo-quota-bytes` remains the one-run override).

`--pack-size` trades RAM and re-upload-on-interruption for **fewer, larger objects**
on the backend — worth it for the many small Drive files over a network REST/S3
store, pointless for already-large photo blobs (restic's default 16 MiB target is
fine there). See restic's
[tuning backup parameters](https://restic.readthedocs.io/en/stable/047_tuning_backup_parameters.html).

Every backup also runs restic with `--skip-if-unchanged`: when a source is
unchanged, restic creates **no new snapshot**. Treat this as a *best-effort*
reduction of redundant snapshots, not a guarantee — restic compares the full
absolute path *including its ancestor directories*, and an ancestor's mtime/ctime
drifting from unrelated activity (e.g. anything touching `~/Library`) defeats the
skip for that run. Reliable snapshot retention is the **server's** job (a
`forget`/`prune` policy), since the Mac holds no prune right; the flag just trims
some of what the server would otherwise have to prune. Repository-v2 zstd
compression (`--compression auto`) is likewise always on — it helps text/PDF,
leaves already-compressed media untouched.

**Excludes.** Every backup drops macOS filesystem junk — `.DS_Store`, `.Trashes`,
`.Spotlight-V100`, `.fseventsd`, `.DocumentRevisions-V100`, `.TemporaryItems` — plus
any directory tagged with `CACHEDIR.TAG` (`--exclude-caches`). This matters more here
than in an ordinary restic setup: the Mac has no prune right, so **anything
snapshotted is permanent** — junk that gets in can never be removed. Add your own
patterns on top (persisted in the set, so the timer applies them too):

```sh
baaackaaab --add-exclude '*.tmp'                 # a restic exclude glob (repeatable)
baaackaaab --add-exclude 'node_modules'          # matches that base name at any depth
baaackaaab --add-exclude-file ~/my-excludes.txt  # a file of patterns (one per line; must exist)
baaackaaab --list                                # shows your patterns + the always-on defaults
```

Patterns follow restic's [exclude rules](https://restic.readthedocs.io/en/stable/040_backup.html#excluding-files)
(matched on path components; a slash-less pattern matches the base name anywhere). An
`--add-exclude-file` must exist at add time; if it later vanishes it is dropped with a
warning at run time rather than failing the backup.

### Anomaly warning (source-side tripwire)

The append-only store protects *old* snapshots — a compromised Mac can add but
never delete history. What it can't tell you is that the **source** is being
mass-rewritten right now: ransomware that encrypts your iCloud files makes every
file look changed, so the next backup dutifully re-uploads everything. To the store
that looks like a normal (if large) run.

So every backup records its churn (files/bytes/data added, per destination) into the
run history and compares this run against a median baseline of the prior successful
runs to the same destination. Two shapes raise a loud, actionable warning — on the
console and, on an unattended run, as a macOS banner:

- **Spike** — data added is more than 10× the baseline median *and* over 1 GiB:
  "if you did not add/re-encode large amounts of data, check the source for mass
  modification".
- **Shrink** — the source processed less than half the baseline: "check that iCloud
  is signed in and folders/albums still resolve".

This is deliberately **warn-only**: it never changes the run's exit code and never
touches eviction — a false positive costs a banner, never a backup. It stays silent
until at least three baseline runs exist, so early runs don't false-alarm, and it
persists nothing new (the baseline is derived from the existing run history each run).

### Scheduling

```sh
baaackaaab --install-timer --at 12:00        # daily LaunchAgent
baaackaaab --install-timer --at 02:00 --days mon,wed,fri
baaackaaab --timer-status
baaackaaab --uninstall-timer
```

The timer runs `baaackaaab --run-tag scheduled`. It needs no Keychain prompt (the
credential files are read directly); it needs a one-time Photos grant, which a
stable signature then keeps alive across rebuilds.

### Monitoring & notifications

The macOS banner (`Notifier.swift`) is invisible when you're away from the Mac,
and nothing about it can tell "a run failed" apart from "the Mac never even ran
it" — a crashed process, an unplugged machine, or a disabled timer just goes
silent. Both problems need a MONITOR-side dead-man's switch, not another local
notification.

```sh
baaackaaab --set-heartbeat https://hc-ping.com/your-uuid   # or your own Gatus/Uptime-Kuma/healthchecks
baaackaaab --add-ntfy https://ntfy.sh/your-topic
baaackaaab --add-webhook https://your-endpoint/hook
baaackaaab --test-notify                                   # prove the path before you rely on it
```

**Heartbeat semantics.** The heartbeat follows the [Healthchecks](https://healthchecks.io)
convention (self-hosted Gatus/Uptime-Kuma monitors that speak the same
convention work identically): `GET <url>/start` at run begin, a bare `GET <url>`
on success, `GET <url>/fail` on failure. The alarm fires on the **monitor's**
side when an expected ping goes missing — that is the only way to catch a run
that stopped happening entirely, which a local banner structurally cannot do
(it needs a machine that is still running baaackaaab at all). Persisted in the
backup set, so the unattended timer pings it too — that scheduled run is the
whole point.

**Push channels.** `--add-ntfy` / `--add-webhook` additionally deliver the run
outcome away from the Mac: ntfy gets a plain-text push (the same summary the
banner shows, with a `Title:` header and high priority on failure); a webhook
gets a JSON POST — `{ event, outcome, started, finished, verified, total,
destinations: [{name, ok}], message }`. Both are repeatable (`--remove-notify
<url>` drops one by URL) and fire on every terminal outcome, not just failures
— a heartbeat "success" ping is what resets the monitor's clock.

**Privacy note.** These payloads carry status only — counts, an outcome word, a
human summary — never a repo URL, a file path, or a credential-file location
(`destinations` carries only `{name, ok}`, no error text). The heartbeat/ntfy/
webhook URLs themselves may embed a bearer token (an ntfy topic, a Healthchecks
UUID, a webhook path secret); `--list` and every log line redact them the same
way a repo URL is redacted — `--list` shows only `scheme://host/***`. If you
don't want any run metadata leaving your infrastructure at all, point these at
a self-hosted monitor (Gatus, Uptime-Kuma, a self-hosted ntfy, your own webhook
receiver) instead of a public one.

**Best-effort by contract**, matching the banner and `UpdateCheck`'s
network-degrades-gracefully philosophy: a delivery failure is logged (one
console line) and never changes a run's exit code. `--test-notify` is the way
to actually prove delivery works — it fires a clearly-marked sample message
through every configured channel plus a heartbeat ping, synchronously, and
reports delivered/failed per channel with an actionable reason (e.g. "ntfy
returned HTTP 404 — check the topic URL is correct").

### Machine-readable status

Heartbeat/push notify on a run's *outcome*; sometimes you want to poll a file
instead — a status widget, a `cron`-driven check, a Prometheus scrape. Every
REAL run (never a dry run — it wrote nothing worth reporting) writes
`status.json` under the support dir (`~/Library/Application Support/baaackaaab/`,
or `$BAAACKAAAB_SUPPORT_DIR`). `baaackaaab --status-export` rebuilds it (and the
Prometheus textfile below, if configured) on demand and prints its path,
without waiting for the next scheduled run.

Unlike `runs.ndjson` (an internal implementation detail, free to change shape),
`status.json` is a **stable, documented contract** — additions are additive
only. Top-level keys:

```
schema_version   integer, currently 1
generated_at     ISO-8601 timestamp this file was written
last_run         { tag, start, end, exit_code, outcome, verified, total, source_failures }
                 outcome is one of "ok" | "partial" | "failed" | "cancelled"
destinations     [ { name, ok, data_added, bytes_processed } ]   — the last run's per-destination churn;
                 data_added/bytes_processed are OMITTED (not null) when that run had no metrics for it
repo             { size_bytes, quota_bytes, quota_fraction }     — present only when the repo size was sampled
last_drill       { time, ok, bytes, snapshots }                  — present only once a restore drill has run;
                 snapshots is the sampled-snapshot COUNT, not their ids
```

`last_run`/`repo`/`last_drill` are each entirely absent (not `null`-filled)
until there is something to report — no backup run yet, no quota configured
and no `--status-export` probe run, no restore drill yet, respectively.

```sh
baaackaaab --set-prom-textfile /usr/local/etc/node_exporter/textfile_collector
baaackaaab --clear-prom-textfile
```

**Prometheus.** With a directory configured, the same moments that write
status.json also write `<dir>/baaackaaab.prom` in node_exporter's
[textfile-collector](https://github.com/prometheus/node_exporter#textfile-collector)
format — point `node_exporter --collector.textfile.directory=<dir>` at it.
Gauges: `baaackaaab_last_run_timestamp_seconds`, `baaackaaab_last_run_success`
(0/1), `baaackaaab_last_run_exit_code`, `baaackaaab_verified_files`,
`baaackaaab_total_files`, `baaackaaab_dest_ok{dest="…"}`,
`baaackaaab_dest_data_added_bytes{dest="…"}`, `baaackaaab_repo_size_bytes`,
`baaackaaab_repo_quota_bytes`, `baaackaaab_last_drill_timestamp_seconds`. A
metric with no known value (e.g. the repo size was never sampled) is omitted
entirely rather than emitted as 0. If the directory doesn't exist or isn't
writable, a run logs one actionable warning and continues — this never fails a
backup, matching the heartbeat/push contract above.

**Privacy note.** Both files carry status only — counts, booleans, byte
figures, an outcome word — never a repo URL, a file path, or a credential-file
location, the same discipline as the heartbeat/push payloads above. Treat
`status.json` as world-visible content even though it is written `0600`: any
other local tool/process that can read the support dir can read it (the
Prometheus textfile is written with the directory's default permissions, since
node_exporter itself needs to read it).

### Maintenance & diagnostics

```sh
baaackaaab --doctor          # restic, destinations, append-only, disk, Photos, timer, updates — read-only
baaackaaab --verify-repo     # restic check per destination (read-only)
baaackaaab --check-updates   # compare restic + the REST server against the latest releases
baaackaaab --unlock --destination offsite   # remove STALE locks (the only delete op)
```

`--doctor`'s "Append-only enforcement" section actively PROVES the core safety
guarantee instead of just documenting it: for each enabled `rest:` destination it
sends an HTTP DELETE for a guaranteed-absent, non-existent object under `data/`
(never `locks/`, never a real object — so the probe cannot destroy anything even
if enforcement is missing) and checks the response. A `403` means the server
rejected it — append-only holds. A `404` or `2xx` means the server actually
considered or accepted the delete — a hard finding, since a rest-server started
without `--append-only` is otherwise indistinguishable from a correctly
configured one. Non-`rest:` destinations can't be checked at this protocol
level; see [Backends & the immutability caveat](#backends--the-immutability-caveat).

### Staying current

baaackaaab tracks two moving parts — the local `restic` CLI and the remote restic
REST server — against the versions it is **developed and tested against** (pinned in
`UpdateCheck.swift`). Two layers, so the default path never touches the public
internet:

- **Offline baseline** (`--doctor`, and every unattended timer run): the installed
  versions are compared against the pinned baselines. No GitHub. The scheduled run
  posts a macOS banner when restic or the server has fallen behind — the only signal
  you'd otherwise miss, since the scheduled log goes unread.
- **Online latest** (`--check-updates`, opt-in): additionally asks the GitHub
  releases API for the newest upstream release and compares. This is the only
  path that contacts `api.github.com` (the command center's `u` key runs the
  same check); if GitHub is unreachable it degrades to the offline baseline
  rather than failing.

The restic version is read locally (`restic version`). The REST server does not
advertise its version in the normal case, so the server check is best-effort — it
probes the HTTP `Server` header (a reverse proxy sometimes exposes it) and otherwise
reports the latest release for you to compare against your server yourself. The
header probe sends only `scheme://host`, never the repository password. Being behind
is informational; it never fails a backup or a check.

## Tests

```sh
make test     # or: swift test
```

The suite covers the headless pure-logic surface — argument parsing, the backup-set
model, restore path-safety, secret redaction and credential generation, version
parsing/comparison and the server-endpoint extraction behind the update check, the
append-only DELETE probe's status-code classification and rest:-URL/credential
derivation, the launchd schedule round-trip, staging-path sanitizing, notification
escaping, the heartbeat/ntfy/webhook request construction and monitor-URL
redaction, and the on-disk destination and run-history stores. Store tests relocate
to a throwaway directory via `BAAACKAAAB_SUPPORT_DIR`, so they never touch the real
credential store. The live GitHub query, the HTTP header probe, the append-only
DELETE probe, and the heartbeat/ntfy/webhook network sends touch the network, so
they are not unit-tested — all degrade to nil/unreachable (or, for outbound
monitoring, a logged no-op that never changes the run's exit code) by construction.

A second layer of **live restic integration tests** (`ResticIntegrationTests`)
drives the real `restic` binary against a throwaway *local* repository — no
server, no network — to verify the parts unit tests can't reach: the typed
exit-code mapping (repo absent / locked / wrong password), `--skip-if-unchanged`,
`--pack-size`, the **excludes** (macOS-junk defaults, `--exclude-caches`, and custom
globs are all kept out of the snapshot), a full **backup → restore → verify
roundtrip**, `find` / `ls` / `diff`, the exit-3 partial snapshot (an unreadable file
still yields a valid snapshot of the rest), `check`, `unlock`, and snapshot/stats
parsing. They are
skipped automatically when `restic` isn't on `PATH`, so the suite still passes
without it.

The TTY TUI, live restic against a real *rest-server*, Photos/TCC, and the launchd
timer are verified on real hardware, not in the test suite.

### Pre-push hook

There is no macOS CI runner for this project — the dev Mac is the only build host —
so a git pre-push hook gates pushes instead, running `swift build` + `swift test`
and blocking the push on failure. Enable it once:

```sh
make install-hooks
```

It skips the build+test entirely when a push's range touches none of `Sources/`,
`Tests/`, `Package.swift`, or `Makefile` (e.g. a README-only push). To push once
without waiting for it (or around a known-broken WIP commit):

```sh
git push --no-verify
```

## Layout

| File | Role |
|---|---|
| `BackupSet.swift` | the declarative source list (the JSON model) |
| `DriveAcquirer.swift` | materialize + verify iCloud Drive folders in place |
| `PhotosAcquirer.swift` | export iCloud Photos albums in batches (PhotoKit) |
| `Destination.swift` | the multi-destination model + on-disk store |
| `ResticBackend.swift` | the restic shell-out (per-process env, secrets off argv) |
| `BackupRun.swift` | one run: quota → Drive → Photos → manifest → history |
| `RestoreEngine.swift` | safe restore (fresh-target gate, forbidden roots) |
| `Secrets.swift` | the 0600 credential files + Keychain legacy read |
| `ConfigTUI.swift` | the raw-mode terminal UI (command center + editor) |
| `Timer.swift` | the launchd LaunchAgent |
| `UpdateCheck.swift` | restic + REST-server version checks (offline baseline / online latest) |
| `AppendOnlyProbe.swift` | `--doctor`'s active append-only enforcement DELETE probe |
| `Notifier.swift` | the local macOS banner (osascript), failure-only |
| `OutboundNotifier.swift` | outbound heartbeat + ntfy/webhook push, best-effort, every terminal outcome |
| `StatusExport.swift` | status.json (stable contract) + the Prometheus node_exporter textfile |

## Security notes

- Secrets live in `0600` files; only their **paths** are ever passed to restic. No
  secret reaches argv (world-readable via `ps`) or this tool's environment.
- The repo URL embeds the endpoint password; it is redacted wherever it is
  logged or shown — the password is masked (`user:***@host`), and for a
  token-as-username URL the whole userinfo is.
- Tracked source ships placeholder infrastructure values
  (`restic.example.com`, …); real values come from the environment at setup time
  and otherwise live only in the local credential files.
- The store is `--append-only`: a compromised Mac cannot delete or rewrite history.
  `--doctor` actively verifies this per `rest:` destination (an HTTP DELETE probe
  against a guaranteed-absent object) rather than only documenting it — see
  [Maintenance & diagnostics](#maintenance--diagnostics).

## Further reading (restic)

The behaviour of the store itself is restic's, not this tool's. The pages that map
directly onto how baaackaaab drives it:

- [Preparing a new repository](https://restic.readthedocs.io/en/stable/030_preparing_a_new_repo.html) — every backend URL form (`rest:`, `s3:`, `b2:`, `sftp:`, `rclone:`, …).
- [Backing up](https://restic.readthedocs.io/en/stable/040_backup.html) — tags, `--skip-if-unchanged`, exclude rules, exit code 3 (partial snapshot).
- [Tuning backup parameters](https://restic.readthedocs.io/en/stable/047_tuning_backup_parameters.html) — `--pack-size`, compression, read concurrency, and the local cache.
- [Working with repositories](https://restic.readthedocs.io/en/stable/045_working_with_repos.html) — `restic check --read-data-subset` (what `--verify-repo` runs) and lock handling (`unlock` only ever touches lock files, never data).
- [Restoring from backup](https://restic.readthedocs.io/en/stable/050_restore.html) — `restore --target` / `--include` / `--verify`, the primitives behind the safe-restore engine.
- [Removing backup snapshots](https://restic.readthedocs.io/en/stable/060_forget.html) — `forget`/`prune`, which run **server-side only**; the Mac never holds this right.
- [Scripting restic](https://restic.readthedocs.io/en/stable/075_scripting.html) — the typed exit codes (10 absent, 11 locked, 12 wrong password) baaackaaab keys its init/probe/check logic off.

## License

GPL-3.0. See [LICENSE](LICENSE).
