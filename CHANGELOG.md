# Changelog

## v1.2.0 — 2026-08-06

### Features

- **All three schedules are visible and editable in the command center.** The home
  dashboard gained a `schedules` panel listing every unattended job — backup,
  integrity check, restore drill — with its cadence and next run (`daily at 20:00
  · next in 21h`); previously only the backup timer was reachable there and the
  other two were CLI-only. `t` opens the editor, which offers a day-of-month field
  for the monthly drill instead of the weekday keys launchd would ignore, and every
  write still goes through the tested `--install-*-timer` flags, so the TUI and the
  CLI cannot drift apart.
- **The schedules editor is modal, in the vi sense.** Its arrow keys otherwise had
  to mean two things at once — "which job" and "what value" — so landing on the
  screen and reaching for them could nudge a live schedule. **Normal** (`↑`/`↓`
  select the job) owns every command: `i` edit, `w` write, `u` undo, `y` yank,
  `p` put, `o` on/off, `x` delete. **Edit** (`i`) only edits fields. `w` and `u`
  resolve an edit from either mode and always return to Normal, so the mode can
  never outlive the edit it belonged to; leaving the screen or switching job with
  an unwritten edit asks first.
- **Jobs can be turned off without losing their schedule** (`o`, or
  `--pause-timer` / `--resume-timer` and the `-check-` / `-drill-` variants). The
  plist stays on disk and launchd simply unloads it, so turning the job back on
  restores the same cadence — previously the only way to stop a job was to delete
  it and retype its schedule later. A paused job reads as **off** rather than as
  broken.
- **A schedule can be copied between jobs** (`y` yanks, `p` puts). `p` fills the
  target's fields without writing, so a paste onto the wrong job costs a `u`
  rather than a reinstall. The monthly drill and the weekday-based jobs use
  different launchd keys, so a paste across that boundary keeps whatever the
  source cannot express as the target already had it and **names what it
  dropped** — a silent partial paste being the failure mode worth avoiding.
- **A plist that launchd never loaded is now called out.** Such a job looks
  scheduled in every listing and never fires; the dashboard flags it in yellow
  instead of rendering it as healthy.
- **A runs screen (`H`) with a coverage calendar, the history and the failure
  detail.** Three months side by side, one cell per day, so a gap in unattended
  coverage reads as a hole rather than as a missing list row; a day aggregates
  every run it saw, so a failed check on the same day as a good backup shows as
  mixed rather than green. Below it the runs themselves (`f` filters to
  failures) and, for the selected run, its detail — exit code, window,
  per-destination churn, and **the recorded error text**, which until now was
  only counted (`1 dest failed`) and never shown anywhere in the TUI.
- **`--log-tail [n]`** prints the last n lines of the unattended run log
  (default 200) — restic's own output for a scheduled run, which the structured
  history deliberately does not keep. No repo, credentials or network needed, so
  it works in the state where it is needed. The runs screen's `l` shells out to it.

### Fixes

- **The boot race no longer costs a backup.** The login/boot `--catch-up` fire
  lands before Wi-Fi is up, the run-start probe times out, and the run ended
  having backed up nothing — while being exactly the mechanism meant to make up
  a slot missed with the Mac off. An unattended run that reaches no destination
  now waits and probes again (30 s / 60 s / 120 s / 240 s), logging each wait,
  before giving up. Only for transient failures, only unattended, and only while
  no destination at all is reachable — a wrong password, a held lock or an absent
  repo still fails on the first attempt. All three timers do this; a monthly
  drill that lost the race would otherwise wait four weeks.
- **An unreachable destination is no longer reported as a damaged one.** The
  integrity check ran `restic check` first and judged the repo by its result —
  but a transport failure is indistinguishable from damage in that result (a
  non-zero exit with no lock marker), so a server that was merely away produced
  "restic check reported problems" and pointed the operator at a server-side
  repair of a healthy repo. Reachability is now probed first; an unreachable
  destination reports "could not check — NOT a damage verdict" and banners as
  **could not run** instead of **failed**.
