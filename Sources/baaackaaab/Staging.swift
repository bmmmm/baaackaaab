import Foundation

/// One acquired, verified byte-stream on its way into the backup.
/// `verified` is the safety gate: the orchestrator refuses to back up
/// anything that did not pass verification (this is how we avoid silently
/// backing up empty iCloud stub files).
struct AcquiredItem: Codable {
    let source: String      // logical origin: a Drive path or "<assetId>#<resourceType>"
    let kind: String        // "drive" | "photo-resource"
    let stagedPath: String
    let byteCount: Int
    let verified: Bool
    let note: String?
}

/// Owns the staging directory: scratch space for data on its way to restic.
/// Photos are exported here in byte-budgeted batches — a dataless asset would
/// otherwise reach restic as a 0-byte file. Drive is the deliberate exception:
/// it is verified in place and restic reads the live tree directly (a full copy
/// would cost the ~11 GB the in-place design avoids on a disk-constrained Mac).
/// A materialize-and-verify pass plus a post-backup re-eviction check guard
/// against capturing a stub there, so the verification invariant below holds for
/// both sources.
final class Staging {
    let root: URL
    private(set) var items: [AcquiredItem] = []

    init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func subdir(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func record(_ item: AcquiredItem) {
        items.append(item)
    }

    func writeManifest() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(items)
        // Atomic: a crash mid-write must not leave a truncated manifest that a
        // later read would fail to parse.
        try data.write(to: root.appendingPathComponent("manifest.json"), options: .atomic)
    }

    /// Make a string safe to use as a path component (asset ids contain "/", and
    /// an untrusted source filename could be ".", ".." or empty, which would
    /// escape or collapse the staging path when appended).
    static func sanitize(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:")
        let cleaned = s.components(separatedBy: bad).joined(separator: "_")
        switch cleaned {
        case "":   return "_"
        case ".":  return "_"
        case "..": return "__"
        default:   return cleaned
        }
    }
}
