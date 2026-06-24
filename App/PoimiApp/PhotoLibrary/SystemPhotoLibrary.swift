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
//  materialization here), image loading, album export, and the change reconciliation that
//  the observer (below) will drive.
//

import CoreLocation
import Foundation
import Photos
import Curation

actor SystemPhotoLibrary: PhotoLibraryProviding {
    /// Retained so PhotoKit keeps delivering change notifications (D16). Registered lazily
    /// via `startObserving`.
    private var changeObserver: PhotoLibraryChangeObserver?

    func authorizationStatus() async -> LibraryAuthorization {
        Self.map(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    func requestAuthorization() async -> LibraryAuthorization {
        Self.map(await PHPhotoLibrary.requestAuthorization(for: .readWrite))
    }

    func fetchAssets(in interval: DateInterval) async throws -> [AssetRef] {
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
        return refs
    }

    func albums() async throws -> [AlbumRef] {
        var albums: [AlbumRef] = []
        let collections = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
        collections.enumerateObjects { collection, _, _ in
            albums.append(AlbumRef(
                id: collection.localIdentifier,
                title: collection.localizedTitle ?? "Untitled",
                count: nil))
        }
        return albums
    }

    /// Register the change-observer shim (D16). `onChange` is invoked (off the main thread)
    /// whenever the library changes; Phase 2 turns this into the `apply(change:)`
    /// reconciliation against the actor-owned fetch result.
    func startObserving(onChange: @escaping @Sendable () -> Void) {
        let observer = PhotoLibraryChangeObserver(onChange: onChange)
        PHPhotoLibrary.shared().register(observer)
        changeObserver = observer
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
