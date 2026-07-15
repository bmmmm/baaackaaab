import Foundation

// The declarative backup set: the single source of truth for WHAT gets backed
// up. A plain JSON file the user (or a future GUI) edits; the CLI reads it on a
// bare `baaackaaab` run and manages it via --list / --add-folder / etc.
//
// File-first by design: the file is the truth, every front-end is just an editor
// of it. That keeps the tool usable with no GUI at all, and lets the launchd
// timer run `baaackaaab` with zero arguments — the set is what gets backed up.
//
// Pure Foundation, no dependencies. Paths are stored AS THE USER TYPED THEM
// (tilde kept) so the file stays portable and hand-editable; tilde expansion
// happens only at run time.
struct BackupSet: Codable, Equatable {
    var driveFolders: [String]
    var photoAlbums: [String]
    /// Optional configured server quota in bytes, for the soft pre-flight gauge.
    var quotaBytes: Int?
    /// Optional upload throttle in KiB/s, passed to `restic backup --limit-upload`.
    /// Persisted here so the unattended timer (which runs a bare `baaackaaab`) is
    /// throttled too — an overnight backup can be capped without touching the timer.
    var limitUploadKiBps: Int?
    /// Optional restic target pack size in MiB, passed to `restic backup
    /// --pack-size`. Persisted here so the unattended timer uses it too. Larger
    /// packs mean fewer, bigger objects on a network REST/S3 backend (fewer
    /// round-trips) at the cost of RAM and re-upload on interruption. restic's
    /// own default target is 16 MiB when this is unset; valid range 4…128.
    var packSizeMiB: Int?
    /// Extra restic exclude globs, on top of the always-on macOS-junk defaults
    /// (see ResticBackend.junkExcludes). Persisted here so the unattended timer
    /// applies them too. Each is a `restic backup --exclude` pattern — matched on
    /// path components, so a slash-less pattern (`*.tmp`, `node_modules`) matches
    /// that base name anywhere in the tree. On the append-only store, keeping junk
    /// out matters more than usual: a snapshotted file can never be pruned away.
    var excludes: [String]
    /// Paths to restic `--exclude-file`s, persisted so the timer uses them too.
    /// Stored as the user typed them (tilde kept); expanded + existence-checked at
    /// run time (a missing file is dropped with a warning, never fails the backup).
    var excludeFiles: [String]

    init(driveFolders: [String] = [], photoAlbums: [String] = [],
         quotaBytes: Int? = nil, limitUploadKiBps: Int? = nil,
         packSizeMiB: Int? = nil, excludes: [String] = [], excludeFiles: [String] = []) {
        self.driveFolders = driveFolders
        self.photoAlbums = photoAlbums
        self.quotaBytes = quotaBytes
        self.limitUploadKiBps = limitUploadKiBps
        self.packSizeMiB = packSizeMiB
        self.excludes = excludes
        self.excludeFiles = excludeFiles
    }

    // Stable snake_case keys, written explicitly so the on-disk file stays
    // readable and decode never depends on a global strategy.
    enum CodingKeys: String, CodingKey {
        case driveFolders = "drive_folders"
        case photoAlbums = "photo_albums"
        case quotaBytes = "quota_bytes"
        case limitUploadKiBps = "limit_upload_kibps"
        case packSizeMiB = "pack_size_mib"
        case excludes
        case excludeFiles = "exclude_files"
    }

