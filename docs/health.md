# Health & monitoring

The append-only store protects history; this page is about *noticing* — when
backups stop happening, when the source churns suspiciously, when stored bytes
rot — and about getting those signals off the Mac, where they survive a machine
that has gone dark.

## Scheduling

```sh
baaackaaab --install-timer --at 12:00        # daily LaunchAgent
baaackaaab --install-timer --at 02:00 --days mon,wed,fri
baaackaaab --timer-status
baaackaaab --uninstall-timer
```

The timer runs `baaackaaab --run-tag scheduled`. It needs no Keychain prompt (the
credential files are read directly); it needs a one-time Photos grant, which a
stable signature then keeps alive across rebuilds.

## Catch-up on boot/login

The backup LaunchAgent also sets `RunAtLoad` and carries a `--catch-up` marker, so
it fires once when launchd loads it (login/boot) on top of the calendar schedule.
A `--catch-up` run first evaluates a staleness gate against the **installed
schedule's interval** (daily → 1 day; a weekday list → its largest gap, e.g.
mon/wed/fri → 3 days):

- **Fresh** — a successful backup younger than the interval is on record: it exits
  0 with one quiet line. This is what makes the extra login/boot fire cheap, and it
  swallows the duplicate fire right after a normal calendar run.
- **Overdue / no history** — the Mac was off over a scheduled slot (or never backed
  up): it prints `backup is N days overdue — catching up now`, posts a banner (the
  same unattended gate as the failure banner), and runs the backup.

**Existing installs get `RunAtLoad` + `--catch-up` on the next `--install-timer`** —
the plist is regenerated on every install.

## Scheduled restore drill

A backup you have never restored from is a hope, not a backup. A second
LaunchAgent runs a **monthly** drill: it restore-verifies a rotating sample (one
Drive folder + one photo batch) into a temp directory — read-only against the
store — records the outcome in the run history, and banners **only** on failure.
The command center and `--doctor` show the last verified restore; `status.json`
exports it as `last_drill`.

```sh
baaackaaab --install-drill-timer                       # monthly, day 1 at 03:00
baaackaaab --install-drill-timer --day 15 --at 05:30   # day-of-month 1…28
baaackaaab --uninstall-drill-timer
baaackaaab --restore-drill                             # run one drill by hand (what the timer runs)
```

## Rotating integrity check

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

That this actually catches rot — a single flipped pack byte fails the read-data
check with concrete error lines while staying invisible to the structural check —
is demonstrated in the [bit-rot PoC](poc-bitrot-detection.md).

The restore drill and the integrity check are complementary: the **drill** proves a
sample *decrypts and restores* end-to-end, the **check** proves *all bytes still
hash correctly* over time. Both install/uninstall independently of the backup timer
and of each other (`--timer-status` lists all three).

## Power

- **Sleep-hold (always on).** During a real backup and during a rotating integrity
  check, baaackaaab takes an IOKit power assertion
  (`kIOPMAssertionTypePreventUserIdleSystemSleep`) so a long unattended upload or
  re-read isn't cut short by the idle-sleep timer. Pure IOKit — no `caffeinate`
  child. Honest scope: this holds off **idle** sleep only; **closing the lid (or an
  explicit Sleep) still sleeps the machine**. It is harmless outside a run, so there
  is no knob.
- **Battery-defer (opt-in).** `--defer-on-battery` makes *scheduled and catch-up*
  runs exit without backing up while the Mac is on battery (interactive runs always
  proceed); `--no-defer-on-battery` restores the default. It is persisted in the set
  (so the timer honors it) and shown in `--list`. A deferred run exits **before** any
  backup work begins, so — by design — it **looks like a missed run**: the next
  scheduled slot on wall power (or the login/boot catch-up) picks it up. If you use
  the heartbeat (`--set-heartbeat`, below), a battery-deferred run registers as a
  miss on the monitor too — no start ping is sent — which is the correct signal.

## Anomaly warning (source-side tripwire)

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

That this actually fires — real restic, simulated mass encryption, production
thresholds, both verdicts — is demonstrated end-to-end, with honest scope
limits, in the [ransomware-detection PoC](poc-ransomware-detection.md).

**Large-file warning.** Because anything snapshotted is permanent, a single huge
file landing in the set unnoticed can quietly commit the store to it forever. Any
acquired Drive or Photos file over a configurable threshold (default 4 GiB) prints
a warning after acquisition — **warn-only**: it never excludes anything and never
changes the run's outcome, it just gives you the chance to `--add-exclude` it on
purpose.

```sh
baaackaaab --large-file-warn-mib 8192      # warn above 8 GiB instead of the 4 GiB default
baaackaaab --large-file-warn-mib 0         # disable the warning
baaackaaab --clear-large-file-warn-mib     # back to the 4 GiB default
```

## Monitoring & notifications

The macOS banner (`Notifier.swift`) is invisible when you're away from the Mac,
and nothing about it can tell "a run failed" apart from "the Mac never even ran
it" — a crashed process, an unplugged machine, or a disabled timer just goes
silent. Both problems need a MONITOR-side dead-man's switch, not another local
notification.

```sh
baaackaaab --set-heartbeat https://hc-ping.com/your-uuid   # or your own Gatus/Uptime-Kuma/healthchecks; --clear-heartbeat removes it
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

## Machine-readable status

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
last_check       { time, ok, slice, of }                         — present only once a rotating integrity
                 check has run; slice/of is the read-data rotation position
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
`baaackaaab_repo_quota_bytes`, `baaackaaab_last_drill_timestamp_seconds`,
`baaackaaab_last_check_timestamp_seconds`. A
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

## Maintenance & diagnostics

```sh
baaackaaab --doctor          # restic, destinations, append-only, disk, Photos, timer, updates — read-only
baaackaaab --verify-repo     # restic check per destination (read-only)
baaackaaab --check-updates   # compare restic + the REST server against the latest releases
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
level; see [Backends & the immutability caveat](configuration.md#backends--the-immutability-caveat).

## Staying current

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
