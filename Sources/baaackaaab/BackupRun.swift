import Foundation

/// The top-level backup orchestration, extracted from main.swift unchanged: it
/// initializes every destination, runs the quota pre-flight, acquires iCloud
/// Drive and Photos, writes the manifest, prints the summary, records the run
/// history and exits with the conventional code. main.swift resolves the inputs
/// (flags, set, destinations) and hands them here; this owns the run itself.
struct BackupRun {
    let destinations: [Destination]
    let primaryRepo: String
    let runTag: String
    let runStart: Date
    let host: String
    let backupDryRun: Bool
    let configLimitUploadKiBps: Int?
    let configPackSizeMiB: Int?
    let configRestConnections: Int?
    let configReadConcurrency: Int?
    let configExcludes: [String]
    let configExcludeFiles: [String]
    /// Warn-only large-file threshold (MiB; 0 disables), already resolved
    /// against the persisted default by main.swift. Never excludes anything or
    /// changes the run outcome — see `LargeFileWarning`.
    let configLargeFileWarnMiB: Int
    let repoQuotaBytes: Int?
    let quotaWarnFraction: Double
    let driveFolders: [String]
    let photoAlbums: [String]
    let stagingURL: URL
    let photoBatchBytes: Int
    let heartbeatURL: String?
    let notifyChannels: [NotifyChannel]
    let promTextfileDir: String?

