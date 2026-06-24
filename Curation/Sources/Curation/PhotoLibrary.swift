//
//  PhotoLibrary.swift
//  Curation — the PhotoKit-facing seam (issue #18).
//
//  `PhotoLibraryProviding` is the domain's abstract contract over the photo library.
//  The app implements it twice: `SystemPhotoLibrary` (real PhotoKit, an `actor`) and
//  `FakePhotoLibrary` (deterministic, test-only). Per the dependency direction (D14),
//  the protocol and its value types live here in `Curation`; the implementations depend
//  on `Curation`, never the reverse.
//
//  This is the initial Phase-1 surface — enough for the authorization flow, a first grid
//  fetch, and the exclude-album picker. Image loading and album export are added as their
//  own methods/protocols in Phase 2 (D21: split a capability out only when a consumer
//  needs just it).
//

import Foundation

/// The domain mirror of `PHAuthorizationStatus` — `Curation` must not import Photos (D14),
/// so the app maps the PhotoKit status onto this. Navigation is driven by it (D6).
public enum LibraryAuthorization: Sendable, Equatable {
    case notDetermined
    case authorized
    case limited
    case denied
    case restricted
}

/// Typed library errors (D19). Grows with the fetch / export surface in Phase 2.
public enum PhotoLibraryError: Error, Sendable, Equatable {
    /// Full access is required but not granted.
    case notAuthorized
    /// The underlying fetch failed.
    case fetchFailed
}

/// The abstract photo-library seam. `Sendable` because the real implementation is an
/// `actor` and its value results cross the actor boundary; methods are `async` for the
/// same reason. Never vends a live `PHAsset` / `PHFetchResult` — only the value models
/// in this package.
public protocol PhotoLibraryProviding: Sendable {
    /// Current authorization, without prompting.
    func authorizationStatus() async -> LibraryAuthorization

    /// Request access (drives the system prompt in the real impl); returns the resolved
    /// status.
    func requestAuthorization() async -> LibraryAuthorization

    /// Fetch the asset value models whose capture date falls in `interval`, ordered
    /// oldest → newest (the order the grouping function, #19, expects).
    func fetchAssets(in interval: DateInterval) async throws -> [AssetRef]

    /// Enumerate the user's albums — for the exclude-album picker and the export-target
    /// selection step (architecture §8).
    func albums() async throws -> [AlbumRef]
}
