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
        XCTAssertEqual(set.excludes, [])          // missing exclude lists read as empty
        XCTAssertEqual(set.excludeFiles, [])
    }

    func testDecodeExcludeLists() throws {
        let set = try decode(#"""
        {
          "drive_folders": ["~/Documents"],
          "excludes": ["*.tmp", "node_modules"],
          "exclude_files": ["~/my-excludes.txt"]
        }
        """#)
        XCTAssertEqual(set.excludes, ["*.tmp", "node_modules"])
        XCTAssertEqual(set.excludeFiles, ["~/my-excludes.txt"])
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

    // pack_size_mib was the one knob without coverage — every sibling
    // (quota, limit-upload, excludes) already had decode + round-trip pins.
    func testDecodePackSize() throws {
        let set = try decode(#"{ "pack_size_mib": 64 }"#)
        XCTAssertEqual(set.packSizeMiB, 64)
    }

    // rest_connections mirrors pack_size_mib: same optional-Int, tolerant-decode
    // shape, just a different persisted restic knob (REST-backend concurrency).
    func testDecodeRestConnections() throws {
        let set = try decode(#"{ "rest_connections": 2 }"#)
        XCTAssertEqual(set.restConnections, 2)
    }

    // read_concurrency mirrors rest_connections: same optional-Int, tolerant-
    // decode shape, a different persisted restic knob (concurrent file reads).
    func testDecodeReadConcurrency() throws {
        let set = try decode(#"{ "read_concurrency": 4 }"#)
        XCTAssertEqual(set.readConcurrency, 4)
    }

    // MARK: - Round-trip through disk

    func testSaveLoadRoundTrip() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bset-\(UUID().uuidString)")
            .appendingPathComponent("backup-set.json")
        let original = BackupSet(driveFolders: ["~/a", "~/b"], photoAlbums: ["Album"],
                                 quotaBytes: 42, limitUploadKiBps: 512, packSizeMiB: 64,
                                 restConnections: 2, readConcurrency: 4,
                                 excludes: ["*.tmp"], excludeFiles: ["~/ex.txt"])
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
        XCTAssertFalse(text.contains("pack_size_mib"))
        XCTAssertFalse(text.contains("rest_connections"))
        XCTAssertFalse(text.contains("read_concurrency"))
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

    func testExcludeAddTrimsRejectsEmptyAndDedups() {
        var set = BackupSet()
        XCTAssertTrue(set.addExclude("  *.tmp  "))
        XCTAssertEqual(set.excludes, ["*.tmp"])       // trimmed
        XCTAssertFalse(set.addExclude("*.tmp"))       // exact dup
        XCTAssertFalse(set.addExclude("   "))         // empty rejected
        XCTAssertEqual(set.excludes, ["*.tmp"])
        XCTAssertTrue(set.removeExclude("*.tmp"))
        XCTAssertFalse(set.removeExclude("*.tmp"))    // already gone
    }

    func testExcludeFileAddRemoveAndDedup() {
        var set = BackupSet()
        XCTAssertTrue(set.addExcludeFile("  ~/ex.txt  "))
        XCTAssertEqual(set.excludeFiles, ["~/ex.txt"]) // trimmed, tilde kept
        XCTAssertFalse(set.addExcludeFile("~/ex.txt"))
        XCTAssertTrue(set.removeExcludeFile("~/ex.txt"))
        XCTAssertFalse(set.removeExcludeFile("~/ex.txt"))
    }
}
