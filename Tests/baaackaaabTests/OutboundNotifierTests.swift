import XCTest
@testable import baaackaaab

// Outbound monitoring's network sends are untested by design (they degrade to a
// logged, best-effort no-op — the same precedent as UpdateCheck's live GitHub
// query and HTTP header probe). What IS pinned here is every pure piece around
// them: URL/request construction, JSON payload shape, and the redaction that
// keeps a monitor URL's embedded token out of `--list` / logs.
final class OutboundNotifierTests: XCTestCase {

    // MARK: - isValidHTTPURL

    func testValidHTTPURLAcceptsHTTPAndHTTPS() {
        XCTAssertTrue(OutboundNotifier.isValidHTTPURL("https://hc-ping.com/uuid"))
        XCTAssertTrue(OutboundNotifier.isValidHTTPURL("http://localhost:8080/ping"))
    }

    func testValidHTTPURLRejectsOtherSchemesAndMalformed() {
        XCTAssertFalse(OutboundNotifier.isValidHTTPURL("ftp://host/path"))
        XCTAssertFalse(OutboundNotifier.isValidHTTPURL("not-a-url"))
        XCTAssertFalse(OutboundNotifier.isValidHTTPURL(""))
        XCTAssertFalse(OutboundNotifier.isValidHTTPURL("https://"))          // no host
        XCTAssertFalse(OutboundNotifier.isValidHTTPURL("javascript:alert(1)"))
    }

    // MARK: - heartbeatURL suffixing

    func testHeartbeatURLAppendsSuffixToPlainURL() {
        XCTAssertEqual(
            OutboundNotifier.heartbeatURL(base: "https://hc-ping.com/uuid", event: .start)?.absoluteString,
            "https://hc-ping.com/uuid/start")
        XCTAssertEqual(
            OutboundNotifier.heartbeatURL(base: "https://hc-ping.com/uuid", event: .fail)?.absoluteString,
            "https://hc-ping.com/uuid/fail")
    }

    // A bare success ping adds no suffix at all — the Healthchecks convention.
    func testHeartbeatURLSuccessAddsNoSuffix() {
        XCTAssertEqual(
            OutboundNotifier.heartbeatURL(base: "https://hc-ping.com/uuid", event: .success)?.absoluteString,
            "https://hc-ping.com/uuid")
    }

    // The suffix goes on the PATH, never the query string — a self-hosted
    // monitor's URL commonly carries its own auth token as a query parameter.
    func testHeartbeatURLPreservesQueryString() {
        XCTAssertEqual(
            OutboundNotifier.heartbeatURL(base: "https://gatus.example/api/v1/push?token=abc123", event: .start)?.absoluteString,
            "https://gatus.example/api/v1/push/start?token=abc123")
    }

    // A trailing slash on the base must not produce a doubled slash.
    func testHeartbeatURLTrimsOneTrailingSlashBeforeSuffixing() {
        XCTAssertEqual(
            OutboundNotifier.heartbeatURL(base: "https://hc-ping.com/uuid/", event: .fail)?.absoluteString,
            "https://hc-ping.com/uuid/fail")
    }

    func testHeartbeatURLNilForMalformedBase() {
        XCTAssertNil(OutboundNotifier.heartbeatURL(base: "", event: .start))
    }

    func testHeartbeatRequestIsGETWithUserAgent() {
        let req = OutboundNotifier.heartbeatRequest(base: "https://hc-ping.com/uuid", event: .start)
        XCTAssertEqual(req?.httpMethod, "GET")
        XCTAssertEqual(req?.url?.absoluteString, "https://hc-ping.com/uuid/start")
        XCTAssertEqual(req?.value(forHTTPHeaderField: "User-Agent"), "baaackaaab")
    }

    // MARK: - ntfy request

