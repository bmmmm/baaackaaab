import XCTest
@testable import baaackaaab

// The cancellation state machine, on a throwaway instance so the shared
// singleton (used by the restic integration tests) is never armed or cancelled
// here. The arm+raise test exercises the REAL delivery path: SIG_IGN + dispatch
// source, handler off signal context, interrupt of the registered child.
final class BackupCancellationTests: XCTestCase {

    func testFreshInstanceIsNotCancelled() {
        XCTAssertFalse(BackupCancellation().isCancelled)
    }

    func testSetAndClearCurrentTracksOnlyMatchingProcess() {
        let c = BackupCancellation()
        let p1 = Process(), p2 = Process()
        c.setCurrent(p1)      // not cancelled → must NOT interrupt (p1 never ran)
        c.setCurrent(p2)      // replaces p1
        c.clearCurrent(p1)    // stale clear of a replaced child: no-op
        c.clearCurrent(p2)
        // Nothing observable to assert beyond "no crash / no interrupt of an
        // un-launched Process" — which is exactly the contract: interrupt() on a
        // never-run Process would raise, so reaching this line IS the assertion.
        XCTAssertFalse(c.isCancelled)
    }

    // A real SIGTERM: the dispatch source must flag the cancel and interrupt the
    // registered (running) child, which then dies of SIGTERM/SIGINT instead of
    // finishing its sleep.
    func testSignalCancelsAndInterruptsRegisteredChild() throws {
        let c = BackupCancellation()
        c.arm()

        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        c.setCurrent(child)

        // Process-directed (like a real `kill` / launchd shutdown) — raise()
        // is thread-directed and a kqueue signal source may never see it.
        kill(getpid(), SIGTERM)

        // The handler runs async on a dispatch queue — poll for the flag.
        let deadline = Date().addingTimeInterval(5)
        while !c.isCancelled && Date() < deadline { usleep(20_000) }
        XCTAssertTrue(c.isCancelled, "the signal source never flagged the cancel")

        child.waitUntilExit()   // interrupt() must have stopped the 30s sleep
        XCTAssertNotEqual(child.terminationStatus, 0)
        c.clearCurrent(child)
    }

    // A cancel that lands BEFORE the next child registers must interrupt that
    // child immediately on setCurrent — the user already bailed; starting a
    // fresh upload afterwards would ignore them.
    func testSetCurrentAfterCancelInterruptsImmediately() throws {
        let c = BackupCancellation()
        c.arm()
        kill(getpid(), SIGTERM)   // process-directed — see the test above
        let deadline = Date().addingTimeInterval(5)
        while !c.isCancelled && Date() < deadline { usleep(20_000) }
        XCTAssertTrue(c.isCancelled)

        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        c.setCurrent(child)   // must interrupt at once
        child.waitUntilExit()
        XCTAssertNotEqual(child.terminationStatus, 0)
    }
}
