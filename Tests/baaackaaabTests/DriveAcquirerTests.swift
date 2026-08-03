import XCTest
@testable import baaackaaab

// The walk semantics both Drive passes share, pinned against a real (non-iCloud)
// tree: `isRegularFileKey` must NOT follow symlinks. If a future refactor swaps
// the enumerator keys for stat-based checks, a symlink to an evicted stub would
// start counting as a verified regular file — these tests catch that flip.
final class DriveAcquirerTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("baaackaaab-drive-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    // A symlink (live or dangling) is neither a countable file nor a dataless
    // stub — only the real regular file counts. restic stores the link as a link
    // node, so skipping it here loses nothing.
    func testPreviewDatalessSkipsSymlinks() throws {
        let real = dir.appendingPathComponent("real.txt")
        try Data("hello".utf8).write(to: real)
        try FileManager.default.createSymbolicLink(
            at: dir.appendingPathComponent("link.txt"), withDestinationURL: real)
        try FileManager.default.createSymbolicLink(
            at: dir.appendingPathComponent("dangling.txt"),
            withDestinationURL: dir.appendingPathComponent("gone"))

        let (files, dataless) = try DriveAcquirer().previewDataless(folder: dir)
        XCTAssertEqual(files, 1, "only the real regular file counts — symlinks are link nodes")
        XCTAssertEqual(dataless, 0)
    }

    // MARK: - materializeTimeout (size-scaled download wait)

    func testMaterializeTimeoutScalesWithSize() {
        // Small/unknown files keep the 120 s base.
        XCTAssertEqual(DriveAcquirer.materializeTimeout(forByteSize: nil), 120)
        XCTAssertEqual(DriveAcquirer.materializeTimeout(forByteSize: 5_000_000), 120)
        // A 1 GiB file gets ~1024 s (1 MiB/s floor) instead of failing at 120 s.
        XCTAssertEqual(DriveAcquirer.materializeTimeout(forByteSize: 1_073_741_824), 1_024)
        // Ceiling: even a huge file must eventually fail rather than stall the run.
        XCTAssertEqual(DriveAcquirer.materializeTimeout(forByteSize: 100_000_000_000), 3_600)
    }

    // Same pin for the real pass: the symlink is not recorded, not "verified",
    // and the real file is verified with its own byte count.
    func testMaterializeAndVerifySkipsSymlinks() throws {
        let real = dir.appendingPathComponent("real.txt")
        try Data("hello".utf8).write(to: real)
        try FileManager.default.createSymbolicLink(
            at: dir.appendingPathComponent("link.txt"), withDestinationURL: real)

        let stagingRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("baaackaaab-drive-staging-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: stagingRoot) }
        let staging = try Staging(root: stagingRoot)
        try DriveAcquirer().materializeAndVerify(folder: dir, into: staging)

        XCTAssertEqual(staging.items.count, 1, "exactly the regular file — the symlink is a link node")
        XCTAssertEqual(URL(fileURLWithPath: staging.items[0].source).lastPathComponent, "real.txt")
        XCTAssertTrue(staging.items[0].verified)
        XCTAssertEqual(staging.items[0].byteCount, 5)
    }
}
