# Changelog

## Unreleased

### Features

- **All three schedules are visible and editable in the command center.** The home
  dashboard gained a `schedules` panel listing every unattended job — backup,
  integrity check, restore drill — with its cadence and next run (`daily at 20:00
  · next in 21h`). `t` opens the editor, where `tab` picks the job, `i` installs or
  changes it and `u` deletes it; previously only the backup timer was reachable
  there and the other two were CLI-only. The editor offers a day-of-month field
  for the monthly drill instead of the weekday keys launchd would ignore, and every
  write still goes through the tested `--install-*-timer` flags, so the TUI and the
  CLI cannot drift apart.
- **A plist that launchd never loaded is now called out.** Such a job looks
  scheduled in every listing and never fires; the dashboard flags it in yellow
  instead of rendering it as healthy.

### Fixes

- **A dashboard too tall for the window no longer truncates silently.** The last
  visible line now says how many lines are hidden and that the window needs to be
  taller — a short window used to simply drop the lower panels, which reads as
  "there is nothing scheduled".

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
