import Foundation

// baaackaaab acquisition prototype.
//
// One direction only: read iCloud Drive + Photos originals, verify the real
// bytes landed, stage them. Never writes back to the user's data. A separate
// shell step then hands the verified staging tree to restic.

func argValue(_ name: String, default fallback: String? = nil) -> String? {
    let args = CommandLine.arguments
    if let i = args.firstIndex(of: name), i + 1 < args.count {
        return args[i + 1]
    }
    return fallback
}

/// Collect every value of a repeatable flag, e.g. `--drive-folder a --drive-folder b`.
func argValues(_ name: String) -> [String] {
    let args = CommandLine.arguments
    var out: [String] = []
    var i = 0
    while i < args.count {
        if args[i] == name, i + 1 < args.count {
            out.append(args[i + 1])
            i += 2
        } else {
            i += 1
        }
    }
    return out
}

// Line-buffer stdout so our logs interleave in the right order with restic's
// child-process output. Without this, our print() output buffers and surfaces
// only after the subprocess has already written (and a file redirect would be
// block-buffered, scrambling the order entirely).
setvbuf(stdout, nil, _IOLBF, 0)

// Standalone diagnostic: prove the evict/dataless round-trip on one file.
// Runs in isolation and exits — never touches staging or the normal flow.
if let evictTarget = argValue("--evict-test") {
    do {
        try DriveAcquirer().evictRoundTripTest(URL(fileURLWithPath: evictTarget))
        exit(0)
    } catch {
        FileHandle.standardError.write("ERROR: \(error)\n".data(using: .utf8)!)
        exit(1)
    }
}

if let matTarget = argValue("--materialize-test") {
    do {
        try DriveAcquirer().materializeTest(URL(fileURLWithPath: matTarget))
        exit(0)
    } catch {
        FileHandle.standardError.write("ERROR: \(error)\n".data(using: .utf8)!)
        exit(1)
    }
}

let driveFolders = argValues("--drive-folder")
let photoAlbum = argValue("--photo-album")
let stagingURL = URL(fileURLWithPath: argValue("--staging", default: "./tmp/staging")!, isDirectory: true)
let photoBatchBytes = argValue("--photo-batch-bytes").flatMap { Int($0) } ?? 3_000_000_000
let host = argValue("--host") ?? ProcessInfo.processInfo.hostName

guard let repo = argValue("--restic-repo") ?? ProcessInfo.processInfo.environment["RESTIC_REPOSITORY"] else {
    FileHandle.standardError.write("ERROR: set --restic-repo or the RESTIC_REPOSITORY env var\n".data(using: .utf8)!)
    exit(1)
}

let runFmt = DateFormatter()
runFmt.locale = Locale(identifier: "en_US_POSIX")
runFmt.dateFormat = "yyyyMMdd-HHmmss"
let runTag = argValue("--run-tag") ?? "run-\(runFmt.string(from: Date()))"

do {
    let staging = try Staging(root: stagingURL)
    let restic = ResticBackend(repository: repo)
    print("== baaackaaab ==")
    print("repo:     \(repo)")
    print("host:     \(host)")
    print("run-tag:  \(runTag)")
    print("staging:  \(stagingURL.path) (scratch for photo batches only)")
    try restic.ensureInitialized()

    // 1) iCloud Drive — materialize + verify in place, then restic reads the
    //    source tree directly (no full-size staging copy). Strict: a stub that
    //    refuses to materialize aborts the whole Drive backup before it runs.
    if driveFolders.isEmpty {
        print("\n(no --drive-folder given, skipping Drive)")
    } else {
        var verifiedFolders: [URL] = []
        for folder in driveFolders {
            let url = URL(fileURLWithPath: (folder as NSString).expandingTildeInPath, isDirectory: true)
            print("\n--- iCloud Drive: \(url.path) ---")
            try DriveAcquirer().materializeAndVerify(folder: url, into: staging)
            verifiedFolders.append(url)
        }
        try restic.backup(paths: verifiedFolders, tags: [runTag, "drive"], host: host)
    }

    // 2) iCloud Photos — export in byte-budgeted batches; each batch is backed
    //    up and then deleted, so peak extra disk is ~one batch, not 27 GB.
    if let photoAlbum {
        print("\n--- iCloud Photos album: \(photoAlbum) (batch budget \(photoBatchBytes) bytes) ---")
        try PhotosAcquirer().acquireBatched(
            albumTitle: photoAlbum,
            byteBudget: photoBatchBytes,
            into: staging
        ) { batchDir, idx in
            try restic.backup(paths: [batchDir], tags: [runTag, "photos", "batch-\(idx)"], host: host)
        }
    } else {
        print("\n(no --photo-album given, skipping Photos)")
    }

    try staging.writeManifest()

    let verified = staging.items.filter { $0.verified }.count
    let total = staging.items.count
    print("\n== summary: \(verified)/\(total) items verified, run-tag \(runTag) ==")
    print("manifest: \(stagingURL.appendingPathComponent("manifest.json").path)")

    if total == 0 {
        print("FAIL: nothing was acquired")
        exit(2)
    }
    if verified != total {
        print("WARN: \(total - verified) item(s) failed verification and were skipped — review the manifest")
        exit(2)
    }
    print("OK: every acquired byte-stream verified and backed up under tag \(runTag)")
} catch {
    FileHandle.standardError.write("ERROR: \(error)\n".data(using: .utf8)!)
    exit(1)
}
