import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Guards against two backup runs (bare, scheduled, or the TUI's "sync now"
/// child) executing concurrently — overlapping runs would race the shared
/// staging tree and duplicate the materialize/export work. Uses a single
/// `flock` on a fixed file inside the app support dir; `flock` is scoped to
/// the open-file-description, not the process, so it is released
/// automatically when the holding process exits (even a crash) — there is no
/// stale-lock state to clean up, unlike the repo-level restic lock.
enum SingleInstanceLock {
    enum Outcome {
        /// The lock is held by this process. Keep `fd` open for the process
        /// lifetime (never call close on it) — closing it releases the lock.
        case acquired(Int32)
        /// Another process already holds the lock.
        case busy
    }

    /// Same support-dir resolution the credential/destination stores use
    /// (respects BAAACKAAAB_SUPPORT_DIR), so the lock relocates alongside them
    /// under the test harness too.
    static var path: URL { CredentialFiles.dir.appendingPathComponent("run.lock") }

    /// Try to acquire the exclusive run lock, non-blocking (`LOCK_NB`). If the
    /// lock file itself can't be created or opened (e.g. an unwritable support
    /// dir), this fails OPEN — the run proceeds unguarded — because a
    /// filesystem hiccup here must never silently block a legitimate backup;
    /// a broken support dir will already fail loudly elsewhere (the
    /// credential read).
    static func acquire() -> Outcome {
        guard let fd = openLockFile(path, guardName: "concurrent-run guard") else { return .acquired(-1) }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            return .acquired(fd)
        }
        close(fd)
        return .busy
    }

    /// Separate from `path` on purpose. The three scheduled jobs — backup,
    /// integrity check, restore drill — all carry RunAtLoad + `--catch-up`, so
    /// after a long sleep they become due in the same second and run against
    /// the same restic repo at once (issue #23): the check's exclusive restic
    /// lock fails the others as "locked", and three restic starts at once on a
    /// loaded machine are what pushed a probe past its timeout. This lock
    /// serialises them. It is a second file, not `path`, because the two answer
    /// different questions: `path` skips a duplicate BACKUP (the TUI's "sync
    /// now" racing the timer), while this one must not skip a due job — backup
    /// and check default to the same 12:00 slot, so a skip would drop one of
    /// them every day. A backup holds both; the check and the drill hold only
    /// this one, so a backup started during a check still passes `path` and
    /// waits here instead of being skipped.
    static var repoPath: URL { CredentialFiles.dir.appendingPathComponent("repo.lock") }

    /// How long a job waits for a sibling before giving up. Bounded because a
    /// writing restic run has no deadline of its own: a stuck backup would
    /// otherwise park every later check/drill in this wait, and launchd starts
    /// no new instance of a label that is still running — the jobs would stop
    /// without a single failure line.
    static let repoWaitLimit: TimeInterval = 6 * 3_600

    /// Take the repo lock, WAITING for a sibling job to release it. Returns the
    /// held fd (keep it open for the process lifetime), -1 when failing open like
    /// `acquire()`, or nil when the sibling still held it after `limit`. `onWait`
    /// runs once, only when a sibling holds the lock, so the log shows the wait
    /// as what it is. Polls with LOCK_NB rather than blocking in `flock`, which
    /// is what makes the wait bounded; SIGINT/SIGTERM still kill a waiting
    /// process (take this before arming `BackupCancellation`, which ignores them)
    /// and the kernel drops the lock with it.
    static func acquireRepo(limit: TimeInterval = repoWaitLimit, poll: TimeInterval = 5,
                            onWait: () -> Void) -> Int32? {
        guard let fd = openLockFile(repoPath, guardName: "job serialisation") else { return -1 }
        // Awake time, not wall clock: systemUptime stops while the Mac sleeps,
        // so a lid-closed night with the sibling suspended alongside us never
        // counts as the sibling being stuck.
        let deadline = ProcessInfo.processInfo.systemUptime + limit
        var announced = false
        while true {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 { return fd }
            let err = errno
            guard err == EWOULDBLOCK || err == EINTR else {
                // Not "held by a sibling" (e.g. a support dir without flock
                // support) — fail open instead of announcing a phantom wait.
                Console.warn("could not take the repo lock at \(repoPath.path) (errno \(err)) — proceeding WITHOUT job serialisation")
                return fd
            }
            if !announced { onWait(); announced = true }
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { close(fd); return nil }
            Thread.sleep(forTimeInterval: min(poll, remaining))
        }
    }

    /// The CLI side of `acquireRepo` for the three scheduled jobs: announce the
    /// wait, and when the sibling never lets go, fail THIS job naming the real
    /// cause — never as a destination problem — with a banner when unattended.
    static func acquireRepoOrExit(job: String) {
        if acquireRepo(onWait: { Console.note(repoWaitNote) }) != nil { return }
        let message = "the \(job) did not run — another baaackaaab job held the repository for \(Int(repoWaitLimit / 3_600))h of awake time and may be stuck (see the log above it). Nothing was read or written by this run; the destination itself was not judged."
        Console.error(message)
        if isatty(STDERR_FILENO) == 0 {
            Notifier.notify(title: "baaackaaab \u{2014} \(job) did not run", message: message, subtitle: "repository busy")
        }
        exit(1)
    }

    /// The line a job prints before it waits on `repoPath`.
    static let repoWaitNote = "another baaackaaab job (backup / integrity check / restore drill) is using the repository — waiting for it to finish instead of racing it"

    /// Open (creating) a lock file, or nil when that is impossible — the caller
    /// then fails open.
    private static func openLockFile(_ url: URL, guardName: String) -> Int32? {
        try? FileManager.default.createDirectory(
            at: CredentialFiles.dir, withIntermediateDirectories: true)
        let fd = open(url.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else {
            // Fail open, but never silently: the operator should know this run
            // is not protected, and why.
            Console.warn("could not open the lock at \(url.path) — proceeding WITHOUT the \(guardName); check the support dir's permissions")
            return nil
        }
        return fd
    }
}
