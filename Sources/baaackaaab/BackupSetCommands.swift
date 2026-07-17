import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Print the backup set as the aligned key/value overview. `existed` separates
/// "no set yet" (first-run hint) from "set exists but is empty".
func listBackupSet(_ set: BackupSet, path: URL, existed: Bool) {
    Console.section("Backup set", detail: path.path)
    if !existed {
        Console.note("no backup set yet — add folders with --add-folder <dir>, albums with --add-album <name>")
        return
    }
    var pairs: [(String, String)] = []
    for f in set.driveFolders { pairs.append(("drive", f)) }
    for a in set.photoAlbums { pairs.append(("photo", "album \"\(a)\"")) }
    if let q = set.quotaBytes {
        pairs.append(("quota", String(format: "%.2f GB", Double(q) / 1_000_000_000)))
    }
    if let l = set.limitUploadKiBps {
        pairs.append(("limit-upload", "\(l) KiB/s (\(String(format: "%.1f", Double(l) / 1024)) MiB/s)"))
    }
    if let p = set.packSizeMiB {
        pairs.append(("pack-size", "\(p) MiB"))
    }
    if let rc = set.restConnections {
        pairs.append(("rest-connections", "\(rc)"))
    }
    for e in set.excludes { pairs.append(("exclude", e)) }
    for f in set.excludeFiles { pairs.append(("exclude-file", f)) }
    if let hb = set.heartbeatURL {
        pairs.append(("heartbeat", Credentials.redactMonitorURL(hb)))
    }
    for ch in set.notifyChannels {
        pairs.append(("notify", "\(ch.type.rawValue): \(Credentials.redactMonitorURL(ch.url))"))
    }
    // `set.isEmpty` only means "no drive folders/photo albums" (the sources a
    // backup would run against) — a set with only tuning knobs, excludes, or
    // monitoring configured must still print THOSE, not the "empty" hint. Gate
    // on whether there is anything to show at all, not on that narrower flag.
    if pairs.isEmpty {
        Console.note("empty — add folders with --add-folder <dir>, albums with --add-album <name>")
        return
    }
    Console.info(pairs)
    Console.note("Plus always-on defaults: macOS junk (\(ResticBackend.junkExcludes.joined(separator: ", "))) and CACHEDIR.TAG-tagged caches are excluded on every backup.")
}

