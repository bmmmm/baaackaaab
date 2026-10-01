import XCTest
@testable import baaackaaab

// Bit-rot detection PoC: proves the claim that the rotating read-data integrity
// check catches on-disk corruption of stored pack bytes — the thing the
// structural check alone cannot see. A real repo is backed up, ONE byte in the
// middle of a data pack is flipped (size unchanged, so nothing structural
// drifts), and the same checkRepo path the check timer drives must flag it.
// Negative controls: the same check is clean before the corruption, and the
// structural pass (no --read-data) stays clean even AFTER it — demonstrating
// exactly why the read-data rotation exists.
final class BitRotPoCTests: XCTestCase {

    private var tmp: URL!
    private var repoPath: String!
    private let password = "correct-horse-battery-staple"

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(ResticBackend.locateExecutable() != nil,
                          "restic not on PATH — skipping live PoC test")
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("baaackaaab-rotpoc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        setenv("RESTIC_CACHE_DIR", tmp.appendingPathComponent("cache").path, 1)
        repoPath = tmp.appendingPathComponent("repo", isDirectory: true).path
    }

    override func tearDownWithError() throws {
        if let tmp { try? FileManager.default.removeItem(at: tmp) }
        tmp = nil
        try super.tearDownWithError()
    }

    private func makeBackend() -> ResticBackend {
        let dest = Destination(name: "poc", link: "default", order: 0, enabled: true,
                               repo: .value(repoPath), password: .value(password))
        return ResticBackend(destination: dest)
    }

    /// The largest file under repo/data/** — a content pack.
    private func largestDataPack() throws -> URL {
        let dataDir = URL(fileURLWithPath: repoPath).appendingPathComponent("data")
        var best: (URL, Int)?
        let e = FileManager.default.enumerator(at: dataDir,
                                               includingPropertiesForKeys: [.fileSizeKey])
        while let url = e?.nextObject() as? URL {
            guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size > 0 else { continue }
            if best == nil || size > best!.1 { best = (url, size) }
        }
        guard let best else {
            struct NoPack: Error {}
            XCTFail("no data pack found under \(dataDir.path)")
            throw NoPack()
        }
        return best.0
    }

    func testFlippedPackByteFailsReadDataCheckButNotStructuralCheck() throws {
        let backend = makeBackend()
        try backend.ensureInitialized()

        // Incompressible content, so the pack on disk carries these bytes and a
        // mid-file flip cannot land in slack the check would never hash.
        let source = tmp.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        var random = Data(count: 4 << 20)
        random.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, 4 << 20) }
        try random.write(to: source.appendingPathComponent("media.bin"))
        try backend.backup(paths: [source], tags: ["poc"], host: "poc-host")

        // Negative control: the full read-data check is clean pre-corruption.
        // "1/1" comes from the production subset builder the check timer uses.
        let fullSubset = RotatingCheck.subsetSpec(slice: 1, slices: 1)
        XCTAssertTrue(backend.checkRepo(readDataSubset: fullSubset).clean,
                      "an intact repo must pass the read-data check")

        // THE ROT: flip one byte in the middle of the largest data pack. Size,
        // name, and mtime-relevant structure stay untouched. restic writes packs
        // read-only; real bit-rot happens below the permission layer, so lifting
        // the mode bit is part of the simulation, not a cheat.
        let pack = try largestDataPack()
        try FileManager.default.setAttributes([.posixPermissions: 0o644],
                                              ofItemAtPath: pack.path)
        var bytes = try Data(contentsOf: pack)
        let mid = bytes.count / 2
        bytes[mid] ^= 0xFF
        try bytes.write(to: pack)

        // The structural pass alone does NOT see it — the documented reason the
        // read-data rotation exists at all.
        let structural = backend.checkRepo(readDataSubset: nil)
        XCTAssertTrue(structural.clean,
                      "a mid-pack byte flip must be invisible to the structural check " +
                      "(got: \(structural.errorLines))")

        // The read-data check MUST catch it, with concrete error lines the
        // banner/doctor can surface.
        let verdict = backend.checkRepo(readDataSubset: fullSubset)
        XCTAssertFalse(verdict.clean, "a flipped pack byte must fail the read-data check")
        XCTAssertFalse(verdict.lockedOut,
                       "corruption must not be misclassified as a lock conflict")
        XCTAssertFalse(verdict.errorLines.isEmpty,
                       "the failure must carry actionable error lines")
        print("POC-ROT: 1 flipped byte in \(pack.lastPathComponent): structural check " +
              "clean, read-data check failed with \(verdict.errorLines.count) error line(s), " +
              "e.g.: \(verdict.errorLines.first ?? "-")")
    }
}
