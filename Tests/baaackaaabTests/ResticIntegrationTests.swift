import XCTest
@testable import baaackaaab

// Live integration tests that drive the REAL `restic` binary against a LOCAL
// filesystem repository in a throwaway temp dir — no server, no network, no
// listen socket, so they run anywhere restic is installed. They exercise exactly
// the paths that unit tests can't reach: the typed exit-code mapping
// (probe/ensureInitialized), --skip-if-unchanged, --pack-size, -o
// rest.connections, excludes (junk + caches + custom globs), the restore/read
// commands, check, and unlock.
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

    // Create a small source tree to back up. Keys may contain "/" for nesting.
    @discardableResult
    private func makeSource(_ name: String, files: [String: String]) throws -> URL {
        let dir = tmp.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (f, contents) in files {
            let fileURL = dir.appendingPathComponent(f)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: fileURL, atomically: true, encoding: .utf8)
        }
        return dir
    }

    // Locate the first file with a given name anywhere under `root` (restic
    // restores the original absolute path under the restore target, so the exact
    // depth is an implementation detail we don't want to hard-code).
    private func firstFile(named name: String, under root: URL) throws -> URL {
        let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        while let url = e?.nextObject() as? URL {
            if url.lastPathComponent == name { return url }
        }
        struct NotRestored: Error, CustomStringConvertible {
            let name: String, root: String
            var description: String { "no file named \(name) found under \(root)" }
        }
        throw NotRestored(name: name, root: root.path)
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

    // MARK: - -o rest.connections

    /// A backup with a configured connection cap is accepted by restic. This
    /// proves SYNTACTIC acceptance only: `-o` is a restic persistent flag
    /// (valid before or after the subcommand), and the option is
    /// backend-specific — restic silently ignores it for this local-filesystem
    /// test repo, so neither the argument position nor the key's effect is
    /// discriminated here. The throttling effect is only observable against a
    /// real REST backend (see issue #6).
    func testRestConnectionsBackupIsAcceptedAndVerifies() throws {
        let backend = makeBackend()
        try backend.ensureInitialized()
        let src = try makeSource("src", files: ["doc.txt": "hello"])
        try backend.backup(paths: [src], tags: ["throttled"], host: "testhost", restConnections: 2)
        XCTAssertEqual(try backend.listSnapshots().count, 1)

        let check = backend.checkRepo(readDataSubset: "100%")
        XCTAssertTrue(check.clean, "repo should pass check after a rest-connections backup:\n\(check.output)")
        XCTAssertFalse(check.lockedOut)
    }

    // MARK: - --read-concurrency

    /// A backup with a configured read-concurrency is accepted by restic (a bad
    /// flag would fail the run) and produces a snapshot that passes an
    /// integrity check. Same syntactic-acceptance scope as the pack-size /
    /// rest-connections tests above: the concurrency EFFECT is not observable
    /// against a tiny local test repo.
    func testReadConcurrencyBackupIsAcceptedAndVerifies() throws {
        let backend = makeBackend()
        try backend.ensureInitialized()
        let src = try makeSource("src", files: ["doc.txt": "hello"])
        try backend.backup(paths: [src], tags: ["concurrent"], host: "testhost", readConcurrency: 4)
        XCTAssertEqual(try backend.listSnapshots().count, 1)

        let check = backend.checkRepo(readDataSubset: "100%")
        XCTAssertTrue(check.clean, "repo should pass check after a read-concurrency backup:\n\(check.output)")
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

    // MARK: - restore roundtrip (safety-critical)

    /// A full backup → restore → verify roundtrip against real restic: the
    /// restored bytes match the source, and restic's own `--verify` (re-reading
    /// every restored file against the repo) exits clean. This exercises the
    /// backend.restore path end-to-end, not just the RestoreEngine's path gate.
    func testRestoreRoundtripVerifies() throws {
        let backend = makeBackend()
        try backend.ensureInitialized()
        let src = try makeSource("src", files: ["a.txt": "hello", "sub/b.txt": "nested"])
        try backend.backup(paths: [src], tags: ["t"], host: "testhost")

        let target = tmp.appendingPathComponent("restore-out", isDirectory: true)
        // verify: true makes restic re-read every restored file against the repo;
        // a byte mismatch would make it exit non-zero and this call throw.
        try backend.restore(snapshot: "latest", target: target, include: nil,
                            dryRun: false, verify: true)

        // And prove the file physically landed with the right content (restic
        // recreates the original absolute path under the target).
        let restoredA = try firstFile(named: "a.txt", under: target)
        XCTAssertEqual(try String(contentsOf: restoredA, encoding: .utf8), "hello")
        let restoredB = try firstFile(named: "b.txt", under: target)
        XCTAssertEqual(try String(contentsOf: restoredB, encoding: .utf8), "nested")
    }

    /// A single-path restore via restoreVerify (the sampled test-restore path)
    /// restores just the named file and re-verifies it — exit 0.
    func testRestoreVerifySinglePath() throws {
        let backend = makeBackend()
        try backend.ensureInitialized()
        let src = try makeSource("src", files: ["keep.txt": "data", "other.txt": "x"])
        try backend.backup(paths: [src], tags: ["t"], host: "testhost")

        let target = tmp.appendingPathComponent("verify-out", isDirectory: true)
        let wanted = src.appendingPathComponent("keep.txt").path
        let (code, output) = backend.restoreVerify(snapshot: "latest", target: target, includes: [wanted])
        XCTAssertEqual(code, 0, "single-path restore+verify should exit 0:\n\(output)")
        XCTAssertNoThrow(try firstFile(named: "keep.txt", under: target),
                         "the requested file should have been restored")
    }

    // MARK: - find / ls / diff (read commands)

    func testFindAndLsLocateFiles() throws {
        let backend = makeBackend()
        try backend.ensureInitialized()
        let src = try makeSource("src", files: ["needle.txt": "x", "hay.txt": "y"])
        try backend.backup(paths: [src], tags: ["t"], host: "testhost")

        let found = try backend.find(pattern: "needle.txt", snapshot: nil)
        XCTAssertTrue(found.contains { $0.path.hasSuffix("/needle.txt") },
                      "find should locate needle.txt; got \(found.map(\.path))")

        let snapID = try XCTUnwrap(try backend.listSnapshots().first).id
        let entries = try backend.ls(snapshot: snapID, path: nil)
        XCTAssertTrue(entries.contains { $0.name == "needle.txt" && $0.type == "file" })
        XCTAssertTrue(entries.contains { $0.name == "hay.txt" })
    }

    /// A file changed between two backups produces two versions once find()'s
    /// hits are grouped by snapshot (the --history command's core data path):
    /// newest-first by mtime, each carrying its own size.
    func testHistoryGroupsHitsPerSnapshotNewestFirst() throws {
        let backend = makeBackend()
        try backend.ensureInitialized()
        let src = try makeSource("src", files: ["doc.txt": "v1"])
        try backend.backup(paths: [src], tags: ["t"], host: "testhost")
        Thread.sleep(forTimeInterval: 1.1)   // a distinct, later mtime for the second write
        try "version-two".write(to: src.appendingPathComponent("doc.txt"), atomically: true, encoding: .utf8)
        try backend.backup(paths: [src], tags: ["t"], host: "testhost")

        let hits = try backend.find(pattern: "doc.txt", snapshot: nil)
        let versions = groupHistoryBySnapshot(hits)
        XCTAssertEqual(versions.count, 2, "the file should have one version per snapshot")
        XCTAssertNotEqual(versions.first?.snapshot, versions.last?.snapshot)
        XCTAssertEqual(versions.first?.size, 11, "newest version ('version-two', 11 bytes) should lead")
        XCTAssertEqual(versions.last?.size, 2, "oldest version ('v1', 2 bytes) should trail")
        XCTAssertNotNil(versions.first?.mtime)
        XCTAssertNotNil(versions.last?.mtime)
    }

    /// diff between two snapshots reports the modified file with the "M" modifier
    /// and non-zero changed-file statistics.
    func testDiffReportsChange() throws {
        let backend = makeBackend()
        try backend.ensureInitialized()
        let src = try makeSource("src", files: ["a.txt": "one"])
        try backend.backup(paths: [src], tags: ["v1"], host: "testhost")
        try "two-different".write(to: src.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try backend.backup(paths: [src], tags: ["v2"], host: "testhost")

        let snaps = try backend.listSnapshots()   // newest first
        XCTAssertEqual(snaps.count, 2)
        let result = try backend.diff(snapshotA: snaps[1].id, snapshotB: snaps[0].id)
        XCTAssertTrue(result.changes.contains { $0.path.hasSuffix("/a.txt") && $0.modifier == "M" },
                      "diff should mark a.txt as modified; got \(result.changes.map { "\($0.modifier) \($0.path)" })")
        XCTAssertGreaterThan(result.changedFiles, 0)
    }

    // MARK: - exit 3 (partial snapshot from an unreadable file)

    /// An unreadable source file makes restic exit 3 — a VALID but partial
    /// snapshot. finishBackup treats that as a warning (returns, doesn't throw),
    /// so the backup still succeeds, the snapshot lands, and it contains the
    /// readable file but not the unreadable one.
    func testUnreadableFileYieldsPartialSnapshot() throws {
        let backend = makeBackend()
        try backend.ensureInitialized()
        let src = try makeSource("src", files: ["readable.txt": "ok", "locked.txt": "secret"])
        let locked = src.appendingPathComponent("locked.txt")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path) }

        // Must NOT throw: exit 3 is a warning, not a destination failure.
        XCTAssertNoThrow(try backend.backup(paths: [src], tags: ["t"], host: "testhost"))
        let snaps = try backend.listSnapshots()
        XCTAssertEqual(snaps.count, 1, "a partial snapshot must still be created")

        let entries = try backend.ls(snapshot: snaps[0].id, path: nil)
        XCTAssertTrue(entries.contains { $0.name == "readable.txt" }, "the readable file should be captured")
        XCTAssertFalse(entries.contains { $0.name == "locked.txt" }, "the unreadable file should be absent")
    }

    // MARK: - excludes (junk defaults + caches + custom patterns)

    /// A backup drops the always-on macOS-junk defaults (.DS_Store), any
    /// CACHEDIR.TAG-tagged cache directory (`--exclude-caches`), and the caller's
    /// own `--exclude` globs — while keeping the real files. Asserted against the
    /// snapshot via `ls`, so it proves the excluded paths never entered the store
    /// (which, being append-only, could never shed them afterwards).
    func testExcludesDropJunkCachesAndCustomPatterns() throws {
        let backend = makeBackend()
        try backend.ensureInitialized()
        let src = try makeSource("src", files: [
            "keep.txt": "keep",
            "sub/keep2.txt": "keep2",
            ".DS_Store": "finder junk",                 // junk default
            "sub/.DS_Store": "finder junk",             // junk default, nested
            "debug.log": "noise",                       // custom exclude *.log
            // A cache dir per the Cache Directory Tagging Standard — restic's
            // --exclude-caches drops its contents (the signature must match exactly).
            "cachedir/CACHEDIR.TAG": "Signature: 8a477f597d28d172789f06886806bc55\n",
            "cachedir/blob.bin": "cached data that must not be backed up",
        ])

        try backend.backup(paths: [src], tags: ["t"], host: "testhost", excludes: ["*.log"])

        let snap = try XCTUnwrap(try backend.listSnapshots().first)
        let names = Set(try backend.ls(snapshot: snap.id, path: nil).map(\.name))

        XCTAssertTrue(names.contains("keep.txt"), "real files must be backed up; got \(names.sorted())")
        XCTAssertTrue(names.contains("keep2.txt"), "nested real files must be backed up")
        XCTAssertFalse(names.contains(".DS_Store"), "the .DS_Store junk default must be excluded")
        XCTAssertFalse(names.contains("debug.log"), "the custom *.log exclude must drop debug.log")
        XCTAssertFalse(names.contains("blob.bin"), "--exclude-caches must drop CACHEDIR.TAG-tagged contents")
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

    // MARK: - --repo-usage (lsDetailed + RepoUsage.aggregate against a real snapshot)

    /// `lsDetailed` (the `restic ls -l --json` helper) plus the pure
    /// `RepoUsage.aggregate` reproduce the exact `--repo-usage` command path
    /// against a real snapshot. The temp source tree's absolute path depth is an
    /// implementation detail we don't hard-code (unlike a production iCloud
    /// path, $TMPDIR can be deeply nested), so the assertions are invariants
    /// that hold regardless of depth: the top-level buckets account for every
    /// byte, both levels are sorted descending, and the secondary table only
    /// ever drills into the reported largest top bucket.
    func testRepoUsageAggregatesRealSnapshot() throws {
        let backend = makeBackend()
        try backend.ensureInitialized()
        let src = try makeSource("src", files: [
            "alice/small.txt": "hi",                                  // 2 bytes
            "bob/big.bin": String(repeating: "x", count: 10_000),      // 10,000 bytes
        ])
        try backend.backup(paths: [src], tags: ["t"], host: "testhost")

        let entries = try backend.lsDetailed(snapshot: "latest")
        let files = entries.filter { $0.type == "file" }
        XCTAssertTrue(files.contains { $0.name == "small.txt" })
        XCTAssertTrue(files.contains { $0.name == "big.bin" })
        let totalFileBytes = files.reduce(0) { $0 + ($1.size ?? 0) }
        XCTAssertGreaterThanOrEqual(totalFileBytes, 10_002)

        let (top, secondaryOf, secondary) = RepoUsage.aggregate(entries: entries)
        XCTAssertFalse(top.isEmpty)
        XCTAssertEqual(top.reduce(0) { $0 + $1.bytes }, totalFileBytes,
                       "every file byte must land in exactly one top-level bucket")
        for i in 1..<top.count {
            XCTAssertGreaterThanOrEqual(top[i - 1].bytes, top[i].bytes, "top buckets must sort descending")
        }
        if let secondaryOf {
            XCTAssertTrue(top.contains { $0.path == secondaryOf }, "the drill-down must name an actual top bucket")
            for i in 1..<secondary.count {
                XCTAssertGreaterThanOrEqual(secondary[i - 1].bytes, secondary[i].bytes, "secondary buckets must sort descending")
            }
        }
    }
}
