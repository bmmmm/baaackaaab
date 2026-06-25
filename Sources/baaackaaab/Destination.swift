import Foundation

// A backup destination: one independent restic repository with its own URL and
// its own encryption password.
//
// restic cannot span a single repository over two backends, so "back up to more
// than one place" means more than one repository. We model each as a Destination
// and back up to every enabled one. Two destinations are therefore two FULL,
// independent copies with two SEPARATE keys: losing one repo, one server, or one
// key never touches the other. There is no cross-repo dedup — each destination
// pays its own upload — which is the deliberate price of that isolation.
//
// The Mac stays read + append only toward every destination: it only ever runs
// init/backup/read-only queries, never forget/prune/delete. A compromised Mac
// cannot wipe any copy.

/// Where a destination's repository lives, expressed as the restic env var that
/// names it. We never put the URL on argv (it embeds the endpoint password and
/// argv is world-readable via `ps`).
enum RepoRef {
    case file(URL)       // RESTIC_REPOSITORY_FILE — restic reads the path itself
    case value(String)   // RESTIC_REPOSITORY — an explicit/ad-hoc or legacy URL
}

/// Where a destination's encryption password comes from, again as the env var.
/// `.unset` means "set nothing" — restic then has no password and fails fast
/// (we feed it /dev/null on stdin so it never hangs on a prompt).
enum PasswordRef {
    case file(URL)       // RESTIC_PASSWORD_FILE
    case value(String)   // RESTIC_PASSWORD (legacy Keychain / inherited env)
    case unset
}

/// One configured target. `link` and `order` drive the multi-destination run
/// choreography; the run loop sorts by `order` (primary first) and may run
/// different `link` labels in parallel (same label = shared uplink = sequential).
struct Destination {
    let name: String
    let link: String
    let order: Int
    let enabled: Bool
    let repo: RepoRef
    let password: PasswordRef

    /// The RESTIC_* vars this destination needs, to overlay onto a child's
    /// environment. Exactly one repo source and at most one password source —
    /// restic treats `RESTIC_REPOSITORY`/`_FILE` (and the password pair) as
    /// mutually exclusive and aborts if both are present, which is why the
    /// overlay names only one of each and the backend wipes the rest first.
    var envOverlay: [String: String] {
        var o: [String: String] = [:]
        switch repo {
        case .file(let u):  o["RESTIC_REPOSITORY_FILE"] = u.path
        case .value(let v): o["RESTIC_REPOSITORY"] = v
        }
        switch password {
        case .file(let u):  o["RESTIC_PASSWORD_FILE"] = u.path
        case .value(let v): o["RESTIC_PASSWORD"] = v
        case .unset:        break
        }
        return o
    }

