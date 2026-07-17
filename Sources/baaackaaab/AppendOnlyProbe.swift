import Foundation

// Active verification of the single most important safety property this tool
// depends on: that a `rest:` destination's server actually runs in
// `--append-only` mode, so a compromised Mac cannot delete backup data. Until
// now that property was only documented — a rest-server accidentally started
// WITHOUT `--append-only` looks byte-for-byte identical to a correctly
// configured one from every other check `--doctor` runs (it still answers
// reads, still accepts backups). This probes it directly.
//
// The probe: issue an HTTP DELETE against a guaranteed-absent object under
// the repo's `data/` prefix. rest-server in append-only mode rejects EVERY
// delete with 403, before it even checks whether the object exists — so a
// 403 on a nonexistent object proves enforcement. A 404 means the server
// actually evaluated (and would have performed) the delete, i.e. it is NOT
// append-only (or we probed the wrong repo path).
//
// Non-destructive BY CONSTRUCTION: `probeObjectName` is a fixed, hand-picked
// hex pattern, never a real pack id (restic pack ids are SHA-256 hashes of
// pack contents, so this can never collide with real data) and never
// randomized (a random name would be just as safe here, but a fixed constant
// is reproducible and auditable). The probe only ever targets `data/` — never
// `locks/` (legitimately deletable by `--unlock`) or any real object name.
enum AppendOnlyProbe {

    /// 64 lowercase hex characters, deliberately a fixed repeating pattern
    /// rather than a random or real-looking id — restic pack ids are content
    /// hashes, so this can never equal a real one, and a constant means every
    /// run (and every reader of this source) probes the exact same object.
    static let probeObjectName = String(repeating: "ba", count: 32)

    /// The outcome of one probe DELETE, and the actionable message for it.
    /// Pure — derived only from the HTTP status code (nil on a network-level
    /// failure), so it is exhaustively unit-testable without touching a
    /// network.
    enum Verdict: Equatable {
        /// 403 — the server rejected the delete outright. Append-only holds.
        case enforced
        /// 404 or any 2xx — the server considered or accepted the delete.
        /// This is a HARD FINDING: the ransomware guarantee is not in force.
        case notEnforced(Int)
        /// 401 — the probe's own credentials were rejected; enforcement
        /// could not be checked at all.
        case authProblem
        /// A network error or timeout — consistent with how doctor already
        /// handles an unreachable destination elsewhere: informational, not
        /// a finding, the probe is simply skipped.
        case unreachable
        /// Any other status code — doesn't match a known rest-server
        /// response, so the probe result is inconclusive rather than guessed.
        case inconclusive(Int)

        /// Whether this verdict is a blocking problem (counts toward
        /// doctor's exit-non-zero verdict), matching the other hard failures
        /// doctor already tracks (missing restic, unreachable destination, …).
        var isProblem: Bool {
            if case .notEnforced = self { return true }
            return false
        }

        var message: String {
            switch self {
            case .enforced:
                return "append-only enforced — the probe DELETE was rejected with 403"
            case .notEnforced(let code):
                return "server is NOT in --append-only mode (or wrong repo) — the ransomware guarantee is not in force; restart rest-server with --append-only (probe DELETE returned \(code))"
            case .authProblem:
                return "probe DELETE got 401 — check the htpasswd entry for this destination; append-only enforcement could not be verified"
            case .unreachable:
                return "unreachable — append-only probe skipped"
            case .inconclusive(let code):
                return "probe DELETE returned unexpected status \(code) — append-only enforcement could not be verified"
            }
        }
    }

    /// Classify a probe response's HTTP status code (nil for a network-level
    /// failure) into a `Verdict`. This is the entire decision — kept separate
    /// from the URLSession call so it can be tested exhaustively without a
    /// network. rest-server checks the append-only flag BEFORE existence, so
    /// 403 vs. 404 is a clean signal regardless of whether the probe object
    /// happens to exist (it never does, by construction).
    static func classify(statusCode: Int?) -> Verdict {
        guard let statusCode else { return .unreachable }
        switch statusCode {
        case 403: return .enforced
        case 401: return .authProblem
        case 404, 200...299: return .notEnforced(statusCode)
        default: return .inconclusive(statusCode)
        }
    }