- **The healthy states are green, not grey.** The drill, check, backup-age and
  schedule lines rendered their passing state in the same dim grey as "nothing
  here yet" — while the run and destination rows next to them had always been
  green when clean. A passing restore drill is the most expensive evidence the
  tool produces; it now reads like it, and all four lines carry the same tick.
- **The cancel notice no longer claims an upload that never happened.** Ctrl-C
  or a SIGTERM printed "data already uploaded is kept (dedup reuses it next run)"
  for every job, including the read-only integrity check and restore drill, which
  upload nothing. Each job now states its own aftermath: the check reports the
  repository untouched and the slice simply not run, the drill that its partial
  restore is discarded with the temp directory.
- **A dashboard too tall for the window no longer truncates silently.** The last
  visible line now says how many lines are hidden and that the window needs to be
  taller — a short window used to simply drop the lower panels, which reads as
  "there is nothing scheduled".
- **The coverage calendar never claims a missed run it cannot know about.** Days
  outside the recorded window — before the first record, or in the future —
  render blank instead of as "no run", and a store with no history at all says so
  rather than painting three months of dots.

## v1.1.0 — 2026-08-04

### Features

- **Offsite destinations on S3-compatible storage (R2 / S3).** New optional
  per-destination `transport-env` file (0600, `KEY=VALUE`) carries backend
  transport credentials (e.g. `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`)
  into that destination's restic children only — never argv, never a global
  export, and the four `RESTIC_*` repo/password names are ignored with a
  warning so the file can never redirect the repo or its key. The recovery
  kit embeds the file's lines as `export` statements in its copy-paste
  recovery block; `--doctor` warns when the file is group/world-readable and
  names the honest per-backend immutability story (AWS S3 IAM deny vs
  Cloudflare R2 credential separation only). Docs gained a full offsite
  runbook including a small-files smoke test before the first full sync.
- **Native Gotify push channel** alongside ntfy/webhook; the app token is
  read from the environment or a hidden prompt, never argv.
- **Repeatable TUI smoke gate** (`scripts/tui-smoke.sh`) against an isolated
  throwaway store; resize wakeup no longer depends on signal delivery.
- **Boot catch-up for the drill/check timers** (RunAtLoad + `--catch-up`),
  and a dead check timer is now flagged.

### Fixes

- A value flag as the final token (e.g. a bare `--destination`) no longer
  falls through to a full backup of the set — it is rejected with the
  missing-value error.
- The quota pre-flight `restic stats` is bounded by the probe timeout; a
  wedged destination no longer stalls the scheduled run indefinitely.
- The scheduled integrity check and restore drill register their restic
  children for cancellation: a SIGTERM interrupts restic instead of
  orphaning it with the repo lock held.
- Recovery-kit export lines escape embedded single quotes (imported
  passwords, hand-written transport-env values).
- Doctor honors `--staging` for the disk-space check and inspects
  transport-env permissions even when the destination's key is missing.
- A found-but-unstartable restic binary reports `launchFailed` with the
  underlying reason instead of a misleading "not found in PATH".
- Assorted acquisition/robustness hardening: cancellable downloads, budget
  pre-flush, scaled timeouts, per-destination churn baselines, scoped drill
  cursor, UTF-8 key handling and CSI/EINTR guards in the TUI.

### Internal

- The four restic process runners are consolidated behind one spawn core
  that states the invariants (stdin /dev/null, secrets via child env only,
  read-before-wait, no force-terminate without a deadline) in one place.
- `doctorCommand` moved to Doctor.swift, the read-only query surface to
  ResticBackendQueries.swift — both verbatim, no behaviour change.
- CI runs the TUI smoke; Dependabot watches the GitHub Actions.

## v1.0.0 — 2026-07-17

Initial release: one-way iCloud Drive + Photos backup into an append-only
restic store, with the doctor's active append-only probe, monthly restore
drills, the rotating 1/8 read-data integrity check, multiple destinations,
and the encrypted emergency recovery kit.
