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

/// Owns the staging directory: a clean, fully-materialized copy of everything
/// we are about to hand to restic. We never back up the live iCloud tree
/// directly, because a dataless stub there would be captured as a 0-byte file.
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
        try data.write(to: root.appendingPathComponent("manifest.json"))
    }

    /// Make a string safe to use as a path component (asset ids contain "/").
    static func sanitize(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:")
        return s.components(separatedBy: bad).joined(separator: "_")
    }
}
