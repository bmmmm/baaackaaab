# Recovery

Getting data back out — routine restores, proving restores actually work, and
the disaster path for when the Mac itself (and the credential files on it) is
gone.

## Restoring

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
                                                    # (--sample N files, --max-bytes N budget)
```

Photos restore to their **original files** (import them back via Photos > File >
Import), not a rebuilt `.photoslibrary`.

For the *scheduled* monthly restore drill — the unattended version of
`--test-restore` — see [Health & monitoring](health.md#scheduled-restore-drill).

## Emergency recovery kit

The two secrets — the repo URL and the restic encryption password — live only in
`0600` files on this Mac. If the Mac dies, so do they, and the append-only store
becomes permanently undecryptable with them; the server never holds a copy of the
encryption key. `--export-recovery-kit` writes a single offline Markdown sheet
that fixes that: every destination's full repo URL, its restic encryption
password, the endpoint (htpasswd) password (extracted from the URL where
present), and terse plain-`restic` recovery steps that need nothing but stock
restic on any machine — no baaackaaab, no Mac.

```sh
baaackaaab --export-recovery-kit ~/Desktop/baaackaaab-recovery.md.enc
```

The sheet is encrypted by default (`openssl enc -aes-256-cbc -pbkdf2 -iter 600000
-salt`), with an interactive, non-echoed passphrase prompt (min 10 characters,
never on argv or in the environment). Decrypt it on any machine with stock
openssl:

```sh
openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -in baaackaaab-recovery.md.enc
```

`--export-recovery-kit-plain <path>` skips encryption for a printable sheet
(extra-loud warning — treat the plaintext file itself as the master key). Either
way, **get this file OFF the Mac immediately**: print it, put it in a password
manager, or seal it on a USB stick — never a synced folder (that is exactly the
compromised-source domain this backup exists to survive), never git. Both
variants refuse to write into live iCloud Drive / Photos. A destination whose
credential files are missing/unreadable at export time is noted as incomplete in
the sheet rather than failing the whole export.

That the sheet actually suffices — its own recovery commands, executed verbatim
with stock restic in a clean environment, restore the data byte-identically —
is proven continuously by the [recovery-kit PoC](poc-recovery-kit.md).

## Locks & store usage

```sh
baaackaaab --unlock --destination offsite   # remove STALE locks (the only delete op)
baaackaaab --repo-usage                     # what fills the permanent store (per destination)
```

`--unlock` is the single delete operation the Mac may perform: it removes stale
lock files only — never snapshots, never data — and needs `--destination` plus a
confirm (or `--yes`). A damaged repo is repaired SERVER-side; the Mac has no
delete/prune right.

`--repo-usage` aggregates the **latest** snapshot's file sizes per top-level path
component (plus a drill-down one level deeper under the largest bucket) and prints
a table sorted descending, with each bucket's share of the total. Sizes are
**logical** (pre-dedup/compression), not the deduplicated repo size `--doctor`
reports. Because the store is append-only, anything already snapshotted is
permanent — this tells you what to
[`--add-exclude`](configuration.md#excludes) to stop *future* growth; it
cannot shrink what is already stored.
