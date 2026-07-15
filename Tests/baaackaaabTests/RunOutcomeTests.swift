import XCTest
@testable import baaackaaab

// RunOutcome.evaluate is the pure exit matrix extracted from BackupRun.execute()
// (exit()-coupled, otherwise untestable). Review round 2 already touched the
// clean-empty total==0 branch once (commit faf5622) — pin the full matrix so a
// future change to any branch shows up here first, not in a live run.
final class RunOutcomeTests: XCTestCase {

    private func evaluate(
        verified: Int = 5, total: Int = 5, sourceFailures: Int = 0,
        destInitFailures: Int = 0, destBackupFailures: Int = 0,
        runCancelled: Bool = false, sourcesConfigured: Bool = true,
        dryRun: Bool = false, readyCount: Int = 1, runTag: String = "tag-1"
    ) -> RunOutcome.Result {
        RunOutcome.evaluate(
            verified: verified, total: total, sourceFailures: sourceFailures,
            destInitFailures: destInitFailures, destBackupFailures: destBackupFailures,
            runCancelled: runCancelled, sourcesConfigured: sourcesConfigured,
            dryRun: dryRun, readyCount: readyCount, runTag: runTag)
    }

    // MARK: - Clean run

    func testCleanRun() {
        let r = evaluate(verified: 5, total: 5, readyCount: 2, runTag: "run-42")
        XCTAssertEqual(r.exitCode, 0)
        XCTAssertEqual(r.state, .ok)
        XCTAssertFalse(r.notify)
        XCTAssertNil(r.notifyMessage)
        XCTAssertEqual(r.headline, "5/5 verified to 2 destination(s) — every acquired byte-stream backed up under tag run-42")
    }

    // MARK: - Clean-empty (total == 0, sources configured, everything ran cleanly)

    func testCleanEmptyIsExitZeroWithoutBanner() {
        let r = evaluate(verified: 0, total: 0, sourceFailures: 0,
                         destInitFailures: 0, destBackupFailures: 0,
                         sourcesConfigured: true)
        XCTAssertEqual(r.exitCode, 0)
        XCTAssertEqual(r.state, .ok)
        XCTAssertFalse(r.notify)
        XCTAssertNil(r.notifyMessage)
        XCTAssertEqual(r.headline, "nothing to back up — the configured source(s) hold 0 files right now; every source ran cleanly")
    }

    func testCleanEmptyWithAnyFailureIsNotClean() {
        // A source failure alongside total == 0 must NOT take the clean-empty
        // exit-0 path — it's the "nothing was acquired" failure instead.
        let r = evaluate(verified: 0, total: 0, sourceFailures: 1, sourcesConfigured: true)
        XCTAssertEqual(r.exitCode, 2)
        XCTAssertEqual(r.state, .fail)
        XCTAssertTrue(r.notify)
    }

    // MARK: - Empty SET (no sources configured at all)

    func testEmptySetIsExitTwoWithBanner() {
        let r = evaluate(verified: 0, total: 0, sourceFailures: 0,
                         destInitFailures: 0, destBackupFailures: 0,
                         sourcesConfigured: false)
        XCTAssertEqual(r.exitCode, 2)
        XCTAssertEqual(r.state, .fail)
        XCTAssertTrue(r.notify)
        XCTAssertEqual(r.headline, "nothing was acquired")
        XCTAssertEqual(r.notifyMessage, "nothing was acquired")
    }

    func testEmptySetHeadlineMentionsSourceFailureCount() {
        let r = evaluate(verified: 0, total: 0, sourceFailures: 3, sourcesConfigured: false)
        XCTAssertEqual(r.headline, "nothing was acquired (3 source(s) failed)")
        XCTAssertEqual(r.notifyMessage, "nothing was acquired (3 source(s) failed)")
    }

    // MARK: - Partial verification

    func testPartialVerificationIsExitTwoWithBanner() {
        let r = evaluate(verified: 3, total: 5)
        XCTAssertEqual(r.exitCode, 2)
        XCTAssertEqual(r.state, .warn)
        XCTAssertTrue(r.notify)
        XCTAssertEqual(r.headline, "3/5 verified — 2 item(s) failed verification; review the manifest")
        // The banner message omits the "review the manifest" tail the on-screen headline has.
        XCTAssertEqual(r.notifyMessage, "3/5 verified — 2 item(s) failed verification")
    }

    func testPartialWithSourceAndDestFailuresListsAllProblems() {
        let r = evaluate(verified: 5, total: 5, sourceFailures: 1,
                         destInitFailures: 1, destBackupFailures: 1)
        XCTAssertEqual(r.exitCode, 2)
        XCTAssertEqual(r.state, .warn)
        XCTAssertEqual(r.headline,
            "5/5 verified — 1 source(s) skipped after errors; 1 destination(s) unavailable; 1 destination(s) had backup failures; review the manifest")
    }

    // MARK: - Cancelled

    func testCancelledIsExitOneThirtyWithoutBanner() {
        let r = evaluate(verified: 2, total: 5, runCancelled: true)
        XCTAssertEqual(r.exitCode, 130)
        XCTAssertEqual(r.state, .warn)
        XCTAssertFalse(r.notify)
        XCTAssertNil(r.notifyMessage)
        XCTAssertEqual(r.headline, "cancelled — 2/5 acquired before interrupt; restic stopped, uploaded data kept for next run")
    }

    func testCancelledTakesPrecedenceOverOtherFailures() {
        // Even with source/dest failures also present, cancellation wins.
        let r = evaluate(verified: 2, total: 5, sourceFailures: 1, destInitFailures: 1, runCancelled: true)
        XCTAssertEqual(r.exitCode, 130)
        XCTAssertFalse(r.notify)
    }

    // MARK: - Dry run

    func testDryRunCompleteIsExitZeroWithoutBanner() {
        let r = evaluate(runCancelled: false, dryRun: true, readyCount: 2)
        XCTAssertEqual(r.exitCode, 0)
        XCTAssertEqual(r.state, .ok)
        XCTAssertFalse(r.notify)
        XCTAssertTrue(r.headline.hasPrefix("dry run complete — 2 destination(s) reachable"))
    }

    func testDryRunCancelledIsExitOneThirtyWithoutBanner() {
        let r = evaluate(runCancelled: true, dryRun: true)
        XCTAssertEqual(r.exitCode, 130)
        XCTAssertEqual(r.state, .warn)
        XCTAssertFalse(r.notify)
        XCTAssertEqual(r.headline, "dry run cancelled — nothing was written")
    }

    func testDryRunNeverNotifiesEvenWithFailureCounts() {
        // Dry-run paths never record history or notify — evaluate() short-circuits
        // on dryRun before looking at any of the failure counts.
        let r = evaluate(sourceFailures: 5, destInitFailures: 5, destBackupFailures: 5, dryRun: true)
        XCTAssertEqual(r.exitCode, 0)
        XCTAssertFalse(r.notify)
    }
}
