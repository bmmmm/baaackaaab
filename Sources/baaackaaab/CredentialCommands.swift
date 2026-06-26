import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// First-run credential setup. Generates both secrets, stores them in two
/// `0600` files, and prints the one-way bcrypt line plus the command to create
/// the endpoint user on the server. The cleartext endpoint password never leaves
/// the file store; only its hash is printed. restic reads the files directly, so
/// neither secret ever reaches argv, our environment, or a Keychain prompt.
func initCredentials() throws {
    Console.banner("baaackaaab", tagline: "credential setup")

    // Refuse to clobber an existing credential file store. Re-running this
    // generates a NEW encryption password; overwriting the only copy of the key
    // orphans the existing repository — every snapshot becomes permanently
    // unreadable. Only --force (a deliberate fresh start) gets past this guard.
    if CredentialFiles.present && !cli.has("--force") {
        Console.error("credential files already exist at \(CredentialFiles.dir.path) — re-running --init-credentials generates a NEW encryption password and would ORPHAN the existing repository (its snapshots become permanently unreadable). To start a fresh repo on purpose, re-run with --force. To move existing Keychain secrets into the files WITHOUT regenerating, use --migrate-credentials.")
        exit(1)
    }

    // The real rest-server host is private and is NOT baked into the source. It
    // must be supplied via BAAACKAAAB_ENDPOINT_HOST (e.g. in ~/.env); refuse
    // rather than store a useless placeholder URL pointing at example.com.
    guard Credentials.endpointHost != Credentials.placeholderHost else {
        Console.error("endpoint host is unset — the real rest-server host is not baked into the binary. Export it in the shell that runs this (it must be live in the environment, not just written to ~/.env): `export BAAACKAAAB_ENDPOINT_HOST=<your rest-server host> && baaackaaab --init-credentials` (or add it to ~/.env and open a new shell). Optionally export BAAACKAAAB_ENDPOINT_USER and BAAACKAAAB_ADMIN_SSH too.")
        exit(1)
    }

    let endpointPW = Credentials.randomURLSafe(byteCount: 24)   // ~192 bits, endpoint auth
    let repoPW = Credentials.randomURLSafe(byteCount: 32)       // ~256 bits, encryption key
    let repoURL = Credentials.repoURL(password: endpointPW)

    try CredentialFiles.write(repoURL, to: CredentialFiles.repoURLFile)
    try CredentialFiles.write(repoPW, to: CredentialFiles.repoPasswordFile)

    Console.section("Credential files")
    Console.success("stored endpoint URL + encryption password (0600, \(CredentialFiles.dir.path))")
    Console.info([("repo", Credentials.redact(repoURL))])
    Console.warn("The encryption password lives ONLY in this 0600 file — the server never has it. Lose it and the backups are unrecoverable. It is protected by FileVault at rest; back it up to your password manager.")

    let line = try Credentials.htpasswdLine(user: Credentials.endpointUser, password: endpointPW)
    Console.section("Server", detail: "create the endpoint user on garage")
    Console.note("One-way bcrypt hash (safe to paste); the cleartext password is not shown. It sets /data/.htpasswd to exactly user '\(Credentials.endpointUser)' — re-running rotates the password (overwrite, so this single-user tool stays at one endpoint user):")
    print("")
    print("    printf '%s\\n' '\(line)' \\")
    print("      | ssh \(Credentials.adminSSH) 'docker exec -i restic-rest-server sh -c \"cat > /data/.htpasswd\"'")
    print("")
    Console.section("Verify")
    Console.step("then run:  baaackaaab --check")
    Console.note("reaches the server with the stored credentials and initializes the repository.")
    Console.note("If --check returns 401, the server cached the old .htpasswd — run `ssh \(Credentials.adminSSH) docker restart restic-rest-server`, then retry.")
}

/// One-time migration of an existing setup from the Keychain to the `0600` file
/// store. Reads both items from the Keychain once (the last Keychain prompt this
/// tool ever triggers) and writes them verbatim to the files — the encryption
/// password is NOT regenerated, so the existing repository stays intact. Prints
/// the commands to drop the now-unused Keychain items (kept, not auto-deleted,
/// so the user decides when to remove the fallback).
func migrateCredentials() throws {
    Console.banner("baaackaaab", tagline: "migrate credentials → files")

    if CredentialFiles.present {
        Console.warn("credential files already exist at \(CredentialFiles.dir.path) — they will be overwritten with the current Keychain values")
    }
    guard let url = (try? Keychain.get(account: Credentials.repoURLAccount)) ?? nil else {
        Console.error("no repo URL in the Keychain (item '\(Credentials.repoURLAccount)') — nothing to migrate; run `baaackaaab --init-credentials` to set up the file store directly")
        exit(1)
    }
    guard let pw = (try? Keychain.get(account: Credentials.repoPasswordAccount)) ?? nil else {
        Console.error("no encryption password in the Keychain (item '\(Credentials.repoPasswordAccount)') — nothing to migrate")
        exit(1)
    }

    try CredentialFiles.write(url, to: CredentialFiles.repoURLFile)
    try CredentialFiles.write(pw, to: CredentialFiles.repoPasswordFile)

    Console.section("Credential files")
    Console.success("wrote repo URL + encryption password to 0600 files (password unchanged — repo intact)")
    Console.info([
        ("dir", CredentialFiles.dir.path),
        ("repo", Credentials.redact(url)),
    ])
    Console.note("restic now reads these via RESTIC_REPOSITORY_FILE / RESTIC_PASSWORD_FILE — no Keychain prompt, interactive or under launchd.")

    Console.section("Cleanup", detail: "optional — drop the now-unused Keychain items")
    Console.note("the file store is authoritative from here; remove the Keychain items when ready:")
    print("")
    print("    security delete-generic-password -s \(Keychain.service) -a \(Credentials.repoURLAccount)")
    print("    security delete-generic-password -s \(Keychain.service) -a \(Credentials.repoPasswordAccount)")
    print("")
    Console.step("verify:  baaackaaab --check")
}