    // Tolerant decode: a hand-edited file may omit an array entirely (e.g. only
    // photo_albums set). Treat any missing list as empty instead of failing the
    // whole load. Encode stays synthesized (omits nil knobs, keeps both lists).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        driveFolders = try c.decodeIfPresent([String].self, forKey: .driveFolders) ?? []
        photoAlbums = try c.decodeIfPresent([String].self, forKey: .photoAlbums) ?? []
        quotaBytes = try c.decodeIfPresent(Int.self, forKey: .quotaBytes)
        limitUploadKiBps = try c.decodeIfPresent(Int.self, forKey: .limitUploadKiBps)
        packSizeMiB = try c.decodeIfPresent(Int.self, forKey: .packSizeMiB)
        excludes = try c.decodeIfPresent([String].self, forKey: .excludes) ?? []
        excludeFiles = try c.decodeIfPresent([String].self, forKey: .excludeFiles) ?? []
    }

    // A set with no sources contributes nothing to a run.
    var isEmpty: Bool { driveFolders.isEmpty && photoAlbums.isEmpty }

    // MARK: - Location

    /// Default config path: ~/.config/baaackaaab/backup-set.json. XDG-style so it
    /// is easy to find and hand-edit; overridable with --config for tests.
    static func defaultPath() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("baaackaaab", isDirectory: true)
            .appendingPathComponent("backup-set.json", isDirectory: false)
    }

    // MARK: - Load / save

    /// Decode the set from `url`. Throws on unreadable/corrupt JSON — the caller
    /// checks file existence first to tell "no set yet" from "broken set".
    static func load(from url: URL) throws -> BackupSet {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(BackupSet.self, from: data)
    }

    /// Write the set to `url`, creating the parent directory. Pretty-printed,
    /// keys sorted, slashes unescaped so the file reads cleanly when hand-edited.
    func save(to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(self)
        data.append(0x0A)   // trailing newline — plays nicer with editors and diffs
        try data.write(to: url, options: .atomic)
    }

    // MARK: - Mutation (each returns true when the set actually changed)

    /// Normalize a path for storage and comparison: trim whitespace and a single
    /// trailing slash so `~/x` and `~/x/` are the same entry. Tilde is kept.
    private static func normalizeFolder(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.count > 1 && s.hasSuffix("/") { s.removeLast() }
        return s
    }

    mutating func addFolder(_ raw: String) -> Bool {
        let f = Self.normalizeFolder(raw)
        guard !f.isEmpty, !driveFolders.contains(f) else { return false }
        driveFolders.append(f)
        return true
    }

    mutating func removeFolder(_ raw: String) -> Bool {
        let f = Self.normalizeFolder(raw)
        guard let i = driveFolders.firstIndex(of: f) else { return false }
        driveFolders.remove(at: i)
        return true
    }

    /// Whether `raw` is in the set, under the same normalization addFolder and
    /// removeFolder use — so a caller comparing against the stored spelling
    /// (e.g. the TUI's selection markers) cannot drift from the mutation rules.
    func containsFolder(_ raw: String) -> Bool {
        driveFolders.contains(Self.normalizeFolder(raw))
    }

    mutating func addAlbum(_ raw: String) -> Bool {
        let a = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !a.isEmpty, !photoAlbums.contains(a) else { return false }
        photoAlbums.append(a)
        return true
    }

    mutating func removeAlbum(_ raw: String) -> Bool {
        let a = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let i = photoAlbums.firstIndex(of: a) else { return false }
        photoAlbums.remove(at: i)
        return true
    }

    // Exclude globs and exclude-file paths follow the same trim/dedup contract as
    // folders. They are stored verbatim (no path normalization): a glob is not a
    // path, and an exclude-file keeps its tilde like a drive folder does. Existence
    // of an exclude-file is checked by the caller, not here (this stays pure).
    mutating func addExclude(_ raw: String) -> Bool {
        let e = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !e.isEmpty, !excludes.contains(e) else { return false }
        excludes.append(e)
        return true
    }

    mutating func removeExclude(_ raw: String) -> Bool {
        let e = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let i = excludes.firstIndex(of: e) else { return false }
        excludes.remove(at: i)
        return true
    }

    mutating func addExcludeFile(_ raw: String) -> Bool {
        let f = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !f.isEmpty, !excludeFiles.contains(f) else { return false }
        excludeFiles.append(f)
        return true
    }

    mutating func removeExcludeFile(_ raw: String) -> Bool {
        let f = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let i = excludeFiles.firstIndex(of: f) else { return false }
        excludeFiles.remove(at: i)
        return true
    }
}