    func testNtfyRequestIsPlainTextPOSTWithTitleHeader() {
        let req = OutboundNotifier.ntfyRequest(
            url: "https://ntfy.sh/mytopic", title: "baaackaaab backup failed",
            body: "1/3 verified — 2 item(s) failed verification", priorityHigh: false)
        XCTAssertEqual(req?.httpMethod, "POST")
        XCTAssertEqual(req?.value(forHTTPHeaderField: "Title"), "baaackaaab backup failed")
        XCTAssertNil(req?.value(forHTTPHeaderField: "Priority"))
        XCTAssertEqual(req.flatMap { $0.httpBody.flatMap { String(data: $0, encoding: .utf8) } },
                       "1/3 verified — 2 item(s) failed verification")
    }

    func testNtfyRequestSetsHighPriorityOnFailure() {
        let req = OutboundNotifier.ntfyRequest(url: "https://ntfy.sh/mytopic", title: "t", body: "b", priorityHigh: true)
        XCTAssertEqual(req?.value(forHTTPHeaderField: "Priority"), "high")
    }

    func testNtfyRequestNilForMalformedURL() {
        XCTAssertNil(OutboundNotifier.ntfyRequest(url: "not a url", title: "t", body: "b", priorityHigh: false))
    }

    // MARK: - webhook request / payload shape

    func testWebhookRequestIsJSONPOST() {
        let payload = OutboundNotifier.WebhookPayload(
            event: "backup_run", outcome: "success",
            started: "2026-07-17T09:00:00Z", finished: "2026-07-17T09:05:00Z",
            verified: 3, total: 3,
            destinations: [.init(name: "default", ok: true)],
            message: "3/3 verified to 1 destination(s)")
        let req = OutboundNotifier.webhookRequest(url: "https://example.com/hook", payload: payload)
        XCTAssertEqual(req?.httpMethod, "POST")
        XCTAssertEqual(req?.value(forHTTPHeaderField: "Content-Type"), "application/json")
        guard let body = req?.httpBody else { return XCTFail("missing body") }
        let decoded = try! JSONDecoder().decode(OutboundNotifier.WebhookPayload.self, from: body)
        XCTAssertEqual(decoded, payload)
    }

    // The privacy contract: the payload never carries a repo URL or a path — only
    // status. Pinning the exact field set catches an accidental future addition
    // of something sensitive (e.g. a destination's error text or repo URL).
    func testWebhookPayloadDestinationsCarryOnlyNameAndOk() {
        let payload = OutboundNotifier.WebhookPayload(
            event: "backup_run", outcome: "failure", started: "s", finished: "f",
            verified: 0, total: 2, destinations: [.init(name: "offsite", ok: false)],
            message: "no destination could be initialized — nothing was backed up")
        let data = try! JSONEncoder().encode(payload)
        let json = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        let dests = json["destinations"] as! [[String: Any]]
        XCTAssertEqual(Set(dests[0].keys), Set(["name", "ok"]))
        XCTAssertEqual(Set(json.keys), Set(["event", "outcome", "started", "finished", "verified", "total", "destinations", "message"]))
    }

    func testWebhookRequestNilForMalformedURL() {
        let payload = OutboundNotifier.WebhookPayload(
            event: "e", outcome: "o", started: "s", finished: "f",
            verified: 0, total: 0, destinations: [], message: "m")
        XCTAssertNil(OutboundNotifier.webhookRequest(url: "not a url", payload: payload))
    }

    // MARK: - NotifyChannel round-trip

    func testNotifyChannelDecodesTypeAndURL() throws {
        let json = #"{ "type": "ntfy", "url": "https://ntfy.sh/mytopic" }"#
        let channel = try JSONDecoder().decode(NotifyChannel.self, from: Data(json.utf8))
        XCTAssertEqual(channel.type, .ntfy)
        XCTAssertEqual(channel.url, "https://ntfy.sh/mytopic")
    }

    func testNotifyChannelWebhookKind() throws {
        let json = #"{ "type": "webhook", "url": "https://example.com/hook" }"#
        let channel = try JSONDecoder().decode(NotifyChannel.self, from: Data(json.utf8))
        XCTAssertEqual(channel.type, .webhook)
    }
}
