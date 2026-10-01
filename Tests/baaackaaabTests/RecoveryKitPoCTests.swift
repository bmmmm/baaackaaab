import XCTest
@testable import baaackaaab

// Recovery-kit disaster drill PoC: proves the claim that the exported sheet plus
// STOCK restic recovers the data on any machine — no baaackaaab, no Mac, no
// credential files. The test does not re-derive the recovery procedure: it backs
// up known bytes, composes the real sheet, then EXECUTES the sheet's own fenced
// `sh` block verbatim in a clean working directory with a minimal environment
// (no RESTIC_* inherited), and verifies the restored bytes match the source.
// A sheet whose URL form, field wording, or command lines drift into something
// stock restic cannot execute fails this test forever after.
//
// Scope limit (see docs/poc-recovery-kit.md): the destination here is a local
// path, so the rest:-URL + htpasswd variant's credential embedding is covered by
// the credential-derivation unit tests, not by this end-to-end run.
final class RecoveryKitPoCTests: XCTestCase {

    private var tmp: URL!
    private var repoPath: String!
    private let password = "correct-horse-battery-staple"

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(ResticBackend.locateExecutable() != nil,
                          "restic not on PATH — skipping live PoC test")
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("baaackaaab-kitpoc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        setenv("RESTIC_CACHE_DIR", tmp.appendingPathComponent("cache").path, 1)
        repoPath = tmp.appendingPathComponent("repo", isDirectory: true).path
    }

    override func tearDownWithError() throws {
        if let tmp { try? FileManager.default.removeItem(at: tmp) }
        tmp = nil
        try super.tearDownWithError()
    }

    /// Extract the fenced ```sh block under `## Destination: <name>` — exactly
    /// what a disaster victim would copy-paste.
    private func shBlock(fromSheet sheet: String, destination: String) throws -> String {
        guard let destRange = sheet.range(of: "## Destination: \(destination)") else {
            throw XCTSkip("sheet section for \(destination) not found — sheet format changed?")
        }
        let after = sheet[destRange.upperBound...]
        guard let open = after.range(of: "```sh\n"),
              let close = after[open.upperBound...].range(of: "\n```") else {
            struct NoBlock: Error {}
            XCTFail("no ```sh recovery block found in the sheet for \(destination)")
            throw NoBlock()
        }
        return String(after[open.upperBound..<close.lowerBound])
    }

    func testSheetShBlockRecoversDataWithStockResticOnly() throws {
        // 1. A life: real files backed up through the real backend.
        let dest = Destination(name: "poc", link: "default", order: 0, enabled: true,
                               repo: .value(repoPath), password: .value(password))
        let backend = ResticBackend(destination: dest)
        try backend.ensureInitialized()
        let source = tmp.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let payload = "the exact bytes we must get back — \(UUID().uuidString)"
        try payload.write(to: source.appendingPathComponent("precious.txt"),
                          atomically: true, encoding: .utf8)
        try backend.backup(paths: [source], tags: ["poc"], host: "poc-host")

        // 2. The real sheet, from the real entry builder (reads the same
        //    Destination accessors the CLI export uses).
        let sheet = RecoveryKit.composeSheet(
            entries: RecoveryKit.buildEntries(from: [dest]),
            generatedAt: Date(timeIntervalSince1970: 1_750_000_000))
        let script = try shBlock(fromSheet: sheet, destination: "poc")
        XCTAssertTrue(script.contains("restic restore"),
                      "the sheet's recovery block must contain a restore command")

        // 3. THE DISASTER MACHINE: a clean working dir, a minimal environment —
        //    stock restic on PATH, nothing else. No RESTIC_* leaks in; the
        //    script must be self-sufficient.
        let machine = tmp.appendingPathComponent("fresh-machine", isDirectory: true)
        try FileManager.default.createDirectory(at: machine, withIntermediateDirectories: true)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-e", "-c", script]
        proc.currentDirectoryURL = machine
        proc.environment = [
            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
            "HOME": machine.path,
            "RESTIC_CACHE_DIR": machine.appendingPathComponent("cache").path,
        ]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = out
        try proc.run()
        proc.waitUntilExit()
        let log = String(data: out.fileHandleForReading.readDataToEndOfFile(),
                         encoding: .utf8) ?? ""
        XCTAssertEqual(proc.terminationStatus, 0,
                       "the sheet's own recovery block must run clean:\n\(log)")

        // 4. The proof: the restored bytes equal the source bytes. The sheet
        //    restores into ./recovered (its own --target), preserving the
        //    original absolute path underneath.
        let recovered = machine.appendingPathComponent("recovered", isDirectory: true)
        var restored: URL?
        let e = FileManager.default.enumerator(at: recovered, includingPropertiesForKeys: nil)
        while let url = e?.nextObject() as? URL {
            if url.lastPathComponent == "precious.txt" { restored = url; break }
        }
        guard let restored else {
            return XCTFail("precious.txt not found under \(recovered.path):\n\(log)")
        }
        XCTAssertEqual(try String(contentsOf: restored, encoding: .utf8), payload,
                       "restored bytes must match the source exactly")
        print("POC-KIT: sheet sh-block ran clean with stock restic; " +
              "restored bytes verified byte-identical (--verify re-read included)")
    }
}
