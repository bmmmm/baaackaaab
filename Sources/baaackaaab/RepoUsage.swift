import Foundation

/// Pure aggregation behind `--repo-usage`: turns a flat `restic ls -l` listing
/// into a size breakdown an operator can act on ("what is actually filling the
/// permanent store"). No filesystem, no process — takes plain path/size pairs
/// so it's directly unit-testable against hand-built fixtures.
enum RepoUsage {
    /// One aggregated bucket: a path prefix plus the total logical bytes of
    /// every file under it.
    struct Bucket {
        let path: String
        let bytes: Int
    }

    /// Split an absolute snapshot path into components, dropping the leading
    /// empty component the leading `/` produces.
    static func components(of path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    /// Aggregate FILE sizes (restic `ls` also emits directory nodes, which carry
    /// no useful size of their own and would double-count their contents) by
    /// their top-level path component, plus a secondary breakdown one level
    /// deeper — but only under whichever top-level bucket is largest, which is
    /// the one an operator actually wants to drill into. Both lists are sorted
    /// descending by size. `secondaryOf` is nil when there is nothing to bucket
    /// (no files at all).
    static func aggregate(entries: [ResticBackend.LsEntry]) -> (top: [Bucket], secondaryOf: String?, secondary: [Bucket]) {
        let files = entries.filter { $0.type == "file" }

        var topTotals: [String: Int] = [:]
        for f in files {
            guard let first = components(of: f.path).first else { continue }
            topTotals[first, default: 0] += f.size ?? 0
        }
        let top = topTotals.map { Bucket(path: $0.key, bytes: $0.value) }
            .sorted { $0.bytes == $1.bytes ? $0.path < $1.path : $0.bytes > $1.bytes }

        guard let largest = top.first else { return ([], nil, []) }

        var secondTotals: [String: Int] = [:]
        for f in files {
            let comps = components(of: f.path)
            guard comps.first == largest.path, comps.count >= 2 else { continue }
            secondTotals[comps[1], default: 0] += f.size ?? 0
        }
        let secondary = secondTotals.map { Bucket(path: $0.key, bytes: $0.value) }
            .sorted { $0.bytes == $1.bytes ? $0.path < $1.path : $0.bytes > $1.bytes }

        return (top, largest.path, secondary)
    }
}
