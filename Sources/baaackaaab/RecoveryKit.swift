import Foundation

// The emergency recovery kit: the missing half of the durability story. Every
// secret this tool relies on lives in 0600 files on the Mac — if the Mac dies,
// those files die with it, and the append-only store (which the Mac itself
// cannot even read back without them) becomes permanently undecryptable. The
// kit is a single offline document holding everything a bare machine with
// stock restic needs to recover: the full repo URL, the encryption password,
// and the endpoint password, in the clear, on purpose — encrypted at rest by
// default so the artifact itself is safe to print, drop on a USB stick, or
// hand to a password manager.

enum RecoveryKitError: Error, CustomStringConvertible, Equatable {
    case forbiddenTarget(String)
    case opensslMissing
    case opensslFailed(Int32)
    case passphraseTooShort
    case passphraseMismatch
    case writeFailed(String)
    case noDestinations

    var description: String {
        switch self {
        case .forbiddenTarget(let p):
            return "refusing to write the recovery kit into \(p) — it is inside live iCloud Drive / Photos or a cloud-synced (FileProvider) folder; with Desktop & Documents sync that includes ~/Desktop and ~/Documents. A recovery kit synced back into the compromised-source domain defeats its purpose; pick a non-synced path (e.g. a USB stick, an external disk, or ~/Downloads), then move it offline immediately."
        case .opensslMissing:
            return "openssl not found on PATH — it ships with macOS and every Linux, so this is unusual; check your PATH. Without it the kit cannot be encrypted here. Use --export-recovery-kit-plain instead (unencrypted — extra risk in transit) or install openssl."
        case .opensslFailed(let code):
            return "openssl exited with code \(code) — the kit was NOT written; see its output above"
        case .passphraseTooShort:
            return "passphrase must be at least 10 characters"
        case .passphraseMismatch:
            return "passphrases did not match"
        case .writeFailed(let p):
            return "could not write \(p)"
        case .noDestinations:
            return "no destinations configured — nothing to export. Run `--init-credentials` or `--add-destination` first."
        }
    }
}

/// Pure composition + I/O leaves for `--export-recovery-kit`. Kept separate
/// from the CLI wiring (RecoveryKitCommand.swift) so the Markdown composition
/// and the passphrase validation are directly unit-testable with no process
/// exit, no terminal, and no real credential store.
enum RecoveryKit {
    /// One destination's material for the sheet. `repoURL` / `password` are nil
    /// when the credential files are missing/unreadable — the sheet then notes
    /// the destination as incomplete instead of failing the whole export.
    struct Entry {
        let name: String
        let repoURL: String?
        let password: String?
    }

    /// Build entries from live destinations (I/O: reads the 0600 credential
    /// files). Pulled out from `composeSheet` so the Markdown formatting stays
    /// pure and testable with hand-built entries.
    static func buildEntries(from destinations: [Destination]) -> [Entry] {
        destinations.map { Entry(name: $0.name, repoURL: $0.displayURL, password: $0.passwordValue) }
    }

    /// Compose the full Markdown recovery sheet. Pure — no filesystem, no
    /// process, no Date() default (the caller passes `generatedAt` so a test can
    /// pin it and diff the exact text).
    static func composeSheet(entries: [Entry], generatedAt: Date) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd HH:mm 'UTC'"
        fmt.timeZone = TimeZone(identifier: "UTC")

        var lines: [String] = []
        lines.append("# baaackaaab emergency recovery kit")
        lines.append("")
        lines.append("Generated \(fmt.string(from: generatedAt)).")
        lines.append("")
        lines.append("## What this is")
        lines.append("")
        lines.append("Every secret baaackaaab needs — the repository URL and the restic encryption")
        lines.append("password for each destination — normally lives only in 0600 files on this")
        lines.append("Mac. If the Mac is lost, stolen, or wiped, those files are gone, and the")
        lines.append("append-only backup store becomes permanently undecryptable with them — the")
        lines.append("server holds no copy of the encryption key by design. This document is the")
        lines.append("one offline copy of that information, plus the handful of plain `restic`")
        lines.append("commands needed to recover on ANY machine with stock restic installed — no")
        lines.append("baaackaaab binary, no Mac, no this tool at all.")
        lines.append("")
        lines.append("## WHY THIS MUST LIVE OFFLINE")
        lines.append("")
        lines.append("This file contains cleartext passwords that decrypt every byte in your")
        lines.append("backup store. Treat it like the master key it is:")
        lines.append("")
        lines.append("- Print it and store the paper somewhere safe, OR keep it in a password")
        lines.append("  manager, OR put it on a sealed USB stick in a drawer/safe.")
        lines.append("- NEVER put it in an iCloud Drive / Dropbox / Google Drive folder or any")
        lines.append("  other synced location — that folder is exactly the compromised-source")
        lines.append("  domain this backup exists to survive.")
        lines.append("- NEVER commit it to git, even a private repository.")
        lines.append("- If this copy is encrypted (the default), the passphrase you chose is")
        lines.append("  itself a secret you must remember or store separately — losing it makes")
        lines.append("  this file useless.")
        lines.append("")

