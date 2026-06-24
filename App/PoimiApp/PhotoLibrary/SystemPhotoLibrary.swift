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

import CoreLocation
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