/// Handle the backup-set management flags (--list / --add-* / --remove-*). Loads
/// the set, applies every add/remove flag, saves only when something changed,
/// and prints the resulting set. No network, no Keychain — pure file editing.
func manageBackupSet(configPath: URL) {
    Console.banner("baaackaaab", tagline: "backup set")
    let existed = FileManager.default.fileExists(atPath: configPath.path)
    var set: BackupSet
    if existed {
        do { set = try BackupSet.load(from: configPath) }
        catch {
            Console.error("backup set at \(configPath.path) is unreadable — fix or delete it: \(error)")
            exit(1)
        }
    } else {
        set = BackupSet()
    }

    var changed = false
    for f in cli.values("--add-folder") {
        if set.addFolder(f) { changed = true; Console.success("added drive folder  \(f)") }
        else { Console.note("drive folder already in set: \(f)") }
    }
    for f in cli.values("--remove-folder") {
        if set.removeFolder(f) { changed = true; Console.success("removed drive folder  \(f)") }
        else { Console.note("drive folder not in set: \(f)") }
    }
    for a in cli.values("--add-album") {
        if set.addAlbum(a) { changed = true; Console.success("added photo album  \(a)") }
        else { Console.note("photo album already in set: \(a)") }
    }
    for a in cli.values("--remove-album") {
        if set.removeAlbum(a) { changed = true; Console.success("removed photo album  \(a)") }
        else { Console.note("photo album not in set: \(a)") }
    }
    // Upload-throttle knob: persisted in the set so the unattended timer is
    // throttled too. `--limit-upload <n>` sets KiB/s; `--clear-limit-upload` lifts it.
    if let raw = cli.value("--limit-upload") {
        guard let n = Int(raw), n > 0 else {
            Console.error("--limit-upload needs a positive integer (KiB/s), e.g. --limit-upload 2048 for ~2 MiB/s")
            exit(1)
        }
        if set.limitUploadKiBps != n { set.limitUploadKiBps = n; changed = true; Console.success("upload limit set to \(n) KiB/s") }
        else { Console.note("upload limit already \(n) KiB/s") }
    }
    if cli.has("--clear-limit-upload") {
        if set.limitUploadKiBps != nil { set.limitUploadKiBps = nil; changed = true; Console.success("upload limit cleared (unthrottled)") }
        else { Console.note("no upload limit was set") }
    }
    // Pack-size knob: persisted in the set (like the throttle) so the timer uses
    // it too. restic accepts 4…128 MiB; `--clear-pack-size` restores the default.
    if let raw = cli.value("--pack-size") {
        guard let n = Int(raw), (4...128).contains(n) else {
            Console.error("--pack-size needs an integer MiB in 4…128 (restic's range), e.g. --pack-size 64")
            exit(1)
        }
        if set.packSizeMiB != n { set.packSizeMiB = n; changed = true; Console.success("pack size set to \(n) MiB") }
        else { Console.note("pack size already \(n) MiB") }
    }
    if cli.has("--clear-pack-size") {
        if set.packSizeMiB != nil { set.packSizeMiB = nil; changed = true; Console.success("pack size cleared (restic default, 16 MiB target)") }
        else { Console.note("no pack size was set") }
    }
    // REST-backend connection cap: persisted in the set (like pack size) so the
    // timer uses it too. Passed to restic as the global `-o rest.connections=N`
    // option; restic's own default is 5 parallel connections, which can 502 a
    // small store host under concurrent pack uploads. `--clear-rest-connections`
    // restores that default.
    if let raw = cli.value("--rest-connections") {
        guard let n = Int(raw), n > 0 else {
            Console.error("--rest-connections needs a positive integer, e.g. --rest-connections 2 to cap a small store host")
            exit(1)
        }
        if set.restConnections != n { set.restConnections = n; changed = true; Console.success("rest connections set to \(n)") }
        else { Console.note("rest connections already \(n)") }
    }
    if cli.has("--clear-rest-connections") {
        if set.restConnections != nil { set.restConnections = nil; changed = true; Console.success("rest connections cleared (restic default, 5 connections)") }
        else { Console.note("no rest connections cap was set") }
    }
    // Repo-quota gauge: persisted in the set so the UNATTENDED timer warns too
    // — that run is the whole point of the pre-flight gauge, and it reads only
    // the set. (`--repo-quota-bytes` remains the per-run override.) This was
    // previously a read-only field with no setter outside hand-editing the JSON.
    if let raw = cli.value("--repo-quota") {
        guard let n = Int(raw), n > 0 else {
            Console.error("--repo-quota needs a positive integer (bytes), e.g. --repo-quota 50000000000 for a 50 GB server quota")
            exit(1)
        }
        if set.quotaBytes != n {
            set.quotaBytes = n; changed = true
            Console.success(String(format: "repo quota set to %.2f GB — runs warn at the configured fraction before it fills", Double(n) / 1_000_000_000))
        } else { Console.note("repo quota already set to that value") }
    }
    if cli.has("--clear-repo-quota") {
        if set.quotaBytes != nil { set.quotaBytes = nil; changed = true; Console.success("repo quota cleared (no pre-flight gauge)") }
        else { Console.note("no repo quota was set") }
    }
    // Exclude globs: extra `restic backup --exclude` patterns on top of the
    // always-on macOS-junk defaults. Persisted so the timer applies them too.
    for e in cli.values("--add-exclude") {
        if set.addExclude(e) { changed = true; Console.success("added exclude  \(e)") }
        else { Console.note("exclude already in set (or empty): \(e)") }
    }
    for e in cli.values("--remove-exclude") {
        if set.removeExclude(e) { changed = true; Console.success("removed exclude  \(e)") }
        else { Console.note("exclude not in set: \(e)") }
    }
    // Exclude-files: paths to `restic backup --exclude-file` lists. Validated to
    // exist + be readable at add time — the common failure is a typo, and a
    // missing file would otherwise only surface as a warning at backup time. A
    // path that vanishes later is dropped (with a warning) at run time, never
    // failing the backup. Stored as typed (tilde kept); expanded only to check.
    for raw in cli.values("--add-exclude-file") {
        let expanded = (raw as NSString).expandingTildeInPath
        guard FileManager.default.isReadableFile(atPath: expanded) else {
            Console.error("exclude-file not found or unreadable: \(raw) — create it first (one restic exclude pattern per line), then add it")
            exit(1)
        }
        if set.addExcludeFile(raw) { changed = true; Console.success("added exclude-file  \(raw)") }
        else { Console.note("exclude-file already in set (or empty): \(raw)") }
    }
    for raw in cli.values("--remove-exclude-file") {
        if set.removeExcludeFile(raw) { changed = true; Console.success("removed exclude-file  \(raw)") }
        else { Console.note("exclude-file not in set: \(raw)") }
    }
    // Heartbeat: a Healthchecks-style dead-man's-switch URL, persisted so the
    // unattended timer pings it too — a monitor that never hears from a stopped
    // machine is the failure a local macOS banner can never report.
    if let raw = cli.value("--set-heartbeat") {
        guard OutboundNotifier.isValidHTTPURL(raw) else {
            Console.error("--set-heartbeat needs an http(s) URL — got '\(raw)' (e.g. https://hc-ping.com/your-uuid)")
            exit(1)
        }
        if set.setHeartbeat(raw) { changed = true; Console.success("heartbeat set to  \(Credentials.redactMonitorURL(raw))") }
        else { Console.note("heartbeat already set to that URL") }
    }
    if cli.has("--clear-heartbeat") {
        if set.clearHeartbeat() { changed = true; Console.success("heartbeat cleared") }
        else { Console.note("no heartbeat was set") }
    }
    // Push channels: ntfy and generic webhook, persisted so the timer pushes too.
    if let raw = cli.value("--add-ntfy") {
        guard OutboundNotifier.isValidHTTPURL(raw) else {
            Console.error("--add-ntfy needs an http(s) topic URL — got '\(raw)' (e.g. https://ntfy.sh/your-topic)")
            exit(1)
        }
        if set.addNotifyChannel(type: .ntfy, url: raw) { changed = true; Console.success("added ntfy channel  \(Credentials.redactMonitorURL(raw))") }
        else { Console.note("ntfy channel already configured: \(Credentials.redactMonitorURL(raw))") }
    }
    if let raw = cli.value("--add-webhook") {
        guard OutboundNotifier.isValidHTTPURL(raw) else {
            Console.error("--add-webhook needs an http(s) URL — got '\(raw)'")
            exit(1)
        }
        if set.addNotifyChannel(type: .webhook, url: raw) { changed = true; Console.success("added webhook channel  \(Credentials.redactMonitorURL(raw))") }
        else { Console.note("webhook channel already configured: \(Credentials.redactMonitorURL(raw))") }
    }
    if let raw = cli.value("--remove-notify") {
        if set.removeNotifyChannel(url: raw) { changed = true; Console.success("removed notify channel  \(Credentials.redactMonitorURL(raw))") }
        else { Console.note("no notify channel matches that URL: \(Credentials.redactMonitorURL(raw))") }
    }

    if changed {
        do { try set.save(to: configPath) }
        catch {
            Console.error("could not write backup set to \(configPath.path): \(error)")
            exit(1)
        }
    }
    listBackupSet(set, path: configPath, existed: existed || changed)
}
