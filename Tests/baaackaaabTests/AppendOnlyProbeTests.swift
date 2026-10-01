import XCTest
@testable import baaackaaab

// The append-only enforcement probe has two pure, network-free pieces worth
// pinning: the status-code → verdict classification (exhaustive — every
// branch of the switch), and the rest:-URL → probe-URL/credential derivation.
// The actual DELETE call is not exercised here (it touches the network); like
// UpdateCheck's header probe it degrades to `.unreachable` on any failure by
// construction.
final class AppendOnlyProbeTests: XCTestCase {

    // MARK: - probeObjectName

    // Never a real pack id, never `locks/` — the constant itself must look
    // like a plausible `data/` object (64 lowercase hex chars) so a server
    // can't reject it on shape alone before ever reaching the append-only
    // check.
    func testProbeObjectNameIsSixtyFourLowercaseHexChars() {
        let name = AppendOnlyProbe.probeObjectName
        XCTAssertEqual(name.count, 64)
        XCTAssertTrue(name.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    }

    // MARK: - classify(statusCode:) — exhaustive

    func testClassify403IsEnforced() {
        XCTAssertEqual(AppendOnlyProbe.classify(statusCode: 403), .enforced)
    }

    func testClassify404IsNotEnforced() {
        XCTAssertEqual(AppendOnlyProbe.classify(statusCode: 404), .notEnforced(404))
    }

    func testClassify2xxIsNotEnforced() {
        for code in [200, 201, 204, 299] {
            XCTAssertEqual(AppendOnlyProbe.classify(statusCode: code), .notEnforced(code), "\(code)")
        }
    }

    func testClassify401IsAuthProblem() {
        XCTAssertEqual(AppendOnlyProbe.classify(statusCode: 401), .authProblem)
    }

    func testClassifyNilIsUnreachable() {
        XCTAssertEqual(AppendOnlyProbe.classify(statusCode: nil), .unreachable)
    }

    func testClassifyOtherStatusIsInconclusive() {
        for code in [301, 400, 405, 429, 500, 502, 503] {
            XCTAssertEqual(AppendOnlyProbe.classify(statusCode: code), .inconclusive(code), "\(code)")
        }
    }

    // MARK: - Verdict.isProblem — only notEnforced blocks doctor's verdict

    func testOnlyNotEnforcedIsAProblem() {
        XCTAssertFalse(AppendOnlyProbe.Verdict.enforced.isProblem)
        XCTAssertTrue(AppendOnlyProbe.Verdict.notEnforced(404).isProblem)
        XCTAssertFalse(AppendOnlyProbe.Verdict.authProblem.isProblem)
        XCTAssertFalse(AppendOnlyProbe.Verdict.unreachable.isProblem)
        XCTAssertFalse(AppendOnlyProbe.Verdict.inconclusive(500).isProblem)
    }

    // MARK: - Verdict.message — actionable, and the hard finding names the fix

    func testNotEnforcedMessageIsActionable() {
        let msg = AppendOnlyProbe.Verdict.notEnforced(404).message
        XCTAssertTrue(msg.contains("NOT in --append-only mode"))
        XCTAssertTrue(msg.contains("--append-only"))   // names the fix
    }

    func testAuthProblemMessageMentionsHtpasswd() {
        XCTAssertTrue(AppendOnlyProbe.Verdict.authProblem.message.lowercased().contains("htpasswd"))
    }

    // MARK: - target(from:) — URL + credential derivation

    func testTargetDerivesDataURLUnderRepoPath() throws {
        let target = try XCTUnwrap(AppendOnlyProbe.target(from: "rest:https://macbook:s3cr3t@host.example/macbook/"))
        XCTAssertEqual(
            target.url.absoluteString,
            "https://host.example/macbook/data/" + AppendOnlyProbe.probeObjectName)
    }

    func testTargetKeepsPort() throws {
        let target = try XCTUnwrap(AppendOnlyProbe.target(from: "rest:https://u:p@host:8000/repo/"))
        XCTAssertEqual(
            target.url.absoluteString,
            "https://host:8000/repo/data/" + AppendOnlyProbe.probeObjectName)
    }

    func testTargetAddsMissingTrailingSlashBeforeData() throws {
        // A repo URL without a trailing slash on the subpath must still land
        // on ".../repo/data/<id>", not ".../repodata/<id>".
        let target = try XCTUnwrap(AppendOnlyProbe.target(from: "rest:https://u:p@host/repo"))
        XCTAssertEqual(
            target.url.absoluteString,
            "https://host/repo/data/" + AppendOnlyProbe.probeObjectName)
    }

    func testTargetBasicAuthHeaderEncodesUserAndPassword() throws {
        let target = try XCTUnwrap(AppendOnlyProbe.target(from: "rest:https://macbook:s3cr3t@host.example/macbook/"))
        let expected = "Basic " + Data("macbook:s3cr3t".utf8).base64EncodedString()
        XCTAssertEqual(target.authorizationHeader, expected)
    }

    func testTargetTokenAsUsernameHasEmptyPassword() throws {
        let target = try XCTUnwrap(AppendOnlyProbe.target(from: "rest:https://SECRETTOKEN@host.example/path/"))
        let expected = "Basic " + Data("SECRETTOKEN:".utf8).base64EncodedString()
        XCTAssertEqual(target.authorizationHeader, expected)
    }

    // A password containing '@' must still be split at the LAST '@' in the
    // authority, exactly like Credentials.redact and UpdateCheck.restEndpoint.
    func testTargetHandlesPasswordContainingAtSign() throws {
        let target = try XCTUnwrap(AppendOnlyProbe.target(from: "rest:https://user:pa@ss@host.example/user/"))
        let expected = "Basic " + Data("user:pa@ss".utf8).base64EncodedString()
        XCTAssertEqual(target.authorizationHeader, expected)
        XCTAssertEqual(
            target.url.absoluteString,
            "https://host.example/user/data/" + AppendOnlyProbe.probeObjectName)
    }

    func testTargetNilForNonRestBackends() {
        XCTAssertNil(AppendOnlyProbe.target(from: "sftp:user@host:/srv/repo"))
        XCTAssertNil(AppendOnlyProbe.target(from: "/local/path/repo"))
        XCTAssertNil(AppendOnlyProbe.target(from: "s3:s3.amazonaws.com/bucket"))
        XCTAssertNil(AppendOnlyProbe.target(from: "b2:bucket:repo"))
        XCTAssertNil(AppendOnlyProbe.target(from: "rest:ftp://host/repo/"))
    }

    // MARK: - No password ever reaches the probed URL (only the header)

    // The whole point of building the Authorization header separately: the
    // password must never be re-embedded in a URL string that could end up
    // logged, retried, or printed in a request trace.
    func testProbeURLNeverContainsThePassword() throws {
        let target = try XCTUnwrap(AppendOnlyProbe.target(from: "rest:https://macbook:s3cr3t-password@host.example/macbook/"))
        XCTAssertFalse(target.url.absoluteString.contains("s3cr3t-password"))
        // Redacting the URL is a no-op — there was never a secret in it to
        // begin with, which is the property this test pins.
        XCTAssertEqual(Credentials.redact(target.url.absoluteString), target.url.absoluteString)
    }

    func testProbeURLNeverContainsAtSignPassword() throws {
        let target = try XCTUnwrap(AppendOnlyProbe.target(from: "rest:https://user:pa@ss@host.example/user/"))
        XCTAssertFalse(target.url.absoluteString.contains("pa@ss"))
    }
}
