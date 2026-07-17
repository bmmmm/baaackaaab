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

    /// The CLEARTEXT encryption password — for the recovery kit only. Every
    /// other consumer of a destination must stay redacted/path-only; this exists
    /// solely to compose an intentionally-plaintext offline recovery sheet. nil
    /// when the file is missing/unreadable/empty, so the caller can note the
    /// destination is incomplete rather than exporting a blank password.
    var passwordValue: String? {
        switch password {
        case .value(let v): return v.isEmpty ? nil : v
        case .file(let u):
            guard let data = FileManager.default.contents(atPath: u.path) else { return nil }
            let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (s?.isEmpty ?? true) ? nil : s
        case .unset: return nil
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

    /// Decode each field independently, falling back to its default when absent.
    /// Without this, adding ONE field to the schema (or an older file missing a
    /// newer key) would fail the whole decode and silently reset link/order/enabled
    /// to defaults — re-enabling a destination the user disabled and collapsing its
    /// order onto the primary's. Per-field decoding keeps the present values intact.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.link = try c.decodeIfPresent(String.self, forKey: .link) ?? "default"
        self.order = try c.decodeIfPresent(Int.self, forKey: .order) ?? 0
        self.enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
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
        let meta = loadMeta(name)
        return Destination(
            name: name, link: meta.link, order: meta.order, enabled: meta.enabled,
            repo: .file(urlFile(name)), password: .file(passwordFile(name))
        )
    }

    /// Read a destination's meta.json. A MISSING file is the legitimate default
    /// (the legacy single repo, or before the first writeMeta). A file that EXISTS
    /// but won't decode is NOT silently defaulted to enabled=true — that would
    /// re-enable a destination the user disabled and collapse its order onto the
    /// primary's. We warn loudly so the corruption is actionable, then fall back to
    /// defaults (keeping the destination visible rather than silently dropping it).
    private static func loadMeta(_ name: String) -> DestinationMeta {
        guard let data = FileManager.default.contents(atPath: metaFile(name).path) else {
            return DestinationMeta()   // no meta.json yet — legitimate default
        }
        do {
            return try JSONDecoder().decode(DestinationMeta.self, from: data)
        } catch {
            Console.warn("destination '\(name)': meta.json is unreadable (\(error)) — falling back to defaults (enabled, order 0). Re-check with --list-destinations and re-apply --order/--disabled if needed.")
            return DestinationMeta()
        }
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
        // Treat an empty value (`--restic-repo ''` or an exported but blank
        // RESTIC_REPOSITORY=) as absent, not as an override: an empty URL would
        // otherwise shadow the entire file store and hand restic a bogus repo.
        func nonEmpty(_ s: String?) -> String? {
            guard let s, !s.isEmpty else { return nil }
            return s
        }

        if let explicit = nonEmpty(explicitRepo) ?? nonEmpty(env["RESTIC_REPOSITORY"]) {
            return [Destination(name: "explicit", link: "default", order: 0, enabled: true,
                                repo: .value(explicit), password: adHocPassword(env))]
        }
        if let urlFile = nonEmpty(env["RESTIC_REPOSITORY_FILE"]) {
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
        // Empty is absent here too (see resolve): a blank RESTIC_PASSWORD= must not
        // win over the file store / Keychain and leave restic with no usable key.
        if let v = env["RESTIC_PASSWORD"], !v.isEmpty { return .value(v) }
        if let f = env["RESTIC_PASSWORD_FILE"], !f.isEmpty { return .file(URL(fileURLWithPath: f)) }
        if CredentialFiles.present { return .file(CredentialFiles.repoPasswordFile) }
        if let pw = (try? Keychain.get(account: Credentials.repoPasswordAccount)) ?? nil {
            return .value(pw)
        }
        return .unset
    }
}

enum DestinationError: Error, CustomStringConvertible {
    case invalidName(String)
    case exists(String)
    case notFound(String)
    case writeFailed(String)

    var description: String {
        switch self {
        case .invalidName(let n): return "invalid destination name '\(n)' — use letters, digits, '.', '_' or '-' (no slashes, no leading dot)"
        case .exists(let n): return "destination '\(n)' already exists — remove it first or pick another name"
        case .notFound(let n): return "no destination named '\(n)'"
        case .writeFailed(let p): return "could not write \(p)"
        }
    }
}

extension DestinationStore {
    /// A safe destinations/ subdir name: non-empty, no path separators, no
    /// leading dot, restricted to a portable character set.
    static func validName(_ name: String) -> Bool {
        guard !name.isEmpty, name.first != "." else { return false }
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        return name.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// Atomically write a value to a 0600 file, creating its parent (0700) first.
    /// Used for the per-destination url / password / meta files. Writes a sibling
    /// temp file (created 0600 from the start — no world-readable window) and then
    /// rename(2)s it over the target: an interrupt or full disk mid-write leaves
    /// either the old file or the new one, never a missing or half-written one. The
    /// previous remove-then-create left NO file if interrupted between the two
    /// steps, which (for meta.json) silently reset a destination to defaults.
    private static func write0600(_ value: String, to file: URL) throws {
        let fm = FileManager.default
        let dir = file.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        let tmp = dir.appendingPathComponent(".\(file.lastPathComponent).tmp-\(ProcessInfo.processInfo.processIdentifier)")
        if fm.fileExists(atPath: tmp.path) { try fm.removeItem(at: tmp) }
        guard fm.createFile(atPath: tmp.path, contents: Data(value.utf8),
                            attributes: [.posixPermissions: 0o600]) else {
            throw DestinationError.writeFailed(file.path)
        }
        // rename(2) atomically replaces an existing destination on the same volume
        // (tmp is a sibling, so it is). Foundation's moveItem refuses an existing
        // target, so use the POSIX call to get a true atomic swap.
        guard rename(tmp.path, file.path) == 0 else {
            try? fm.removeItem(at: tmp)
            throw DestinationError.writeFailed(file.path)
        }
    }

    static func writeMeta(_ meta: DestinationMeta, to name: String) throws {
        let data = try JSONEncoder().encode(meta)
        try write0600(String(data: data, encoding: .utf8) ?? "{}", to: metaFile(name))
    }

    /// Move a legacy single repo (top-level repo-url/repo-password) into
    /// destinations/default, so adding a SECOND destination doesn't silently drop
    /// the first (once destinations/ is non-empty, `all()` reads only it). Writes
    /// the new files first and only removes the legacy ones once both landed —
    /// never leaving the store without a readable copy of the working repo.
    /// Returns true if a migration happened.
    @discardableResult
    static func migrateLegacyIfNeeded() throws -> Bool {
        guard names().isEmpty, CredentialFiles.present else { return false }
        guard let url = (try? CredentialFiles.readURL()) ?? nil,
              let pwData = FileManager.default.contents(atPath: CredentialFiles.repoPasswordFile.path),
              let pw = String(data: pwData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        else { return false }
        try write0600(url, to: urlFile("default"))
        try write0600(pw, to: passwordFile("default"))
        try writeMeta(DestinationMeta(link: "default", order: 0, enabled: true), to: "default")
        // Both new files verified by write0600 (it throws on failure); now the
        // legacy copies are redundant, so remove them to keep one copy of the key.
        try? FileManager.default.removeItem(at: CredentialFiles.repoURLFile)
        try? FileManager.default.removeItem(at: CredentialFiles.repoPasswordFile)
        return true
    }

    /// Create a new destination. `password` is the repository encryption key —
    /// for a brand-new repo the caller passes a freshly generated one; to
    /// re-attach an EXISTING repo it must be that repo's existing key (a fresh
    /// one cannot decrypt it). Migrates a legacy single repo first so the
    /// existing backup is preserved as destinations/default.
    static func add(name: String, repoURL: String, password: String,
                    link: String, order: Int?, enabled: Bool) throws {
        guard validName(name) else { throw DestinationError.invalidName(name) }
        try migrateLegacyIfNeeded()
        guard load(name) == nil else { throw DestinationError.exists(name) }
        let resolvedOrder = order ?? ((all().map { $0.order }.max() ?? -1) + 1)
        try write0600(repoURL, to: urlFile(name))
        try write0600(password, to: passwordFile(name))
        try writeMeta(DestinationMeta(link: link, order: resolvedOrder, enabled: enabled), to: name)
    }

    /// Remove a destination's LOCAL pointer only. This deletes the stored URL +
    /// key + meta; it never touches the remote repository's data (the Mac has no
    /// delete right anyway). Returns false if there was no such destination.
    @discardableResult
    static func remove(name: String) throws -> Bool {
        guard validName(name) else { throw DestinationError.invalidName(name) }
        let d = destDir(name)
        guard FileManager.default.fileExists(atPath: d.path) else { return false }
        try FileManager.default.removeItem(at: d)
        return true
    }
}

/// Per-destination state for one backup run: its backend plus whether init
/// succeeded and how many backups failed. This is what makes a run best-effort
/// ACROSS destinations — one unreachable repo records its failure here and is
/// skipped for backups, but never aborts the others. Mirrors the per-source
/// best-effort the run already does for Drive folders and Photo albums.
final class DestinationRun {
    let destination: Destination
    let backend: ResticBackend
    /// Set when the destination could not be initialized/reached; it is then
    /// skipped for all backups in this run.
    var initError: String?
    var backupFailures = 0
    var firstBackupError: String?

    init(_ destination: Destination) {
        self.destination = destination
        self.backend = ResticBackend(destination: destination)
    }

    /// Initialized and therefore eligible to receive backups this run.
    var ready: Bool { initError == nil }
    /// Initialized AND every backup to it succeeded.
    var ok: Bool { initError == nil && backupFailures == 0 }
}
