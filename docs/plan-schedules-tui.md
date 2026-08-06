# Plan: schedules screen — insert mode, dirty colour, copy/paste

Handoff plan for a fresh session. Written 2026-08-06. Delete this file once the
work has landed.

Scope: the command center's schedules screen (`Sources/baaackaaab/TimerScreen.swift`,
its state on `ConfigTUI`, and `ScheduleDashboard`). Three requested changes plus
one blocking prerequisite.

## 0. Prerequisite — the installed binary is stale (do this first)

The vi-style Normal/Edit split already landed on `main` (commit `37d3756`), but
`~/.local/bin/baaackaaab` symlinks to `.build/release/baaackaaab`, which was
built at 00:49 — *before* that commit. So the running binary still has the older
"first arrow press arms adjustment" behaviour, which is why arrows appear to edit
the time straight after pressing `t`.

```
make release     # swift build -c release + scripts/sign.sh (keeps the Photos TCC grant)
```

Re-check the actual behaviour after that build **before** writing any code — part
of requirement 1 may already be satisfied, and the remaining work is then only the
`i`-key rebinding below.

## 1. `i` / `e` enter insert mode — DONE

Requested: after `t`, arrows must not change values; press `i` or `e` first.

The root cause turned out to be bigger than the key binding. Every command
(`i`, `o`, `u`, `d`) existed in BOTH modes, which made the mode decoration
rather than structure — and discarding from inside Edit mode reset the fields
but left the mode alone, so a screen that looked finished still had the arrows
editing values instead of selecting the next job. Fixed by making the split
strict: Edit mode is now vi's insert mode and does nothing but edit fields.

Landed keymap:

| Key | Normal | Edit |
|-----|--------|------|
| `↑`/`↓`, `j`/`k` | select job | adjust focused field |
| `←`/`→` | — | move field |
| `1`-`7`, `0` | — | weekdays (non-monthly jobs) |
| `i`, `e`, `Enter` | → Edit mode | — |
| `w` | write (install/rewrite) | — |
| `u` | undo (revert to installed) | — |
| `x` | delete the schedule | — |
| `o` | on/off (pause/resume) | — |
| `Enter` | → Edit mode | write + back to Normal |
| `esc` | back to home (confirm if dirty) | back to Normal, edit stays pending |

Decisions taken (both were open in the first draft):

- **`u` is undo, not uninstall.** vi's `u` is undo, and "revert to what's
  installed" *is* undo — so `u` took that meaning and delete moved to `x`. The
  swap also makes a slip safer: the key that used to delete a schedule now does
  something harmless.
- **`esc` from Edit does not prompt.** Leaving vi's insert mode neither writes
  nor discards, so the pending edit simply survives into Normal. Confirmation is
  now only on the paths that would actually LOSE it — switching job, leaving the
  screen, quitting.

## 2. Colour the current job while it has unapplied changes

Requested: as soon as something in the current schedule is changed, its colour
changes.

**Status: the operator confirmed the colours read correctly as they are** (mode
badge + the yellow "unapplied edit" note + green/yellow job rows). Treat the
rest of this section as optional polish, not requested work.

Today only a separate yellow note line appears ("unapplied edit — …"); the job
row itself stays green/cyan, so the row and the truth disagree.

- Selected job row renders **yellow** while `timerTouched`, instead of the
  `.ok`/`.off` colour, so the list itself shows which job diverges from disk.
- Per-field: render only the field(s) that actually differ from the *installed*
  schedule (`timerCurrent`) in yellow — that answers "what did I change", not
  just "something changed". Fields equal to what's installed stay normal even
  while the job as a whole is dirty.
- Keep the existing note line; it carries the actionable "`w` installs it,
  `d` discards it".

## 2. Colour the current job while it has unapplied changes

Requested: as soon as something in the current schedule is changed, its colour
changes.

Today only a separate yellow note line appears ("unapplied edit — …"); the job
row itself stays green/cyan, so the row and the truth disagree.

- Selected job row renders **yellow** while `timerTouched`, instead of the
  `.ok`/`.off` colour, so the list itself shows which job diverges from disk.
- Per-field: render only the field(s) that actually differ from the *installed*
  schedule (`timerCurrent`) in yellow — that answers "what did I change", not
  just "something changed". Fields equal to what's installed stay normal even
  while the job as a whole is dirty.
- Keep the existing note line; it carries the actionable "`w` installs it,
  `d` discards it".

Put the comparison in a **pure function** (e.g. `TimerEdit.dirtyFields(edited:installed:)`
returning a set of `TimerField` + a weekday/day-of-month flag) so it is unit-testable
without a TTY. The renderer only picks colours from its result.

