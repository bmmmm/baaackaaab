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

    /// Store or replace a generic-password item for `account`.
    static func set(account: String, value: String) throws {
        let data = Data(value.utf8)
        let match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemUpdate(match as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = match
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.unexpectedStatus(addStatus) }
        } else if status != errSecSuccess {
            throw KeychainError.unexpectedStatus(status)
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
        var description: String {
            switch self {
            case .htpasswdFailed(let code):
                return "htpasswd exited with code \(code) — is /usr/sbin/htpasswd present?"
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

    /// Mask the secret in a `rest:https://user:PASS@host/…` URL so it can be
    /// logged. Masks the password when there is a `user:pass` pair, and the WHOLE
    /// userinfo when there is no colon (e.g. `rest:https://TOKEN@host`) — that
    /// token-as-username form must not leak either. Returns the input unchanged
    /// only when there is no `scheme://…@host` userinfo at all.
    static func redact(_ repoURL: String) -> String {
        guard let scheme = repoURL.range(of: "://"),
              let at = repoURL.range(of: "@", range: scheme.upperBound..<repoURL.endIndex)
        else { return repoURL }
        let userinfo = repoURL[scheme.upperBound..<at.lowerBound]
        if let colon = userinfo.firstIndex(of: ":") {
            return String(repoURL[..<repoURL.index(after: colon)]) + "***" + String(repoURL[at.lowerBound...])
        }
        return String(repoURL[..<scheme.upperBound]) + "***" + String(repoURL[at.lowerBound...])
    }

    /// Compute the bcrypt `user:$2y$…` htpasswd line for the server. The
    /// cleartext password is fed to htpasswd over stdin (never argv); only the
    /// one-way hash is returned.
    static func htpasswdLine(user: String, password: String) throws -> String {
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

    /// Write `value` to `file` created with `0600` from the start (no
    /// world-readable window), the directory `0700`. No trailing newline —
    /// restic strips one anyway, but an exact byte image is cleaner.
    static func write(_ value: String, to file: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        if fm.fileExists(atPath: file.path) { try fm.removeItem(at: file) }
        guard fm.createFile(atPath: file.path, contents: Data(value.utf8),
                            attributes: [.posixPermissions: 0o600]) else {
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
