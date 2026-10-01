import XCTest
@testable import baaackaaab

// End-to-end proof of the ENCRYPTED recovery-kit path — the default export
// mode, previously never executed by any test (only the plaintext sheet was).
// The decrypt step uses exactly the parameter list the kit's printed
// instructions give the operator (RecoveryKitCommand: `openssl enc -d
// -aes-256-cbc -pbkdf2 -iter 600000 -in <path>`): if encrypt parameters and
// printed decrypt instructions ever drift apart, the operator discovers it
// during a real disaster — this test discovers it in CI instead.
final class RecoveryKitRoundTripTests: XCTestCase {

    private var supportDir: URL!

    override func setUpWithError() throws {
        try XCTSkipUnless(RecoveryKit.locateOpenSSL() != nil, "openssl not found — skipping")
        supportDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("baaackaaab-kit-\(UUID().uuidString)", isDirectory: true)
        setenv("BAAACKAAAB_SUPPORT_DIR", supportDir.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("BAAACKAAAB_SUPPORT_DIR")
        if let supportDir { try? FileManager.default.removeItem(at: supportDir) }
    }

    private func decrypt(_ file: URL, passphrase: String) throws -> (status: Int32, output: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: RecoveryKit.locateOpenSSL()!)
        // Mirror of the printed instructions + `-pass stdin` (the instructions
        // let openssl prompt interactively; a test has no tty).
        proc.arguments = ["enc", "-d", "-aes-256-cbc", "-pbkdf2", "-iter", "600000",
                          "-in", file.path, "-pass", "stdin"]
        let input = Pipe(), output = Pipe()
        proc.standardInput = input
        proc.standardOutput = output
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        input.fileHandleForWriting.write(Data((passphrase + "\n").utf8))
        input.fileHandleForWriting.closeFile()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return (proc.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    func testEncryptedKitRoundTripsWithPrintedDecryptParameters() throws {
        let plaintext = "recovery sheet\nRESTIC_PASSWORD=example-not-real\numlauts: äöü\n"
        let out = supportDir.appendingPathComponent("kit.md.enc")
        try RecoveryKit.encrypt(plaintext: plaintext, passphrase: "drill-pass-123", to: out)

        // 0600 — the kit carries cleartext secrets by design.
        let perms = try FileManager.default.attributesOfItem(atPath: out.path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600)

        let (status, decrypted) = try decrypt(out, passphrase: "drill-pass-123")
        XCTAssertEqual(status, 0)
        XCTAssertEqual(decrypted, plaintext)
    }

    func testWrongPassphraseFailsToDecrypt() throws {
        let out = supportDir.appendingPathComponent("kit.md.enc")
        try RecoveryKit.encrypt(plaintext: "secret", passphrase: "right", to: out)
        let (status, decrypted) = try decrypt(out, passphrase: "wrong")
        XCTAssertNotEqual(status, 0)
        XCTAssertNotEqual(decrypted, "secret")
    }

    // The staged plaintext temp file must be gone afterwards — it holds the
    // sheet's cleartext secrets and lives only for the openssl call.
    func testNoPlaintextTempFileLeftBehind() throws {
        let out = supportDir.appendingPathComponent("kit.md.enc")
        try RecoveryKit.encrypt(plaintext: "secret", passphrase: "p", to: out)
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: supportDir.path))?
            .filter { $0.contains("recovery-kit-plain") } ?? []
        XCTAssertEqual(leftovers, [])
    }
}
