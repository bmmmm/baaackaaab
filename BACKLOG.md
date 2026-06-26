# Backlog

Findings from a deep-dive read of the codebase, each re-verified against the
source before being listed here. Line numbers are anchors and will drift; the
file + symbol is the stable reference. Severity is relative to this tool's threat
model (one-way backup, read+append-only toward the store, single user).

Nothing here is a known live data-loss bug in normal operation. The Drive item is
the closest to the safety core and is worth doing first.

## Data integrity

- [ ] **Drive: `verified` flag is recorded, never used as a backup gate; small
  within-folder re-eviction window remains.** `Med-Low`
  - `DriveAcquirer.materializeAndVerify` (DriveAcquirer.swift:100-139) records
    `verified: size >= 0` per file, but the Drive backup hands restic the *live
    folder tree* wholesale (`backupToAll(paths: [url], …)`, main.swift:1647). The
    real gate is the *throw* on the first dataless stub (DriveAcquirer.swift:122),
    which skips the whole folder. A file that is non-dataless but whose size read
    fails is recorded `verified: false` (DriveAcquirer.swift:126-134) and **still
    backed up** — contradicting the invariant documented in Staging.swift:7-14
    ("the orchestrator refuses to back up anything that did not pass
    verification"). That invariant holds for Photos (a failed resource is deleted
    from the batch dir before backup, PhotosAcquirer.swift:146-148), not for Drive.
  - Residual TOCTOU: materialize-all-then-restic-reads-all means a file
    materialized early in a large folder can be re-evicted by the FileProvider
    under storage pressure before restic reads it at the end → restic captures a
    0-byte stub while the manifest says `verified`. The cross-folder window is
    already closed (per-folder materialize right before its backup,
    main.swift:1619-1648); only this within-folder window remains. Low probability
    (needs storage pressure mid-run) but it is exactly what the verify machinery
    exists to prevent.
  - Fix sketch: re-check `isDataless` immediately before/after restic reads each
    file, or back up from a verified staging copy instead of in place (costs the
    disk the in-place design avoids — weigh against the ~11 GB set on a
    disk-constrained Mac). At minimum, make the documented invariant true: fail
    the folder when any regular file ends up `verified: false`.
  - Non-issue confirmed: skipping symlinks/dirs in the materialize pass
    (`guard isFile`) is correct — they carry no cloud byte-content to fault in.

## CLI strictness / UX

- [x] **Unknown flags fall through to a real backup.** `Med` — done (10637a4)
  - No unknown-flag rejection. A typo'd subcommand (e.g. `--restoree`,
    `--snapshot s` without a real command) matches none of the dispatch `if`s
    (main.swift:1206-1388) and falls through to the backup path (main.swift:1390+)
    — silently running a full backup of the set instead of erroring.
  - Fix sketch: after dispatch, validate that every `--flag` token is a known
    flag; exit with an actionable "unknown flag X" otherwise.

