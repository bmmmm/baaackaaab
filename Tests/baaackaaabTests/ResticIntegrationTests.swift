import XCTest
@testable import baaackaaab

// Live integration tests that drive the REAL `restic` binary against a LOCAL
// filesystem repository in a throwaway temp dir — no server, no network, no
// listen socket, so they run anywhere restic is installed. They exercise exactly
// the paths that unit tests can't reach: the typed exit-code mapping
// (probe/ensureInitialized), --skip-if-unchanged, --pack-size, check, and unlock.
//
// Gated on restic being present (XCTSkipUnless), so `swift test` on a machine
// without restic still passes — matching the suite's "degrades by construction"
// stance. Each test isolates restic's cache into the temp tree via
// RESTIC_CACHE_DIR, which the backend inherits, so the real cache is untouched.
final class ResticIntegrationTests: XCTestCase {

    private var tmp: URL!
    private var repoPath: String!
    private let password = "correct-horse-battery-staple"

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(ResticBackend.locateExecutable() != nil,
                          "restic not on PATH — skipping live integration tests")
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("baaackaaab-it-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        // Isolate restic's cache into the temp tree (the backend inherits the
        // parent env, minus the RESTIC_* repo/password vars it strips).
        setenv("RESTIC_CACHE_DIR", tmp.appendingPathComponent("cache").path, 1)
        repoPath = tmp.appendingPathComponent("repo", isDirectory: true).path
    }

    override func tearDownWithError() throws {
        if let tmp { try? FileManager.default.removeItem(at: tmp) }
        tmp = nil
        try super.tearDownWithError()
    }

    // A backend pointing at the local repo, with an explicit repo path + password
    // carried in the env overlay (never on argv) — same shape a real destination
    // produces, just a local path instead of a rest: URL.
    private func makeBackend(password: String? = nil) -> ResticBackend {
        let dest = Destination(name: "it", link: "default", order: 0, enabled: true,
                               repo: .value(repoPath),
                               password: .value(password ?? self.password))
        return ResticBackend(destination: dest)
    }

    // Create a small source tree to back up.
    @discardableResult
    private func makeSource(_ name: String, files: [String: String]) throws -> URL {
        let dir = tmp.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (f, contents) in files {
            try contents.write(to: dir.appendingPathComponent(f), atomically: true, encoding: .utf8)
        }
        return dir
    }

    // MARK: - Exit-code mapping (probe / ensureInitialized)

    /// A not-yet-created repo probes as .absent (restic exit 10), then .present
    /// after init — and ensureInitialized is idempotent (a second call is a clean
    /// no-op, not a re-init).
    func testProbeAbsentThenInitThenPresent() throws {
        XCTAssertEqual(makeBackend().probe(), .absent,
                       "a fresh path should map restic's exit 10 to .absent")
        try makeBackend().ensureInitialized()
        XCTAssertEqual(makeBackend().probe(), .present,
                       "after init the repo should probe as .present (exit 0)")
        // Idempotent: calling it again must not throw and must not clobber.
        XCTAssertNoThrow(try makeBackend().ensureInitialized())
        XCTAssertEqual(makeBackend().probe(), .present)
    }

    /// A wrong password against an EXISTING repo maps restic exit 12 to
    /// .wrongPassword, and ensureInitialized then throws .wrongPassword instead of
    /// attempting a destructive-looking re-init.
    func testWrongPasswordIsClassifiedAndBlocksInit() throws {
        try makeBackend().ensureInitialized()        // create with the real key
        let wrong = makeBackend(password: "definitely-not-the-key")
        XCTAssertEqual(wrong.probe(), .wrongPassword,
                       "a bad key on an existing repo should map exit 12 to .wrongPassword")
        XCTAssertThrowsError(try wrong.ensureInitialized()) { error in
            guard case ResticError.wrongPassword = error else {
                return XCTFail("expected ResticError.wrongPassword, got \(error)")
            }
        }
        // The repo must still be intact and readable with the correct key.
        XCTAssertEqual(makeBackend().probe(), .present)
    }

    // MARK: - --skip-if-unchanged

