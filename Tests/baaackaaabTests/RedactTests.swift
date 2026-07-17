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

    // A password containing a raw '/' truncates the apparent authority BEFORE
    // its '@' — the spec-only split then found no userinfo and returned the URL
    // UNCHANGED, logging the cleartext password. The fallback (last '@'
    // anywhere) must catch it. This is the realistic external-URL case: base64
    // from other tools contains '/'; only baaackaaab's own generated passwords
    // are base64url-safe.
    func testMasksPasswordContainingSlash() {
        XCTAssertEqual(
            Credentials.redact("rest:https://macbook:pa/ss@host.example/macbook/"),
            "rest:https://macbook:***@host.example/macbook/")
    }

    // An '@' in the PATH of a URL that carries a userinfo is still bounded to
    // the authority (rule 1 fires first).
    func testAtSignInPathWithUserinfoStaysCorrect() {
        XCTAssertEqual(
            Credentials.redact("rest:https://user:pass@host.example/weird@folder/"),
            "rest:https://user:***@host.example/weird@folder/")
    }

    // An '@' in the PATH of a CREDENTIAL-LESS URL is indistinguishable from a
    // '/'-in-password userinfo, so the redactor deliberately over-masks it:
    // mangling the display of an exotic URL is acceptable, leaking a cleartext
    // password (the previous behaviour for '/'-passwords) is not.
    func testAtSignInPathWithoutUserinfoOverMasks() {
        XCTAssertEqual(
            Credentials.redact("rest:https://host.example/weird@folder/"),
            "rest:https://***@folder/")
    }

    func testNoUserinfoLeavesURLUnchanged() {
        let url = "rest:https://host.example/repo/"
        XCTAssertEqual(Credentials.redact(url), url)
    }

    func testNonURLStringLeftUnchanged() {
        XCTAssertEqual(Credentials.redact("not-a-url"), "not-a-url")
        XCTAssertEqual(Credentials.redact(""), "")
    }

    // MARK: - redactMonitorURL (heartbeat / ntfy / webhook URLs)

    // Unlike a restic repo URL, a monitor URL's secret usually sits in the PATH
    // (an ntfy topic name, a Healthchecks UUID) or the QUERY (a webhook token) —
    // not a clearly-scoped userinfo. So this masks everything past the host.
    func testRedactMonitorURLMasksPathAndQuery() {
        XCTAssertEqual(
            Credentials.redactMonitorURL("https://hc-ping.com/2c4d5e6f-uuid"),
            "https://hc-ping.com/***")
        XCTAssertEqual(
            Credentials.redactMonitorURL("https://ntfy.sh/my-secret-topic-name"),
            "https://ntfy.sh/***")
        XCTAssertEqual(
            Credentials.redactMonitorURL("https://gatus.example/api/v1/push?token=abc123"),
            "https://gatus.example/***")
    }

    func testRedactMonitorURLKeepsSchemeHostAndPort() {
        XCTAssertEqual(
            Credentials.redactMonitorURL("http://localhost:8080/ping/uuid"),
            "http://localhost:8080/***")
    }

    func testRedactMonitorURLUnchangedForNonURLString() {
        XCTAssertEqual(Credentials.redactMonitorURL("not-a-url"), "not-a-url")
        XCTAssertEqual(Credentials.redactMonitorURL(""), "")
    }
}