    /// The DELETE probe target derived from a `rest:` repo URL: the object
    /// URL under `data/`, and the Basic-Auth header built directly from the
    /// embedded credentials. The header is base64 of `user:password`, exactly
    /// what rest-server's Basic Auth expects; it is computed once here and
    /// the credentials are never re-embedded into a URL string (which is why
    /// `target.url` never contains the password), so it can't leak into a
    /// logged request line. Callers must never print `authorizationHeader`.
    struct Target: Equatable {
        let url: URL
        let authorizationHeader: String
    }

    /// Parse a `rest:` repo URL into a probe `Target`, or nil for a
    /// non-`rest:` backend — there is nothing to probe at the protocol level
    /// there (see the README's backend-agnostic caveat: immutability on
    /// s3:/b2:/sftp:/a local path must come from the storage layer instead).
    /// Reuses `Credentials.userinfoDelimiter` — the same boundary rule the
    /// log redactor and `UpdateCheck.restEndpoint` use — so a password
    /// containing '@' or a raw '/' is split identically everywhere.
    static func target(from repoURL: String) -> Target? {
        guard repoURL.hasPrefix("rest:") else { return nil }
        let raw = repoURL.dropFirst("rest:".count)
        guard let schemeSep = raw.range(of: "://") else { return nil }
        let scheme = String(raw[raw.startIndex..<schemeSep.lowerBound])
        guard scheme == "http" || scheme == "https" else { return nil }
        let afterScheme = raw[schemeSep.upperBound...]
        guard let at = Credentials.userinfoDelimiter(in: afterScheme) else { return nil }
        let userinfo = afterScheme[afterScheme.startIndex..<at]
        let hostAndPath = afterScheme[afterScheme.index(after: at)...]
        guard !hostAndPath.isEmpty else { return nil }

        let user: Substring
        let password: Substring
        if let colon = userinfo.firstIndex(of: ":") {
            user = userinfo[userinfo.startIndex..<colon]
            password = userinfo[userinfo.index(after: colon)...]
        } else {
            user = userinfo
            password = ""
        }

        // The repo path (the private-repos subpath, e.g. "macbook/") is part
        // of hostAndPath and stays IN the probed URL — unlike UpdateCheck's
        // bare-host header probe, the append-only check must hit the actual
        // repo's object namespace, not just the host.
        var base = "\(scheme)://\(hostAndPath)"
        if !base.hasSuffix("/") { base += "/" }
        guard let url = URL(string: base + "data/" + probeObjectName) else { return nil }

        let authValue = "Basic " + Data("\(user):\(password)".utf8).base64EncodedString()
        return Target(url: url, authorizationHeader: authValue)
    }

    /// Issue the actual network probe. NOT unit-tested (touches the network,
    /// same as `UpdateCheck.restServerInstalled`) — it degrades to
    /// `.unreachable` on any failure by construction, so a dead or firewalled
    /// server is reported gracefully rather than failing doctor outright.
    /// Bounded to `timeout` seconds so one wedged destination can't stall the
    /// whole doctor run.
    static func probe(_ target: Target, timeout: TimeInterval = 10) -> Verdict {
        var request = URLRequest(url: target.url)
        request.httpMethod = "DELETE"
        request.timeoutInterval = timeout
        request.setValue(target.authorizationHeader, forHTTPHeaderField: "Authorization")
        request.setValue("baaackaaab", forHTTPHeaderField: "User-Agent")
        let box = SyncBox<Int?>(nil)
        let sem = DispatchSemaphore(value: 0)
        let task = URLSession.shared.dataTask(with: request) { _, response, _ in
            box.value = (response as? HTTPURLResponse)?.statusCode
            sem.signal()
        }
        task.resume()
        if sem.wait(timeout: .now() + timeout + 2) == .timedOut {
            task.cancel()
            return .unreachable
        }
        return classify(statusCode: box.value)
    }
}
