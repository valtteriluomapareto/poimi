// SPIKE — throwaway, delete in Phase 2
//
//  SpikeLibrary.swift
//  PoimiApp — Spike data layer (THROWAWAY)
//
//  The disposable data/fetch/selection/export shortcuts (D1, "thrown away" tier).
//  In the real app this becomes the `SystemPhotoLibrary` actor behind
//  `PhotoLibraryProviding`, handing the UI `Sendable` `AssetRef` snapshots — NOT a
//  live `[PHAsset]` array. Here we cut every corner: full-access `.authorized`
//  path only, a flat `[PHAsset]` held on the main actor, a `Set<String>` selection,
//  and a fire-and-forget album dump. Good enough to *feel* the loop; not the
//  architecture.

import Photos

/// Throwaway PhotoKit facade for the spike. Everything here is intentionally the
/// simplest thing that runs on a real library; none of it survives Phase 2.
enum SpikeLibrary {

    // MARK: - Authorization (full access, .authorized path only)

    /// Request read-write full-library access and return the resulting status.
    /// The spike only proceeds on `.authorized` — `.limited` / `.denied` /
    /// `.notDetermined` recovery flows are Phase 2 (D6).
    static func requestAuthorization() async -> PHAuthorizationStatus {
        await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    // MARK: - Fetch (date-range slice)

    /// Fetch all image assets with `creationDate` in `[start, end)`, oldest first.
    /// Throwaway shortcut: materializes the whole `PHFetchResult` into a flat
    /// `[PHAsset]` array on the main actor (the real app keeps the lazy result
    /// inside the actor and snapshots windows — D17). For the spike, a slice of
    /// one date range is small enough that the array is fine and simpler.
    static func fetchImageAssets(from start: Date, to end: Date) -> [PHAsset] {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(
            format: "mediaType == %d AND creationDate >= %@ AND creationDate < %@",
            PHAssetMediaType.image.rawValue, start as NSDate, end as NSDate
        )
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]

        let result = PHAsset.fetchAssets(with: options)
        var assets: [PHAsset] = []
        assets.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            assets.append(asset)
        }
        return assets
    }

    // MARK: - Export (dump to album)

    /// Create-or-find an album named `albumTitle` and add `assets` to it.
    /// Throwaway: no dupe guard, no stored album identifier, no partial-failure
    /// model (all of which the real export gets — D19). Just dumps the selection.
    static func dumpToAlbum(named albumTitle: String, assets: [PHAsset]) async throws {
        let collection = try await findOrCreateAlbum(named: albumTitle)
        try await PHPhotoLibrary.shared().performChangesAsync {
            guard let request = PHAssetCollectionChangeRequest(for: collection) else { return }
            request.addAssets(assets as NSArray)
        }
    }

    /// Find an album by title or create it.
    private static func findOrCreateAlbum(named title: String) async throws -> PHAssetCollection {
        // Look for an existing user album with this exact title.
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "title == %@", title)
        let existing = PHAssetCollection.fetchAssetCollections(
            with: .album, subtype: .albumRegular, options: options)
        if let found = existing.firstObject {
            return found
        }

        // Otherwise create it and re-fetch via its placeholder's identifier.
        // The change block is `@Sendable`, so funnel the placeholder id out
        // through a lock-protected box rather than a captured `var`.
        let placeholderBox = SpikeSendableBox<String>()
        try await PHPhotoLibrary.shared().performChangesAsync {
            let create = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: title)
            placeholderBox.value = create.placeholderForCreatedAssetCollection.localIdentifier
        }
        guard let placeholderID = placeholderBox.value else {
            throw SpikeExportError.albumCreationFailed
        }
        let created = PHAssetCollection.fetchAssetCollections(
            withLocalIdentifiers: [placeholderID], options: nil)
        guard let collection = created.firstObject else {
            throw SpikeExportError.albumCreationFailed
        }
        return collection
    }
}

/// Throwaway error type for the spike export.
enum SpikeExportError: Error {
    case albumCreationFailed
}

/// Lock-protected box so a `@Sendable` change block can hand a value back out
/// under Swift 6 strict concurrency. Throwaway helper for the spike.
private final class SpikeSendableBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T?
    var value: T? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// `performChanges` as an async throwing call — small bridge for the spike.
private extension PHPhotoLibrary {
    func performChangesAsync(_ changes: @escaping @Sendable () -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            performChanges(changes) { success, error in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: error ?? SpikeExportError.albumCreationFailed)
                }
            }
        }
    }
}
