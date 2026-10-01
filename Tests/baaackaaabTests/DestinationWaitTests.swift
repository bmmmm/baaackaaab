import XCTest
@testable import baaackaaab

// The retry gate exists for the boot race, and its whole value is being NARROW:
// a gate that waits on a wrong password delays an actionable error by eight
// minutes, and one that waits at a terminal looks like a hang. These pin each
// axis of the narrowing separately.
final class DestinationWaitTests: XCTestCase {

    // MARK: - What counts as worth waiting for

    func testTimeoutIsTransient() {
        XCTAssertTrue(DestinationWait.isTransient(ResticError.timedOut(command: "cat", seconds: 60)))
    }

    func testAGenericFailureIsTransient() {
        // A link that is down but answering (DNS not resolving yet, the REST
        // server still starting) exits non-zero immediately instead of timing
        // out — the same race, a different symptom.
        XCTAssertTrue(DestinationWait.isTransient(ResticError.failed(command: "init", code: 1)))
    }

    func testDecisionsTheNetworkCannotChangeAreNotTransient() {
        XCTAssertFalse(DestinationWait.isTransient(ResticError.wrongPassword))
        XCTAssertFalse(DestinationWait.isTransient(ResticError.locked))
        XCTAssertFalse(DestinationWait.isTransient(ResticError.notFound))
        XCTAssertFalse(DestinationWait.isTransient(ResticError.launchFailed("bad arch")))
    }

    func testOnlyAnUnreachableProbeIsTransient() {
        XCTAssertTrue(DestinationWait.isTransient(RepoProbe.unreachable))
        XCTAssertFalse(DestinationWait.isTransient(RepoProbe.present))
        XCTAssertFalse(DestinationWait.isTransient(RepoProbe.absent))
        XCTAssertFalse(DestinationWait.isTransient(RepoProbe.locked))
        XCTAssertFalse(DestinationWait.isTransient(RepoProbe.wrongPassword))
    }

    // MARK: - When to retry at all

    func testInteractiveRunsNeverWait() {
        XCTAssertNil(DestinationWait.delayBeforeRetry(attemptsMade: 1, unattended: false, allTransient: true))
    }

    func testAPermanentFailureNeverWaits() {
        XCTAssertNil(DestinationWait.delayBeforeRetry(attemptsMade: 1, unattended: true, allTransient: false))
    }

    func testBackoffIsFrontLoadedAndFinite() {
        let delays = (1...DestinationWait.backoff.count).map {
            DestinationWait.delayBeforeRetry(attemptsMade: $0, unattended: true, allTransient: true)
        }
        XCTAssertEqual(delays, DestinationWait.backoff.map { Optional($0) })
        // Past the last backoff entry the run must give up rather than loop.
        XCTAssertNil(DestinationWait.delayBeforeRetry(attemptsMade: DestinationWait.backoff.count + 1,
                                                      unattended: true, allTransient: true))
    }

    func testWorstCaseWindowCountsProbeTimeNotJustTheBackoff() {
        // The number the operator is told must be the wall clock, and a probe
        // against a dead endpoint costs its full timeout rather than failing
        // fast — quoting the backoff alone would understate it by half.
        XCTAssertEqual(DestinationWait.worstCaseWindow,
                       DestinationWait.backoffTotal
                       + Double(DestinationWait.maxAttempts) * ResticBackend.probeTimeout)
        XCTAssertGreaterThan(DestinationWait.worstCaseWindow, DestinationWait.backoffTotal)
    }

    func testWorstCaseWindowStaysWellInsideADailyCadence() {
        // A boot race clears in seconds; the window only has to outlast a link
        // coming up. If it ever approached a day it would start eating the next
        // scheduled slot.
        XCTAssertGreaterThan(DestinationWait.worstCaseWindow, 5 * 60)
        XCTAssertLessThan(DestinationWait.worstCaseWindow, 20 * 60)
    }

