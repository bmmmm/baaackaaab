import XCTest
@testable import baaackaaab

// The update check has three pure, network-free pieces worth pinning: parsing a
// version out of arbitrary tool output, comparing two versions, and turning a
// (installed, reference) pair into a verdict. The fourth — extracting the bare
// server endpoint from a credential-bearing repo URL — must drop the password
// exactly like the redactor does. The online GitHub query and the live HTTP header
// probe are not exercised here (they touch the network); they degrade to nil/
// baseline by construction.
final class UpdateCheckTests: XCTestCase {

    // MARK: - SemVer parsing

    func testParsesResticVersionLine() {
        let v = SemVer(parsing: "restic 0.18.0 compiled with go1.21.5 on darwin/arm64")
        XCTAssertEqual(v, SemVer(0, 18, 0))   // not go1.21.5 — the FIRST run wins
    }

    func testParsesLeadingVTag() {
        XCTAssertEqual(SemVer(parsing: "v0.19.0"), SemVer(0, 19, 0))
    }

    func testParsesServerHeaderForm() {
        XCTAssertEqual(SemVer(parsing: "rest-server/0.13.0"), SemVer(0, 13, 0))
        XCTAssertEqual(SemVer(parsing: "Server: rest-server/0.12.1 (go1.22)"), SemVer(0, 12, 1))
    }

    func testMissingPatchDefaultsToZero() {
        XCTAssertEqual(SemVer(parsing: "0.13"), SemVer(0, 13, 0))
    }

    func testRejectsTextWithoutAVersion() {
        XCTAssertNil(SemVer(parsing: "no version here"))
        XCTAssertNil(SemVer(parsing: ""))
        // A bare single number is not a version (needs at least MAJOR.MINOR).
        XCTAssertNil(SemVer(parsing: "restic 5 apples"))
    }

    func testTakesOnlyTheFirstThreeComponents() {
        XCTAssertEqual(SemVer(parsing: "1.2.3.4"), SemVer(1, 2, 3))
    }

    // MARK: - SemVer comparison

    func testComparison() {
        XCTAssertTrue(SemVer(0, 18, 0) < SemVer(0, 19, 0))
        XCTAssertTrue(SemVer(0, 18, 0) < SemVer(0, 18, 1))   // patch matters
        XCTAssertTrue(SemVer(0, 99, 99) < SemVer(1, 0, 0))   // major dominates
        XCTAssertFalse(SemVer(0, 19, 0) < SemVer(0, 19, 0))  // equal is not behind
        XCTAssertEqual(SemVer(0, 19, 0), SemVer(0, 19, 0))
    }

    // MARK: - Verdict

    func testVerdictBehind() {
        XCTAssertEqual(
            UpdateCheck.verdict(installed: SemVer(0, 18, 0), reference: SemVer(0, 19, 0)),
            .behind(SemVer(0, 18, 0), SemVer(0, 19, 0)))
    }

    func testVerdictUpToDateWhenEqualOrNewer() {
        XCTAssertEqual(UpdateCheck.verdict(installed: SemVer(0, 19, 0), reference: SemVer(0, 19, 0)), .upToDate)
        XCTAssertEqual(UpdateCheck.verdict(installed: SemVer(0, 20, 0), reference: SemVer(0, 19, 0)), .upToDate)
    }

    func testVerdictUnknownSides() {
        XCTAssertEqual(UpdateCheck.verdict(installed: nil, reference: SemVer(0, 19, 0)), .unknownInstalled)
        XCTAssertEqual(UpdateCheck.verdict(installed: SemVer(0, 19, 0), reference: nil), .unknownReference)
    }

    // MARK: - REST endpoint extraction (drops credentials + path)

    func testEndpointStripsUserinfoAndPath() {
        XCTAssertEqual(
            UpdateCheck.restEndpoint(from: "rest:https://macbook:s3cr3t@host.example/macbook/"),
            "https://host.example/")
    }

    func testEndpointKeepsPort() {
        XCTAssertEqual(
            UpdateCheck.restEndpoint(from: "rest:https://u:p@host:8000/repo/"),
            "https://host:8000/")
    }

    // A password containing '@' must be dropped whole — split at the LAST '@' in the
    // authority, mirroring the redactor.
    func testEndpointDropsPasswordContainingAtSign() {
        XCTAssertEqual(
            UpdateCheck.restEndpoint(from: "rest:https://user:pa@ss@host.example/user/"),
            "https://host.example/")
    }

    func testEndpointTokenAsUsername() {
        XCTAssertEqual(
            UpdateCheck.restEndpoint(from: "rest:https://SECRETTOKEN@host.example/path/"),
            "https://host.example/")
    }

    func testEndpointHttpScheme() {
        XCTAssertEqual(UpdateCheck.restEndpoint(from: "rest:http://host/repo/"), "http://host/")
    }

    func testEndpointNilForNonRestBackends() {
        XCTAssertNil(UpdateCheck.restEndpoint(from: "sftp:user@host:/srv/repo"))
        XCTAssertNil(UpdateCheck.restEndpoint(from: "/local/path/repo"))
        XCTAssertNil(UpdateCheck.restEndpoint(from: "s3:s3.amazonaws.com/bucket"))
        // rest: with an unsupported inner scheme
        XCTAssertNil(UpdateCheck.restEndpoint(from: "rest:ftp://host/repo/"))
    }
}
