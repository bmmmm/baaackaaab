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
    static let endpointHost = "restic.example.com"
    static let endpointUser = "macbook"

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

    /// Mask the endpoint password in a `rest:https://user:PASS@host/…` URL so it
    /// can be logged. Returns the input unchanged if it has no userinfo.
    static func redact(_ repoURL: String) -> String {
        guard let at = repoURL.firstIndex(of: "@"),
              let scheme = repoURL.range(of: "://"),
              let colon = repoURL[scheme.upperBound..<at].firstIndex(of: ":")
        else { return repoURL }
        return String(repoURL[..<repoURL.index(after: colon)]) + "***" + String(repoURL[at...])
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
