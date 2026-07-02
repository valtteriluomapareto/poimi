//
//  SystemPhotoLibrary.swift
//  PoimiApp — the real PhotoKit-backed photo library (issue #22).
//
//  The single `actor` through which all PhotoKit fetch / authorization calls flow
//  (architecture §1). It vends only `Sendable` value models (`AssetRef`/`AlbumRef`) — a live
//  `PHAsset` / `PHFetchResult` never crosses the actor boundary.
//
//  Phase-1 skeleton: authorization is real (it drives the permission flow), and a basic
//  date-range fetch + album enumeration are in place. Deferred to Phase 2: the exclude
//  filters, the windowed `AssetRef` snapshot by index range (D17, vs. the whole-result
//  materialization here), image loading, album export, and registering + reconciling the
//  change-observer shim (`PhotoLibraryChangeObserver`) — that wiring lands in Phase 2 with
//  the actor-owned fetch result (so there's no register/unregister lifecycle to leak yet).
//

import Foundation
import OSLog
import Photos
import Curation

actor SystemPhotoLibrary: PhotoLibraryProviding {
    func authorizationStatus() async -> LibraryAuthorization {
        Self.map(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    func requestAuthorization() async -> LibraryAuthorization {
        let status = Self.map(await PHPhotoLibrary.requestAuthorization(for: .readWrite))
        Log.photoLibrary.notice("requestAuthorization resolved: \(String(describing: status), privacy: .public)")
        return status
    }

    func fetchAssets(in interval: DateInterval) async throws -> [AssetRef] {
        // SHARED CONTRACT with FakePhotoLibrary (the conformance invariant, D24): dated assets
        // in [start, end), oldest → newest. PhotoKit's predicate does not match a nil
        // creationDate, so undated assets are excluded from a range fetch — they reach the
        // "Undated" section via a separate Phase-2 path, never through this method.
        let options = PHFetchOptions()
        options.predicate = NSPredicate(
            format: "creationDate >= %@ AND creationDate < %@",
            interval.start as NSDate, interval.end as NSDate)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]

        let result = PHAsset.fetchAssets(with: .image, options: options)
        var refs: [AssetRef] = []
        refs.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            refs.append(Self.ref(from: asset))
        }
        // `.notice` (not `.info`) so it persists to the store and `log show` surfaces it after
        // the run — fetch counts are the main diagnostic here and are infrequent.
        Log.photoLibrary.notice("fetchAssets returned \(refs.count) assets in the requested interval")
        return refs
    }

    func albums() async throws -> [AlbumRef] {
        var albums: [AlbumRef] = []
        // User albums only (.albumRegular): the exclude-album picker shouldn't surface smart /
        // system collections the user can't meaningfully exclude (architecture §8).
        let collections = PHAssetCollection.fetchAssetCollections(
            with: .album, subtype: .albumRegular, options: nil)
        collections.enumerateObjects { collection, _, _ in
            albums.append(AlbumRef(
                id: collection.localIdentifier,
                title: collection.localizedTitle ?? "Untitled",
                count: nil))
        }
        return albums
    }

    func assetIDs(inAlbums albumIDs: [String]) async throws -> Set<String> {
        guard !albumIDs.isEmpty else { return [] }
        var ids: Set<String> = []
        // Only images can be candidates (fetchAssets fetches `.image`), so restrict membership to
        // images too — tighter and cheaper than enumerating an excluded album's videos/audio.
        let imageOptions = PHFetchOptions()
        imageOptions.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        // Resolve each excluded album by localIdentifier, then collect its assets' ids. Only the
        // id strings escape the actor — the `PHAsset`s never do.
        let collections = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: albumIDs, options: nil)
        collections.enumerateObjects { collection, _, _ in
            PHAsset.fetchAssets(in: collection, options: imageOptions).enumerateObjects { asset, _, _ in
                ids.insert(asset.localIdentifier)
            }
        }
        return ids
    }

    func export(assetIDs: Set<String>, toAlbumNamed name: String,
                existingAlbumID: String?) async throws -> ExportResult {
        // Creating/modifying an album needs full-library write access; `.limited` can't add arbitrary
        // assets to a collection, so require `.authorized` (D19 revoked-auth path).
        guard Self.map(PHPhotoLibrary.authorizationStatus(for: .readWrite)) == .authorized else {
            throw ExportError.notAuthorized
        }
        // Resolve to LIVE assets (an id deleted under the selection simply drops out). Only id strings
        // and the resolved membership escape; no PHAsset crosses back to the caller (D31).
        let liveIDs = Self.liveAssetIDs(from: assetIDs)
        guard !liveIDs.isEmpty else { throw ExportError.noAssetsResolved }

        if let existingAlbumID {
            // Re-export: find the stored album (throw `.albumMissing` if it was deleted → the screen
            // offers "create a new album instead"), then add only the picks it doesn't already hold.
            guard let collection = PHAssetCollection.fetchAssetCollections(
                withLocalIdentifiers: [existingAlbumID], options: nil).firstObject else {
                throw ExportError.albumMissing
            }
            let existingIDs = Self.assetIDs(in: collection)
            let toAdd = Array(liveIDs.subtracting(existingIDs))     // dupe guard
            if !toAdd.isEmpty {
                do {
                    try await PHPhotoLibrary.shared().performChanges {
                        // Re-fetch inside the block so no non-Sendable PHAsset/collection is captured.
                        guard let collection = PHAssetCollection.fetchAssetCollections(
                            withLocalIdentifiers: [existingAlbumID], options: nil).firstObject,
                              let request = PHAssetCollectionChangeRequest(for: collection) else { return }
                        request.addAssets(PHAsset.fetchAssets(withLocalIdentifiers: toAdd, options: nil))
                    }
                } catch {
                    Log.photoLibrary.error("export addAssets failed: \(String(describing: error), privacy: .public)")
                    throw ExportError.writeFailed
                }
            }
            Log.photoLibrary.notice("export updated album: +\(toAdd.count), now \(existingIDs.count + toAdd.count)")
            return ExportResult(albumID: existingAlbumID, added: toAdd.count, total: existingIDs.count + toAdd.count)
        }

        // First export: create the album AND add every resolved pick in one change.
        let addIDs = Array(liveIDs)
        // `nonisolated(unsafe)`: `performChanges` runs the block to completion before it returns, so
        // reading the placeholder id afterward is safe — this only opts the capture out of the check.
        nonisolated(unsafe) var placeholderID: String?
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: name)
                request.addAssets(PHAsset.fetchAssets(withLocalIdentifiers: addIDs, options: nil))
                placeholderID = request.placeholderForCreatedAssetCollection.localIdentifier
            }
        } catch {
            Log.photoLibrary.error("export createAlbum failed: \(String(describing: error), privacy: .public)")
            throw ExportError.writeFailed
        }
        guard let albumID = placeholderID else { throw ExportError.writeFailed }
        Log.photoLibrary.notice("export created album with \(addIDs.count) photos")
        return ExportResult(albumID: albumID, added: addIDs.count, total: addIDs.count)
    }

    /// The subset of `ids` that still resolve to a live `PHAsset` (their local identifiers).
    private static func liveAssetIDs(from ids: Set<String>) -> Set<String> {
        guard !ids.isEmpty else { return [] }
        var live: Set<String> = []
        PHAsset.fetchAssets(withLocalIdentifiers: Array(ids), options: nil).enumerateObjects { asset, _, _ in
            live.insert(asset.localIdentifier)
        }
        return live
    }

    /// The asset ids currently in `collection` — the dupe-guard baseline for a re-export.
    private static func assetIDs(in collection: PHAssetCollection) -> Set<String> {
        var ids: Set<String> = []
        PHAsset.fetchAssets(in: collection, options: nil).enumerateObjects { asset, _, _ in
            ids.insert(asset.localIdentifier)
        }
        return ids
    }

    // MARK: - Value mapping (PHAsset never escapes the actor)

    private static func map(_ status: PHAuthorizationStatus) -> LibraryAuthorization {
        switch status {
        case .authorized: .authorized
        case .limited: .limited
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notDetermined
        @unknown default: .denied
        }
    }

    private static func ref(from asset: PHAsset) -> AssetRef {
        AssetRef(
            id: asset.localIdentifier,
            captureDate: asset.creationDate,
            coordinate: asset.location.map {
                Coordinate(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude)
            },
            pixelSize: PixelSize(width: asset.pixelWidth, height: asset.pixelHeight),
            isScreenshot: asset.mediaSubtypes.contains(.photoScreenshot),
            isFavorite: asset.isFavorite)
    }
}
