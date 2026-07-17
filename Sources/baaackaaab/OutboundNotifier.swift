import Foundation

// Outbound monitoring & push, on top of the local macOS banner (Notifier.swift).
// The banner is invisible when the user is away from the Mac; nothing in the
// tool today can tell "a run failed" from "the Mac never even tried" — that
// needs a monitor-side dead-man's switch, not a local notification.
//
// Two channel kinds:
//   * heartbeat: a Healthchecks-style ping URL. GET <url>/start at run begin,
//     GET <url> on success, GET <url>/fail on failure. The absence of a ping is
//     the alarm — it fires on the MONITOR side, so it also catches "the machine
//     never ran the backup at all" (crashed, unplugged, timer disabled).
//   * push (ntfy / webhook): the run outcome pushed to a phone/webhook so a
//     failure is seen away from the Mac.
//
// Strictly best-effort by contract: a delivery failure NEVER changes the run's
// outcome/exit code, matching Notifier's macOS-banner contract and the
// UpdateCheck "degrades gracefully" philosophy. Sends are fire-and-forget from
// the run's perspective, bounded by `waitForPending` so they actually leave
// before the process calls `exit()` — a bare `exit()` kills in-flight requests.

/// A configured push channel, persisted in the backup set.
struct NotifyChannel: Codable, Equatable {
    enum Kind: String, Codable, Equatable {
        case ntfy
        case webhook
        case gotify
    }
    var type: Kind
    var url: String
}

enum OutboundNotifier {
    private static let timeout: TimeInterval = 10

    // MARK: - Validation

    /// Whether `raw` is a well-formed http(s) URL with a host — the gate for
    /// `--set-heartbeat` / `--add-ntfy` / `--add-webhook`. Pure, no network.
    static func isValidHTTPURL(_ raw: String) -> Bool {
        guard let comps = URLComponents(string: raw), let scheme = comps.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = comps.host, !host.isEmpty else { return false }
        return true
    }

    // MARK: - Heartbeat URL construction

    enum HeartbeatEvent {
        case start, success, fail

        /// The Healthchecks convention: /start begins a run, a bare ping means
        /// success, /fail means failure. Self-hosted Gatus/Uptime-Kuma monitors
        /// that speak the same convention work identically.
        var pathSuffix: String {
            switch self {
            case .start:   return "/start"
            case .success: return ""
            case .fail:    return "/fail"
            }
        }
    }

    /// Append the event suffix to the URL's PATH (never the query string), so a
    /// monitor URL that already carries its own query parameters (an auth token,
    /// a Gatus check id) still pings the right endpoint. A single trailing slash
    /// on the base is trimmed first so it can't produce a doubled slash. nil when
    /// `base` isn't a well-formed http(s) URL — `URLComponents` alone is too
    /// lenient (it happily percent-encodes "not a url" into a relative path
    /// instead of failing), so this gates on `isValidHTTPURL` first. That matters
    /// beyond defense-in-depth: a hand-edited backup-set.json bypasses the
    /// `--set-heartbeat` CLI validation entirely, so this is the last check.
    static func heartbeatURL(base: String, event: HeartbeatEvent) -> URL? {
        guard isValidHTTPURL(base), var comps = URLComponents(string: base) else { return nil }
        var path = comps.path
        if path.hasSuffix("/") { path.removeLast() }
        comps.path = path + event.pathSuffix
        return comps.url
    }

    static func heartbeatRequest(base: String, event: HeartbeatEvent) -> URLRequest? {
        guard let url = heartbeatURL(base: base, event: event) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = timeout
        req.setValue("baaackaaab", forHTTPHeaderField: "User-Agent")
        return req
    }

    // MARK: - ntfy

