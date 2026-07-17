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
}