    /// The repo URL for redacted display/logging. Read from the file for a
    /// file-store destination; the literal for an explicit one. nil if the file
    /// is missing/unreadable.
    var displayURL: String? {
        switch repo {
        case .value(let v): return v
        case .file(let u):
            guard let data = FileManager.default.contents(atPath: u.path) else { return nil }
            return String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// Whether the encryption password is actually present — a non-empty value or
    /// a non-empty file. The run/check paths gate on this so a missing key fails
    /// with an actionable message instead of restic's terser prompt-then-error.
    var passwordAvailable: Bool {
        switch password {
        case .value(let v): return !v.isEmpty
        case .file(let u):
            guard let data = FileManager.default.contents(atPath: u.path) else { return false }
            return !data.isEmpty
        case .unset: return false
        }
    }
}

/// On-disk metadata for a stored destination (everything that isn't a secret).
/// Lives next to the two 0600 credential files as `meta.json`.
struct DestinationMeta: Codable {
    var link: String
    var order: Int
    var enabled: Bool

    init(link: String = "default", order: Int = 0, enabled: Bool = true) {
        self.link = link
        self.order = order
        self.enabled = enabled
    }
}

/// The set of configured destinations on disk, plus the resolution order that
/// turns an invocation (with optional --restic-repo / RESTIC_REPOSITORY override)
/// into the concrete list to act on.
///
/// Layout under ~/Library/Application Support/baaackaaab:
///   destinations/<name>/repo-url        0600
///   destinations/<name>/repo-password   0600
///   destinations/<name>/meta.json       0600 (link, order, enabled)
/// Back-compat: a legacy single repo (top-level repo-url/repo-password) is
/// surfaced as the destination "default" until the first --add-destination
/// migrates it into destinations/default.
enum DestinationStore {
    static var dir: URL { CredentialFiles.dir.appendingPathComponent("destinations", isDirectory: true) }

    static func destDir(_ name: String) -> URL { dir.appendingPathComponent(name, isDirectory: true) }
    static func urlFile(_ name: String) -> URL { destDir(name).appendingPathComponent("repo-url") }
    static func passwordFile(_ name: String) -> URL { destDir(name).appendingPathComponent("repo-password") }
    static func metaFile(_ name: String) -> URL { destDir(name).appendingPathComponent("meta.json") }

    /// Names of the stored destinations (subdirectories of destinations/ that
    /// carry a non-empty url + password). Sorted for stable display.
    static func names() -> [String] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        else { return [] }
        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map { $0.lastPathComponent }
            .filter { nonEmpty(urlFile($0)) && nonEmpty(passwordFile($0)) }
            .sorted()
    }

    private static func nonEmpty(_ url: URL) -> Bool {
        guard let data = FileManager.default.contents(atPath: url.path) else { return false }
        return !data.isEmpty
    }

    /// Load one stored destination by name, or nil if its files are missing.
    static func load(_ name: String) -> Destination? {
        guard nonEmpty(urlFile(name)), nonEmpty(passwordFile(name)) else { return nil }
        let meta: DestinationMeta = (FileManager.default.contents(atPath: metaFile(name).path))
            .flatMap { try? JSONDecoder().decode(DestinationMeta.self, from: $0) }
            ?? DestinationMeta()
        return Destination(
            name: name, link: meta.link, order: meta.order, enabled: meta.enabled,
            repo: .file(urlFile(name)), password: .file(passwordFile(name))
        )
    }

    /// All stored destinations (or the legacy single "default"), ordered by
    /// `order` then name. Reads no Keychain and triggers no prompt.
    static func all() -> [Destination] {
        let stored = names().compactMap(load)
        if !stored.isEmpty {
            return stored.sorted { ($0.order, $0.name) < ($1.order, $1.name) }
        }
        // Legacy single repo, still in the top-level credential files.
        if CredentialFiles.present {
            return [Destination(
                name: "default", link: "default", order: 0, enabled: true,
                repo: .file(CredentialFiles.repoURLFile),
                password: .file(CredentialFiles.repoPasswordFile)
            )]
        }
        return []
    }

    /// Resolve the destinations to actually act on for this invocation.
    /// Order of precedence:
    ///   1. an explicit `--restic-repo` or inherited RESTIC_REPOSITORY[_FILE]
    ///      → exactly one ad-hoc destination (test/one-off runs)
    ///   2. the stored destinations (or the legacy single "default")
    ///   3. the legacy Keychain item → one destination (last resort, may prompt)
    /// Returns [] when nothing is configured; callers turn that into the
    /// actionable "no repository" error.
    static func resolve(explicitRepo: String?) -> [Destination] {
        let env = ProcessInfo.processInfo.environment

        if let explicit = explicitRepo ?? env["RESTIC_REPOSITORY"] {
            return [Destination(name: "explicit", link: "default", order: 0, enabled: true,
                                repo: .value(explicit), password: adHocPassword(env))]
        }
        if let urlFile = env["RESTIC_REPOSITORY_FILE"] {
            return [Destination(name: "env", link: "default", order: 0, enabled: true,
                                repo: .file(URL(fileURLWithPath: urlFile)), password: adHocPassword(env))]
        }

        let stored = all()
        if !stored.isEmpty { return stored }

        if let url = (try? Keychain.get(account: Credentials.repoURLAccount)) ?? nil,
           let pw = (try? Keychain.get(account: Credentials.repoPasswordAccount)) ?? nil {
            return [Destination(name: "keychain", link: "default", order: 0, enabled: true,
                                repo: .value(url), password: .value(pw))]
        }
        return []
    }

    /// Only the enabled destinations from `resolve`, for a real backup run.
    static func resolveEnabled(explicitRepo: String?) -> [Destination] {
        resolve(explicitRepo: explicitRepo).filter { $0.enabled }
    }

    /// Password for an explicit/inherited-repo invocation, mirroring the old
    /// resolveAndExport order: an inherited RESTIC_PASSWORD[_FILE] wins, else the
    /// file store, else the legacy Keychain, else nothing (fail fast).
    private static func adHocPassword(_ env: [String: String]) -> PasswordRef {
        if let v = env["RESTIC_PASSWORD"] { return .value(v) }
        if let f = env["RESTIC_PASSWORD_FILE"] { return .file(URL(fileURLWithPath: f)) }
        if CredentialFiles.present { return .file(CredentialFiles.repoPasswordFile) }
        if let pw = (try? Keychain.get(account: Credentials.repoPasswordAccount)) ?? nil {
            return .value(pw)
        }
        return .unset
    }
}
