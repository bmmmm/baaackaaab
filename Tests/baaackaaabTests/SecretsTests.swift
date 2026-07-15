import XCTest
@testable import baaackaaab

// The two generators behind --init-credentials. `randomURLSafe` must emit only
// URL-userinfo-safe characters — a raw '+' or '/' in the endpoint password would
// corrupt the repo URL's authority (see the redact tests for what a '/' there
// does to parsing). `repoURL` must embed the password in the one shape every
// consumer (redact, restEndpoint, restic itself) expects.
final class SecretsTests: XCTestCase {

    func testRandomURLSafeAlphabetAndLength() {
        for _ in 0..<50 {
            let s = Credentials.randomURLSafe(byteCount: 32)
            // base64url, unpadded: 32 bytes → ceil(32/3)·4 − padding = 43 chars.
            XCTAssertEqual(s.count, 43)
            XCTAssertFalse(s.contains("+"))
            XCTAssertFalse(s.contains("/"))
            XCTAssertFalse(s.contains("="))
        }
    }

    func testRandomURLSafeIsNotConstant() {
        XCTAssertNotEqual(Credentials.randomURLSafe(byteCount: 32),
                          Credentials.randomURLSafe(byteCount: 32))
    }

    // Environment-independent shape check: whatever BAAACKAAAB_ENDPOINT_* is
    // set to, the URL must be rest:https:// with a user:password@ userinfo and
    // a trailing slash, and the password must round-trip into redact's mask.
    func testRepoURLShapeAndRedactRoundTrip() {
        let url = Credentials.repoURL(password: "PW123SECRET")
        XCTAssertTrue(url.hasPrefix("rest:https://"))
        XCTAssertTrue(url.contains(":PW123SECRET@"))
        XCTAssertTrue(url.hasSuffix("/"))
        let redacted = Credentials.redact(url)
        XCTAssertFalse(redacted.contains("PW123SECRET"))
        XCTAssertTrue(redacted.contains(":***@"))
    }
}
