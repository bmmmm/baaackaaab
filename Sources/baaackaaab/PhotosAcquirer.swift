import Foundation
import Photos

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
        print("[photos] authorization = \(describe(status))")
        guard status == .authorized || status == .limited else {
            throw PhotosError.notAuthorized(describe(status))
        }

        guard let album = findAlbum(title: albumTitle) else {
            throw PhotosError.albumNotFound(albumTitle)
        }

        let assets = PHAsset.fetchAssets(in: album, options: nil)
        print("[photos] album '\(albumTitle)' contains \(assets.count) asset(s)")
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
            print("[photos] batch \(batchIndex): \(assetsInBatch) asset(s), \(batchBytes) bytes -> backup")
            try onBatchReady(dir, batchIndex)
            try? FileManager.default.removeItem(at: dir)   // reclaim disk immediately
            print("[photos] batch \(batchIndex) backed up + removed — staging holds at most one batch")
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
        print("[photos] asset \(index)/\(count) id=\(asset.localIdentifier) resources=\(resources.count)")
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
            semaphore.wait()

            let size = (try? dest.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? -1
            let ok = writeError == nil && size > 0
            if !ok {
                // Never let a 0-byte / failed download reach restic.
                try? FileManager.default.removeItem(at: dest)
            } else {
                bytes += size
            }
            staging.record(AcquiredItem(
                source: "\(asset.localIdentifier)#\(resource.type.rawValue)",
                kind: "photo-resource",
                stagedPath: dest.path,
                byteCount: size,
                verified: ok,
                note: writeError.map { "\($0)" }
            ))
            let errSuffix = writeError.map { " error=\($0)" } ?? ""
            print("[photos]   resource type=\(resource.type.rawValue) '\(resource.originalFilename)' -> \(size) bytes verified=\(ok)\(errSuffix)")
        }
        return bytes
    }

    private func requestAuthorization() -> PHAuthorizationStatus {
        let semaphore = DispatchSemaphore(value: 0)
        var result: PHAuthorizationStatus = .notDetermined
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
            result = status
            semaphore.signal()
        }
        semaphore.wait()
        return result
    }

    private func findAlbum(title: String) -> PHAssetCollection? {
        let collections = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
        var found: PHAssetCollection?
        collections.enumerateObjects { collection, _, stop in
            if collection.localizedTitle == title {
                found = collection
                stop.pointee = true
            }
        }
        return found
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
