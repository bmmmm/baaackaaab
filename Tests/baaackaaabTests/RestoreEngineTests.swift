import XCTest
@testable import baaackaaab

// Restore is the one operation that writes a lot of data, so `validateTarget` is
// safe-by-construction: it hard-rejects the filesystem root, the home directory,
// anything inside live iCloud Drive / Photos, and any existing non-empty dir.
//
// The case-insensitive forbidden-root check is the safety-critical part — a
// regression here previously let a lowercase `~/library/mobile documents/…`
// target write into the real iCloud Drive (APFS is case-insensitive). These
// tests pin that gate. validateTarget never writes; it only reads the target's
// existence, so feeding it forbidden paths is harmless.
final class RestoreEngineTests: XCTestCase {

    private var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    private func assertRejected(_ target: URL, _ message: String) {
        XCTAssertThrowsError(try RestoreEngine.validateTarget(target), message)
    }

    private func assertAccepted(_ target: URL, _ message: String) {
        XCTAssertNoThrow(try RestoreEngine.validateTarget(target), message)
    }

    // MARK: - Near-root / home

    func testRejectsFilesystemRootAndNearRoot() {
        assertRejected(URL(fileURLWithPath: "/"), "filesystem root")
        assertRejected(URL(fileURLWithPath: "/Users"), "one level below root")
    }

    func testRejectsHomeDirectoryItself() {
        assertRejected(home, "home directory")
    }

    // MARK: - Forbidden iCloud / Photos roots

    func testRejectsInsideICloudDrive() {
        assertRejected(home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/x"),
                       "inside live iCloud Drive")
    }

    func testRejectsInsidePictures() {
        assertRejected(home.appendingPathComponent("Pictures/restored-here"),
                       "inside the Pictures tree where the Photos library lives")
    }

    // The regression that motivated the case-insensitive component compare: a
    // lowercase path resolves on a case-insensitive APFS volume to the real
    // iCloud Drive, so a naive string-prefix check would wave it through.
    func testRejectsCaseVariantOfICloudDrive() {
        assertRejected(home.appendingPathComponent("library/mobile documents/com~apple~clouddocs/x"),
                       "lowercase iCloud Drive path must still be rejected")
        assertRejected(home.appendingPathComponent("PICTURES/x"),
                       "uppercase Pictures must still be rejected")
    }

    // MARK: - Component-boundary: a sibling that merely shares a prefix is fine

    func testAcceptsSiblingThatSharesAPrefixWithForbiddenRoot() {
        // ~/Pictures-restore is NOT inside ~/Pictures — a prefix-string check would
        // wrongly reject it; the component-wise check accepts it.
        assertAccepted(home.appendingPathComponent("Pictures-restore/\(UUID().uuidString)"),
                       "a prefix-sharing sibling of a forbidden root is allowed")
    }

    // MARK: - Fresh-directory requirement

    func testAcceptsFreshNonexistentTargetUnderHome() {
        assertAccepted(home.appendingPathComponent("baaackaaab-restore/\(UUID().uuidString)"),
                       "a fresh non-existent dir under home is the normal case")
    }

    func testRejectsExistingNonEmptyDirectory() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("restore-nonempty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: dir.appendingPathComponent("file.txt"))
        assertRejected(dir, "an existing non-empty dir is refused (no in-place overwrite)")
    }

    func testAcceptsExistingEmptyDirectory() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("restore-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        assertAccepted(dir, "an existing empty dir is fine")
    }

    func testAcceptsDirectoryContainingOnlyDSStore() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("restore-dsstore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data().write(to: dir.appendingPathComponent(".DS_Store"))
        assertAccepted(dir, ".DS_Store does not count as 'in use'")
    }

    func testRejectsWhenAPlainFileSitsAtTheTargetPath() throws {
        let file = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("restore-isfile-\(UUID().uuidString)")
        try Data("x".utf8).write(to: file)
        assertRejected(file, "a plain file at the target path is refused")
    }

    // MARK: - isInsideForbiddenRoot (shared with the recovery-kit export gate)

    func testIsInsideForbiddenRootTrueForICloudDrive() {
        XCTAssertTrue(RestoreEngine.isInsideForbiddenRoot(
            home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/x")))
    }

    func testIsInsideForbiddenRootFalseForOrdinaryPath() {
        XCTAssertFalse(RestoreEngine.isInsideForbiddenRoot(
            URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("recovery-kit-\(UUID().uuidString)")))
    }

    // MARK: - defaultTarget

    func testDefaultTargetIsDeterministicUnderHome() {
        let t = RestoreEngine.defaultTarget(snapshot: "abc123", stamp: "20260628-120000")
        XCTAssertEqual(t.deletingLastPathComponent().lastPathComponent, "baaackaaab-restore")
        XCTAssertEqual(t.lastPathComponent, "abc123-20260628-120000")
        assertAccepted(t, "the default fresh target must itself pass validation")
    }
}
