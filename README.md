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

#### Rotating integrity check

A second scheduled job re-hashes the *stored bytes* to catch on-disk bit-rot — the
thing a restore drill (which only samples) cannot. Each run re-reads the next
rotating **1/8** of the pack data with `restic check --read-data-subset`, so after
eight runs every pack has been re-read once:

```sh
baaackaaab --install-check-timer --at 04:00              # daily rotating read-data check
baaackaaab --install-check-timer --at 04:00 --days sun   # weekly, if daily is too much I/O
baaackaaab --uninstall-check-timer
baaackaaab --verify-repo --rotate-read-data              # run one slice by hand (what the timer runs)
```

It is read-only against the store, records each run in the history (with the slice
position), and banners **only** on failure. The command center and `--doctor` show
the last check and its slice (e.g. `integrity check 3/8 · 2d ago`). A plain
`baaackaaab --verify-repo` (no `--rotate-read-data`) is unchanged — the manual
structural check, with an optional one-off `--read-data-subset`.

The restore drill and the integrity check are complementary: the **drill** proves a
sample *decrypts and restores* end-to-end, the **check** proves *all bytes still
hash correctly* over time. Both install/uninstall independently of the backup timer
and of each other (`--timer-status` lists all three).

### Maintenance & diagnostics

```sh
baaackaaab --doctor          # restic, destinations, disk, Photos, timer, updates — read-only
baaackaaab --verify-repo     # restic check per destination (read-only)
baaackaaab --check-updates   # compare restic + the REST server against the latest releases
baaackaaab --unlock --destination offsite   # remove STALE locks (the only delete op)
```

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
launchd schedule round-trip, staging-path sanitizing, notification escaping, and
the on-disk destination and run-history stores. Store tests relocate to a throwaway directory via
`BAAACKAAAB_SUPPORT_DIR`, so they never touch the real credential store. The live
GitHub query and HTTP header probe touch the network, so they are not unit-tested —
both degrade to nil/baseline by construction.

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
