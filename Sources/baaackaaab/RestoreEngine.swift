import Foundation

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

    /// Hard safety gate on the restore target. Rejects the filesystem root and
    /// near-root paths, the home directory itself, anything inside live iCloud
    /// Drive / Photos, and any existing non-empty directory. A non-existent path
    /// (the usual case for the fresh default) passes.
    static func validateTarget(_ target: URL) throws {
        let resolved = target.resolvingSymlinksInPath().standardizedFileURL
        let path = resolved.path
        let home = FileManager.default.homeDirectoryForCurrentUser
            .resolvingSymlinksInPath().standardizedFileURL

        if path == "/" || resolved.pathComponents.count < 3 {
            throw RestoreError.unsafeTarget(path: path, reason: "that is too close to the filesystem root")
        }
        if path == home.path {
            throw RestoreError.unsafeTarget(path: path, reason: "that is your home directory")
        }
        for root in forbiddenRoots() {
            let r = root.resolvingSymlinksInPath().standardizedFileURL.path
            if path == r || path.hasPrefix(r + "/") {
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
