import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Resolve the destinations to back up to / query, honoring an explicit
/// `--restic-repo` / RESTIC_REPOSITORY override, or exit with an actionable
/// message when nothing is configured. Only ENABLED destinations are returned,
/// already ordered primary-first. The credential secrets never reach our argv or
/// environment — each `Destination` carries them as a per-restic-child env
/// overlay (see `ResticBackend`).
func resolveDestinationsOrExit() -> [Destination] {
    let dests = DestinationStore.resolveEnabled(explicitRepo: cli.value("--restic-repo"))
    if !dests.isEmpty { return dests }
    Console.error("no repository — pass --restic-repo, set RESTIC_REPOSITORY, run `baaackaaab --migrate-credentials` (Keychain→files), or `--init-credentials` first")
    exit(1)
}

/// Reach the server with the stored credentials and ensure the repo exists.
/// A fast end-to-end check of DNS + Traefik + htpasswd auth + restic init.
func checkRemote() {
    Console.banner("baaackaaab", tagline: "remote check")
    let dests = resolveDestinationsOrExit()
    var failures = 0
    for dest in dests {
        let repo = dest.displayURL ?? dest.name
        Console.section("Destination", detail: "\(dest.name) [\(dest.link)]")
        Console.info([("repo", Credentials.redact(repo))])
        guard dest.passwordAvailable else {
            Console.failure(noPasswordNote())
            failures += 1
            continue
        }
        do {
            let backend = ResticBackend(destination: dest)
            try backend.ensureInitialized()
            Console.success("reachable, authentication OK, repository ready")
            // Read-only per-(source × destination) summary: total snapshots + size,
            // then the newest snapshot per source (drive / photos). Same data the
            // TUI dashboard shows; surfaced here so it is visible without a TTY.
            let status = backend.remoteStatus()
            if status.reachable {
                let size = status.sizeBytes.map { String(format: ", %.2f GB", Double($0) / 1_000_000_000) } ?? ""
                Console.detail("\(status.snapshotCount) snapshot(s)\(size)")
                for src in status.sources {
                    let when = src.latestTime.map { String($0.prefix(16)).replacingOccurrences(of: "T", with: " ") } ?? "never"
                    Console.detail("  \(src.source): \(src.count) snapshot(s), latest \(when)")
                }
            }
        } catch {
            Console.failure("\(error)")
            failures += 1
        }
    }
    if failures > 0 {
        Console.error("\(failures)/\(dests.count) destination(s) failed the check — see above")
        exit(1)
    }
    Console.success("all \(dests.count) destination(s) reachable and ready")
}

/// Resolve the destinations a read/restore command should act on: every enabled
/// one, or just the single `--destination <name>`. Exits with an actionable error
/// if `--destination` names something that is not configured. The restore flow
/// uses this to pick its source repository.
func destinationsForCommand() -> [Destination] {
    let all = resolveDestinationsOrExit()
    guard let name = cli.value("--destination") else { return all }
    guard let match = all.first(where: { $0.name == name }) else {
        Console.error("no enabled destination named '\(name)' — configured: \(all.map { $0.name }.joined(separator: ", "))")
        exit(1)
    }
    return [match]
}

/// The repeated "missing encryption key" note, in one place so the wording stays
/// identical everywhere it can surface. `name` is woven in for the single-
/// destination commands that already know which destination failed.
func noPasswordNote(for name: String? = nil) -> String {
    let who = name.map { " for '\($0)'" } ?? ""
    return "no encryption password\(who) — the credential files are missing or unreadable"
}

/// Fan a read/verify command out over `dests`, wrapping the scaffold every one
/// of them repeats: the per-destination section header and the missing-key guard
/// (printed as a failure and counted). `body` runs only for a destination whose
/// key is present; it returns false — or throws — to mark that destination
/// failed (a thrown error is printed as the failure line). Returns the count of
/// failed destinations; the caller prints its own command-specific summary/exit.
@discardableResult
func forEachDestination(_ dests: [Destination], _ body: (Destination) throws -> Bool) -> Int {
    var failures = 0
    for dest in dests {
        Console.section("Destination", detail: "\(dest.name) [\(dest.link)]")
        guard dest.passwordAvailable else {
            Console.failure(noPasswordNote())
            failures += 1
            continue
        }
        do { if !(try body(dest)) { failures += 1 } }
        catch {
            Console.failure("\(error)")
            failures += 1
        }
    }
    return failures
}

