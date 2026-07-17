# Development

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
redaction, the recovery-kit sheet composition and passphrase validation, the
repo-usage size aggregation, the large-file warning threshold, and the on-disk
destination and run-history stores. Store tests relocate to a throwaway directory
via `BAAACKAAAB_SUPPORT_DIR`, so they never touch the real credential store. The
live GitHub query, the HTTP header probe, the append-only DELETE probe, and the
heartbeat/ntfy/webhook network sends touch the network, so they are not
unit-tested — all degrade to nil/unreachable (or, for outbound monitoring, a
logged no-op that never changes the run's exit code) by construction.

A second layer of **live restic integration tests** (`ResticIntegrationTests`)
drives the real `restic` binary against a throwaway *local* repository — no
server, no network — to verify the parts unit tests can't reach: the typed
exit-code mapping (repo absent / locked / wrong password), `--skip-if-unchanged`,
`--pack-size`, the **excludes** (macOS-junk defaults, `--exclude-caches`, and custom
globs are all kept out of the snapshot), a full **backup → restore → verify
roundtrip**, `find` / `ls` / `diff`, the exit-3 partial snapshot (an unreadable file
still yields a valid snapshot of the rest), `check`, `unlock`, snapshot/stats
parsing, and the `--repo-usage` aggregation against a real snapshot. They are
skipped automatically when `restic` isn't on `PATH`, so the suite still passes
without it.

The TTY TUI, live restic against a real *rest-server*, Photos/TCC, and the launchd
timer are verified on real hardware, not in the test suite.

## Pre-push hook

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
