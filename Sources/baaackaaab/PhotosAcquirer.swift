import Foundation
import Photos

/// One user album, as shown in the configure picker.
struct PhotoAlbumInfo {
    let title: String
    let count: Int
}

enum PhotosError: Error, CustomStringConvertible {
    case notAuthorized(String)
    case authorizationTimedOut(Int)
    case albumNotFound(String)
    case albumEmpty(String)

    var description: String {
        switch self {
        case .notAuthorized(let s): return "Photos access not granted (status: \(s)). Grant your terminal app access under System Settings > Privacy & Security > Photos."
        case .authorizationTimedOut(let s): return "Photos authorization did not return within \(s)s — the system prompt machinery appears wedged (this is NOT a denial). Re-run, or grant access manually under System Settings > Privacy & Security > Photos."
        case .albumNotFound(let t): return "album not found: '\(t)' (create it in Photos.app and drop a few photos in)"
        case .albumEmpty(let t): return "album '\(t)' is empty"
        }
    }
}

/// Acquires originals from an iCloud Photos album via PhotoKit.
///
/// We deliberately do NOT touch the `.photoslibrary` package on disk — that is
/// unsupported and can corrupt the library. Instead we go through PhotoKit and
/// export every resource of every asset (original photo, paired Live-Photo
/// video, RAW, etc.), allowing iCloud network download for cloud-only assets.
final class PhotosAcquirer {

    /// Upper bound on a single resource's iCloud download. Generous (a 4K video
    /// resource over a slow link is legitimately slow) but finite: without it a
    /// stuck download would hang the whole backup forever — and under launchd
    /// that also blocks every following scheduled run. On timeout the request is
    /// CANCELLED (see exportResources), the resource is recorded unverified and
    /// skipped; the run continues.
    private let resourceTimeout: TimeInterval = 600

    /// Whether the current batch should flush BEFORE the next asset is exported:
    /// only when the batch already holds data and the next asset's estimated
    /// size would push it past the budget. Keeps peak staging disk at
    /// ~max(budget, single asset) instead of budget + asset — on the
    /// disk-constrained Mac this tool targets, a 4K-video asset landing on a
    /// nearly-full batch would otherwise spike well past the documented
    /// "~one batch" invariant. A nil estimate (PhotoKit exposes no public size)
    /// changes nothing. Pure — unit-testable.
    static func shouldPreFlush(batchBytes: Int, estimatedAssetBytes: Int?, budget: Int) -> Bool {
        guard batchBytes > 0, let estimate = estimatedAssetBytes, estimate > 0 else { return false }
        return batchBytes + estimate > budget
    }

    /// Best-effort size estimate for one asset: the sum of its resources'
    /// `fileSize` values, read via KVC — PhotoKit has no public size API, but
    /// this key has been stable for years and is only ever used to decide an
    /// early flush (a nil/wrong estimate costs nothing but the old peak-disk
    /// behavior). nil when no resource reports a size.
    static func estimatedSize(of resources: [PHAssetResource]) -> Int? {
        let sizes = resources.compactMap { ($0.value(forKey: "fileSize") as? NSNumber)?.intValue }
        return sizes.isEmpty ? nil : sizes.reduce(0, +)
    }

    /// A FileHandle wrapper that makes "download chunk arrives" and "we gave up
    /// and closed the file" safe to race: PHAssetResourceManager's
    /// dataReceivedHandler can fire concurrently with the timeout path, and a
    /// write on a closed FileHandle raises. All access under one lock; writes
    /// after close are silently dropped (the request is being cancelled anyway).
    final class GuardedFileWriter: @unchecked Sendable {
        private let lock = NSLock()
        private var handle: FileHandle?
        private(set) var failed = false

        init?(path: String) {
            guard FileManager.default.createFile(atPath: path, contents: nil),
                  let h = FileHandle(forWritingAtPath: path) else { return nil }
            handle = h
        }

        func write(_ data: Data) {
            lock.lock(); defer { lock.unlock() }
            guard let h = handle else { return }
            do { try h.write(contentsOf: data) } catch { failed = true }
        }

        func close() {
            lock.lock(); defer { lock.unlock() }
            try? handle?.close()
            handle = nil
        }
    }

    /// Bound on the one-time Photos authorization wait. Long enough for a human
    /// to answer the macOS prompt on first grant; under launchd TCC decides
    /// immediately, so this only ever matters if the prompt machinery wedges.
    private let authTimeout: TimeInterval = 300

