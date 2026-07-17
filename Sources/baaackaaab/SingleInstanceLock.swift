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
        try? FileManager.default.createDirectory(
            at: CredentialFiles.dir, withIntermediateDirectories: true)
        let fd = open(path.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return .acquired(-1) }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            return .acquired(fd)
        }
        close(fd)
        return .busy
    }
}
