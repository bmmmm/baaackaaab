import Foundation
#if canImport(Darwin)
import Darwin
#endif

// Update awareness for the two components baaackaaab leans on: the local `restic`
// CLI and the remote restic REST server. Two layers, deliberately separated so the
// DEFAULT path never reaches out to the public internet:
//
//   * OFFLINE BASELINE (the default — used by --doctor and the unattended run):
//     compare the installed version against a version pinned in THIS source, the
//     newest release baaackaaab is developed + tested against. No GitHub. "You are
//     behind the tested baseline" is a local, deterministic verdict — for restic it
//     needs no network at all, for the server it reuses the host the tool already
//     talks to.
//
//   * ONLINE LATEST (opt-in — `--check-updates`): additionally ask the GitHub
//     releases API what the newest upstream release actually is, and compare. This
//     is the ONLY path that contacts api.github.com, so it never runs unless the
//     operator explicitly asks for it; if GitHub is unreachable it degrades to the
//     offline baseline rather than failing.
//
// The local restic version is read locally (`restic version`). The REST server's
// installed version is, in the normal case, NOT discoverable from the Mac — the
// rest-server does not advertise it — so the server check is best-effort: it probes
// the HTTP `Server` response header (a reverse-proxy front sometimes exposes it)
// and, failing that, is honest about not knowing. Nothing here is ever a hard
// failure: being behind is informational, and an unreachable check is a no-op.

/// A minimal semantic version (major.minor.patch) with the comparison and parsing
/// baaackaaab needs — enough to answer "is the installed one older than the
/// reference one?". Pre-release / build metadata is ignored (a trailing "-rc.1"
/// compares as its release), which is the right behaviour for an "are you behind?"
/// gauge. Comparable + Equatable are synthesized from the three components.
struct SemVer: Comparable, Equatable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int

    init(_ major: Int, _ minor: Int, _ patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// Extract the first `MAJOR.MINOR[.PATCH]` run from arbitrary text, so it parses
    /// "restic 0.18.0 compiled with go1.21.5 on darwin/arm64", "v0.19.0", "0.13",
    /// "rest-server/0.13.0", or a bare "0.18.0". At least MAJOR.MINOR is required
    /// (restic / rest-server always carry a minor); a missing patch defaults to 0.
    /// nil when no version-looking token is present.
    init?(parsing raw: String) {
        func isDigit(_ c: Character) -> Bool { c >= "0" && c <= "9" }
        let chars = Array(raw)
        var i = 0
        while i < chars.count {
            guard isDigit(chars[i]) else { i += 1; continue }
            var comps: [Int] = []
            var j = i
            readRun: while j < chars.count {
                var num = 0
                var any = false
                while j < chars.count, isDigit(chars[j]) {
                    let d = chars[j].wholeNumberValue ?? 0
                    // Swift traps on Int overflow, and this input can be
                    // remote-controlled (the HTTP `Server` header, a GitHub
                    // tag_name): a ≥19-digit run must clamp to Int.max, not
                    // crash the whole informational check.
                    num = num <= (Int.max - d) / 10 ? num * 10 + d : Int.max
                    any = true
                    j += 1
                }
                guard any else { break readRun }
                comps.append(num)
                // A '.' followed by another digit continues the version; anything
                // else (space, slash, end, a lone dot) ends it.
                if j + 1 < chars.count, chars[j] == ".", isDigit(chars[j + 1]) {
                    j += 1   // consume the dot; the loop reads the next number
                } else {
                    break readRun
                }
            }
            if comps.count >= 2 {
                self.major = comps[0]
                self.minor = comps[1]
                self.patch = comps.count >= 3 ? comps[2] : 0
                return
            }
            i = max(j, i + 1)   // skip past this too-short run, keep scanning
        }
        return nil
    }

    var description: String { "\(major).\(minor).\(patch)" }

    static func < (l: SemVer, r: SemVer) -> Bool {
        (l.major, l.minor, l.patch) < (r.major, r.minor, r.patch)
    }
}

enum UpdateCheck {
    /// The versions baaackaaab is developed + tested against. Bump these
    /// deliberately once a newer release has been validated; an installed component
    /// older than its baseline earns a "behind the tested baseline" notice. Offline
    /// — comparing against these needs no network. (restic: README "developed
    /// against restic 0.19"; rest-server: the current stable line.)
    static let resticBaseline = SemVer(0, 19, 0)
    static let restServerBaseline = SemVer(0, 14, 0)

    /// GitHub repos queried for the newest release on the opt-in online path.
    static let resticRepo = "restic/restic"
    static let restServerRepo = "restic/rest-server"

    /// Where a finding's reference version came from — a version pinned in source
    /// (offline) or the latest release pulled from GitHub (online).
    enum ReferenceKind { case baseline, latest }