- [x] **`--dry-run` still materializes the entire Drive set.** `Med` — done
  - `materializeAndVerify` runs regardless of `backupDryRun` (main.swift:1640);
    only Photos are skipped on a dry run. A "preview" therefore downloads every
    dataless Drive stub from iCloud (potentially the full ~11 GB). The comment
    (main.swift:1411-1414) frames materialize as a "read-only coordinated read" —
    true (no write-back), but not free in time/bandwidth.
  - Fix sketch: on a dry run, *count/report* dataless files without faulting them
    in (stat the dataless flag, don't coordinate-read), or document the cost
    loudly in the dry-run banner.

- [x] **`--limit-upload` collides with source flags → silently diverts to
  set-management.** `Med` — done (4398d0b)
  - `--limit-upload` is in the set-management trigger list (main.swift:1383-1388),
    so `baaackaaab --drive-folder ~/X --limit-upload 2048` runs `manageBackupSet`
    and exits — the ad-hoc backup never happens and `--drive-folder` is ignored.
    There is no ad-hoc throttle path at all: `backup()` reads the throttle from the
    set (`configLimitUploadKiBps`, main.swift:1404), never from argv.
  - Fix sketch: reject `--limit-upload` combined with source flags with a message
    pointing at the set-only nature, or support a true per-run throttle.

## Robustness

- [x] **restic probe timeout terminates with SIGTERM only, no SIGKILL
  escalation.** `Low` — done
  - On timeout the bounded read-only probes call `proc.terminate()` (SIGTERM),
    wait 5 s, then throw regardless of whether the child died
    (ResticBackend.swift:716-719 and 791-795). A restic child wedged in a state
    that ignores SIGTERM is leaked (the reaper thread blocks too). Only affects
    read-only queries (cat config / snapshots / stats / ls), never a writing
    backup we must not kill mid-flight.
  - Fix sketch: after the 5 s grace, `kill(proc.processIdentifier, SIGKILL)` if
    still running.

- [x] **`RunHistory.append` is not locked against concurrent runs.** `Low` — done
  - `seekToEnd` + `write` without `flock`/`O_APPEND` (RunHistory.swift:67-81). Two
    concurrent processes can seek to the same offset and one overwrites the
    other's line. Concurrent backups are rare (restic repo-locks anyway) and the
    reader tolerates a corrupt trailing line (RunHistory.swift:86-95), so impact
    is a lost diagnostic line at most.
  - Fix sketch: open with `O_APPEND` or take an `flock` around the write.

- [x] **Photos authorization timeout is reported as `notDetermined`, not "timed
  out".** `Low` — done
  - `requestAuthorization` returns `.notDetermined` on a 300 s timeout
    (PhotosAcquirer.swift:206-217); the caller then throws
    `notAuthorized("notDetermined")` (PhotosAcquirer.swift:60-61), which reads as
    "first run will prompt" rather than "the prompt machinery wedged". Diagnostic
    accuracy only.

## TUI (TTY-only — operator-verifiable, not unit-testable)

- [x] **Unicode display width: layout counts graphemes, not terminal cells.**
  `Low-Med` — done (operator-verifiable: build green; runtime needs a real TTY)
  - `fit` (ConfigTUI.swift:1643-1647), the reverse-video cursor padding
    (`.padding(toLength: cols, …)` in every render*Row), and `divider`
    (ConfigTUI.swift:1569-1573) all assume 1 character = 1 column. A CJK/emoji
    folder name or album title (2 cells per glyph, or 0 for combining marks)
    overflows `cols` and corrupts the layout / highlight bar. Names are
    user-controlled (iCloud Drive folders, Photos albums).
  - Fix sketch: a small `wcwidth`-style width function used by fit/pad/divider.

- [x] **ESC vs. arrow keys: a lone ESC at a read() boundary is treated as
  back/quit.** `Low` — done (operator-verifiable: build green; runtime needs a real TTY)
  - `readKey` only decodes an arrow when `[` is already buffered after ESC; a
    `\u{1B}[A` split across two `read(2)` calls makes the first ESC return `.esc`
    (ConfigTUI.swift:1594-1619). The comment documents this as an accepted
    trade-off. Rare (a single keypress's 3 bytes almost always arrive together),
    but on a slow/loaded PTY an arrow could trigger an accidental "back".
  - Fix sketch: after a bare ESC, do a short `VTIME`/`poll`-bounded read for a
    following `[` before deciding it was a lone ESC.

- [x] **SIGWINCH not handled: a resize redraws only on the next keypress.** `Low`
  — done (operator-verifiable: build green; runtime needs a real TTY)
  - `terminalSize()` is read per render (ConfigTUI.swift:1621-1627), but nothing
    triggers a render on resize, so the layout is stale until the next key.
  - Fix sketch: install a SIGWINCH handler that sets a flag and nudges the loop.

## Refactor

- [ ] **P3: extract the top-level backup orchestration into a `BackupRun`
  type.** `refactor, no behaviour change`
  - The ~320-line `do { … } catch { … }` at file scope (main.swift:1472-1795)
    drives init, quota, Drive, Photos, manifest, summary, run-history and exit
    codes inline. Extracting it into a type would make it testable and readable.
    Lower value than P2 was; do after the correctness items.

## Decisions — do NOT re-investigate

- **`--config` forwarding to the restore/read children is a no-op (dead code).**
  `--restore`/`--diff`/`--ls`/`--find`/`--snapshots`/`--test-restore`/`--verify-repo`
  all dispatch (main.swift:1263-1332) *before* `configPath` is resolved
  (main.swift:1335), and they read `DestinationStore`, not the backup-set config.
  Forwarding `--config` to them would forward a flag they never read. `--config`
  *is* correctly forwarded where it matters (the TUI sync child `syncArgs()` and
  `--install-timer`, which do read the set). Do not "fix" this.

- **Photos `.readWrite` is not over-privileged.** PhotoKit has no read-only
  access level: `PHAccessLevel` is `.addOnly` (write-only) or `.readWrite`.
  Reading the library requires `.readWrite`, so it is the minimum, not an
  over-grant (PhotosAcquirer.swift:171-172, 192, 209).
</content>
</invoke>
