import XCTest
@testable import baaackaaab

// The large-file warning is warn-only: it never excludes anything, so the only
// contract to pin is the pure threshold filter — which files it flags, and that
// 0 (the documented "disabled" value) always yields nothing.
final class LargeFileWarningTests: XCTestCase {

    private let mib = 1_048_576

    func testFilterFlagsFilesStrictlyOverThreshold() {
        let items: [(path: String, bytes: Int)] = [
            ("small.txt", 1 * mib),
            ("exactly-at-threshold.bin", 4096 * mib),
            ("over.bin", 4097 * mib),
        ]
        let large = LargeFileWarning.filter(items, thresholdMiB: 4096)
        XCTAssertEqual(large.map(\.path), ["over.bin"], "a file exactly AT the threshold must not warn, only strictly over")
    }

    func testFilterZeroThresholdDisablesWarningEntirely() {
        let items: [(path: String, bytes: Int)] = [("huge.bin", 100 * mib * 1024)]
        XCTAssertTrue(LargeFileWarning.filter(items, thresholdMiB: 0).isEmpty)
    }

    func testFilterNegativeThresholdIsTreatedAsDisabled() {
        let items: [(path: String, bytes: Int)] = [("huge.bin", 100 * mib * 1024)]
        XCTAssertTrue(LargeFileWarning.filter(items, thresholdMiB: -1).isEmpty)
    }

    func testFilterEmptyItemsYieldsEmpty() {
        XCTAssertTrue(LargeFileWarning.filter([], thresholdMiB: 4096).isEmpty)
    }

    func testFilterPreservesPathAndByteCount() {
        let items: [(path: String, bytes: Int)] = [("/x/big.mov", 5000 * mib)]
        let large = LargeFileWarning.filter(items, thresholdMiB: 4096)
        XCTAssertEqual(large.count, 1)
        XCTAssertEqual(large[0].path, "/x/big.mov")
        XCTAssertEqual(large[0].bytes, 5000 * mib)
    }

    // MARK: - BackupSet.largeFileWarnMiBEffective

    func testEffectiveThresholdDefaultsWhenUnset() {
        let set = BackupSet()
        XCTAssertEqual(set.largeFileWarnMiBEffective, BackupSet.defaultLargeFileWarnMiB)
    }

    func testEffectiveThresholdHonorsExplicitZero() {
        var set = BackupSet()
        set.largeFileWarnMiB = 0
        XCTAssertEqual(set.largeFileWarnMiBEffective, 0, "explicit 0 must disable, not fall back to the default")
    }

    func testEffectiveThresholdHonorsExplicitValue() {
        var set = BackupSet()
        set.largeFileWarnMiB = 8192
        XCTAssertEqual(set.largeFileWarnMiBEffective, 8192)
    }
}
