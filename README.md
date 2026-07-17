# baaackaaab

[![CI](https://github.com/bmmmm/baaackaaab/actions/workflows/ci.yml/badge.svg)](https://github.com/bmmmm/baaackaaab/actions/workflows/ci.yml)

One-way backup for iCloud Drive and iCloud Photos into an immutable
[restic](https://restic.net) repository, built to survive ransomware: the Mac can
only ever **add** to the backup store, never delete or overwrite it.

It is a single Swift command-line tool for macOS. A bare run backs up a declarative
*backup set*; an interactive terminal UI edits that set and shows a remote
dashboard; a launchd timer runs it unattended.

## Highlights

- **Ransomware-proof by design** — the store is a restic REST server in
  `--append-only` mode; the Mac holds no delete/prune right at all, and
  `--doctor` actively *proves* the server enforces it (a harmless DELETE probe).
- **iCloud-native acquisition** — materializes FileProvider-backed Drive files
  in place and exports Photos via PhotoKit in byte-budgeted batches, so a small
  disk can back up a large library.
- **Safe restore by construction** — always into a fresh directory, never back
  over live iCloud; previews with `--dry-run`, re-reads with `--verify`.
- **Trust is scheduled, not assumed** — a monthly restore drill proves a sample
  decrypts end-to-end; a rotating read-data check re-hashes every stored byte
  over eight runs to catch bit-rot
  ([proven against a real flipped byte](docs/poc-bitrot-detection.md)).
- **Monitoring that survives a dead Mac** — Healthchecks-style heartbeat,
  ntfy/webhook pushes, `status.json` + a Prometheus textfile; a source-side
  anomaly tripwire flags ransomware-shaped mass-rewrite churn
  ([demonstrated end-to-end](docs/poc-ransomware-detection.md), not just claimed).
- **Multiple destinations & an emergency recovery kit** — independent repos
  with separate keys, plus an encrypted offline sheet that restores with stock
  restic on any machine — no baaackaaab, no Mac
  ([the sheet's own commands are executed in the test suite](docs/poc-recovery-kit.md)).
- **One binary, no daemons** — a single Swift CLI; scheduling is a plain
  launchd LaunchAgent, secrets live in `0600` files and never touch argv.

Not what you were looking for? The wider restic ecosystem — GUIs, cron
wrappers, browsers, other backup front-ends — is cataloged at
[awesome-restic](https://github.com/rubiojr/awesome-restic).

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
  caveat](docs/configuration.md#backends--the-immutability-caveat) for what that
  does and doesn't buy you on non-REST stores.

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

## Everyday use

`baaackaaab --help` lists every flag; the deep dives live in
[Documentation](#documentation) below. The short version:

```sh
baaackaaab --add-folder ~/Documents      # add an iCloud Drive folder to the set
baaackaaab --add-album "Camera Roll"     # add an iCloud Photos album
baaackaaab --list                        # show the set
baaackaaab --configure                   # interactive TUI editor (browse + toggle)

baaackaaab                               # back up the set (this is what the timer runs)
baaackaaab --dry-run                     # preview what would upload; writes nothing
baaackaaab --install-timer --at 12:00    # daily unattended LaunchAgent

baaackaaab --snapshots                              # browse snapshots, newest first
baaackaaab --restore --include path/to/report.pdf   # restore, always into a fresh dir
```

The set lives in `~/.config/baaackaaab/backup-set.json` — a plain, hand-editable
file that is the single source of truth; every front-end just edits it. Run
`baaackaaab` with no arguments in a terminal to open the **command center** — the
set plus a remote dashboard, with keys to edit, sync now, refresh remote status,
and check for restic / server updates.

## Documentation

- **[Configuration](docs/configuration.md)** — the backup set, run behavior &
  photo batching, excludes, multiple destinations, backends & the immutability
  caveat, tuning knobs.
- **[Health & monitoring](docs/health.md)** — scheduling & catch-up, the restore
  drill, the rotating integrity check, anomaly & large-file tripwires,
  heartbeat/ntfy/webhook, `status.json` + Prometheus, `--doctor`, staying current.
- **[Recovery](docs/recovery.md)** — restoring, the emergency recovery kit,
  locks & store usage.
- **[Development](docs/development.md)** — tests, the pre-push hook, source layout.

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
  [Maintenance & diagnostics](docs/health.md#maintenance--diagnostics).

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

## Support

If baaackaaab is useful to you, you can support its development on
[ko-fi.com/bmabma](https://ko-fi.com/bmabma).

## License

GPL-3.0. See [LICENSE](LICENSE).
