import Foundation

/// Whether an unattended run that reached NO destination should wait and probe
/// again, and for how long.
///
/// The case this exists for is the boot race. The login/boot `--catch-up` fire
/// lands seconds after launchd loads the agents, while Wi-Fi is still coming up,
/// so the run-start probe times out and the run gives up having backed up
/// nothing. That fire IS the make-up mechanism for a slot missed while the Mac
/// was off — when it gives up on the first attempt, the missed backup stays
/// missed until the next calendar slot, typically a day later. Retrying the
/// probe costs a few minutes of a background job; not retrying costs a backup.
///
/// Deliberately narrow, on three axes:
///   * only TRANSIENT failures — a wrong password, a held lock or an absent repo
///     is not fixed by waiting, so those still fail on the first attempt;
///   * only UNATTENDED runs — at a terminal the operator wants the error now,
///     not eight minutes of silence;
///   * only when NO destination came up — if one is reachable the run proceeds
///     exactly as before and the unreachable one is skipped, as it always was.
enum DestinationWait {
    /// Delay before each successive retry. Front-loaded, because a boot race
    /// usually clears within the first minute, and totalling 7.5 minutes — past
    /// any plausible link-up, and still short next to a daily cadence.
    static let backoff: [TimeInterval] = [30, 60, 120, 240]

    /// Attempts in total, the first one included.
    static var maxAttempts: Int { backoff.count + 1 }

    /// Time spent WAITING between attempts.
    static var backoffTotal: TimeInterval { backoff.reduce(0, +) }

    /// Worst-case wall clock before a permanently dead destination is given up
    /// on: the waits plus every probe running into its own cap. Measured, not
    /// assumed — restic does not fail fast on a refused connection, it retries
    /// the backend request internally until `probeTimeout` cuts it off, so a
    /// probe against a dead endpoint costs the full 60s (verified by
    /// ResticIntegrationTests.testADeadEndpointProbesAsUnreachable). Quoting the
    /// backoff alone would understate the delay by half.
    static var worstCaseWindow: TimeInterval {
        backoffTotal + Double(maxAttempts) * ResticBackend.probeTimeout
    }

    /// Whether waiting could plausibly fix this failure.
    ///
    /// `timedOut` is the boot race itself. A generic `failed` is included because
    /// a link that is down but answering (DNS not yet resolving, the REST server
    /// still starting) makes restic exit non-zero immediately rather than time
    /// out — the same race, a different symptom. Everything else is a decision
    /// the network cannot change: a missing binary, a bad password, a held lock.
    /// A stale lock in particular never clears on its own, so waiting on it would
    /// only delay the actionable `--unlock` message.
    static func isTransient(_ error: Error) -> Bool {
        switch error {
        case ResticError.timedOut, ResticError.failed:
            return true
        default:
            return false
        }
    }

    /// Same judgment for the dry-run path, which probes instead of initializing.
    static func isTransient(_ probe: RepoProbe) -> Bool { probe == .unreachable }

    /// How long to wait before the next attempt, or nil when the run should stop
    /// retrying and report the failure. `attemptsMade` counts attempts already
    /// completed, so it is 1 after the first probe failed. Pure — the caller
    /// supplies the context rather than this reading the environment.
    static func delayBeforeRetry(attemptsMade: Int, unattended: Bool,
                                 allTransient: Bool) -> TimeInterval? {
        guard unattended, allTransient else { return nil }
        guard attemptsMade >= 1, attemptsMade <= backoff.count else { return nil }
        return backoff[attemptsMade - 1]
    }

    /// The line printed before each wait. Names the attempt and the delay so the
    /// unattended log shows a boot race as what it is, rather than as a gap
    /// between one failure and a later success.
    static func retryNotice(attemptsMade: Int, delay: TimeInterval) -> String {
        "no destination reachable — retrying in \(Int(delay))s "
        + "(attempt \(attemptsMade + 1) of \(maxAttempts); giving up after up to \(Int(worstCaseWindow / 60))m)"
    }

    /// Probe one destination until it answers or the backoff runs out, returning
    /// the final probe result. The backup run wraps its own init loop; the check
    /// and drill jobs work one destination at a time and have no such loop, so
    /// they call this instead. `probe` is injected rather than taken as a backend
    /// so the retry sequence is testable without a repo.
    static func awaitReachable(probe: () -> RepoProbe, unattended: Bool,
                               isCancelled: () -> Bool = { false },
                               notify: (String) -> Void = { Console.warn($0) },
                               sleep: (TimeInterval) -> Bool = { waitCancellable($0, isCancelled: { false }) }) -> RepoProbe {
        var attemptsMade = 0
        while true {
            let result = probe()
            attemptsMade += 1
            guard result == .unreachable, !isCancelled() else { return result }
            guard let delay = delayBeforeRetry(attemptsMade: attemptsMade, unattended: unattended,
                                               allTransient: true) else { return result }
            notify(retryNotice(attemptsMade: attemptsMade, delay: delay))
            if !sleep(delay) { return result }
        }
    }

    /// Sleep in slices so a Ctrl-C during the wait is honoured promptly instead
    /// of being swallowed for up to four minutes. Returns false when the run was
    /// cancelled while waiting.
    static func waitCancellable(_ seconds: TimeInterval, slice: TimeInterval = 0.5,
                                isCancelled: () -> Bool) -> Bool {
        var remaining = seconds
        while remaining > 0 {
            if isCancelled() { return false }
            let step = min(slice, remaining)
            Thread.sleep(forTimeInterval: step)
            remaining -= step
        }
        return !isCancelled()
    }
}