    /// A plain-text ntfy push: the body IS the human summary (the same message
    /// Notifier's banner shows), with a `Title:` header and, on failure, a `high`
    /// priority so it actually interrupts the phone.
    static func ntfyRequest(url: String, title: String, body: String, priorityHigh: Bool) -> URLRequest? {
        guard isValidHTTPURL(url), let u = URL(string: url) else { return nil }
        var req = URLRequest(url: u)
        req.httpMethod = "POST"
        req.httpBody = Data(body.utf8)
        req.timeoutInterval = timeout
        req.setValue(title, forHTTPHeaderField: "Title")
        if priorityHigh { req.setValue("high", forHTTPHeaderField: "Priority") }
        return req
    }

    // MARK: - gotify

    /// The Gotify push body: `{title, message, priority}`. The app token is NOT
    /// here — it rides in the URL's `?token=` the operator configured, matching
    /// how ntfy/webhook carry their secret in the URL.
    struct GotifyPayload: Codable, Equatable {
        let title: String
        let message: String
        let priority: Int
    }

    /// Build the Gotify push endpoint from a server base URL + app token:
    /// `<base>/message?token=<token>`. Accepts either the server root
    /// (`https://gotify.example.com`) or a URL that already ends in `/message`,
    /// and trims one trailing slash — so the common path is "paste the token",
    /// not "hand-assemble the URL". The token is not percent-encoded: Gotify's
    /// generated app tokens are drawn from a URL-safe alphabet ([A-Za-z0-9._-]).
    static func gotifyEndpoint(base: String, token: String) -> String {
        var b = base.trimmingCharacters(in: .whitespacesAndNewlines)
        if b.hasSuffix("/") { b.removeLast() }
        if !b.hasSuffix("/message") { b += "/message" }
        return b + "?token=" + token.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A Gotify push: JSON `{title, message, priority}` POSTed to the app's
    /// `/message?token=…` endpoint. Priority follows Gotify's 0–10 scale — 8 on
    /// failure so it interrupts the phone, 4 on success so it stays a quiet log
    /// entry, matching ntfy's high/default split.
    static func gotifyRequest(url: String, title: String, body: String, priorityHigh: Bool) -> URLRequest? {
        guard isValidHTTPURL(url), let u = URL(string: url),
              let data = try? JSONEncoder().encode(
                GotifyPayload(title: title, message: body, priority: priorityHigh ? 8 : 4)) else { return nil }
        var req = URLRequest(url: u)
        req.httpMethod = "POST"
        req.httpBody = data
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return req
    }

    // MARK: - webhook

    /// The webhook payload: status only, never a repo URL, a path, or a
    /// credential-file location — `destinations` deliberately carries only
    /// name + ok, not the (already-redacted, but still unnecessary) error text.
    struct WebhookPayload: Codable, Equatable {
        struct DestStatus: Codable, Equatable {
            let name: String
            let ok: Bool
        }
        let event: String
        let outcome: String
        let started: String
        let finished: String
        let verified: Int
        let total: Int
        let destinations: [DestStatus]
        let message: String
    }

    static func webhookRequest(url: String, payload: WebhookPayload) -> URLRequest? {
        guard isValidHTTPURL(url), let u = URL(string: url),
              let body = try? JSONEncoder().encode(payload) else { return nil }
        var req = URLRequest(url: u)
        req.httpMethod = "POST"
        req.httpBody = body
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return req
    }

    static func iso8601(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    // MARK: - Sending

    /// One outcome of a delivery attempt, for `--test-notify`'s per-channel
    /// report. `detail` is always an actionable fragment ("HTTP 404", "timed out
    /// after 10s", a network error description).
    struct DeliveryResult {
        let ok: Bool
        let detail: String
    }

    /// Refuses to follow any redirect — SSRF discipline for a webhook/heartbeat
    /// URL the operator configured: baaackaaab must never be turned into a proxy
    /// that follows a redirect to an internal address by a compromised monitor.
    private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                         willPerformHTTPRedirection response: HTTPURLResponse,
                         newRequest request: URLRequest,
                         completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        return URLSession(configuration: config, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }()

    /// Perform one request and block for the result, bounded by `timeout` + 2s
    /// slack — the same synchronous network-call bridge UpdateCheck uses
    /// (SyncBox + semaphore). Used by `--test-notify`, which needs to actually
    /// report delivered/failed per channel rather than fire-and-forget.
    static func perform(_ request: URLRequest) -> DeliveryResult {
        let box = SyncBox<DeliveryResult>(DeliveryResult(ok: false, detail: "no response"))
        let sem = DispatchSemaphore(value: 0)
        let task = session.dataTask(with: request) { _, response, error in
            if let error {
                box.value = DeliveryResult(ok: false, detail: error.localizedDescription)
            } else if let http = response as? HTTPURLResponse {
                if (200...299).contains(http.statusCode) {
                    box.value = DeliveryResult(ok: true, detail: "delivered (HTTP \(http.statusCode))")
                } else {
                    box.value = DeliveryResult(ok: false, detail: "HTTP \(http.statusCode)")
                }
            }
            sem.signal()
        }
        task.resume()
        if sem.wait(timeout: .now() + timeout + 2) == .timedOut {
            task.cancel()
            return DeliveryResult(ok: false, detail: "timed out after \(Int(timeout))s")
        }
        return box.value
    }

    /// Outstanding fire-and-forget sends, so `waitForPending` can give them a
    /// bounded chance to actually leave before the process calls `exit()`.
    private static let pending = DispatchGroup()

    private static func fireAndForget(_ request: URLRequest, onFailure: @escaping @Sendable (DeliveryResult) -> String) {
        pending.enter()
        DispatchQueue.global(qos: .utility).async {
            let result = perform(request)
            if !result.ok { Console.note(onFailure(result)) }
            pending.leave()
        }
    }

    /// Fire a heartbeat ping in the background. Silently a no-op on a malformed
    /// URL (validated at add-time; this is defense in depth, never fails a run).
    static func fireHeartbeat(base: String, event: HeartbeatEvent) {
        guard let req = heartbeatRequest(base: base, event: event) else { return }
        let redacted = Credentials.redactMonitorURL(base)
        fireAndForget(req) { "heartbeat delivery failed (\(redacted)): \($0.detail)" }
    }

    /// Push the run outcome to every configured channel, in the background.
    static func pushOutcome(
        channels: [NotifyChannel], ok: Bool, message: String,
        started: Date, finished: Date, verified: Int, total: Int,
        destinations: [(name: String, ok: Bool)]
    ) {
        let title = "baaackaaab backup \(ok ? "succeeded" : "failed")"
        for channel in channels {
            let redacted = Credentials.redactMonitorURL(channel.url)
            switch channel.type {
            case .ntfy:
                guard let req = ntfyRequest(url: channel.url, title: title, body: message, priorityHigh: !ok) else {
                    Console.note("ntfy channel has a malformed URL, skipping: \(redacted)")
                    continue
                }
                fireAndForget(req) { "ntfy delivery failed (\(redacted)): \($0.detail)" }
            case .gotify:
                guard let req = gotifyRequest(url: channel.url, title: title, body: message, priorityHigh: !ok) else {
                    Console.note("gotify channel has a malformed URL, skipping: \(redacted)")
                    continue
                }
                fireAndForget(req) { "gotify delivery failed (\(redacted)): \($0.detail)" }
            case .webhook:
                let payload = WebhookPayload(
                    event: "backup_run", outcome: ok ? "success" : "failure",
                    started: iso8601(started), finished: iso8601(finished),
                    verified: verified, total: total,
                    destinations: destinations.map { WebhookPayload.DestStatus(name: $0.name, ok: $0.ok) },
                    message: message)
                guard let req = webhookRequest(url: channel.url, payload: payload) else {
                    Console.note("webhook channel has a malformed URL, skipping: \(redacted)")
                    continue
                }
                fireAndForget(req) { "webhook delivery failed (\(redacted)): \($0.detail)" }
            }
        }
    }

    /// Block until every outstanding fire-and-forget send finishes or `timeout`
    /// elapses — called right before a terminal `exit()` so a ping/push actually
    /// leaves instead of being killed mid-flight.
    static func waitForPending(timeout: TimeInterval = 12) {
        _ = pending.wait(timeout: .now() + timeout)
    }
}

// MARK: - --test-notify

/// Prove the alerting path works before it is relied on: fires a clearly-marked
/// sample message through every configured channel AND a heartbeat success ping,
/// SYNCHRONOUSLY (unlike the fire-and-forget path a real run uses) so it can
/// report exactly what got delivered and what didn't.
func testNotifyCommand(configPath: URL) {
    Console.banner("baaackaaab", tagline: "test notify")
    guard FileManager.default.fileExists(atPath: configPath.path) else {
        Console.error("no backup set at \(configPath.path) — configure a channel first: --set-heartbeat <url>, --add-ntfy <url>, --add-gotify <server-url>, or --add-webhook <url>")
        exit(1)
    }
    let set: BackupSet
    do { set = try BackupSet.load(from: configPath) }
    catch {
        Console.error("backup set at \(configPath.path) is unreadable — fix or delete it: \(error)")
        exit(1)
    }
    guard set.heartbeatURL != nil || !set.notifyChannels.isEmpty else {
        Console.error("no heartbeat or notify channel configured — add one first: --set-heartbeat <url>, --add-ntfy <url>, --add-gotify <server-url>, or --add-webhook <url>")
        exit(1)
    }

    Console.section("Channels")
    var failures = 0
    let now = Date()
    let sampleMessage = "[TEST] baaackaaab sample notification — this is a --test-notify drill, not a real backup outcome"

    func report(label: String, url: String, result: OutboundNotifier.DeliveryResult) {
        let redacted = Credentials.redactMonitorURL(url)
        if result.ok {
            Console.success("\(label) (\(redacted)) — \(result.detail)")
            return
        }
        failures += 1
        let hint = label == "ntfy" ? "check the topic URL is correct"
                  : label == "gotify" ? "check the server URL and app token are correct"
                  : label == "webhook" ? "check the webhook URL is correct and reachable"
                  : "check the heartbeat URL is correct and reachable"
        Console.failure("\(label) (\(redacted)) — \(result.detail); \(hint)")
    }

    if let hb = set.heartbeatURL {
        if let req = OutboundNotifier.heartbeatRequest(base: hb, event: .success) {
            report(label: "heartbeat", url: hb, result: OutboundNotifier.perform(req))
        } else {
            failures += 1
            Console.failure("heartbeat (\(Credentials.redactMonitorURL(hb))) — malformed URL")
        }
    }

    for channel in set.notifyChannels {
        let request: URLRequest?
        switch channel.type {
        case .ntfy:
            request = OutboundNotifier.ntfyRequest(
                url: channel.url, title: "baaackaaab test notification", body: sampleMessage, priorityHigh: false)
        case .gotify:
            request = OutboundNotifier.gotifyRequest(
                url: channel.url, title: "baaackaaab test notification", body: sampleMessage, priorityHigh: false)
        case .webhook:
            let payload = OutboundNotifier.WebhookPayload(
                event: "test", outcome: "test",
                started: OutboundNotifier.iso8601(now), finished: OutboundNotifier.iso8601(now),
                verified: 0, total: 0, destinations: [], message: sampleMessage)
            request = OutboundNotifier.webhookRequest(url: channel.url, payload: payload)
        }
        guard let request else {
            failures += 1
            Console.failure("\(channel.type.rawValue) (\(Credentials.redactMonitorURL(channel.url))) — malformed URL")
            continue
        }
        report(label: channel.type.rawValue, url: channel.url, result: OutboundNotifier.perform(request))
    }

    Console.section("Summary")
    if failures == 0 {
        Console.success("all channel(s) delivered — the alerting path is proven")
    } else {
        Console.failure("\(failures) channel(s) failed to deliver — see above")
        exit(1)
    }
}
