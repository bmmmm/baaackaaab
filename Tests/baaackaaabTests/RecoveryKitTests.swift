import XCTest
@testable import baaackaaab

// The recovery kit's Markdown composition and passphrase validation are pure —
// no filesystem, no process, no Date() default — so they're exercised directly
// with hand-built entries, matching SecretsTests' style for Credentials. The
// openssl encryption path itself is a thin process shell-out (mirrors
// Credentials.htpasswdLine) and isn't re-tested here; RecoveryKitCommand wires
// it, RecoveryKit.encrypt just runs openssl with -pass stdin.
final class RecoveryKitTests: XCTestCase {

    // MARK: - endpointPassword extraction (Credentials, shared by the kit)

    func testEndpointPasswordExtractsFromUserPassURL() {
        let url = "rest:https://macbook:S3cr3tPW@restic.example.com/macbook/"
        XCTAssertEqual(Credentials.endpointPassword(from: url), "S3cr3tPW")
    }

    func testEndpointPasswordNilForNoUserinfo() {
        XCTAssertNil(Credentials.endpointPassword(from: "/local/path/to/repo"))
        XCTAssertNil(Credentials.endpointPassword(from: "s3:s3.amazonaws.com/bucket"))
    }

    func testEndpointPasswordNilForTokenOnlyUserinfo() {
        // A token-as-username URL (no colon) has no separable password.
        XCTAssertNil(Credentials.endpointPassword(from: "rest:https://TOKENVALUE@host/repo/"))
    }

    // MARK: - composeSheet (pure)

    func testComposeSheetIncludesEveryDestinationsSecretsInPlaintext() {
        let entries = [
            RecoveryKit.Entry(name: "default",
                              repoURL: "rest:https://macbook:endpw@restic.example.com/macbook/",
                              password: "repo-encryption-key"),
            RecoveryKit.Entry(name: "offsite",
                              repoURL: "sftp:user@host:/repo",
                              password: "other-key"),
        ]
        let sheet = RecoveryKit.composeSheet(entries: entries, generatedAt: Date(timeIntervalSince1970: 1_700_000_000))

        // Full URLs and passwords are in the clear — that is the point.
        XCTAssertTrue(sheet.contains("rest:https://macbook:endpw@restic.example.com/macbook/"))
        XCTAssertTrue(sheet.contains("repo-encryption-key"))
        XCTAssertTrue(sheet.contains("endpw"))            // extracted endpoint password
        XCTAssertTrue(sheet.contains("sftp:user@host:/repo"))
        XCTAssertTrue(sheet.contains("other-key"))

        // Recovery steps are plain restic, no baaackaaab.
        XCTAssertTrue(sheet.contains("export RESTIC_REPOSITORY='rest:https://macbook:endpw@restic.example.com/macbook/'"))
        XCTAssertTrue(sheet.contains("export RESTIC_PASSWORD='repo-encryption-key'"))
        XCTAssertTrue(sheet.contains("restic snapshots"))
        XCTAssertTrue(sheet.contains("restic restore latest --target ./recovered --verify"))

        // The offline warning header is present.
        XCTAssertTrue(sheet.contains("OFFLINE"))
        XCTAssertTrue(sheet.contains("NEVER"))
    }

    func testComposeSheetNotesDestinationWithoutEndpointPasswordAsNotApplicable() {
        let entries = [RecoveryKit.Entry(name: "local", repoURL: "/Volumes/Backup/repo", password: "key")]
        let sheet = RecoveryKit.composeSheet(entries: entries, generatedAt: Date())
        XCTAssertTrue(sheet.contains("n/a"), "a repo URL with no embedded credential should note n/a, not a blank/garbage password")
    }

    func testComposeSheetMarksIncompleteDestinationWithoutFailing() {
        let entries = [
            RecoveryKit.Entry(name: "broken", repoURL: nil, password: nil),
            RecoveryKit.Entry(name: "fine", repoURL: "rest:https://h/fine/", password: "k"),
        ]
        let sheet = RecoveryKit.composeSheet(entries: entries, generatedAt: Date())
        XCTAssertTrue(sheet.contains("INCOMPLETE"))
        XCTAssertTrue(sheet.contains("broken"))
        // The complete destination's secrets still made it in.
        XCTAssertTrue(sheet.contains("rest:https://h/fine/"))
    }

    func testComposeSheetEmptyEntriesStillProducesAValidSheet() {
        let sheet = RecoveryKit.composeSheet(entries: [], generatedAt: Date())
        XCTAssertTrue(sheet.contains("# baaackaaab emergency recovery kit"))
        XCTAssertTrue(sheet.contains("No destinations"))
    }

    // MARK: - buildEntries (I/O boundary, but exercised with a real Destination)

    func testBuildEntriesReadsDisplayURLAndPasswordValue() {
        let dest = Destination(name: "d", link: "default", order: 0, enabled: true,
                               repo: .value("rest:https://h/d/"), password: .value("pw123"))
        let entries = RecoveryKit.buildEntries(from: [dest])
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].name, "d")
        XCTAssertEqual(entries[0].repoURL, "rest:https://h/d/")
        XCTAssertEqual(entries[0].password, "pw123")
    }

    func testBuildEntriesNilPasswordForUnsetPassword() {
        let dest = Destination(name: "d", link: "default", order: 0, enabled: true,
                               repo: .value("rest:https://h/d/"), password: .unset)
        let entries = RecoveryKit.buildEntries(from: [dest])
        XCTAssertNil(entries[0].password)
    }

    // MARK: - validatePassphrase (pure)

    func testValidatePassphraseRejectsShort() {
        XCTAssertEqual(RecoveryKit.validatePassphrase("short", "short"), .passphraseTooShort)
    }

    func testValidatePassphraseRejectsMismatch() {
        XCTAssertEqual(RecoveryKit.validatePassphrase("longenoughpw1", "longenoughpw2"), .passphraseMismatch)
    }

    func testValidatePassphraseAcceptsMatchingLongEnough() {
        XCTAssertNil(RecoveryKit.validatePassphrase("longenoughpassphrase", "longenoughpassphrase"))
    }

    func testValidatePassphraseBoundaryTenChars() {
        XCTAssertNil(RecoveryKit.validatePassphrase("1234567890", "1234567890"))   // exactly 10
        XCTAssertNotNil(RecoveryKit.validatePassphrase("123456789", "123456789"))  // exactly 9
    }
}