    /// How an installed version stands against a reference. Either side may be
    /// missing, and the verdict names which, so the caller can phrase an honest,
    /// actionable line instead of inventing a comparison. Pure + unit-tested.
    enum Verdict: Equatable {
        case upToDate
        case behind(SemVer, SemVer)   // installed, reference
        case unknownInstalled         // couldn't read the installed version
        case unknownReference         // couldn't determine the reference version
    }

    /// The pure comparison at the heart of every check. Behind == strictly older
    /// than the reference; equal or newer is up to date.
    static func verdict(installed: SemVer?, reference: SemVer?) -> Verdict {
        guard let installed else { return .unknownInstalled }
        guard let reference else { return .unknownReference }
        return installed < reference ? .behind(installed, reference) : .upToDate
    }

    /// One component's currency, ready to render. `unavailableNote` is the
    /// component-appropriate line shown when the installed version can't be read.
    struct Finding {
        let component: String
        let installed: SemVer?
        let reference: SemVer?
        let referenceKind: ReferenceKind
        let unavailableNote: String

        var verdict: Verdict { UpdateCheck.verdict(installed: installed, reference: reference) }

        /// Print this finding through Console, and report whether it is a concern
        /// (strictly behind the reference). An unknown installed/reference version
        /// is informational, not a concern — we never warn about what we can't see.
        @discardableResult
        func emit() -> Bool {
            let refLabel = referenceKind == .latest ? "latest release" : "tested baseline"
            switch verdict {
            case .upToDate:
                Console.success("\(component) \(installed!) — current (\(refLabel) \(reference!))")
                return false
            case .behind(let inst, let ref):
                Console.warn("\(component) \(inst) — update available: \(ref) (\(refLabel))")
                return true
            case .unknownInstalled:
                Console.note("\(component): \(unavailableNote)")
                if let ref = reference { Console.detail("\(refLabel): \(ref)") }
                return false
            case .unknownReference:
                let inst = installed.map { "\($0)" } ?? "?"
                Console.note("\(component) \(inst): could not determine the \(refLabel) (offline?)")
                return false
            }
        }

        /// A short fragment for the macOS banner when this component is behind, else
        /// nil. Kept terse — banners truncate.
        var bannerFragment: String? {
            if case .behind(let inst, let ref) = verdict { return "\(component) \(inst) < \(ref)" }
            return nil
        }
    }

    // MARK: - Installed-version detection

    /// The installed restic CLI version, parsed from `restic version`. nil when
    /// restic is missing or the version line didn't parse. Local — no network.
    static func resticInstalled() -> SemVer? {
        ResticBackend.resticVersion().flatMap { SemVer(parsing: $0) }
    }

    /// Best-effort installed REST-server version, read from the HTTP `Server`
    /// response header of the repo's host. The restic rest-server does not advertise
    /// its version in the normal case, so this usually returns nil (the server check
    /// then falls back to advisory) — but a reverse proxy in front of it sometimes
    /// does. We require the header to actually name "rest-server" so a generic proxy
    /// banner (`nginx/1.2.3`) can't be misread as the server version. Never sends
    /// the password: it probes only scheme+host[+port] with a bounded timeout, and
    /// reads only the header. nil for non-REST backends (sftp:, s3:, a local path).
    static func restServerInstalled(repoURL: String?, timeout: TimeInterval = 8) -> SemVer? {
        guard let repoURL, let endpoint = restEndpoint(from: repoURL),
              let url = URL(string: endpoint) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = timeout
        request.setValue("baaackaaab", forHTTPHeaderField: "User-Agent")
        // SyncBox + semaphore bridge the completion handler back to this synchronous
        // call (the same handoff ResticBackend uses for piped stdout).
        let box = SyncBox<String?>(nil)
        let sem = DispatchSemaphore(value: 0)
        let task = URLSession.shared.dataTask(with: request) { _, response, _ in
            box.value = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Server")
            sem.signal()
        }
        task.resume()
        if sem.wait(timeout: .now() + timeout + 2) == .timedOut { task.cancel(); return nil }
        guard let header = box.value, header.lowercased().contains("rest-server") else { return nil }
        return SemVer(parsing: header)
    }

    /// The bare `scheme://host[:port]/` endpoint of a restic REST repo URL
    /// (`rest:https://user:pass@host:8000/repo/`), with the `rest:` prefix, the
    /// userinfo (credentials), and the repo path stripped — exactly enough to make a
    /// header probe and nothing that leaks the password. nil for non-REST backends
    /// (no HTTP server to probe). The userinfo boundary comes from
    /// `Credentials.userinfoDelimiter` — the SAME rule the log redaction uses —
    /// so a password containing '@' or a raw '/' is stripped whole here too
    /// instead of leaking a fragment into the probed host.
    static func restEndpoint(from repoURL: String) -> String? {
        guard repoURL.hasPrefix("rest:") else { return nil }
        let raw = repoURL.dropFirst("rest:".count)
        guard let schemeSep = raw.range(of: "://") else { return nil }
        let scheme = String(raw[raw.startIndex..<schemeSep.lowerBound])
        guard scheme == "http" || scheme == "https" else { return nil }
        let afterScheme = raw[schemeSep.upperBound...]
        let hostStart: Substring.Index
        if let at = Credentials.userinfoDelimiter(in: afterScheme) {
            hostStart = afterScheme.index(after: at)
        } else {
            hostStart = afterScheme.startIndex
        }
        let hostTail = afterScheme[hostStart...]
        let hostEnd = hostTail.firstIndex(of: "/") ?? hostTail.endIndex
        let hostPort = hostTail[..<hostEnd]
        guard !hostPort.isEmpty else { return nil }
        return "\(scheme)://\(hostPort)/"
    }