    func execute() {
        // Hold off IDLE system sleep for the whole real backup, so a long overnight
        // upload isn't cut short by the idle-sleep timer (a lid close still sleeps —
        // this is PreventUserIdleSystemSleep, not PreventSystemSleep). A dry run
        // uploads nothing, so it takes no assertion. The defer covers the normal
        // return; the kernel releases the assertion on process exit for the many
        // exit() paths below (documented in SleepHold).
        let sleepHold = backupDryRun ? nil : SleepHold(reason: "baaackaaab backup in progress")
        defer { sleepHold?.release() }

        // Fire a macOS failure banner, but ONLY when our output is invisible (launchd or
        // piped): an interactive run already shows the summary on screen, so a banner
        // there would be noise. This is the unattended timer's one human-visible failure
        // signal — the scheduled log goes unread.
        func notifyOnFailure(_ headline: String) {
            guard isatty(STDERR_FILENO) == 0 else { return }
            Notifier.notify(title: "baaackaaab \u{2014} backup failed",
                            message: headline, subtitle: "run \(runTag)")
        }

        // Outbound monitoring is fire-and-forget: it never touches the exit code.
        // Skipped entirely on a dry run — it writes/uploads nothing, so it isn't
        // the run the dead-man's switch (or the operator's phone) needs to hear
        // about. Every call site that uses this also calls
        // OutboundNotifier.waitForPending() right before its own exit(), so the
        // pings/pushes actually leave instead of being killed mid-flight.
        func sendOutboundOutcome(ok: Bool, message: String, verified: Int, total: Int,
                                 destStatuses: [(name: String, ok: Bool)]) {
            guard !backupDryRun, heartbeatURL != nil || !notifyChannels.isEmpty else { return }
            if let heartbeatURL {
                OutboundNotifier.fireHeartbeat(base: heartbeatURL, event: ok ? .success : .fail)
            }
            if !notifyChannels.isEmpty {
                OutboundNotifier.pushOutcome(channels: notifyChannels, ok: ok, message: message,
                                             started: runStart, finished: Date(),
                                             verified: verified, total: total, destinations: destStatuses)
            }
            OutboundNotifier.waitForPending()
        }

        do {
            let staging = try Staging(root: stagingURL)
            // Heartbeat "start" ping, fired as early as the run itself starts
            // (before init/acquisition can fail) — a crash right after this still
            // gets its "start" ping followed by a "fail" ping from the catch below,
            // which is exactly what a dead-man's switch needs to see.
            if !backupDryRun, let heartbeatURL {
                OutboundNotifier.fireHeartbeat(base: heartbeatURL, event: .start)
            }
            let runs = destinations.map { DestinationRun($0) }
            // Set only when the quota pre-flight below actually samples the repo
            // size — reused for status.json's `repo` block instead of a second
            // network round-trip. nil (and the block simply omitted) when no
            // --repo-quota is configured; `--status-export` probes it explicitly
            // on demand instead.
            var repoSizeBytesForStatus: Int64? = nil

            // Append one NDJSON history record, then exit. Built from the live `runs` so
            // every terminal path (no-destination, nothing-acquired, partial, success)
            // records the same shape. Best-effort: a failed write never blocks the exit.
            // Also rebuilds status.json (+ the Prometheus textfile, if configured) from
            // the history it just appended to — same best-effort contract, never blocks.
            func recordRun(exitCode: Int, verified: Int, total: Int, sourceFailures: Int) {
                let dests = runs.map { r -> RunRecord.Dest in
                    let c = r.churn
                    return RunRecord.Dest(
                        name: r.destination.name, ok: r.ok,
                        error: r.initError ?? r.firstBackupError,
                        dataAdded: c.hasData ? c.dataAdded : nil,
                        filesChanged: c.hasData ? c.filesChanged : nil,
                        filesNew: c.hasData ? c.filesNew : nil,
                        bytesProcessed: c.hasData ? c.bytesProcessed : nil)
                }
                let record = RunRecord(runTag: runTag, start: runStart, end: Date(),
                                       exitCode: exitCode, verified: verified, total: total,
                                       sourceFailures: sourceFailures, destinations: dests)
                try? RunHistory.append(record)
                StatusExport.exportAfterRun(repoSizeBytes: repoSizeBytesForStatus,
                                            quotaBytes: repoQuotaBytes.map(Int64.init),
                                            promTextfileDir: promTextfileDir)
            }

            // Arm cancellation BEFORE the first restic child (the init probe): a Ctrl-C /
            // SIGTERM from here on interrupts the in-flight restic and unwinds to the
            // cancelled summary instead of hard-killing us. Armed this early so a cancel
            // during repository init is handled too, not just one during a backup.
            BackupCancellation.shared.arm()

            // Resolve exclude-files once for the whole run: expand the tilde (restic
            // does NOT expand `~`, the shell would) and drop any that no longer exist
            // or aren't readable — with a warning, not a failure. A missing
            // --exclude-file would make restic exit non-zero and fail the WHOLE
            // backup, which under the unattended timer means a silent no-backup; a
            // stale path must never cost the run. The set globs need no such handling
            // (they're matched against the tree, not opened).
            let excludeFilesResolved: [String] = configExcludeFiles.compactMap { path in
                let expanded = (path as NSString).expandingTildeInPath
                if FileManager.default.isReadableFile(atPath: expanded) { return expanded }
                Console.warn("exclude-file not found or unreadable, ignoring it this run: \(path)")
                return nil
            }

            Console.banner("baaackaaab", tagline: "one-way iCloud → restic backup")
            var info: [(String, String)] = [
                ("host", host),
                ("run-tag", runTag),
                ("staging", "\(stagingURL.path) (scratch for photo batches only)"),
            ]
            if destinations.count == 1 {
                info.insert(("repo", Credentials.redact(primaryRepo)), at: 0)
            } else {
                info.insert(("destinations",
                             destinations.map { "\($0.name) [\($0.link)]" }.joined(separator: ", ")), at: 0)
            }
            if backupDryRun { info.append(("mode", "dry run — preview only, nothing uploaded")) }
            if let lim = configLimitUploadKiBps, lim > 0, !backupDryRun {
                info.append(("limit-upload", "\(lim) KiB/s"))
            }
            if let ps = configPackSizeMiB, ps > 0, !backupDryRun {
                info.append(("pack-size", "\(ps) MiB"))
            }
            if let rc = configRestConnections, rc > 0, !backupDryRun {
                info.append(("rest-connections", "\(rc)"))
            }
            if let rcc = configReadConcurrency, rcc > 0, !backupDryRun {
                info.append(("read-concurrency", "\(rcc)"))
            }
            // Excludes are always active (the macOS-junk defaults + caches), so this
            // line shows on every run — plus any set globs / exclude-files, so it's
            // visible exactly what is being kept out of the un-prunable store.
            var excludeParts = ["macOS junk + caches"]
            if !configExcludes.isEmpty { excludeParts.append("\(configExcludes.count) pattern(s)") }
            if !excludeFilesResolved.isEmpty { excludeParts.append("\(excludeFilesResolved.count) exclude-file(s)") }
            info.append(("excludes", excludeParts.joined(separator: ", ")))
            if !backupDryRun, heartbeatURL != nil || !notifyChannels.isEmpty {
                var monitoring: [String] = []
                if heartbeatURL != nil { monitoring.append("heartbeat") }
                if !notifyChannels.isEmpty { monitoring.append("\(notifyChannels.count) push channel(s)") }
                info.append(("monitoring", monitoring.joined(separator: ", ")))
            }
            Console.info(info)

            // Initialize every destination, best-effort. A destination that can't be
            // reached / initialized is recorded and skipped for all backups; the others
            // still run, so one dead repo never costs you the whole backup. (init refuses
            // to clobber an existing repo, so this is safe to call every run.)
            Console.section("Destinations")
            for run in runs {
                if backupDryRun {
                    // A dry run must write NOTHING, so probe for the repo instead of
                    // initializing it. restic's typed exit codes let us name the exact
                    // reason a repo can't be previewed, instead of one catch-all.
                    switch run.backend.probe() {
                    case .present:
                        Console.success("\(run.destination.name): reachable (dry run — not initialized)  \(Credentials.redact(run.backend.repository))")
                    case .absent:
                        run.initError = "repository not created yet — run `--check` to create it; a dry run never initializes"
                        Console.failure("\(run.destination.name): \(run.initError!)")
                    case .locked:
                        run.initError = "repository is locked by another restic operation — retry, or clear a stale lock with `--unlock`"
                        Console.failure("\(run.destination.name): \(run.initError!)")
                    case .wrongPassword:
                        run.initError = "repository password is wrong — this destination's stored key cannot decrypt the repo"
                        Console.failure("\(run.destination.name): \(run.initError!)")
                    case .unreachable:
                        run.initError = "repository not reachable (timeout / transport / auth) — run `--check` to diagnose; a dry run never initializes"
                        Console.failure("\(run.destination.name): \(run.initError!)")
                    }
                    continue
                }
                do {
                    try run.backend.ensureInitialized()
                    Console.success("\(run.destination.name): ready  \(Credentials.redact(run.backend.repository))")
                } catch {
                    run.initError = "\(error)"
                    Console.failure("\(run.destination.name): unavailable — \(error)")
                }
            }
            // Cancelled during init (the interrupt makes a destination's init fail) — take
            // that as cancellation, not as "no destination could be initialized", so we
            // exit 130 and record a cancelled run rather than a spurious failure.
            if BackupCancellation.shared.isCancelled {
                Console.summary(headline: "cancelled during init — nothing was backed up yet",
                                state: .warn, details: [("run-tag", runTag)])
                recordRun(exitCode: 130, verified: 0, total: 0, sourceFailures: 0)
                exit(130)
            }

            let ready = runs.filter { $0.ready }
            if ready.isEmpty {
                // A dry run with nothing previewable (no repo created yet) is not a backup
                // failure — report it and exit non-zero, but don't record a run or fire the
                // failure banner (it wrote nothing and isn't the unattended timer's job).
                if backupDryRun {
                    Console.summary(headline: "dry run — no destination is previewable (not reachable or not created yet); nothing was written",
                                    state: .warn, details: [("run-tag", runTag)])
                    exit(1)
                }
                Console.summary(headline: "no destination could be initialized — nothing was backed up",
                                state: .fail, details: [("run-tag", runTag)])
                recordRun(exitCode: 2, verified: 0, total: 0, sourceFailures: 0)
                notifyOnFailure("no destination could be initialized — nothing was backed up")
                sendOutboundOutcome(ok: false, message: "no destination could be initialized — nothing was backed up",
                                   verified: 0, total: 0,
                                   destStatuses: runs.map { (name: $0.destination.name, ok: false) })
                exit(2)
            }

            // Back up `paths` to every ready destination, sequential primary-first.
            // Per-destination best-effort: a failure is recorded on that destination and
            // reported, but never aborts the other destinations, the other sources, or
            // the run. (Parallel-by-link is a later slice; this is the sequential base.)
            // The ONLY thing it throws is RunCancelled — a real restic failure is recorded
            // and swallowed, but a cancel must propagate so the run stops launching work.
            // A real backup always runs `restic --json` (the churn summary must be
            // captured even under the timer); on a TTY that stream renders the live
            // progress bar, off a TTY it yields one concise tally line per backup.
            // A dry run (file-list preview) keeps restic's plain output.
            let showProgress = isatty(STDOUT_FILENO) != 0 && !backupDryRun

            // Warn-only large-file notice: print one Console.warn per newly-staged
            // item over the configured threshold. `items` is the SLICE added since
            // the last call (drive: one folder; photos: one batch), so each source
            // reports independently. Never excludes anything and never changes the
            // run outcome — purely informational.
            func warnLargeFiles(_ items: ArraySlice<AcquiredItem>) {
                let large = LargeFileWarning.filter(
                    items.map { (path: $0.stagedPath, bytes: $0.byteCount) },
                    thresholdMiB: configLargeFileWarnMiB)
                for item in large {
                    let size = ByteCountFormatter.string(fromByteCount: Int64(item.bytes), countStyle: .file)
                    Console.warn("\(item.path) (\(size)) exceeds the large-file threshold — it will be baked permanently into the append-only store; add an exclude if unwanted")
                }
            }

            func backupToAll(paths: [URL], tags: [String], label: String) throws {
                for run in ready {
                    if BackupCancellation.shared.isCancelled { throw RunCancelled() }
                    do {
                        // Aggregate the per-snapshot churn summary into this
                        // destination's running total (nil on a dry run / a skipped
                        // backup that wrote no snapshot). Persisted + fed to the tripwire.
                        if let summary = try run.backend.backup(
                                paths: paths, tags: tags, host: host,
                                dryRun: backupDryRun, limitUploadKiBps: configLimitUploadKiBps,
                                packSizeMiB: configPackSizeMiB,
                                restConnections: configRestConnections,
                                readConcurrency: configReadConcurrency,
                                excludes: configExcludes, excludeFiles: excludeFilesResolved,
                                showProgress: showProgress) {
                            run.churn.add(summary)
                        }
                    } catch {
                        // A cancel interrupts restic into a non-zero (130) exit; treat that
                        // as cancellation, not as this destination's own backup failure.
                        if BackupCancellation.shared.isCancelled { throw RunCancelled() }
                        run.backupFailures += 1
                        if run.firstBackupError == nil { run.firstBackupError = "\(error)" }
                        Console.failure("\(run.destination.name): backup failed for \(label) — \(error)")
                    }
                }
            }

            // 0) Remote-quota pre-flight (soft gauge) on the primary ready destination.
            //    Reads the current repo size and, if it is past the warn fraction of the
            //    operator-supplied quota, prints an actionable warning. The server still
            //    hard-stops at 100%; this just gives lead time to raise --max-size.
            if let quota = repoQuotaBytes, quota > 0 {
                Console.section("Quota")
                if let used = ready[0].backend.repoSizeBytes() {
                    repoSizeBytesForStatus = Int64(used)
                    let frac = Double(used) / Double(quota)
                    let pct = Int((frac * 100).rounded())
                    let usedGB = String(format: "%.2f", Double(used) / 1_000_000_000)
                    let quotaGB = String(format: "%.2f", Double(quota) / 1_000_000_000)
                    Console.step("\(ready[0].destination.name): \(usedGB) GB / \(quotaGB) GB (\(pct)%)")
                    if frac >= quotaWarnFraction {
                        Console.warn("repo is at \(pct)% of the configured quota. Raise --max-size on the rest-server (edit the stack's docker-compose.yml, redeploy — no data migration) before it fills; the server hard-stops new backups at 100%.")
                    }
                } else {
                    Console.note("repo size unavailable (fresh repo or stats failed) — skipping quota gauge")
                }
            }

            // 1) iCloud Drive — for each folder: materialize + verify in place ONCE, then
            //    back it up to every destination. Materializing per folder right before
            //    its backup closes the TOCTOU window where a folder materialized early
            //    could be re-evicted by the file provider before restic reads it.
            //    Per-source best-effort: a folder that fails to materialize is recorded
            //    and skipped (for all destinations) — one bad folder must not abort the
            //    remaining folders or the Photos phase.
            var driveFailures = 0
            var photoFailures = 0
            var runCancelled = false
            // Drive and Photos run inside one do: a cancel surfaces as RunCancelled thrown
            // out of backupToAll (or rethrown from a photo album), and unwinds straight to
            // the cancelled finalizer below — without aborting the manifest write.
            do {
                if driveFolders.isEmpty {
                    Console.section("iCloud Drive")
                    Console.note("no --drive-folder given, skipping Drive")
                } else {
                    for folder in driveFolders {
                        let url = URL(fileURLWithPath: (folder as NSString).expandingTildeInPath, isDirectory: true)
                        Console.section("iCloud Drive", detail: url.path)
                        if backupDryRun {
                            // A dry run must download NOTHING. Walk metadata only (no
                            // coordinated read → no fault-in) and report how many files are
                            // still cloud-only; a real run would materialize exactly those.
                            // We deliberately do NOT hand the live tree to restic here:
                            // restic would read file contents to build its preview, and that
                            // read faults the stubs in from iCloud — the cost the dry run
                            // exists to avoid.
                            do {
                                let (files, dataless) = try DriveAcquirer().previewDataless(folder: url)
                                Console.success("\(files) file(s); \(dataless) still cloud-only (a real run downloads those)")
                            } catch {
                                driveFailures += 1
                                Console.failure("drive folder skipped: \(url.path) — \(error)")
                            }
                            continue
                        }
                        let beforeCount = staging.items.count
                        do {
                            try DriveAcquirer().materializeAndVerify(folder: url, into: staging)
                        } catch {
                            driveFailures += 1
                            Console.failure("drive folder skipped: \(url.path) — \(error)")
                            continue
                        }
                        warnLargeFiles(staging.items[beforeCount...])
                        try backupToAll(paths: [url], tags: [runTag, "drive"], label: url.lastPathComponent)

                        // Re-eviction guard: materialize proved real bytes before
                        // restic read the tree, but under storage pressure the file
                        // provider could re-evict a file mid-read, letting restic
                        // capture a 0-byte stub. A metadata-only re-walk (lstat, no
                        // fault-in) catches it: anything dataless again means this
                        // snapshot may hold a stub, so fail the folder and let the
                        // next run re-capture it rather than report a silent success.
                        do {
                            let recheck = try DriveAcquirer().previewDataless(folder: url)
                            if recheck.dataless > 0 {
                                driveFailures += 1
                                Console.failure("\(url.lastPathComponent): \(recheck.dataless) file(s) were re-evicted during the backup — this snapshot may contain 0-byte stubs; re-run to re-capture them")
                            }
                        } catch {
                            // The backup itself succeeded; we just cannot confirm
                            // nothing was re-evicted mid-read. Warn, don't fail.
                            Console.warn("\(url.lastPathComponent): backed up, but the post-backup re-eviction check could not run (\(error))")
                        }
                    }
                }

                // 2) iCloud Photos — export in byte-budgeted batches; each batch is backed
                //    up to EVERY destination and then deleted, so peak extra disk stays
                //    ~one batch (not 27 GB) regardless of how many destinations there are.
                if backupDryRun && !photoAlbums.isEmpty {
                    Console.section("iCloud Photos")
                    Console.note("dry run — skipping Photos: a real preview would have to export every original to staging (as costly as a real backup). Run without --dry-run to back them up.")
                } else if photoAlbums.isEmpty {
                    Console.section("iCloud Photos")
                    Console.note("no photo album configured, skipping Photos")
                } else {
                    // Batch indices run globally across albums so each photo snapshot in a
                    // run gets a distinct batch-N tag, even with more than one album.
                    // Indices advance by however many batches actually ran (lastIdx), so
                    // they stay monotonic even when an album fails partway. Per-source
                    // best-effort: a failing album is recorded and skipped, not fatal.
                    var photoBatchBase = 0
                    for album in photoAlbums {
                        Console.section("iCloud Photos", detail: "album '\(album)' (batch budget \(photoBatchBytes) bytes)")
                        var lastIdx = -1
                        var priorItemCount = staging.items.count
                        do {
                            try PhotosAcquirer().acquireBatched(
                                albumTitle: album,
                                byteBudget: photoBatchBytes,
                                into: staging
                            ) { batchDir, idx in
                                lastIdx = idx
                                // acquireBatched already recorded this batch's items into
                                // `staging` before invoking us, so the slice since the
                                // last batch (or the album's start) is exactly this one.
                                warnLargeFiles(staging.items[priorItemCount...])
                                priorItemCount = staging.items.count
                                // backupToAll only throws RunCancelled — a single
                                // destination's plain failure does not abort the album's
                                // remaining batches; the batch is still deleted, peak holds.
                                try backupToAll(
                                    paths: [batchDir],
                                    tags: [runTag, "photos", "batch-\(photoBatchBase + idx)"],
                                    label: "batch \(photoBatchBase + idx)"
                                )
                            }
                        } catch is RunCancelled {
                            throw RunCancelled()   // bubble up to the phase-level catch
                        } catch {
                            photoFailures += 1
                            Console.failure("photo album skipped: '\(album)' — \(error)")
                        }
                        photoBatchBase += lastIdx + 1   // lastIdx = -1 (no batches ran) → no-op
                    }
                }
            } catch is RunCancelled {
                runCancelled = true
            }

            // A dry run is a preview: it stages nothing and uploads nothing, so finish
            // here — skip the manifest, the run-history record, and the failure banner,
            // and never fall through to the "nothing acquired" failure path (a dry run
            // legitimately acquires nothing). Re-running without --dry-run does the work.
            if backupDryRun {
                let outcome = RunOutcome.evaluate(
                    verified: 0, total: 0, sourceFailures: 0, destInitFailures: 0, destBackupFailures: 0,
                    runCancelled: runCancelled,
                    sourcesConfigured: !(driveFolders.isEmpty && photoAlbums.isEmpty),
                    dryRun: true, readyCount: ready.count, runTag: runTag)
                var d: [(String, String)] = [("run-tag", runTag)]
                let unavailable = runs.filter { $0.initError != nil }.count
                if unavailable > 0 { d.append(("note", "\(unavailable) destination(s) not previewable (repo not created yet)")) }
                if driveFailures > 0 { d.append(("drive", "\(driveFailures) folder(s) could not be previewed")) }
                Console.summary(headline: outcome.headline, state: outcome.state, details: d)
                exit(outcome.exitCode)
            }

            // The manifest is a local diagnostic, so writing it is best-effort: a failure
            // here must NOT unwind to the outer catch and overwrite the real outcome —
            // that would misrecord a cancelled or fully-successful run as a crash. The
            // counts below come from staging's in-memory state, not from re-reading it.
            do { try staging.writeManifest() }
            catch { Console.warn("could not write the run manifest: \(error) — the run still completed; counts below are from this run's in-memory state") }

            // Summary across BOTH sources (acquisition) and destinations (delivery).
            let verified = staging.items.filter { $0.verified }.count
            let total = staging.items.count
            let sourceFailures = driveFailures + photoFailures
            let destInitFailures = runs.filter { $0.initError != nil }.count
            let destBackupFailures = runs.filter { $0.backupFailures > 0 }.count
            let manifestPath = stagingURL.appendingPathComponent("manifest.json").path
            var details: [(String, String)] = [("run-tag", runTag), ("manifest", manifestPath)]
            if destinations.count > 1 {
                let perDest = runs.map { r -> String in
                    if r.initError != nil { return "\(r.destination.name): unavailable" }
                    return r.backupFailures > 0
                        ? "\(r.destination.name): \(r.backupFailures) failed"
                        : "\(r.destination.name): ok"
                }.joined(separator: "; ")
                details.append(("destinations", perDest))
            }

            let outcome = RunOutcome.evaluate(
                verified: verified, total: total, sourceFailures: sourceFailures,
                destInitFailures: destInitFailures, destBackupFailures: destBackupFailures,
                runCancelled: runCancelled,
                sourcesConfigured: !(driveFolders.isEmpty && photoAlbums.isEmpty),
                dryRun: false, readyCount: ready.count, runTag: runTag)
            Console.summary(headline: outcome.headline, state: outcome.state, details: details)
            // Snapshot the history BEFORE recording this run, so the churn-anomaly
            // baseline is built purely from PRIOR runs and never includes the run we
            // are about to append.
            let priorHistory = runCancelled ? [] : RunHistory.recent(ChurnAnomaly.baselineWindow)
            recordRun(exitCode: Int(outcome.exitCode), verified: verified, total: total, sourceFailures: sourceFailures)
            if outcome.notify, let message = outcome.notifyMessage { notifyOnFailure(message) }

            // Source-side ransomware tripwire (warn-only). Compare each destination's
            // aggregated churn against a median baseline of its prior successful runs
            // and, on a spike or shrink, warn loudly + fire a notification. This NEVER
            // alters the exit code and NEVER touches eviction — an explicit warn-only
            // decision, so a false positive costs a banner, never a backup. Skipped on
            // a cancelled run (its metrics are partial). The notification mirrors the
            // failure-banner gate: only when our output is invisible (launchd / piped),
            // since an interactive run already shows the warning on screen.
            if !runCancelled {
                for run in ready where run.ok && run.churn.hasData {
                    let baseline = ChurnAnomaly.baseline(from: priorHistory,
                                                         destination: run.destination.name)
                    let message: String
                    switch ChurnAnomaly.evaluate(current: run.churn, baseline: baseline) {
                    case .clean, .insufficientBaseline:
                        continue
                    case .spike(let m), .shrink(let m):
                        message = m
                    }
                    Console.warn("\(run.destination.name): \(message)")
                    if isatty(STDERR_FILENO) == 0 {
                        Notifier.notify(title: "baaackaaab \u{2014} anomaly warning",
                                        message: message,
                                        subtitle: "run \(runTag) \u{2014} \(run.destination.name)")
                    }
                }
            }
            // Unlike the macOS banner (failure-only, since a passing run is already
            // visible on screen), the heartbeat/push path reports EVERY terminal
            // outcome — a heartbeat's whole point is a "success" ping resetting the
            // monitor's dead-man's-switch clock, not just a failure alert.
            sendOutboundOutcome(ok: outcome.state == .ok, message: outcome.notifyMessage ?? outcome.headline,
                               verified: verified, total: total,
                               destStatuses: runs.map { (name: $0.destination.name, ok: $0.initError == nil && $0.backupFailures == 0) })
            // Unattended (log-only) path: nudge once per clean run when restic or the
            // server has fallen behind the tested baseline — the scheduled log goes
            // unread, so a banner is the only signal. Offline for restic; best-effort
            // probe for the server (we just reached it). Silent when everything is
            // current, and never on an interactive run (the summary is on screen). Only
            // on the full-success path (exit 0 with items actually acquired), matching
            // the clean-empty branch's original exemption from this nudge too.
            if outcome.exitCode == 0, total > 0, isatty(STDERR_FILENO) == 0,
               let stale = UpdateCheck.staleBaselineBanner(primaryRepoURL: primaryRepo) {
                Notifier.notify(title: "baaackaaab \u{2014} update available",
                                message: stale, subtitle: "run \(runTag)")
            }
            exit(outcome.exitCode)
        } catch {
            Console.error("\(error)")
            // The throw happened before/around acquisition (e.g. staging init): `runs` is
            // out of scope here, so record a minimal "crashed early" line — still visible
            // in the dashboard so a wedged scheduled run doesn't vanish silently.
            try? RunHistory.append(RunRecord(runTag: runTag, start: runStart, end: Date(),
                                             exitCode: 1, verified: 0, total: 0,
                                             sourceFailures: 0, destinations: []))
            StatusExport.exportAfterRun(repoSizeBytes: nil, quotaBytes: repoQuotaBytes.map(Int64.init),
                                        promTextfileDir: promTextfileDir)
            notifyOnFailure("\(error)")
            sendOutboundOutcome(ok: false, message: "\(error)", verified: 0, total: 0, destStatuses: [])
            exit(1)
        }
        exit(0)
    }
}