Edge case: a job that is not installed at all has no baseline — everything is
"new" rather than "changed". Decide whether that renders dirty from the first
keystroke (probably yes) or not at all.

## 3. Copy / paste a job's schedule

Requested: a copy-and-paste job function.

- `y` copies the **currently displayed** schedule (i.e. `previewSchedule()`,
  which includes unapplied edits — what you see is what you yank) into a
  session-only clipboard: a new `var timerClipboard: Schedule?` on `ConfigTUI`.
  Not persisted to disk.
- `p` pastes onto the selected job by **filling the editor fields only** — it does
  NOT install. The paste therefore lands as a normal dirty edit that the operator
  confirms with `w`/`Enter` or drops with `d`. This keeps the existing
  "nothing reaches launchd without an explicit write" property.
- Status line reports both ends, e.g. `yanked backup: daily at 20:00` /
  `pasted onto integrity check — w installs it`.

Edge case that needs a decision (the real design work here): **the drill is
monthly, backup and check are weekday-based** (`LaunchdTimer.Kind.isMonthly`).
Pasting across that boundary can't be lossless:

- weekly → monthly (drill): time-of-day carries over; the weekday set has no
  meaning on a `Day` schedule. Keep the drill's existing day-of-month and say so
  in the status line.
- monthly → weekly (backup/check): time-of-day carries over; day-of-month is
  dropped, weekdays fall back to "every day" (or the target's current set).

Whatever is chosen, the status line must state what was dropped — a silent
partial paste is the failure mode to avoid. A pure `Schedule` → `Schedule`
adapter keyed on the target `Kind` makes this unit-testable.

Also note: the editor holds a single time-of-day, so yanking a multi-time
schedule (only creatable via repeated `--at` on the CLI) collapses it. The screen
already warns about this on install; the paste path should not silently widen the
loss.

## 4. Tests + verification

- **Unit** (`Tests/baaackaaabTests/ScheduleDashboardTests.swift` or a new
  `TimerEditTests.swift`): dirty-field detection, the paste adapter across the
  monthly/weekly boundary, clipboard-empty `p` as a no-op.
- **TTY gate**: extend the repo's own `scripts/tui-smoke.exp` (driven by
  `scripts/tui-smoke.sh`) — do not write ad-hoc expect scripts. Its header
  documents the hard-learned pattern rules: **ASCII-only patterns** (the file is
  not read as UTF-8, so em-dashes silently never match) and **unique per screen**
  (footer hints false-positive on bare words).
- `swift build` and `swift test` need `--disable-sandbox`; restic-touching tests
  need `RESTIC_CACHE_DIR` under `$TMPDIR`.
- Finish with `make release` again so the installed binary matches `main` —
  otherwise the next session hits exactly the stale-binary confusion in §0.

### The TTY gate is not in pre-push — check it by hand

`.githooks/pre-push` runs only `swift build` + `swift test`. `scripts/tui-smoke.sh`
is NOT part of it, which is how the modal rework shipped with the smoke script
still matching the pre-modal divider text (`"edit backup"`, `"i installs:"`) —
broken, unnoticed, and green on every push. **Run `scripts/tui-smoke.sh` by hand
after any schedules-screen change.**

Worth considering (not done, deliberately): adding the smoke to pre-push. It
needs `expect` and spawns its own pty, so it would work from a normal terminal —
but it drives the operator's REAL LaunchAgents (only the support dir is isolated,
`~/Library/LaunchAgents` is not) and pushes already take ~4 minutes.

Two patterns the smoke script now depends on, both learned the hard way:

- **Match in render order.** `expect` consumes the stream sequentially, so asking
  for the mode badge (line 3) *after* the `scheduled jobs` divider (line 5) waits
  for the next repaint and times out on a screen that is already correct.
- **`expect -- "-- NORMAL --"`.** Without the `--`, the leading dashes parse as
  expect flags.

## Current state

`main` = `6c3c627` plus this slice's follow-ups, pushed to both `origin`
(Forgejo) and `github`. Already landed and **not** part of the remaining work:

- on/off pause per job (`o`, `--pause-*-timer` / `--resume-*-timer`, marker file
  under `CredentialFiles.dir`, `ScheduleDashboard.Level.off`)
- the strict Normal/Edit split with its `-- NORMAL --` / `-- EDIT: <job> --`
  badge, the `i`/`w`/`u`/`x` keymap, and the smoke coverage that pins it

Remaining: §3 (copy/paste), and §2 only if the colours stop feeling right.