    /// Export the album in byte-budgeted batches. After each batch fills the
    /// budget it is handed to `onBatchReady` (which backs it up) and then
    /// deleted, so peak extra disk is ~one batch — not the whole library. This
    /// is what lets a 27 GB library back up on a near-full Mac.
    ///
    /// Best-effort per resource: a single failed iCloud download is removed
    /// (never backed up as a 0-byte file) and recorded as unverified, but does
    /// not abort the run — one bad asset must not block the other 27 GB.
    func acquireBatched(
        albumTitle: String,
        byteBudget: Int,
        into staging: Staging,
        onBatchReady: (URL, Int) throws -> Void
    ) throws {
        let status = try requestAuthorization()
        Console.step("authorization = \(describe(status))")
        guard status == .authorized || status == .limited else {
            throw PhotosError.notAuthorized(describe(status))
        }
        if status == .limited {
            // With a limited grant PhotoKit only surfaces the user-selected
            // subset: every visible asset verifies, the summary reads "N/N
            // verified" and the run exits 0 — while the rest of the library was
            // never even visible to back up. Say so loudly on the backup path
            // itself, not just in --doctor.
            Console.warn("Photos access is LIMITED — only the photos selected under System Settings > Privacy & Security > Photos are visible, so this backup covers that subset, NOT the full library. Grant full access for a complete backup.")
        }

        // Resolve EVERY album with this title, not just the first. Photos lets two
        // albums share a name; backing up only one would silently drop the other's
        // photos. A one-way backup never deletes, so backing up all same-named
        // albums is always safe — and it spares the user a forced rename in
        // Photos.app. A photo that is in several of them is exported once per
        // membership; restic dedups the bytes, so the repo does not grow.
        let albums = findAlbums(title: albumTitle)
        guard !albums.isEmpty else {
            throw PhotosError.albumNotFound(albumTitle)
        }
        if albums.count > 1 {
            Console.step("\(albums.count) albums are titled '\(albumTitle)' — backing up all of them")
        }

        let assetLists = albums.map { PHAsset.fetchAssets(in: $0, options: nil) }
        let totalAssets = assetLists.reduce(0) { $0 + $1.count }
        let spread = albums.count > 1 ? " across \(albums.count) albums" : ""
        Console.step("album '\(albumTitle)' contains \(totalAssets) asset(s)\(spread)")
        guard totalAssets > 0 else { throw PhotosError.albumEmpty(albumTitle) }

        let photosRoot = try staging.subdir("photos")
        // Downloads land here first, OUTSIDE every batch dir, and are renamed
        // into the batch only after they verify. `writeData` has no
        // cancellation: a timed-out download keeps running and can land its
        // file on disk long after we gave up on it — if that path were inside
        // the batch dir, restic would back up a file whose manifest entry says
        // `verified: false`. The rename-on-verify makes the batch dir hold
        // only verified files by construction.
        let inflightDir = try staging.subdir("photos/.inflight")
        let manager = PHAssetResourceManager.default()

        var batchIndex = 0
        var batchBytes = 0
        var assetsInBatch = 0

        func batchDir() throws -> URL {
            let dir = photosRoot.appendingPathComponent(String(format: "batch-%04d", batchIndex), isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }

        func flush() throws {
            guard assetsInBatch > 0 else { return }
            let dir = try batchDir()
            Console.step("batch \(batchIndex): \(assetsInBatch) asset(s), \(batchBytes) bytes -> backup")
            try onBatchReady(dir, batchIndex)
            try? FileManager.default.removeItem(at: dir)   // reclaim disk immediately
            Console.detail("batch \(batchIndex) backed up + removed — staging holds at most one batch")
            batchIndex += 1
            batchBytes = 0
            assetsInBatch = 0
        }

        // Flatten the albums into one asset stream. `ordinal` counts globally
        // across albums so each staged asset dir is unique (the localIdentifier is
        // in the name too) and the "asset N/total" log stays monotonic; batches
        // also flow across album boundaries, keeping each batch full to budget.
        var ordinal = 0
        for assets in assetLists {
            for i in 0..<assets.count {
                let asset = assets.object(at: i)
                ordinal += 1
                // Pre-flush: if this asset's estimated size would push the
                // current batch past the budget, back up + clear the batch
                // FIRST, so peak disk stays ~max(budget, asset) — see
                // shouldPreFlush. An oversized single asset still exports (its
                // data must be backed up) but into an otherwise-empty batch,
                // with a warning naming the spike.
                let resources = PHAssetResource.assetResources(for: asset)
                let estimate = Self.estimatedSize(of: resources)
                if Self.shouldPreFlush(batchBytes: batchBytes, estimatedAssetBytes: estimate,
                                       budget: byteBudget) {
                    try flush()
                }
                if let estimate, estimate > byteBudget {
                    Console.warn("asset \(ordinal) is ~\(estimate) bytes — larger than the batch budget (\(byteBudget)); staging will briefly hold this one asset beyond the budget")
                }
                let assetDir = try batchDir().appendingPathComponent(
                    String(format: "%04d_%@", ordinal, Staging.sanitize(asset.localIdentifier)),
                    isDirectory: true
                )
                try? FileManager.default.createDirectory(at: assetDir, withIntermediateDirectories: true)

                let added = exportResources(
                    of: asset, resources: resources, index: ordinal, count: totalAssets,
                    into: assetDir, inflight: inflightDir,
                    manager: manager, staging: staging
                )
                if added > 0 {
                    batchBytes += added
                    assetsInBatch += 1
                } else {
                    // Every resource of this asset failed or timed out, so its
                    // dir holds nothing verified. Drop it: a batch where all
                    // assets failed then flushes as a no-op instead of handing
                    // restic a tree of empty directories (a near-empty
                    // permanent snapshot in an un-prunable store).
                    try? FileManager.default.removeItem(at: assetDir)
                }
                if batchBytes >= byteBudget { try flush() }
            }
        }
        try flush()   // final partial batch
        // Best-effort: clear abandoned partial downloads. A still-running
        // timed-out download may re-create this dir afterwards; harmless — it
        // is scratch space that no backup ever reads.
        try? FileManager.default.removeItem(at: inflightDir)
    }

    /// Export every resource (original, paired Live-Photo video, RAW, …) of one
    /// asset into `assetDir`. Returns the verified byte total. Each resource is
    /// downloaded into `inflight` (outside the batch tree) and renamed into the
    /// batch only once verified — a failed/timed-out download never has a path
    /// inside anything restic reads.
    ///
    /// Uses `requestData` (chunks written via GuardedFileWriter) instead of
    /// `writeData` because only requestData returns a request ID that
    /// `cancelDataRequest` can stop: with writeData a timed-out download kept
    /// running invisibly in the background — consuming network + disk after the
    /// run had moved on, across every stuck resource of a scheduled run.
    private func exportResources(
        of asset: PHAsset, resources: [PHAssetResource], index: Int, count: Int,
        into assetDir: URL, inflight: URL,
        manager: PHAssetResourceManager, staging: Staging
    ) -> Int {
        Console.step("asset \(index)/\(count) id=\(asset.localIdentifier) resources=\(resources.count)")
        var bytes = 0

        for resource in resources {
            let filename = "\(resource.type.rawValue)_\(Staging.sanitize(resource.originalFilename))"
            let dest = assetDir.appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: dest.path) {
                try? FileManager.default.removeItem(at: dest)
            }
            // `index` is the run-global asset ordinal, so this path is unique
            // per resource even across same-named albums/assets.
            let tmp = inflight.appendingPathComponent("\(index)_\(filename)")
            if FileManager.default.fileExists(atPath: tmp.path) {
                try? FileManager.default.removeItem(at: tmp)
            }

            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = true   // allow download of cloud-only originals

            guard let writer = GuardedFileWriter(path: tmp.path) else {
                staging.record(AcquiredItem(
                    source: "\(asset.localIdentifier)#\(resource.type.rawValue)",
                    kind: "photo-resource", stagedPath: dest.path, byteCount: -1,
                    verified: false, note: "could not create the staging file at \(tmp.path)"))
                continue
            }
            let semaphore = DispatchSemaphore(value: 0)
            let writeError = SyncBox<Error?>(nil)
            let requestID = manager.requestData(for: resource, options: options,
                                                dataReceivedHandler: { writer.write($0) },
                                                completionHandler: { error in
                writeError.value = error
                semaphore.signal()
            })
            let completed = semaphore.wait(timeout: .now() + resourceTimeout) == .success
            if !completed {
                // Actually stop the transfer — the whole point of requestData.
                manager.cancelDataRequest(requestID)
            }
            writer.close()   // safe against a chunk still in flight (see GuardedFileWriter)

            let size = (try? tmp.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? -1
            var ok = completed && writeError.value == nil && !writer.failed && size > 0
            // On timeout, `writeError.value` is never read (the && short-circuits),
            // so there is no unsynchronized read racing the late completion handler.
            var note = !completed
                ? "download timed out after \(Int(resourceTimeout))s — request cancelled"
                : writeError.value.map { "\($0)" }
                    ?? (writer.failed ? "writing the download to disk failed (disk full?)" : nil)
                    ?? (size <= 0 ? "download completed but produced 0 bytes — not backed up" : nil)
            if ok {
                do {
                    try FileManager.default.moveItem(at: tmp, to: dest)
                    bytes += size
                } catch {
                    ok = false
                    note = "downloaded and verified, but could not move into the batch: \(error)"
                    try? FileManager.default.removeItem(at: tmp)
                }
            } else {
                // Never let a 0-byte / failed / timed-out download reach restic.
                try? FileManager.default.removeItem(at: tmp)
            }
            staging.record(AcquiredItem(
                source: "\(asset.localIdentifier)#\(resource.type.rawValue)",
                kind: "photo-resource",
                stagedPath: dest.path,
                byteCount: size,
                verified: ok,
                note: note
            ))
            let noteSuffix = note.map { " (\($0))" } ?? ""
            Console.detail("resource type=\(resource.type.rawValue) '\(resource.originalFilename)' -> \(size) bytes verified=\(ok)\(noteSuffix)")
        }
        return bytes
    }

    /// List the user's albums (title + asset count) for the configure picker.
    /// Triggers the Photos authorization prompt on first use — listing needs the
    /// same read grant the backup does (PhotoKit has no read-only access level).
    func listAlbums() throws -> [PhotoAlbumInfo] {
        let status = try requestAuthorization()
        guard status == .authorized || status == .limited else {
            throw PhotosError.notAuthorized(describe(status))
        }
        var out: [PhotoAlbumInfo] = []
        let albums = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
        albums.enumerateObjects { collection, _, _ in
            guard let title = collection.localizedTitle, !title.isEmpty else { return }
            let count = PHAsset.fetchAssets(in: collection, options: nil).count
            out.append(PhotoAlbumInfo(title: title, count: count))
        }
        return out.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// The CURRENT Photos authorization, read WITHOUT triggering a prompt (unlike
    /// `requestAuthorization`, which would pop the system dialog). For the doctor
    /// diagnostic, which must observe the grant, never request it. Returns whether
    /// access is usable plus a human-readable, actionable label.
    static func authorizationLabel() -> (granted: Bool, label: String) {
        let s = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        let granted = (s == .authorized || s == .limited)
        let label: String
        switch s {
        case .notDetermined: label = "not yet granted — the first Photos backup will prompt for access"
        case .restricted:    label = "restricted by a system policy (MDM / parental controls)"
        case .denied:        label = "denied — grant it under System Settings > Privacy & Security > Photos"
        case .authorized:    label = "authorized"
        case .limited:       label = "limited — only selected albums are visible; grant full access for a complete backup"
        @unknown default:    label = "unknown(\(s.rawValue))"
        }
        return (granted, label)
    }

    private func requestAuthorization() throws -> PHAuthorizationStatus {
        let semaphore = DispatchSemaphore(value: 0)
        let result = SyncBox<PHAuthorizationStatus>(.notDetermined)
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
            result.value = status
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + authTimeout) == .timedOut {
            // Distinct from a genuine .notDetermined ("first run will prompt"): the
            // prompt machinery never answered, so surface that as its own error
            // instead of mislabelling a wedged hang as "not yet granted".
            throw PhotosError.authorizationTimedOut(Int(authTimeout))
        }
        return result.value
    }

    /// Every user album with this exact title (Photos allows duplicates). Sorted
    /// by localIdentifier so the backup order is stable across runs — it does not
    /// affect the result (all are backed up) but keeps the staging layout and the
    /// "asset N/total" numbering reproducible.
    private func findAlbums(title: String) -> [PHAssetCollection] {
        let collections = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
        var matches: [PHAssetCollection] = []
        collections.enumerateObjects { collection, _, _ in
            if collection.localizedTitle == title { matches.append(collection) }
        }
        return matches.sorted { $0.localIdentifier < $1.localIdentifier }
    }

    private func describe(_ status: PHAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "notDetermined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .authorized: return "authorized"
        case .limited: return "limited"
        @unknown default: return "unknown(\(status.rawValue))"
        }
    }
}
