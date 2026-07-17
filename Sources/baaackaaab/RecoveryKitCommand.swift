import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Read one line from stdin with terminal ECHO disabled — a plain password
/// prompt. Only ECHO is turned off (canonical/line mode stays on), so
/// backspace and line editing still work; only the typed characters are
/// invisible. Falls back to a normal `readLine()` when stdin isn't a TTY (a
/// pipe, or a non-interactive invocation) — there is no terminal echo to
/// suppress there anyway, and this command REQUIRES a TTY before it ever calls
/// this (see `exportRecoveryKitCommand`), so the fallback is defensive, not a
/// silent downgrade of the security property.
func readSecretLine(prompt: String) -> String? {
    print(prompt, terminator: "")
    guard isatty(STDIN_FILENO) != 0 else { return readLine() }
    var oldAttrs = termios()
    guard tcgetattr(STDIN_FILENO, &oldAttrs) == 0 else { return readLine() }
    var newAttrs = oldAttrs
    newAttrs.c_lflag &= ~tcflag_t(ECHO)
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &newAttrs)
    defer {
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &oldAttrs)
        print("")   // the newline ECHO would otherwise have shown for the Enter keypress
    }
    return readLine()
}

/// Prompt twice for the recovery-kit encryption passphrase (no echo), looping
/// on a too-short or mismatched entry until it validates. The validation logic
/// itself (`RecoveryKit.validatePassphrase`) is pure and unit-tested; this is
/// just the interactive retry loop around it.
func promptRecoveryKitPassphrase() -> String {
    while true {
        guard let first = readSecretLine(prompt: "Recovery kit passphrase (min 10 chars): "), !first.isEmpty else {
            Console.error("no passphrase entered — try again")
            continue
        }
        guard let confirm = readSecretLine(prompt: "Confirm passphrase: ") else {
            Console.error("no confirmation entered — try again")
            continue
        }
        if let err = RecoveryKit.validatePassphrase(first, confirm) {
            Console.error("\(err) — try again")
            continue
        }
        return first
    }
}

/// `--export-recovery-kit <path>` / `--export-recovery-kit-plain <path>`: write
/// a Markdown recovery sheet covering every configured destination (repo URL,
/// encryption password, endpoint password, plain-restic recovery steps) to
/// `path`. Encrypted by default (AES-256-CBC via openssl, interactive
/// passphrase); `plain` skips encryption for a printable sheet. Refuses to
/// write into live iCloud Drive / Photos — a recovery kit synced back into the
/// compromised-source domain defeats its purpose.
func exportRecoveryKitCommand(plain: Bool) {
    Console.banner("baaackaaab", tagline: plain ? "export recovery kit (PLAINTEXT)" : "export recovery kit")

    guard let rawPath = cli.value(plain ? "--export-recovery-kit-plain" : "--export-recovery-kit"),
          !rawPath.isEmpty else {
        Console.error("--export-recovery-kit\(plain ? "-plain" : "") needs a path, e.g. --export-recovery-kit ~/Desktop/baaackaaab-recovery.md.enc")
        exit(1)
    }
    let output = URL(fileURLWithPath: (rawPath as NSString).expandingTildeInPath)

    guard !RestoreEngine.isInsideForbiddenRoot(output) else {
        Console.error("\(RecoveryKitError.forbiddenTarget(output.path))")
        exit(1)
    }

    let destinations = DestinationStore.all()
    guard !destinations.isEmpty else {
        Console.error("\(RecoveryKitError.noDestinations)")
        exit(1)
    }

    let entries = RecoveryKit.buildEntries(from: destinations)
    let incomplete = entries.filter { $0.repoURL == nil || $0.password == nil }
    let sheet = RecoveryKit.composeSheet(entries: entries, generatedAt: Date())

    if plain {
        Console.warn("EXTRA LOUD WARNING: this writes the recovery sheet UNENCRYPTED. Anyone who reads this file can decrypt your entire backup store. Move it offline (print it / a password manager / a sealed USB stick) IMMEDIATELY and never leave a copy on this Mac or any synced location.")
    } else {
        guard isatty(STDIN_FILENO) != 0 else {
            Console.error("--export-recovery-kit needs an interactive terminal to prompt for the encryption passphrase (no echo) — run it directly in Terminal.app, or use --export-recovery-kit-plain if you will encrypt the file yourself afterward")
            exit(1)
        }
    }

    do {
        if plain {
            try RecoveryKit.writePlain(sheet, to: output)
        } else {
            let passphrase = promptRecoveryKitPassphrase()
            try RecoveryKit.encrypt(plaintext: sheet, passphrase: passphrase, to: output)
        }
    } catch {
        Console.error("\(error)")
        exit(1)
    }

    Console.section("Written")
    Console.success("\(output.path)  (0600\(plain ? ", UNENCRYPTED" : ", AES-256-CBC encrypted"))")
    if !incomplete.isEmpty {
        Console.warn("\(incomplete.count) destination(s) are INCOMPLETE in this kit (credential file(s) missing/unreadable): \(incomplete.map { $0.name }.joined(separator: ", ")). Fix access and re-export for a complete kit.")
    }

    Console.section("MOVE THIS FILE OFFLINE NOW")
    Console.warn("This file can recover your entire backup store on any machine. Get it OFF this Mac: print it, put it in a password manager, or a sealed USB stick — never a synced folder, never git.")

    if !plain {
        Console.section("To decrypt (any machine with openssl)")
        print("")
        print("    openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -in \(output.path)")
        print("")
        Console.note("openssl will prompt for the passphrase you just entered (interactively, no echo).")
    }
}
