import Foundation

enum DriveError: Error, CustomStringConvertible {
    case cannotEnumerate(String)
    case downloadTimeout(String)
    case stillDataless(String)
    case verifyFailed(String)

    var description: String {
        switch self {
        case .cannotEnumerate(let p): return "cannot enumerate \(p)"
        case .downloadTimeout(let p): return "iCloud download timed out for \(p)"
        case .stillDataless(let p): return "file is still a dataless stub after download attempt: \(p)"
        case .verifyFailed(let p): return "byte verification failed for \(p)"
        }
    }
}

/// Acquires a small set of iCloud Drive files: materializes any cloud-only
/// stubs, copies the real bytes into staging, and verifies them.
///
/// Strictly read-only towards the user's data — it only triggers downloads
/// (non-destructive) and reads. It never writes back into the Drive tree.
final class DriveAcquirer {
    private let fm = FileManager.default

    // BSD flag set on iCloud "dataless" placeholder files (sys/stat.h).
    private let SF_DATALESS: UInt32 = 0x4000_0000

    /// The discriminating signal for "this looks like a real file but holds no
    /// bytes": the dataless flag. `stat`/`ls` size lies for stubs, so we check
    /// the flag, not the logical size.
    func isDataless(_ url: URL) -> Bool {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return false }
        return (st.st_flags & SF_DATALESS) != 0
    }

    func downloadStatusDescription(_ url: URL) -> String {
        let keys: Set<URLResourceKey> = [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]
        guard let vals = try? url.resourceValues(forKeys: keys) else { return "unknown" }
        let ubiquitous = vals.isUbiquitousItem ?? false
        let status = vals.ubiquitousItemDownloadingStatus?.rawValue ?? "n/a"
        return "ubiquitous=\(ubiquitous) status=\(status)"
    }

    private func isMaterialized(_ url: URL) -> Bool {
        if isDataless(url) { return false }
        let status = (try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]))?
            .ubiquitousItemDownloadingStatus
        // Non-ubiquitous files have nil status and are by definition local.
        guard let status else { return true }
        return status == .current || status == .downloaded
    }

    /// Materialize a cloud-only file and wait until the real bytes land.
    ///
    /// Modern iCloud Drive is FileProvider-backed, where
    /// `startDownloadingUbiquitousItem` is a no-op (verified empirically: it
    /// times out, the stub never downloads). The reliable trigger is a
    /// COORDINATED READ — `NSFileCoordinator` faults the contents in on demand
    /// and only invokes the accessor once the bytes are present. We run it off
    /// the main thread and bound the wait with a semaphore timeout.
    func ensureMaterialized(_ url: URL, timeout: TimeInterval) throws {
        if isMaterialized(url) { return }
        try? fm.startDownloadingUbiquitousItem(at: url)   // legacy kick; harmless no-op on FileProvider

        let sem = DispatchSemaphore(value: 0)
        var failure: Error?
        DispatchQueue.global(qos: .userInitiated).async {
            let coordinator = NSFileCoordinator()
            var coordErr: NSError?
            coordinator.coordinate(readingItemAt: url, options: [], error: &coordErr) { readURL in
                // Touching one byte forces the file provider to materialize it.
                if let fh = try? FileHandle(forReadingFrom: readURL) {
                    _ = fh.readData(ofLength: 1)
                    try? fh.close()
                }
            }
            failure = coordErr
            sem.signal()
        }

        if sem.wait(timeout: .now() + timeout) == .timedOut {
            throw DriveError.downloadTimeout(url.lastPathComponent)
        }
        if let failure {
            throw DriveError.downloadTimeout("\(url.lastPathComponent): \(failure)")
        }
        if isDataless(url) {
            throw DriveError.stillDataless(url.lastPathComponent)
        }
    }

    func acquire(folder: URL, into staging: Staging) throws {
        let driveDir = try staging.subdir("drive")
        guard let enumerator = fm.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw DriveError.cannotEnumerate(folder.path)
        }

        for case let fileURL as URL in enumerator {
            let isFile = (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile ?? false
            guard isFile else { continue }

            let rel = relativePath(of: fileURL, base: folder)
            print("[drive] \(rel) — \(downloadStatusDescription(fileURL)) dataless=\(isDataless(fileURL))")

            try ensureMaterialized(fileURL, timeout: 120)
            if isDataless(fileURL) {
                throw DriveError.stillDataless(rel)
            }

            // Copy real bytes into staging, preserving the relative layout.
            let dest = driveDir.appendingPathComponent(rel)
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.copyItem(at: fileURL, to: dest)

            // Verify: staged bytes present and size matches the source.
            let srcSize = (try fileURL.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? -1
            let dstSize = (try dest.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? -2
            let ok = dstSize > 0 && srcSize == dstSize
            staging.record(AcquiredItem(
                source: fileURL.path,
                kind: "drive",
                stagedPath: dest.path,
                byteCount: dstSize,
                verified: ok,
                note: ok ? nil : "size mismatch src=\(srcSize) dst=\(dstSize)"
            ))
            print("[drive]   -> staged \(dstSize) bytes verified=\(ok)")
            if !ok { throw DriveError.verifyFailed(rel) }
        }
    }

    /// Materialize every regular file under `folder` and prove it holds real
    /// bytes — WITHOUT copying. This lets restic read the live tree directly,
    /// so we avoid a full-size staging copy (the Drive set is ~11 GB and the
    /// Mac is disk-constrained). The safety guarantee is unchanged: we never
    /// hand restic a dataless 0-byte placeholder, because we throw on the first
    /// stub that refuses to materialize. A legitimately empty file (0 bytes,
    /// not dataless) is fine — the dataless flag, not the size, is the signal.
    func materializeAndVerify(folder: URL, into staging: Staging) throws {
        guard let enumerator = fm.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw DriveError.cannotEnumerate(folder.path)
        }

        var count = 0
        for case let fileURL as URL in enumerator {
            let isFile = (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile ?? false
            guard isFile else { continue }

            let rel = relativePath(of: fileURL, base: folder)
            try ensureMaterialized(fileURL, timeout: 120)
            if isDataless(fileURL) { throw DriveError.stillDataless(rel) }

            let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? -1
            staging.record(AcquiredItem(
                source: fileURL.path,
                kind: "drive",
                stagedPath: fileURL.path,   // backed up in place — no copy
                byteCount: size,
                verified: true,
                note: "in-place (restic reads source)"
            ))
            count += 1
        }
        print("[drive] materialized + verified \(count) file(s) under \(folder.lastPathComponent) — restic reads in place")
    }

    private func isUbiquitous(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem ?? false
    }

    /// Given a file that is ALREADY a dataless stub (create one for testing with
    /// `brctl evict <file>`), prove we can turn it back into real, readable bytes.
    /// This is the #1 data-loss guard: never back up a 0-byte placeholder.
    func materializeTest(_ url: URL) throws {
        print("[materialize-test] target: \(url.path)")
        print("[materialize-test] start: \(downloadStatusDescription(url)) dataless=\(isDataless(url))")
        guard isDataless(url) else {
            print("[materialize-test] SKIP: not a dataless stub right now. Create one first (`brctl evict <file>`), then re-run.")
            return
        }

        let t0 = Date()
        try ensureMaterialized(url, timeout: 60)
        let secs = Date().timeIntervalSince(t0)

        let nowDataless = isDataless(url)
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? -1
        var firstBytesReadable = false
        if let fh = try? FileHandle(forReadingFrom: url) {
            firstBytesReadable = !fh.readData(ofLength: 16).isEmpty
            try? fh.close()
        }
        print("[materialize-test] after: dataless=\(nowDataless) size=\(size) firstBytesReadable=\(firstBytesReadable) (\(String(format: "%.1f", secs))s)")
        print(!nowDataless && size > 0 && firstBytesReadable
            ? "[materialize-test] PASS: dataless stub -> materialized -> real bytes readable"
            : "[materialize-test] FAIL: stub did not fully materialize into readable bytes")
    }

    /// Proves the full round-trip on a SINGLE file using only public APIs:
    /// materialize -> evict (FileManager.evictUbiquitousItem) -> detect the
    /// dataless stub -> re-materialize -> verify. This exercises op #3 (evict)
    /// and the stub-detection that protects us from backing up 0-byte placeholders.
    func evictRoundTripTest(_ url: URL) throws {
        print("[evict-test] target: \(url.path)")
        print("[evict-test] isUbiquitousItem=\(isUbiquitous(url)) \(downloadStatusDescription(url)) dataless=\(isDataless(url))")

        // Best-effort materialize first, so there is something to evict.
        do {
            try ensureMaterialized(url, timeout: 120)
            print("[evict-test] ensured materialized")
        } catch {
            print("[evict-test] materialize note: \(error)")
        }

        // Try the public evict API. Modern iCloud Drive is FileProvider-backed,
        // so this legacy ubiquity call MAY throw or no-op even though the file
        // is cloud-managed — that outcome is itself the signal we want.
        do {
            try fm.evictUbiquitousItem(at: url)
            print("[evict-test] evictUbiquitousItem: OK")
        } catch {
            print("[evict-test] evictUbiquitousItem THREW: \(error)")
        }

        let deadline = Date().addingTimeInterval(30)
        while !isDataless(url) && Date() < deadline { Thread.sleep(forTimeInterval: 0.5) }
        let becameDataless = isDataless(url)
        print("[evict-test] after evict attempt: dataless=\(becameDataless) \(downloadStatusDescription(url))")

        if becameDataless {
            do { try ensureMaterialized(url, timeout: 120) } catch { print("[evict-test] re-materialize note: \(error)") }
            let stillDataless = isDataless(url)
            print("[evict-test] after re-download: dataless=\(stillDataless)")
            print(stillDataless
                ? "[evict-test] FAIL: still dataless after re-download attempt"
                : "[evict-test] PASS: evict -> dataless detected -> re-materialized")
        } else {
            print("[evict-test] INCONCLUSIVE: file never became a dataless stub (evict is a no-op under FileProvider, or 'Optimize Mac Storage' is off so iCloud keeps it pinned). This means we likely need NSFileProviderManager, not the legacy ubiquity API.")
        }
    }

    private func relativePath(of url: URL, base: URL) -> String {
        let basePath = base.standardizedFileURL.path
        let full = url.standardizedFileURL.path
        if full.hasPrefix(basePath) {
            return String(full.dropFirst(basePath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        return url.lastPathComponent
    }
}
