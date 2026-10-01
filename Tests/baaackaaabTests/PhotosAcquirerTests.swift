import XCTest
@testable import baaackaaab

// Pure batch-budget logic + the concurrency-guarded file writer. The PhotoKit
// paths themselves stay untested by design (they need a granted Photos library);
// everything decision-shaped around them is pinned here.
final class PhotosAcquirerTests: XCTestCase {

    // MARK: - shouldPreFlush (peak-disk cap)

    func testPreFlushWhenEstimateWouldExceedBudget() {
        XCTAssertTrue(PhotosAcquirer.shouldPreFlush(
            batchBytes: 2_900, estimatedAssetBytes: 400, budget: 3_000))
    }

    func testNoPreFlushOnEmptyBatchEvenForOversizedAsset() {
        // An oversized asset must still export — flushing an empty batch first
        // would change nothing except looping forever.
        XCTAssertFalse(PhotosAcquirer.shouldPreFlush(
            batchBytes: 0, estimatedAssetBytes: 9_000, budget: 3_000))
    }

    func testNoPreFlushWithoutAnEstimate() {
        // PhotoKit exposes no public size; a nil estimate keeps the old behavior.
        XCTAssertFalse(PhotosAcquirer.shouldPreFlush(
            batchBytes: 2_900, estimatedAssetBytes: nil, budget: 3_000))
    }

    func testNoPreFlushWhenAssetStillFits() {
        XCTAssertFalse(PhotosAcquirer.shouldPreFlush(
            batchBytes: 1_000, estimatedAssetBytes: 1_500, budget: 3_000))
    }

    // MARK: - GuardedFileWriter (write/close race safety)

    func testGuardedWriterWritesAndCloses() throws {
        let path = NSTemporaryDirectory() + "/baaackaaab-writer-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let writer = try XCTUnwrap(PhotosAcquirer.GuardedFileWriter(path: path))
        writer.write(Data("hello ".utf8))
        writer.write(Data("world".utf8))
        writer.close()
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "hello world")
        XCTAssertFalse(writer.failed)
    }

    // The exact race the guard exists for: a late download chunk arriving after
    // the timeout path closed the file must be dropped silently, never raise.
    func testGuardedWriterDropsWritesAfterClose() throws {
        let path = NSTemporaryDirectory() + "/baaackaaab-writer-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let writer = try XCTUnwrap(PhotosAcquirer.GuardedFileWriter(path: path))
        writer.write(Data("kept".utf8))
        writer.close()
        writer.write(Data(" dropped".utf8))   // must be a silent no-op
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "kept")
    }

    func testGuardedWriterConcurrentWritesDoNotCrashAcrossClose() throws {
        let path = NSTemporaryDirectory() + "/baaackaaab-writer-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let writer = try XCTUnwrap(PhotosAcquirer.GuardedFileWriter(path: path))
        let group = DispatchGroup()
        for i in 0..<50 {
            group.enter()
            DispatchQueue.global().async {
                writer.write(Data("chunk-\(i);".utf8))
                group.leave()
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(1)) { writer.close() }
        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        writer.close()   // idempotent
    }

    func testGuardedWriterNilForUncreatablePath() {
        XCTAssertNil(PhotosAcquirer.GuardedFileWriter(path: "/nonexistent-root-dir/x/y"))
    }
}
