# Configuration

What a run backs up and where it goes. Everything on this page is persisted in
the backup set (`~/.config/baaackaaab/backup-set.json`) unless noted otherwise,
so the unattended timer honors it too.

## The backup set

What a bare run backs up lives in `~/.config/baaackaaab/backup-set.json` — a plain,
hand-editable file that is the single source of truth. Every front-end just edits it.

```sh
baaackaaab --add-folder ~/Documents      # add an iCloud Drive folder
baaackaaab --add-album "Camera Roll"     # add an iCloud Photos album
baaackaaab --list                        # show the set
baaackaaab --configure                   # interactive TUI editor (browse + toggle)
```

## Running a backup

```sh
baaackaaab                 # back up the set (this is what the timer runs)
baaackaaab --dry-run       # preview what would upload; writes nothing
```

On a terminal a real backup shows a live progress bar; piped or under the timer it
logs one concise tally line per backup (a dry run keeps restic's plain file-list
output). Explicit `--drive-folder` / `--photo-album` flags
**replace the whole set for that run** — folders *and* albums; a single
`--photo-album Extra` backs up only that album, not the set plus one album. Run
`baaackaaab` with no arguments in a terminal
to open the **command center** — the set plus a remote dashboard, with keys to edit,
sync now, refresh remote status, and check restic / server updates (`u`, contacts GitHub).
It also surfaces backup health: a **last backup** line that turns **OVERDUE** once the
newest successful backup is older than 1.5× the installed schedule's cadence (age only
when no timer is installed), plus the last restore-drill and integrity-check lines.

Because the Mac can only stage a fraction of the data set at once, Photos are
exported and uploaded in byte-budgeted batches (each backed up, then deleted), so
one run produces several restic snapshots that share a `run-<timestamp>` tag.
`--photo-batch-bytes <n>` sizes a batch (default ~3 GB); `--staging <dir>` moves
the scratch directory.

## Excludes

Every backup drops macOS filesystem junk — `.DS_Store`, `.Trashes`,
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

## Multiple destinations

Back up to several independent restic repositories at once — each a full copy with
its own encryption key, for blast-radius isolation (no cross-repo dedup).

```sh
baaackaaab --add-destination offsite --repo-url rest:https://other/repo --order 1
baaackaaab --list-destinations
```

A run backs up to every enabled destination, primary-first. The Mac stays read +
append only toward all of them.

## Backends & the immutability caveat

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

## Tuning

These persistent knobs live in the backup set (so the unattended timer uses them too):

```sh
baaackaaab --limit-upload 2048         # cap upload at ~2 MiB/s (KiB/s); --clear-limit-upload lifts it
baaackaaab --pack-size 64              # restic target pack size in MiB, 4…128; --clear-pack-size resets
baaackaaab --read-concurrency 4        # files restic reads concurrently, 1…64 (restic default 2); --clear-read-concurrency resets
baaackaaab --rest-connections 2        # parallel REST-backend connections (restic default 5); --clear-rest-connections resets
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
