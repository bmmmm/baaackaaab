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

final class BackupCancellation {
    static let shared = BackupCancellation()
    private init() {}

    private let lock = NSLock()
    private var current: Process?
    private var cancelledFlag = false
    private var armed = false
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
    func arm() {
        lock.lock(); let already = armed; armed = true; lock.unlock()
        guard !already else { return }
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)   // disable default termination; the source observes it
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .global(qos: .userInitiated))
            src.setEventHandler { [weak self] in self?.handle() }
            src.resume()
            sources.append(src)
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
        lock.unlock()
        if first {
            FileHandle.standardError.write(Data(
                "\ncancelling — interrupting restic; data already uploaded is kept (dedup reuses it next run)\n".utf8))
        }
        proc?.interrupt()
    }
}
