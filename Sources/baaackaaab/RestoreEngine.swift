import Foundation
#if canImport(Darwin)
import Darwin
#endif

// The safe restore engine. Restore is the one operation where baaackaaab writes a
// lot of data, so it is safe BY CONSTRUCTION:
//   - it NEVER writes back into the live iCloud Drive or Photos tree (those roots
//     are hard-rejected) — a restore lands in a fresh directory you move from;
//   - it refuses to restore over an existing non-empty directory (no in-place
//     overwrite, ever);
//   - the caller previews with --dry-run before writing and re-reads every
//     restored file with --verify after.
// The repository itself is only ever READ — a restore cannot modify or delete a
// snapshot, so this preserves the read + append-only invariant.
enum RestoreEngine {
    enum RestoreError: Error, CustomStringConvertible {
        case unsafeTarget(path: String, reason: String)
        case targetNotEmpty(String)
        case createFailed(path: String, underlying: String)

        var description: String {
            switch self {
            case .unsafeTarget(let p, let r):
                return "refusing to restore into \(p): \(r). A restore writes to a FRESH directory; move the files back into place yourself afterward."
            case .targetNotEmpty(let p):
                return "restore target \(p) already exists and is not empty — pick a new or empty directory (or omit --target for a fresh timestamped one)"
            case .createFailed(let p, let e):
                return "could not create restore target \(p): \(e)"
            }
        }
    }

    /// Live user-data roots a restore must never write into. We reject the whole
    /// iCloud container tree (Drive + per-app folders) and the Pictures tree (where
    /// the Photos library lives). Compared after symlink resolution so a symlinked
    /// target cannot slip a restore into one of them.
    private static func forbiddenRoots() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent("Library/Mobile Documents", isDirectory: true),
            home.appendingPathComponent("Pictures", isDirectory: true),
        ]
    }

    /// True when `path` is at or under one of the live iCloud Drive / Photos
    /// roots this tool must never write into (see `forbiddenRoots`). Shared by
    /// `validateTarget` (restore targets) and the recovery-kit export, which
    /// must refuse the same roots — a recovery kit synced back into the
    /// compromised-source domain defeats its purpose. Same case-insensitive,
    /// symlink-resolved comparison as the restore gate.
    static func isInsideForbiddenRoot(_ path: URL) -> Bool {
        let resolved = canonicalize(path)
        return forbiddenRoots().contains { isAtOrUnder(resolved, canonicalize($0)) }
    }

    /// Hard safety gate on the restore target. Rejects the filesystem root and
    /// near-root paths, the home directory itself, anything inside live iCloud
    /// Drive / Photos, and any existing non-empty directory. A non-existent path
    /// (the usual case for the fresh default) passes.
    ///
    /// The forbidden-root comparison is the safety-critical part. It must hold on a
    /// CASE-INSENSITIVE volume (APFS default on macOS): a literal lowercase target
    /// like `~/library/mobile documents/…` resolves on disk to the real iCloud
    /// Drive, so a case-sensitive string prefix check would wave it through. We
    /// therefore (1) canonicalize the target — realpath the longest existing
    /// ancestor, which yields its true on-disk case and resolves symlinks, then
    /// re-append the not-yet-existing tail — and (2) compare path COMPONENTS
    /// case-insensitively, so neither case nor a component boundary can be gamed.
    static func validateTarget(_ target: URL) throws {
        let resolved = canonicalize(target)
        let path = resolved.path
        let home = canonicalize(FileManager.default.homeDirectoryForCurrentUser)

        if resolved.pathComponents.count < 3 {
            throw RestoreError.unsafeTarget(path: path, reason: "that is too close to the filesystem root")
        }
        if samePath(resolved, home) {
            throw RestoreError.unsafeTarget(path: path, reason: "that is your home directory")
        }
        for root in forbiddenRoots() {
            if isAtOrUnder(resolved, canonicalize(root)) {
                throw RestoreError.unsafeTarget(
                    path: path,
                    reason: "that is inside live iCloud Drive / Photos — restoring there could overwrite your originals")
            }
        }
        // Fresh-directory requirement: non-existent is ideal; an existing path must
        // be an empty directory. A .DS_Store does not count as "in use".
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: path, isDirectory: &isDir) {
            guard isDir.boolValue else {
                throw RestoreError.unsafeTarget(path: path, reason: "a file already exists at that path")
            }
            let entries = (try? fm.contentsOfDirectory(atPath: path)) ?? []
            if !entries.filter({ $0 != ".DS_Store" }).isEmpty {
                throw RestoreError.targetNotEmpty(path)
            }
        }
    }

    /// Canonicalize a path for safe comparison on a case-insensitive volume:
    /// realpath the LONGEST existing ancestor (which returns its true on-disk case
    /// and fully resolves symlinks), then re-append the components that do not
    /// exist yet (the fresh restore dir). Falls back to the standardized path when
    /// nothing along it exists.
    private static func canonicalize(_ url: URL) -> URL {
        let components = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let fm = FileManager.default
        var existing = components.count
        while existing > 0 {
            let prefix = NSString.path(withComponents: Array(components[0..<existing]))
            if fm.fileExists(atPath: prefix) {
                guard let real = realpathString(prefix) else { break }
                var result = URL(fileURLWithPath: real, isDirectory: true)
                for c in components[existing...] { result.appendPathComponent(c) }
                return result.standardizedFileURL
            }
            existing -= 1
        }
        return url.standardizedFileURL
    }

    /// realpath(3) wrapper: the canonical, symlink-free, true-case absolute path,
    /// or nil if it cannot be resolved.
    private static func realpathString(_ path: String) -> String? {
        guard let c = realpath(path, nil) else { return nil }
        defer { free(c) }
        return String(cString: c)
    }

    /// True when `path` is `root` or a descendant of it, comparing path COMPONENTS
    /// case-insensitively (so neither letter-case nor a component boundary —
    /// e.g. `~/PicturesXYZ` vs `~/Pictures` — can sneak past).
    private static func isAtOrUnder(_ path: URL, _ root: URL) -> Bool {
        let p = path.pathComponents.map { $0.lowercased() }
        let r = root.pathComponents.map { $0.lowercased() }
        guard p.count >= r.count else { return false }
        return Array(p.prefix(r.count)) == r
    }

    /// True when two paths are the same directory (case-insensitive, component-wise).
    private static func samePath(_ a: URL, _ b: URL) -> Bool {
        a.pathComponents.map { $0.lowercased() } == b.pathComponents.map { $0.lowercased() }
    }

    /// The default fresh target when --target is omitted:
    /// ~/baaackaaab-restore/<snapshot>-<stamp>. The caller passes the timestamp so
    /// the directory name is deterministic for the invocation.
    static func defaultTarget(snapshot: String, stamp: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("baaackaaab-restore", isDirectory: true)
            .appendingPathComponent("\(snapshot)-\(stamp)", isDirectory: true)
    }

    /// Create the (already-validated) target directory, 0700.
    static func ensureTargetDir(_ target: URL) throws {
        do {
            try FileManager.default.createDirectory(
                at: target, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        } catch {
            throw RestoreError.createFailed(path: target.path, underlying: "\(error)")
        }
    }
}
