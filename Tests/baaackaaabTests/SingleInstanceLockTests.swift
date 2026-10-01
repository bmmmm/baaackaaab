import XCTest
#if canImport(Darwin)
import Darwin
#endif
@testable import baaackaaab

// flock is scoped to the open-file-description, not the process, so a second
// open+lock call IN THE SAME PROCESS still fails while the first fd is open —
// that is exactly what proves the guard works, without needing a second
// process. The lock path is relocated via BAAACKAAAB_SUPPORT_DIR, same as the
// credential/destination store tests, so the real support dir is untouched.
final class SingleInstanceLockTests: XCTestCase {

    private var supportDir: URL!

    override func setUp() {
        super.setUp()
        supportDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("baaackaaab-lock-\(UUID().uuidString)", isDirectory: true)
        setenv("BAAACKAAAB_SUPPORT_DIR", supportDir.path, 1)
    }

    override func tearDown() {
        unsetenv("BAAACKAAAB_SUPPORT_DIR")
        supportDir = nil
        super.tearDown()
    }

    func testSecondAcquireInSameProcessFailsWhileFirstIsHeld() {
        guard case .acquired(let fd1) = SingleInstanceLock.acquire() else {
            return XCTFail("first acquire should succeed on a fresh lock path")
        }
        defer { close(fd1) }

        guard case .busy = SingleInstanceLock.acquire() else {
            return XCTFail("a second acquire on the same path while the first fd is open should be .busy")
        }
    }

    func testAcquireSucceedsAgainAfterTheFirstFdIsClosed() {
        guard case .acquired(let fd1) = SingleInstanceLock.acquire() else {
            return XCTFail("first acquire should succeed")
        }
        close(fd1)   // releases the flock — same effect as the holding process exiting

        guard case .acquired(let fd2) = SingleInstanceLock.acquire() else {
            return XCTFail("acquire should succeed again once the first fd is closed")
        }
        close(fd2)
    }

    func testLockFileIsCreatedUnderTheRelocatedSupportDir() {
        guard case .acquired(let fd) = SingleInstanceLock.acquire() else {
            return XCTFail("acquire should succeed")
        }
        defer { close(fd) }
        XCTAssertEqual(SingleInstanceLock.path.deletingLastPathComponent().path, supportDir.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: SingleInstanceLock.path.path))
    }

    // Issue #23: the scheduled jobs are serialised by WAITING, never by skipping.
    // A second acquireRepo while the first fd is held must block (and announce
    // the wait), then proceed once the holder is gone.
    func testRepoLockWaitsForTheHolderInsteadOfSkipping() {
        guard let holder = SingleInstanceLock.acquireRepo(onWait: { XCTFail("a free repo lock must not wait") }) else {
            return XCTFail("a free repo lock must be acquired")
        }
        XCTAssertGreaterThanOrEqual(holder, 0)

        let waited = expectation(description: "second job announced the wait")
        let acquired = DispatchSemaphore(value: 0)
        let second = LockedBox<Int32>(-1)
        DispatchQueue.global().async {
            let fd = SingleInstanceLock.acquireRepo(poll: 0.05, onWait: { waited.fulfill() })
            second.set(fd ?? -2)
            acquired.signal()
        }
        wait(for: [waited], timeout: 5)
        // Still blocked while the holder lives.
        XCTAssertEqual(acquired.wait(timeout: .now() + 0.5), .timedOut,
                       "the second job must not get the repo lock while a sibling holds it")

        close(holder)   // the sibling job exits
        XCTAssertEqual(acquired.wait(timeout: .now() + 5), .success, "the second job must proceed once the holder is gone")
        XCTAssertGreaterThanOrEqual(second.get(), 0)
        close(second.get())
    }

    // The two locks are independent: a check/drill holds only the repo lock, so a
    // backup starting meanwhile still passes the run lock (and then waits on the
    // repo lock) instead of being skipped as "another run in progress".
    func testRepoLockDoesNotMakeABackupLookBusy() {
        guard let check = SingleInstanceLock.acquireRepo(onWait: {}) else {
            return XCTFail("a free repo lock must be acquired")
        }
        defer { close(check) }
        guard case .acquired(let fd) = SingleInstanceLock.acquire() else {
            return XCTFail("a running check/drill must not make a backup skip")
        }
        close(fd)
        XCTAssertNotEqual(SingleInstanceLock.repoPath.path, SingleInstanceLock.path.path)
    }

    // The wait is bounded: a sibling that never lets go (a stuck backup) must
    // fail the waiting job after the limit instead of parking it forever.
    func testRepoLockGivesUpAfterTheLimitWhenTheHolderNeverLetsGo() {
        guard let holder = SingleInstanceLock.acquireRepo(onWait: {}) else {
            return XCTFail("a free repo lock must be acquired")
        }
        defer { close(holder) }
        let done = DispatchSemaphore(value: 0)
        let result = LockedBox<Int32?>(0)
        DispatchQueue.global().async {
            result.set(SingleInstanceLock.acquireRepo(limit: 0.3, poll: 0.05, onWait: {}))
            done.signal()
        }
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success, "the wait must end at its limit")
        XCTAssertNil(result.get(), "giving up must be reported as nil, not as a held lock")
    }
}

private final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ v: T) { value = v }
    func set(_ v: T) { lock.lock(); value = v; lock.unlock() }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
}
