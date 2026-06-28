import XCTest
@testable import baaackaaab

// The backup set is the single source of truth for WHAT gets backed up. These
// tests pin the two contracts the rest of the tool relies on: the decode is
// tolerant of a hand-edited file (any missing list reads as empty), and the
// folder/album mutations normalize + dedup so the TUI and the --add-* flags
// produce byte-identical files.
final class BackupSetTests: XCTestCase {

    private func decode(_ json: String) throws -> BackupSet {
        try JSONDecoder().decode(BackupSet.self, from: Data(json.utf8))
    }

    // MARK: - Tolerant decode

    func testDecodeMissingListsBecomeEmpty() throws {
        let set = try decode(#"{ "photo_albums": ["Trip"] }"#)
        XCTAssertEqual(set.driveFolders, [])
        XCTAssertEqual(set.photoAlbums, ["Trip"])
        XCTAssertNil(set.quotaBytes)
        XCTAssertNil(set.limitUploadKiBps)
    }

    func testDecodeEmptyObjectIsEmptySet() throws {
        let set = try decode("{}")
        XCTAssertTrue(set.isEmpty)
    }

    func testDecodeFullObject() throws {
        let set = try decode(#"""
        {
          "drive_folders": ["~/Documents"],
          "photo_albums": ["Family"],
          "quota_bytes": 1000,
          "limit_upload_kibps": 2048
        }
        """#)
        XCTAssertEqual(set.driveFolders, ["~/Documents"])
        XCTAssertEqual(set.photoAlbums, ["Family"])
        XCTAssertEqual(set.quotaBytes, 1000)
        XCTAssertEqual(set.limitUploadKiBps, 2048)
        XCTAssertFalse(set.isEmpty)
    }

    // MARK: - Round-trip through disk

    func testSaveLoadRoundTrip() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bset-\(UUID().uuidString)")
            .appendingPathComponent("backup-set.json")
        let original = BackupSet(driveFolders: ["~/a", "~/b"], photoAlbums: ["Album"],
                                 quotaBytes: 42, limitUploadKiBps: 512)
        try original.save(to: url)
        XCTAssertEqual(try BackupSet.load(from: url), original)
    }

    func testSavedFileOmitsNilKnobsAndSortsKeys() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bset-\(UUID().uuidString)")
            .appendingPathComponent("backup-set.json")
        try BackupSet(driveFolders: ["~/x"]).save(to: url)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(text.contains("quota_bytes"))        // nil knobs omitted
        XCTAssertFalse(text.contains("limit_upload_kibps"))
        XCTAssertFalse(text.contains("\\/"))                // slashes not escaped
        XCTAssertTrue(text.hasSuffix("\n"))                 // trailing newline
    }

    // MARK: - Mutation: normalization + dedup

    func testAddFolderTrimsAndStripsOneTrailingSlash() {
        var set = BackupSet()
        XCTAssertTrue(set.addFolder("  ~/Docs/  "))
        XCTAssertEqual(set.driveFolders, ["~/Docs"])
        // "~/Docs/" normalizes to the same entry → no change, no duplicate.
        XCTAssertFalse(set.addFolder("~/Docs/"))
        XCTAssertEqual(set.driveFolders, ["~/Docs"])
    }

    func testAddFolderRejectsEmpty() {
        var set = BackupSet()
        XCTAssertFalse(set.addFolder("   "))
        XCTAssertTrue(set.driveFolders.isEmpty)
    }

    func testRemoveFolderMatchesNormalizedForm() {
        var set = BackupSet(driveFolders: ["~/Docs"])
        XCTAssertTrue(set.removeFolder("~/Docs/"))   // trailing slash still matches
        XCTAssertTrue(set.driveFolders.isEmpty)
        XCTAssertFalse(set.removeFolder("~/Docs"))   // already gone
    }

    func testAlbumAddRemoveAndDedup() {
        var set = BackupSet()
        XCTAssertTrue(set.addAlbum("  Trip  "))
        XCTAssertEqual(set.photoAlbums, ["Trip"])
        XCTAssertFalse(set.addAlbum("Trip"))         // exact dup
        XCTAssertTrue(set.removeAlbum("Trip"))
        XCTAssertFalse(set.removeAlbum("Trip"))
    }
}
