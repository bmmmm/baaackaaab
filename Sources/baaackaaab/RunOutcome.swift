import Foundation

/// The pure decision core of `BackupRun.execute()`'s exit matrix: given the
/// counted result of one run (post-acquisition — cancellation already
/// resolved, the manifest already written), decides the exit code, summary
/// headline, summary state, and whether the unattended-failure banner fires.
///
/// Extracted because this logic used to live inline, `exit()`-coupled, and
/// therefore untestable — review round 2 already touched it once (the
/// clean-empty `total == 0` branch), which is exactly the kind of change a
/// pinned unit test should catch before it ships.
///
/// Deliberately scoped to the branches that share this input shape. Two
/// earlier failure paths in `execute()` — cancellation during destination
/// init, and "no destination could be initialized" — happen before staging
/// even exists (no verified/total to count yet) and keep their own inline
/// exit/record calls.
enum RunOutcome {
    struct Result {
        let exitCode: Int32
        let headline: String
        let state: Console.SummaryState
        let notify: Bool
        /// Text passed to the failure banner. Sometimes shorter than
        /// `headline` (the partial-verification headline adds a "review the
        /// manifest" tail that the banner omits) — nil when `notify` is false.
        let notifyMessage: String?
    }

    /// - Parameters:
    ///   - sourcesConfigured: at least one `--drive-folder` or photo album was given.
    ///   - readyCount: destinations ready to receive backups — headline text only.
    static func evaluate(
        verified: Int,
        total: Int,
        sourceFailures: Int,
        destInitFailures: Int,
        destBackupFailures: Int,
        runCancelled: Bool,
        sourcesConfigured: Bool,
        dryRun: Bool,
        readyCount: Int,
        runTag: String
    ) -> Result {
        if dryRun {
            if runCancelled {
                return Result(exitCode: 130, headline: "dry run cancelled — nothing was written",
                              state: .warn, notify: false, notifyMessage: nil)
            }
            return Result(
                exitCode: 0,
                headline: "dry run complete — \(readyCount) destination(s) reachable; Drive previewed by metadata (no download), nothing uploaded. Re-run without --dry-run to back up.",
                state: .ok, notify: false, notifyMessage: nil)
        }

        // Cancellation takes precedence over the failure paths below: restic was
        // interrupted on purpose, the data it already uploaded persists in the
        // repo (dedup reuses it next run) — exit 130 (the conventional SIGINT
        // code), no banner (the user is right here doing this).
        if runCancelled {
            return Result(
                exitCode: 130,
                headline: "cancelled — \(verified)/\(total) acquired before interrupt; restic stopped, uploaded data kept for next run",
                state: .warn, notify: false, notifyMessage: nil)
        }

        if total == 0 {
            // "Acquired 0 items" has two very different shapes. A configured
            // Drive folder that currently holds 0 regular files ran cleanly —
            // under launchd that must NOT ring a failure banner every night.
            // Only an empty SET (misconfiguration) or an actual source/
            // destination failure is an error.
            if sourcesConfigured && sourceFailures == 0
                && destInitFailures == 0 && destBackupFailures == 0 {
                return Result(
                    exitCode: 0,
                    headline: "nothing to back up — the configured source(s) hold 0 files right now; every source ran cleanly",
                    state: .ok, notify: false, notifyMessage: nil)
            }
            let extra = sourceFailures > 0 ? " (\(sourceFailures) source(s) failed)" : ""
            let headline = "nothing was acquired\(extra)"
            return Result(exitCode: 2, headline: headline, state: .fail, notify: true, notifyMessage: headline)
        }

        var problems: [String] = []
        if verified != total { problems.append("\(total - verified) item(s) failed verification") }
        if sourceFailures > 0 { problems.append("\(sourceFailures) source(s) skipped after errors") }
        if destInitFailures > 0 { problems.append("\(destInitFailures) destination(s) unavailable") }
        if destBackupFailures > 0 { problems.append("\(destBackupFailures) destination(s) had backup failures") }
        if !problems.isEmpty {
            let joined = problems.joined(separator: "; ")
            return Result(
                exitCode: 2,
                headline: "\(verified)/\(total) verified — \(joined); review the manifest",
                state: .warn, notify: true, notifyMessage: "\(verified)/\(total) verified — \(joined)")
        }

        return Result(
            exitCode: 0,
            headline: "\(verified)/\(total) verified to \(readyCount) destination(s) — every acquired byte-stream backed up under tag \(runTag)",
            state: .ok, notify: false, notifyMessage: nil)
    }
}