    // MARK: - Reference-version detection (online)

    /// The latest release tag of a GitHub repo (e.g. "restic/restic"), parsed to a
    /// SemVer. ONLINE — contacts api.github.com. nil on any failure (offline, rate
    /// limited, parse error) so the caller degrades to the offline baseline. Bounded.
    static func latestRelease(repo: String, timeout: TimeInterval = 10) -> SemVer? {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        // GitHub rejects requests without a User-Agent; ask for the JSON media type.
        request.setValue("baaackaaab", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let box = SyncBox<Data?>(nil)
        let sem = DispatchSemaphore(value: 0)
        let task = URLSession.shared.dataTask(with: request) { data, _, _ in
            box.value = data; sem.signal()
        }
        task.resume()
        if sem.wait(timeout: .now() + timeout + 2) == .timedOut { task.cancel(); return nil }
        guard let payload = box.value,
              let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let tag = obj["tag_name"] as? String else { return nil }
        return SemVer(parsing: tag)
    }

    // MARK: - Findings

    /// Evaluate both components. `primaryRepoURL` is the (redacted or raw) repo URL
    /// whose host the server probe targets — pass nil to skip the server probe.
    /// `online` adds the GitHub latest-release query (otherwise, and when GitHub is
    /// unreachable, each reference falls back to the pinned baseline).
    static func findings(primaryRepoURL: String?, online: Bool) -> [Finding] {
        let resticLatest = online ? latestRelease(repo: resticRepo) : nil
        let serverLatest = online ? latestRelease(repo: restServerRepo) : nil
        return [
            Finding(
                component: "restic",
                installed: resticInstalled(),
                reference: resticLatest ?? resticBaseline,
                referenceKind: resticLatest != nil ? .latest : .baseline,
                unavailableNote: "not found on PATH or version unreadable — install it (`brew install restic`)"),
            Finding(
                component: "rest-server",
                installed: restServerInstalled(repoURL: primaryRepoURL),
                reference: serverLatest ?? restServerBaseline,
                referenceKind: serverLatest != nil ? .latest : .baseline,
                unavailableNote: "installed version not detectable from here (the REST server doesn't advertise it)"),
        ]
    }

    /// The macOS banner text for an unattended run when something is behind the
    /// tested baseline (offline for restic; best-effort probe for the server), or
    /// nil when everything is at/above baseline. Used as the scheduled run's one
    /// human-visible "you are behind" nudge.
    static func staleBaselineBanner(primaryRepoURL: String?) -> String? {
        let parts = findings(primaryRepoURL: primaryRepoURL, online: false).compactMap { $0.bannerFragment }
        return parts.isEmpty ? nil : parts.joined(separator: "; ")
    }
}

/// `--check-updates`: compare the installed restic CLI and REST server against the
/// LATEST upstream GitHub releases (with the pinned baseline as the fallback when
/// GitHub is unreachable). This is the one path that contacts api.github.com, so it
/// only runs on explicit request. Read-only; never writes. Posts a banner when
/// something is behind (so it doubles as a manual "nudge me" command). Always exits
/// 0 — being behind is informational, not an error.
func updateCheckCommand() {
    Console.banner("baaackaaab", tagline: "update check")
    Console.section("Components")
    Console.note("comparing against the latest upstream releases (contacts GitHub); falls back to the tested baseline if GitHub is unreachable")
    let primary = DestinationStore.all().first?.displayURL
    let findings = UpdateCheck.findings(primaryRepoURL: primary, online: true)
    var behind = 0
    for f in findings where f.emit() { behind += 1 }

    Console.section("Verdict")
    if behind > 0 {
        Console.warn("\(behind) component(s) behind — update the flagged one(s) above")
        // Mirror the unattended-run nudge: post a banner when our output is invisible
        // (a wrapper script / piped), so a scheduled `--check-updates` is still seen.
        if isatty(STDOUT_FILENO) == 0 {
            let msg = findings.compactMap { $0.bannerFragment }.joined(separator: "; ")
            if !msg.isEmpty { Notifier.notify(title: "baaackaaab \u{2014} update available", message: msg) }
        }
    } else {
        Console.success("restic and the REST server are up to date")
    }
}
