import Foundation
import Security

// Secret handling for baaackaaab: the macOS Keychain wrapper plus the
// credential domain logic (the two secrets, the client repo URL, and the
// one-way htpasswd hash for the server).
//
// Design rule: a secret must NEVER reach a process argument list. Shelling out
// to `security add-generic-password -w <pw>` would expose the password in argv
// (visible to any process via `ps`), so we talk to the Security framework
// directly and pass secrets as in-process Data. The only value this tool ever
// prints is the bcrypt htpasswd hash, which is one-way and safe to expose.

/// Thin wrapper over the login Keychain for generic-password items, all under
/// one service. Items use kSecAttrAccessibleAfterFirstUnlock so a launchd-driven
/// backup can read them while the screen is locked — but never on a freshly
/// booted machine that has not been unlocked at least once.
enum Keychain {
    static let service = "baaackaaab"

    enum KeychainError: Error, CustomStringConvertible {
        case unexpectedStatus(OSStatus)
        var description: String {
            switch self {
            case .unexpectedStatus(let status):
                let detail = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
                return "Keychain error: \(detail) (\(status))"
            }
        }
    }

    /// Read a generic-password item, or nil if it is not present.
    static func get(account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        guard let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// The baaackaaab credential domain: which Keychain accounts hold what, how the
/// client repo URL is assembled, and how secrets are generated and redacted.
enum Credentials {
    /// Full `rest:https://user:pw@host/user/` URL (endpoint password embedded).
    static let repoURLAccount = "restic-repo-url"
    /// The restic repository encryption password (RESTIC_PASSWORD).
    static let repoPasswordAccount = "restic-password"

    /// The endpoint host and client username. The username doubles as the
    /// private-repos subpath, so `macbook` is confined to `/macbook/`.
    ///
    /// Tracked source ships a placeholder host — the real rest-server host is
    /// private infrastructure and must not live in version control. It is
    /// supplied at setup time via `BAAACKAAAB_ENDPOINT_HOST` (e.g. from ~/.env);
    /// `--init-credentials` refuses to run while the placeholder is still in
    /// effect, so a bogus example.com URL can never be stored. After init the
    /// real URL lives only in the 0600 credential file, so this is needed only
    /// for the one-time setup, not for scheduled backups.
    static let placeholderHost = "restic.example.com"
    static var endpointHost: String {
        ProcessInfo.processInfo.environment["BAAACKAAAB_ENDPOINT_HOST"] ?? placeholderHost
    }
    static var endpointUser: String {
        ProcessInfo.processInfo.environment["BAAACKAAAB_ENDPOINT_USER"] ?? "macbook"
    }

    /// The admin SSH target used only in the printed "create the endpoint user"
    /// instructions. Also placeholder-by-default, real value from the environment.
    static var adminSSH: String {
        ProcessInfo.processInfo.environment["BAAACKAAAB_ADMIN_SSH"] ?? "admin@server.example"
    }

    enum CredentialError: Error, CustomStringConvertible {
        case htpasswdFailed(Int32)
        case htpasswdMissing
        var description: String {
            switch self {
            case .htpasswdFailed(let code):
                return "htpasswd exited with code \(code) — run `/usr/sbin/htpasswd -niB <user>` by hand to see why"
            case .htpasswdMissing:
                return "/usr/sbin/htpasswd not found or not executable — it ships with macOS; on a stripped system install Apache's httpd tools, or compute the bcrypt line on the server instead (`htpasswd -B -n <user>`)"
            }
        }
    }

    /// `byteCount` cryptographically random bytes, base64url without padding so
    /// the value is safe to drop into a URL userinfo field with no escaping.
    static func randomURLSafe(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let rc = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        precondition(rc == errSecSuccess, "SecRandomCopyBytes failed (\(rc))")
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Build the client repo URL embedding the endpoint password.
    static func repoURL(password: String) -> String {
        "rest:https://\(endpointUser):\(password)@\(endpointHost)/\(endpointUser)/"
    }

    /// The `@` that terminates the userinfo in `remainder` (the text after
    /// `://`), or nil when there is no userinfo. ONE rule shared by `redact`
    /// and `UpdateCheck.restEndpoint` so the two can never drift.
    ///
    /// The URL embeds a raw, un-percent-encoded password (see
    /// repoURL(password:)), so the spec's "authority ends at the first `/`"
    /// cannot be trusted: a password containing `/` (any base64 from another
    /// tool) truncates the apparent authority BEFORE its `@`, and a spec-only
    /// split would find no userinfo — logging the cleartext password. Two
    /// steps, security-asymmetric:
    ///   1. the LAST `@` before the first `/` (the spec rule — also keeps a
    ///      password containing `@` masked whole);
    ///   2. failing that, the LAST `@` anywhere. This deliberately over-masks
    ///      a credential-less URL whose PATH contains `@` — a mangled display
    ///      of an exotic URL is acceptable, a cleartext password in a log is not.
    static func userinfoDelimiter(in remainder: Substring) -> Substring.Index? {
        let authorityEnd = remainder.firstIndex(of: "/") ?? remainder.endIndex
        if let at = remainder[..<authorityEnd].lastIndex(of: "@") { return at }
        return remainder.lastIndex(of: "@")
    }

    /// Mask the secret in a `rest:https://user:PASS@host/…` URL so it can be
    /// logged. Masks the password when there is a `user:pass` pair, and the WHOLE
    /// userinfo when there is no colon (e.g. `rest:https://TOKEN@host`) — that
    /// token-as-username form must not leak either. Returns the input unchanged
    /// only when there is no userinfo at all (see `userinfoDelimiter` for how
    /// that boundary is found and why it errs toward masking).
    static func redact(_ repoURL: String) -> String {
        guard let scheme = repoURL.range(of: "://") else { return repoURL }
        let afterScheme = scheme.upperBound
        guard let at = userinfoDelimiter(in: repoURL[afterScheme...]) else { return repoURL }
        let userinfo = repoURL[afterScheme..<at]
        if let colon = userinfo.firstIndex(of: ":") {
            return String(repoURL[..<repoURL.index(after: colon)]) + "***" + String(repoURL[at...])
        }
        return String(repoURL[..<afterScheme]) + "***" + String(repoURL[at...])
    }

    /// Mask a monitoring/notification URL (heartbeat, ntfy, webhook) for display —
    /// the same "never leak it" discipline as `redact`, but a different shape:
    /// unlike a restic repo URL, these carry their secret in the PATH or QUERY
    /// (an ntfy topic name, a Healthchecks UUID, a webhook path token), not in a
    /// clearly-scoped userinfo. So this keeps only scheme + host[:port] — enough to
    /// recognize which service it is in `--list` / logs — and masks everything
    /// after. Returns the input unchanged only when it isn't a parseable URL at all.
    static func redactMonitorURL(_ raw: String) -> String {
        guard let comps = URLComponents(string: raw), let host = comps.host, let scheme = comps.scheme else {
            return raw
        }
        let port = comps.port.map { ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(port)/***"
    }

    /// Compute the bcrypt `user:$2y$…` htpasswd line for the server. The
    /// cleartext password is fed to htpasswd over stdin (never argv); only the
    /// one-way hash is returned.
    static func htpasswdLine(user: String, password: String) throws -> String {
        // Check up front: a missing binary would otherwise surface as a raw
        // NSCocoaError from proc.run(), never reaching the actionable message
        // (htpasswdFailed only fires on a non-zero EXIT of a binary that ran).
        guard FileManager.default.isExecutableFile(atPath: "/usr/sbin/htpasswd") else {
            throw CredentialError.htpasswdMissing
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/htpasswd")
        proc.arguments = ["-niB", user]   // -n: print to stdout, -i: read pw from stdin, -B: bcrypt
        let input = Pipe(), output = Pipe()
        proc.standardInput = input
        proc.standardOutput = output
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        input.fileHandleForWriting.write(Data((password + "\n").utf8))
        input.fileHandleForWriting.closeFile()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0,
              let line = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !line.isEmpty
        else { throw CredentialError.htpasswdFailed(proc.terminationStatus) }
        return line
    }
}

/// File-based credential store: two `0600` files under Application Support that
/// hold the repo URL and the encryption password. This is the preferred store
/// for an unattended job. restic reads the files directly via
/// `RESTIC_REPOSITORY_FILE` / `RESTIC_PASSWORD_FILE`, so the secrets never enter
/// baaackaaab's argv or environment — and there is no Keychain prompt at all.
/// The Keychain's trusted-application ACL does not reliably persist "Always
/// Allow" for a plain (unentitled) CLI, and it would also tie the launchd run to
/// a live GUI session; a file under FileVault + `0600` avoids both. The Keychain
/// wrapper remains only as a legacy read path for `--migrate-credentials`.
enum CredentialFiles {
    enum CredentialFileError: Error, CustomStringConvertible {
        case writeFailed(String)
        var description: String {
            switch self {
            case .writeFailed(let path): return "could not write credential file at \(path)"
            }
        }
    }

    /// ~/Library/Application Support/baaackaaab — or a relocated store when
    /// BAAACKAAAB_SUPPORT_DIR is set (advanced: move the credential + destination
    /// store off the default path; also what the test harness uses to run against
    /// a throwaway store instead of the user's real one).
    static var dir: URL {
        if let override = ProcessInfo.processInfo.environment["BAAACKAAAB_SUPPORT_DIR"],
           !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/baaackaaab", isDirectory: true)
    }
    static var repoURLFile: URL { dir.appendingPathComponent("repo-url") }
    static var repoPasswordFile: URL { dir.appendingPathComponent("repo-password") }

    /// Both files present AND non-empty — the gate for using the file store at
    /// all. Requiring non-empty means a truncated/empty file (a botched manual
    /// edit, or a partial write where the first file landed and the second
    /// threw) falls back to the Keychain / the actionable "no repository" error
    /// instead of exporting a `*_FILE` pointer at broken content and letting
    /// restic fail with its own less-helpful message.
    static var present: Bool {
        nonEmptyFile(repoURLFile) && nonEmptyFile(repoPasswordFile)
    }

    private static func nonEmptyFile(_ url: URL) -> Bool {
        guard let data = FileManager.default.contents(atPath: url.path) else { return false }
        return !data.isEmpty
    }

    /// Atomically write `value` to `file` created with `0600` from the start (no
    /// world-readable window), the directory `0700`. No trailing newline — restic
    /// strips one anyway, but an exact byte image is cleaner. The write goes to a
    /// sibling temp file and is rename(2)d over the target, so an interrupt or full
    /// disk mid-write leaves either the old credential or the new one — never a
    /// missing file (the previous remove-then-create could, losing the credential).
    static func write(_ value: String, to file: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        let tmp = dir.appendingPathComponent(".\(file.lastPathComponent).tmp-\(ProcessInfo.processInfo.processIdentifier)")
        if fm.fileExists(atPath: tmp.path) { try fm.removeItem(at: tmp) }
        guard fm.createFile(atPath: tmp.path, contents: Data(value.utf8),
                            attributes: [.posixPermissions: 0o600]) else {
            throw CredentialFileError.writeFailed(file.path)
        }
        guard rename(tmp.path, file.path) == 0 else {
            try? fm.removeItem(at: tmp)
            throw CredentialFileError.writeFailed(file.path)
        }
    }

    /// The stored repo URL (trimmed), for redacted display. nil if absent.
    static func readURL() throws -> String? {
        guard let data = FileManager.default.contents(atPath: repoURLFile.path) else { return nil }
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
