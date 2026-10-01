import Foundation
#if canImport(Darwin)
import Darwin
#endif

// Cooperative cancellation for a backup run. Ctrl-C (SIGINT) or a `kill` / launchd
// shutdown (SIGTERM) must NOT hard-kill us mid-upload: we want restic to shut down
// cleanly and exit 130 (the data packs it already uploaded persist in the repo, so
// the next run's dedup reuses them — interrupting wastes no upload), and we want to
// record the run as cancelled and exit cleanly (130) ourselves.
//
// We use a GCD signal source, NOT a raw signal handler: the handler block runs on
// a normal dispatch queue (off signal context), so it may safely take a lock and
// call Process.interrupt() — neither of which is async-signal-safe. The default
// disposition is set to SIG_IGN so the signal no longer terminates the process;
// the dispatch source still observes it. (The interactive TUI has its own
// raw-mode Ctrl-C handling and is unaffected — this arms only inside a real
// backup run, including the one the TUI re-execs as a child.)
/// Thrown out of the backup loops once a cancel is observed, to unwind cleanly to
/// the run's cancelled-summary finalizer (distinct from a real backup failure).
struct RunCancelled: Error {}

// @unchecked Sendable: every mutable field below (current / cancelledFlag /
// armed / sources) is accessed only under `lock`, so the type is thread-safe by
// construction — the compiler just can't prove the NSLock discipline, hence
// "unchecked". This is what lets `static let shared` be a concurrency-safe global.
final class BackupCancellation: @unchecked Sendable {
    /// What the armed job is doing. The cancel notice has to state what a cancel
    /// actually leaves behind, and that differs per job: only a backup uploads.
    /// Telling an operator who interrupted a read-only check that "data already
    /// uploaded is kept" describes an upload that never happened — the kind of
    /// hardcoded state claim that makes the rest of the output less trustworthy.
    enum JobKind {
        case backup, check, drill

        var cancelNote: String {
            switch self {
            case .backup:
                return "cancelling — interrupting restic; data already uploaded is kept (dedup reuses it next run)"
            case .check:
                return "cancelling — interrupting restic; the integrity check only reads, so the repository is untouched and the slice simply did not run"
            case .drill:
                return "cancelling — interrupting restic; the drill only reads, and its partial restore is discarded with the temp directory"
            }
        }
    }

    static let shared = BackupCancellation()
    // Internal (not private) so tests can exercise the arm/cancel/interrupt
    // state machine on a throwaway instance WITHOUT contaminating the shared
    // singleton other tests (the restic integration suite) rely on. Production
    // code must only ever use `shared`.
    init() {}

    private let lock = NSLock()
    // FIXME: one slot is correct only while the run loop is strictly sequential
    // (BackupRun: "parallel-by-link is a later slice"). Two concurrent restic
    // children would overwrite each other's setCurrent, and a Ctrl-C would
    // interrupt only the last-registered one. Before implementing parallel
    // destinations, make this a set of live processes and interrupt them all.
    private var current: Process?
    private var cancelledFlag = false
    private var armed = false
    private var job: JobKind = .backup                 // set by arm(); drives the cancel notice
    private var sources: [DispatchSourceSignal] = []   // retained for the run's life

    /// Set once a SIGINT/SIGTERM has been seen. The backup loops poll this between
    /// destinations and sources to stop launching new work and finalize.
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelledFlag }

    /// Register the restic child currently running so a signal can interrupt it.
    /// If a cancel already landed before this child started, interrupt it at once
    /// rather than beginning a fresh upload after the user bailed.
    func setCurrent(_ proc: Process) {
        lock.lock()
        current = proc
        let alreadyCancelled = cancelledFlag
        lock.unlock()
        if alreadyCancelled { proc.interrupt() }
    }

    /// Stop tracking `proc` once it has exited (only if it is still the current
    /// one — a later child may already have replaced it).
    func clearCurrent(_ proc: Process) {
        lock.lock(); if current === proc { current = nil }; lock.unlock()
    }

    /// Install the SIGINT/SIGTERM sources for the duration of a run. Idempotent —
    /// arming twice is a no-op, so it is safe to call unconditionally at run start.
    /// `job` names what is running, so the cancel notice describes that job's
    /// actual aftermath; a re-arm still records it, since the caller that re-armed
    /// is the one whose work a later cancel would interrupt.
    func arm(as job: JobKind) {
        lock.lock(); let already = armed; armed = true; self.job = job; lock.unlock()
        guard !already else { return }
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)   // disable default termination; the source observes it
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .global(qos: .userInitiated))
            src.setEventHandler { [weak self] in self?.handle() }
            src.resume()
            // Under the lock like every other mutable field — arm() is currently
            // single-threaded, but the documented invariant (the basis for
            // @unchecked Sendable) is "all state under `lock`", so keep it true.
            lock.lock(); sources.append(src); lock.unlock()
        }
    }

    /// Off signal-context (a dispatch queue): flag the cancellation and interrupt
    /// the in-flight restic child with SIGINT, which makes restic write its partial
    /// snapshot and exit 130. The run loop then records a cancelled run and exits.
    private func handle() {
        lock.lock()
        let first = !cancelledFlag
        cancelledFlag = true
        let proc = current
        let note = job.cancelNote
        lock.unlock()
        if first {
            FileHandle.standardError.write(Data("\n\(note)\n".utf8))
        }
        proc?.interrupt()
    }
}
