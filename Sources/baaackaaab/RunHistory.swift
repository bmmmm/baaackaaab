import Foundation

// Append-only run history: one NDJSON line per backup run under the support dir.
// It is the unattended timer's black box — a scheduled run prints to a log nobody
// reads, so this is where "did last night's backup succeed, and to which
// destinations" actually lives. The dashboard reads the tail of it.
//
// Contains no secrets: run tag, timestamps, verified/total counts, per-destination
// name + ok flag + (already-redacted) restic error string. Written 0600 anyway,
// to match the rest of the store.

/// One recorded backup run. Times are ISO-8601; `exitCode` mirrors the process
/// exit (0 ok, 2 partial/failed, 1 crashed early, 130 cancelled).
struct RunRecord: Codable {
    let runTag: String
    let start: Date
    let end: Date
    let exitCode: Int
    let verified: Int
    let total: Int
    let sourceFailures: Int
    let destinations: [Dest]

    /// Per-destination outcome for the run. `error` is nil on success; on failure
    /// it is the restic error description (already redacted, never a secret).
    struct Dest: Codable {
        let name: String
        let ok: Bool
        let error: String?
    }

    enum CodingKeys: String, CodingKey {
        case runTag = "run_tag"
        case start, end
        case exitCode = "exit"
        case verified, total
        case sourceFailures = "source_failures"
        case destinations
    }

    /// True when every destination got every byte and nothing was skipped.
    var clean: Bool { exitCode == 0 }
}

enum RunHistory {
    /// ~/Library/Application Support/baaackaaab/runs.ndjson (honors the
    /// BAAACKAAAB_SUPPORT_DIR override via CredentialFiles.dir, so tests and a
    /// relocated store keep their history together with their credentials).
    static var file: URL { CredentialFiles.dir.appendingPathComponent("runs.ndjson") }

    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// Append one record as a single JSON line, creating the file 0600 on first
    /// write. Best-effort by contract: recording history must NEVER fail a backup,
    /// so callers invoke this as `try?` — a full disk or a permission glitch costs
    /// a log line, not the run.
    static func append(_ record: RunRecord) throws {
        var data = try encoder().encode(record)
        data.append(0x0A)   // newline — one record per line (NDJSON)
        let fm = FileManager.default
        try fm.createDirectory(at: CredentialFiles.dir, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        if !fm.fileExists(atPath: file.path) {
            fm.createFile(atPath: file.path, contents: nil,
                          attributes: [.posixPermissions: 0o600])
        }
        let fh = try FileHandle(forWritingTo: file)
        defer { try? fh.close() }
        try fh.seekToEnd()
        try fh.write(contentsOf: data)
    }

    /// The last `limit` records, newest first, for the dashboard. Tolerant of a
    /// corrupt/partially-written trailing line (a crash mid-write) — that line is
    /// simply dropped rather than failing the whole read.
    static func recent(_ limit: Int) -> [RunRecord] {
        guard let data = FileManager.default.contents(atPath: file.path),
              let text = String(data: data, encoding: .utf8) else { return [] }
        let dec = decoder()
        let records = text.split(separator: "\n").compactMap { line -> RunRecord? in
            guard let d = line.data(using: .utf8) else { return nil }
            return try? dec.decode(RunRecord.self, from: d)
        }
        return Array(records.suffix(limit).reversed())
    }
}
