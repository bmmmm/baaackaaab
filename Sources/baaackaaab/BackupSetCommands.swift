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
    if set.isEmpty {
        Console.note("empty — add folders with --add-folder <dir>, albums with --add-album <name>")
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
    Console.info(pairs)
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

    if changed {
        do { try set.save(to: configPath) }
        catch {
            Console.error("could not write backup set to \(configPath.path): \(error)")
            exit(1)
        }
    }
    listBackupSet(set, path: configPath, existed: existed || changed)
}