        guard !entries.isEmpty else {
            lines.append("_No destinations were configured at export time._")
            lines.append("")
            return lines.joined(separator: "\n")
        }

        for entry in entries {
            lines.append("## Destination: \(entry.name)")
            lines.append("")
            guard let repoURL = entry.repoURL, let password = entry.password else {
                lines.append("**INCOMPLETE** — this destination's credential file(s) were missing or")
                lines.append("unreadable when this kit was generated, so its secrets could not be")
                lines.append("included. Fix access to the 0600 files under")
                lines.append("`~/Library/Application Support/baaackaaab/destinations/\(entry.name)/` and")
                lines.append("re-run `--export-recovery-kit` to get a complete sheet for this destination.")
                lines.append("")
                continue
            }
            let endpointPW = Credentials.endpointPassword(from: repoURL)
                ?? "n/a — this backend has no embedded credential (not a `user:pass@` repo URL)"
            lines.append("- Repository URL: `\(repoURL)`")
            lines.append("- Restic encryption password: `\(password)`")
            lines.append("- Endpoint (htpasswd) password: `\(endpointPW)`")
            lines.append("")
            lines.append("### Recovery steps (plain restic, no baaackaaab needed)")
            lines.append("")
            lines.append("```sh")
            lines.append("export RESTIC_REPOSITORY='\(repoURL)'")
            lines.append("export RESTIC_PASSWORD='\(password)'")
            lines.append("restic snapshots")
            lines.append("restic restore latest --target ./recovered --verify")
            lines.append("```")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// Validate a twice-entered passphrase: minimum length, then match. Pure —
    /// the interactive prompt loop (RecoveryKitCommand.swift) calls this and
    /// re-prompts on a non-nil result.
    static func validatePassphrase(_ first: String, _ confirm: String) -> RecoveryKitError? {
        guard first.count >= 10 else { return .passphraseTooShort }
        guard first == confirm else { return .passphraseMismatch }
        return nil
    }

    // MARK: - openssl encryption (I/O)

    /// Resolve the `openssl` binary the same way ResticBackend resolves restic:
    /// common install locations first (a launchd-style minimal PATH would
    /// otherwise miss Homebrew), then a PATH walk.
    static func locateOpenSSL() -> String? {
        let fm = FileManager.default
        for path in ["/usr/bin/openssl", "/opt/homebrew/bin/openssl", "/usr/local/bin/openssl"]
            where fm.isExecutableFile(atPath: path) {
            return path
        }
        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            for dir in pathEnv.split(separator: ":") {
                let full = String(dir) + "/openssl"
                if fm.isExecutableFile(atPath: full) { return full }
            }
        }
        return nil
    }

    /// Encrypt `plaintext` with `passphrase` into `output` via
    /// `openssl enc -aes-256-cbc -pbkdf2 -iter 600000 -salt -pass stdin`,
    /// decryptable with nothing but stock openssl on any machine. `-pass stdin`
    /// takes the passphrase from stdin, so the payload itself must come from a
    /// file (`-in`); we stage it in a 0600 temp file under the support dir and
    /// unlink it in every exit path, including a thrown error, via `defer`.
    static func encrypt(plaintext: String, passphrase: String, to output: URL) throws {
        guard let opensslPath = locateOpenSSL() else { throw RecoveryKitError.opensslMissing }

        let fm = FileManager.default
        try fm.createDirectory(at: CredentialFiles.dir, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        let tmp = CredentialFiles.dir.appendingPathComponent(
            ".recovery-kit-plain-\(ProcessInfo.processInfo.processIdentifier).tmp")
        if fm.fileExists(atPath: tmp.path) { try? fm.removeItem(at: tmp) }
        guard fm.createFile(atPath: tmp.path, contents: Data(plaintext.utf8),
                            attributes: [.posixPermissions: 0o600]) else {
            throw RecoveryKitError.writeFailed(tmp.path)
        }
        defer { try? fm.removeItem(at: tmp) }   // every exit path, including a throw below

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: opensslPath)
        proc.arguments = ["enc", "-aes-256-cbc", "-pbkdf2", "-iter", "600000", "-salt",
                          "-pass", "stdin", "-in", tmp.path, "-out", output.path]
        let input = Pipe()
        proc.standardInput = input
        proc.standardError = FileHandle.standardError
        do { try proc.run() } catch { throw RecoveryKitError.opensslMissing }
        input.fileHandleForWriting.write(Data((passphrase + "\n").utf8))
        input.fileHandleForWriting.closeFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { throw RecoveryKitError.opensslFailed(proc.terminationStatus) }
        // Belt and braces: enforce 0600 explicitly even though openssl creates
        // `output` itself, in case its own umask left it more permissive.
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
    }

    /// Write the plaintext sheet directly to `output`, 0600, no encryption — the
    /// `--export-recovery-kit-plain` variant. Callers print the extra-loud
    /// warning; this just does the write.
    static func writePlain(_ plaintext: String, to output: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: output.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        guard fm.createFile(atPath: output.path, contents: Data(plaintext.utf8),
                            attributes: [.posixPermissions: 0o600]) else {
            throw RecoveryKitError.writeFailed(output.path)
        }
    }
}
