import Foundation

/// Warn-only large-file detection: an acquired file over the configured
/// threshold gets flagged AFTER the fact, purely informational. It never
/// excludes anything and never changes the run outcome — the append-only store
/// bakes anything snapshotted in permanently, so the point is to let an
/// operator notice and `--add-exclude` on purpose, not to have this tool decide
/// for them.
enum LargeFileWarning {
    struct Item: Equatable {
        let path: String
        let bytes: Int
    }

    /// Which of `items` (path, byte count) exceed `thresholdMiB`. `thresholdMiB
    /// <= 0` disables the warning entirely (always returns empty) — 0 is the
    /// documented "disabled" value; a negative one is defensive (CLI validation
    /// should already reject it, but this stays safe either way).
    static func filter(_ items: [(path: String, bytes: Int)], thresholdMiB: Int) -> [Item] {
        guard thresholdMiB > 0 else { return [] }
        let thresholdBytes = thresholdMiB * 1_048_576
        return items
            .filter { $0.bytes > thresholdBytes }
            .map { Item(path: $0.path, bytes: $0.bytes) }
    }
}
