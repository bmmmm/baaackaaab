import Foundation
import Photos

/// One user album, as shown in the configure picker.
struct PhotoAlbumInfo {
    let title: String
    let count: Int
}

enum PhotosError: Error, CustomStringConvertible {
    case notAuthorized(String)
    case albumNotFound(String)
    case albumEmpty(String)

    var description: String {
        switch self {
        case .notAuthorized(let s): return "Photos access not granted (status: \(s)). Grant your terminal app access under System Settings > Privacy & Security > Photos."
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
    /// that also blocks every following scheduled run. On timeout the resource is
    /// recorded unverified and skipped; the run continues.
    private let resourceTimeout: TimeInterval = 600

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
        let status = requestAuthorization()
        Console.step("authorization = \(describe(status))")
        guard status == .authorized || status == .limited else {
            throw PhotosError.notAuthorized(describe(status))
        }

        guard let album = findAlbum(title: albumTitle) else {
            throw PhotosError.albumNotFound(albumTitle)
        }

        let assets = PHAsset.fetchAssets(in: album, options: nil)
        Console.step("album '\(albumTitle)' contains \(assets.count) asset(s)")
        guard assets.count > 0 else { throw PhotosError.albumEmpty(albumTitle) }

        let photosRoot = try staging.subdir("photos")
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

        for i in 0..<assets.count {
            let asset = assets.object(at: i)
            let assetDir = try batchDir().appendingPathComponent(
                String(format: "%04d_%@", i + 1, Staging.sanitize(asset.localIdentifier)),
                isDirectory: true
            )
            try? FileManager.default.createDirectory(at: assetDir, withIntermediateDirectories: true)

            batchBytes += exportResources(
                of: asset, index: i + 1, count: assets.count,
                into: assetDir, manager: manager, staging: staging
            )
            assetsInBatch += 1
            if batchBytes >= byteBudget { try flush() }
        }
        try flush()   // final partial batch
    }

    /// Export every resource (original, paired Live-Photo video, RAW, …) of one
    /// asset into `assetDir`. Returns the verified byte total. A failed resource
    /// is deleted and recorded unverified, never returned in the byte total.
    private func exportResources(
        of asset: PHAsset, index: Int, count: Int,
        into assetDir: URL, manager: PHAssetResourceManager, staging: Staging
    ) -> Int {
        let resources = PHAssetResource.assetResources(for: asset)
        Console.step("asset \(index)/\(count) id=\(asset.localIdentifier) resources=\(resources.count)")
        var bytes = 0

        for resource in resources {
            let filename = "\(resource.type.rawValue)_\(Staging.sanitize(resource.originalFilename))"
            let dest = assetDir.appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: dest.path) {
                try? FileManager.default.removeItem(at: dest)
            }

            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = true   // allow download of cloud-only originals

            let semaphore = DispatchSemaphore(value: 0)
            var writeError: Error?
            manager.writeData(for: resource, toFile: dest, options: options) { error in
                writeError = error
                semaphore.signal()
            }
            let completed = semaphore.wait(timeout: .now() + resourceTimeout) == .success

            let size = (try? dest.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? -1
            let ok = completed && writeError == nil && size > 0
            if !ok {
                // Never let a 0-byte / failed / timed-out download reach restic.
                try? FileManager.default.removeItem(at: dest)
            } else {
                bytes += size
            }
            let note = !completed
                ? "download timed out after \(Int(resourceTimeout))s"
                : writeError.map { "\($0)" }
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
        let status = requestAuthorization()
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

    private func requestAuthorization() -> PHAuthorizationStatus {
        let semaphore = DispatchSemaphore(value: 0)
        var result: PHAuthorizationStatus = .notDetermined
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
            result = status
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + authTimeout) == .timedOut {
            return .notDetermined   // a wedged prompt counts as "not granted", never a hang
        }
        return result
    }

    private func findAlbum(title: String) -> PHAssetCollection? {
        let collections = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
        var matches: [PHAssetCollection] = []
        collections.enumerateObjects { collection, _, _ in
            if collection.localizedTitle == title { matches.append(collection) }
        }
        if matches.count > 1 {
            Console.warn("\(matches.count) albums are titled '\(title)' — backing up the first one; rename them in Photos.app to disambiguate")
        }
        return matches.first
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
