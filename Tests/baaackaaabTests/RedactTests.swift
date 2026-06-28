import XCTest
@testable import baaackaaab

// `Credentials.redact` is the gate that keeps the endpoint password out of every
// log line and dashboard. The repo URL embeds a raw, un-percent-encoded password
// (`rest:https://user:PASS@host/user/`), so the masking has to be robust to a
// password that itself contains '@' and to the token-as-username form. These
// tests pin exactly the cases the recent fixes addressed.
final class RedactTests: XCTestCase {

    func testMasksThePasswordInAUserPassURL() {
        XCTAssertEqual(
            Credentials.redact("rest:https://macbook:s3cr3t@host.example/macbook/"),
            "rest:https://macbook:***@host.example/macbook/")
    }

    // The userinfo is delimited by the LAST '@' in the AUTHORITY. A password
    // containing '@' must be fully masked — a first-'@' split would leak its tail.
    func testMasksPasswordContainingAtSign() {
        XCTAssertEqual(
            Credentials.redact("rest:https://user:pa@ss@host.example/user/"),
            "rest:https://user:***@host.example/user/")
    }

    // Token-as-username (no colon in the userinfo) must mask the WHOLE userinfo.
    func testMasksWholeUserinfoWhenNoColon() {
        XCTAssertEqual(
            Credentials.redact("rest:https://SECRETTOKEN@host.example/path/"),
            "rest:https://***@host.example/path/")
    }

    // An '@' in the PATH must not be mistaken for the userinfo delimiter.
    func testAtSignInPathIsNotTreatedAsUserinfo() {
        let url = "rest:https://host.example/weird@folder/"
        XCTAssertEqual(Credentials.redact(url), url)   // unchanged: no userinfo
    }

    func testNoUserinfoLeavesURLUnchanged() {
        let url = "rest:https://host.example/repo/"
        XCTAssertEqual(Credentials.redact(url), url)
    }

    func testNonURLStringLeftUnchanged() {
        XCTAssertEqual(Credentials.redact("not-a-url"), "not-a-url")
        XCTAssertEqual(Credentials.redact(""), "")
    }
}