    func testTheQuotedGiveUpTimeMatchesTheWorstCase() {
        // The notice is the operator's only view of how long the run may sit
        // there; it must not quote a number the code does not honour.
        let notice = DestinationWait.retryNotice(attemptsMade: 1, delay: 30)
        XCTAssertTrue(notice.contains("\(Int(DestinationWait.worstCaseWindow / 60))m"), notice)
    }

    // MARK: - awaitReachable

    /// Drives awaitReachable with a scripted probe sequence and no real sleeping.
    private func drive(_ results: [RepoProbe], unattended: Bool = true,
                       cancelAfter: Int = .max) -> (final: RepoProbe, probes: Int, waits: Int) {
        var i = 0, waits = 0
        let final = DestinationWait.awaitReachable(
            probe: {
                let r = i < results.count ? results[i] : .unreachable
                i += 1
                return r
            },
            unattended: unattended,
            isCancelled: { i >= cancelAfter },
            notify: { _ in },
            sleep: { _ in waits += 1; return true })
        return (final, i, waits)
    }

    func testAReachableDestinationIsNotWaitedOn() {
        let r = drive([.present])
        XCTAssertEqual(r.final, .present)
        XCTAssertEqual(r.probes, 1)
        XCTAssertEqual(r.waits, 0)
    }

    func testARaceThatClearsOnTheSecondTryProceeds() {
        // The boot race in miniature: first probe times out, Wi-Fi arrives, second
        // probe succeeds — and the run continues instead of failing.
        let r = drive([.unreachable, .present])
        XCTAssertEqual(r.final, .present)
        XCTAssertEqual(r.probes, 2)
        XCTAssertEqual(r.waits, 1)
    }

    func testAPermanentlyDeadDestinationGivesUpAfterTheFullBackoff() {
        let r = drive([])   // every probe unreachable
        XCTAssertEqual(r.final, .unreachable)
        XCTAssertEqual(r.probes, DestinationWait.maxAttempts)
        XCTAssertEqual(r.waits, DestinationWait.backoff.count)
    }

    func testAWrongPasswordIsReturnedImmediatelyNotWaitedOn() {
        // Waiting here would delay an actionable error for eight minutes.
        let r = drive([.wrongPassword])
        XCTAssertEqual(r.final, .wrongPassword)
        XCTAssertEqual(r.waits, 0)
    }

    func testInteractiveRunProbesOnce() {
        let r = drive([.unreachable, .present], unattended: false)
        XCTAssertEqual(r.final, .unreachable)
        XCTAssertEqual(r.probes, 1)
        XCTAssertEqual(r.waits, 0)
    }

    func testCancellationStopsTheRetryLoop() {
        let r = drive([.unreachable, .unreachable, .unreachable], cancelAfter: 2)
        XCTAssertEqual(r.final, .unreachable)
        XCTAssertEqual(r.probes, 2, "must not keep probing after a cancel")
    }

    // MARK: - Operator-facing text

    func testRetryNoticeNamesTheAttemptAndTheGiveUpPoint() {
        let notice = DestinationWait.retryNotice(attemptsMade: 1, delay: 30)
        XCTAssertTrue(notice.contains("30s"), notice)
        XCTAssertTrue(notice.contains("attempt 2 of \(DestinationWait.maxAttempts)"), notice)
        XCTAssertTrue(notice.contains("giving up"), notice)
    }

    // MARK: - The cancellable sleep

    func testWaitCancellableReturnsFalseWhenCancelled() {
        XCTAssertFalse(DestinationWait.waitCancellable(5, slice: 0.01, isCancelled: { true }))
    }

    func testWaitCancellableSleepsRatherThanReturningAtOnce() {
        // A lower bound only: asserting how long a sleep takes from ABOVE would be
        // a claim about the machine's load, and this suite gates every push.
        let started = Date()
        XCTAssertTrue(DestinationWait.waitCancellable(0.2, slice: 0.05, isCancelled: { false }))
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.15)
    }
}