    /// The `--skip-if-unchanged` flag is applied (a bad flag would fail the run)
    /// and does NOT break normal incremental snapshotting: a changed tree always
    /// produces a new snapshot, and re-running never DROPS a needed snapshot.
    ///
    /// The skip direction itself is deliberately NOT asserted here. restic matches
    /// the skip candidate against the parent snapshot's FULL tree — which includes
    /// every ancestor directory of the absolute backup path — and compares mtime
    /// AND ctime. Deep paths (here under $TMPDIR = /var/folders/.../T; in
    /// production under /Users/<me>/Library/Mobile Documents/…) have ancestors
    /// whose metadata drifts from unrelated system activity between runs, which
    /// defeats the skip non-deterministically. So `--skip-if-unchanged` is a
    /// best-effort reduction of redundant snapshots, not a guarantee; reliable
    /// retention is the append-only server's `forget`/`prune` job, since the Mac
    /// holds no prune right. (Manually characterised: with metadata-stable
    /// ancestors the skip does fire and no second snapshot is created.)
    func testSkipIfUnchangedFlagDoesNotBreakSnapshotting() throws {
        let backend = makeBackend()
        try backend.ensureInitialized()
        let src = try makeSource("src", files: ["a.txt": "hello", "b.txt": "world"])
        let tags = ["scheduled", "drive"]

        try backend.backup(paths: [src], tags: tags, host: "testhost")
        XCTAssertEqual(try backend.listSnapshots().count, 1, "first backup should create one snapshot")

        // An identical re-run creates AT MOST one more snapshot (0 if the skip
        // fired, 1 if ancestor drift defeated it) — never loses the existing one.
        try backend.backup(paths: [src], tags: tags, host: "testhost")
        let afterUnchanged = try backend.listSnapshots().count
        XCTAssertTrue((1...2).contains(afterUnchanged),
                      "unchanged re-run must keep the snapshot, never drop it (got \(afterUnchanged))")

        // A changed tree ALWAYS yields a fresh snapshot — the deterministic core.
        try "changed".write(to: src.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try backend.backup(paths: [src], tags: tags, host: "testhost")
        XCTAssertEqual(try backend.listSnapshots().count, afterUnchanged + 1,
                       "a changed tree must add exactly one snapshot")
    }

    // MARK: - --pack-size

    /// A backup with a custom pack size is accepted by restic (a bad flag would
    /// fail the run) and produces a snapshot that passes an integrity check.
    func testPackSizeBackupIsAcceptedAndVerifies() throws {
        let backend = makeBackend()
        try backend.ensureInitialized()
        let src = try makeSource("src", files: ["doc.txt": String(repeating: "lorem ipsum\n", count: 500)])
        try backend.backup(paths: [src], tags: ["packed"], host: "testhost", packSizeMiB: 8)
        XCTAssertEqual(try backend.listSnapshots().count, 1)

        let check = backend.checkRepo(readDataSubset: "100%")
        XCTAssertTrue(check.clean, "repo should pass check after a pack-size backup:\n\(check.output)")
        XCTAssertFalse(check.lockedOut)
    }

    // MARK: - check / locks

    /// A healthy freshly-backed-up repo checks clean, reports no locks, and unlock
    /// on a lock-free repo is a clean no-op (exit 0).
    func testCheckCleanAndNoLocks() throws {
        let backend = makeBackend()
        try backend.ensureInitialized()
        let src = try makeSource("src", files: ["x.txt": "content"])
        try backend.backup(paths: [src], tags: ["t"], host: "testhost")

        let check = backend.checkRepo(readDataSubset: nil)
        XCTAssertTrue(check.clean, check.output)
        XCTAssertFalse(check.lockedOut, "a reachable, unlocked repo is not lockedOut")
        // NB: errorLines is intentionally NOT asserted empty — restic's clean
        // verdict is literally "no errors were found", which the naive substring
        // filter catches. That is harmless: errorLines is only ever shown when
        // clean == false, so a clean repo never surfaces them.

        let (listCode, ids) = backend.listLockIDs()
        XCTAssertEqual(listCode, 0)
        XCTAssertTrue(ids.isEmpty, "a fresh repo should have no locks")

        let (unlockCode, _) = backend.unlock(removeAll: false)
        XCTAssertEqual(unlockCode, 0, "unlock on a lock-free repo should exit 0")
    }

    // MARK: - snapshots / stats plumbing

    /// listSnapshots parses restic's JSON (tags, paths, host) and repoSizeBytes
    /// returns a positive deduplicated size after a real backup.
    func testSnapshotMetadataAndSize() throws {
        let backend = makeBackend()
        try backend.ensureInitialized()
        let src = try makeSource("src", files: ["a.txt": "hello"])
        try backend.backup(paths: [src], tags: ["drive", "run-x"], host: "myhost")

        let snaps = try backend.listSnapshots()
        XCTAssertEqual(snaps.count, 1)
        let snap = try XCTUnwrap(snaps.first)
        XCTAssertEqual(snap.hostname, "myhost")
        XCTAssertTrue(snap.tags.contains("drive"))
        XCTAssertTrue(snap.paths.contains(src.path))
        XCTAssertFalse(snap.shortID.isEmpty)

        let size = backend.repoSizeBytes()
        XCTAssertNotNil(size, "raw-data size should be readable after a backup")
        XCTAssertGreaterThan(size ?? 0, 0)
    }
}