/// Resolve exactly one destination for a single-repository command (diff,
/// test-restore, unlock), print its section header, and verify its key is
/// present — exiting with an actionable error when several/none are configured or
/// the key is missing. `action` completes the "choose ONE destination" sentence,
/// e.g. "diff compares two snapshots in a single repository".
func requireSingleDestination(action: String) -> Destination {
    let picked = destinationsForCommand()
    guard picked.count == 1 else {
        Console.error("choose ONE destination with --destination <name> — \(action) (configured: \(picked.map { $0.name }.joined(separator: ", ")))")
        exit(1)
    }
    let dest = picked[0]
    Console.section("Destination", detail: "\(dest.name) [\(dest.link)]")
    guard dest.passwordAvailable else {
        Console.error(noPasswordNote(for: dest.name))
        exit(1)
    }
    return dest
}

/// Print the configured destinations (read-only): name, link group, order,
/// enabled flag, and the redacted repo URL. Never touches the network.
func listDestinations() {
    Console.banner("baaackaaab", tagline: "destinations")
    let dests = DestinationStore.all()
    Console.section("Destinations", detail: DestinationStore.dir.path)
    if dests.isEmpty {
        Console.note("none configured — add one with `baaackaaab --add-destination <name> --repo-url <url>`, or run `--init-credentials` for the first repo")
        return
    }
    for d in dests {
        Console.step("\(d.name)  [\(d.link)]  order \(d.order)  \(d.enabled ? "enabled" : "disabled")")
        Console.detail(d.displayURL.map { Credentials.redact($0) } ?? "(url unreadable)")
    }
}

/// Add a new destination: a fresh independent repository with its own encryption
/// key. The URL is taken as-is (rest:https://…, a local path, sftp:…); the key is
/// generated locally (or imported from a file to re-attach an existing repo) and
/// never reaches argv. A legacy single repo is migrated to destinations/default
/// first so the existing backup is preserved.
func addDestination(name: String) {
    Console.banner("baaackaaab", tagline: "add destination")
    guard let url = cli.value("--repo-url"), !url.isEmpty else {
        Console.error("--add-destination needs --repo-url <url> (a rest:https://… URL, a local path, sftp:…, etc.)")
        exit(1)
    }
    let link = cli.value("--link") ?? "default"
    // Reject a malformed --order loudly like every other numeric flag — a
    // silent flatMap would drop a typo ("--order two") to the default ordering.
    let order: Int? = cli.value("--order").map { raw in
        guard let n = Int(raw) else {
            Console.error("--order needs an integer (lower runs earlier) — got '\(raw)'")
            exit(1)
        }
        return n
    }
    let enabled = !cli.has("--disabled")

    let importing = cli.value("--repo-password-file") != nil
    let password: String
    if let pwFile = cli.value("--repo-password-file") {
        guard let data = FileManager.default.contents(atPath: (pwFile as NSString).expandingTildeInPath),
              let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !s.isEmpty else {
            Console.error("--repo-password-file is empty or unreadable: \(pwFile)")
            exit(1)
        }
        password = s   // re-attaching an existing repo: must be its existing key
    } else {
        password = Credentials.randomURLSafe(byteCount: 32)   // ~256-bit new key
    }

    do {
        try DestinationStore.add(name: name, repoURL: url, password: password,
                                 link: link, order: order, enabled: enabled)
    } catch {
        Console.error("\(error)")
        exit(1)
    }

    Console.section("Added")
    Console.success("destination '\(name)' stored (0600) at \(DestinationStore.destDir(name).path)")
    Console.info([("repo", Credentials.redact(url)), ("link", link)])
    if !importing {
        Console.warn("A NEW encryption key was generated and lives ONLY in the 0600 file — the server never has it. Lose it and this destination's backups are unrecoverable. It is protected by FileVault at rest; back it up to your password manager.")
    }
    Console.step("verify:  baaackaaab --check   (initializes every destination's repo if new)")
}

/// Remove a destination's LOCAL pointer (URL + key + meta). Never touches the
/// remote repository's data — the Mac has no delete right.
func removeDestination(name: String) {
    Console.banner("baaackaaab", tagline: "remove destination")
    do {
        if try DestinationStore.remove(name: name) {
            Console.success("removed local pointer for destination '\(name)'")
            Console.note("the remote repository's data was NOT touched — the Mac has no delete right. To reclaim that repo's space, prune it server-side with a separate key.")
        } else {
            Console.error("no destination named '\(name)' — see `baaackaaab --list-destinations`")
            exit(1)
        }
    } catch {
        Console.error("\(error)")
        exit(1)
    }
}
