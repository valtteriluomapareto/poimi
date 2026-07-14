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
//  This started as the Phase-1 read surface (authorization, a first grid fetch, the exclude
//  picker). Phase 2 adds the one WRITE capability the app needs — `export` (#39) — to this same
//  seam rather than a separate protocol: the app injects a single `\.photoLibrary` and uses the
//  whole surface, so a capability split (D21) would buy only plumbing. Image loading still lands
//  as its own provider (`\.thumbnailProvider`), where a distinct consumer justified the split.
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

/// The outcome of an album export (#39, D19). Idempotent: `added` is what THIS run added; `total`
/// is what the album holds afterward — so a no-op re-run reports `added == 0`.
public struct ExportResult: Sendable, Equatable {
    /// The created-or-found `PHAssetCollection`'s local identifier (stored as `targetAlbumID`).
    public let albumID: String
    /// Assets this run added (already-present ones are skipped — the dupe guard).
    public let added: Int
    /// Assets the album holds after this run.
    public let total: Int
    /// The destination album's **actual** title. For a first export this is the requested name; for a
    /// re-export to an existing album it's that album's own title, which may differ from the project's
    /// title — so the completion screen names where the photos really landed, not what we asked for (#193).
    public let title: String

    public init(albumID: String, added: Int, total: Int, title: String) {
        self.albumID = albumID
        self.added = added
        self.total = total
        self.title = title
    }
}

/// Typed export failures (#39, D19) — the recoverable channel the export screen maps to actions.
public enum ExportError: Error, Sendable, Equatable {
    /// Write access isn't granted (creating/modifying an album needs full-library access).
    case notAuthorized
    /// The previously-created target album no longer exists (deleted in Photos) — the screen then
    /// offers "create a new album instead".
    case albumMissing
    /// None of the selected ids resolve to a live asset (all deleted under the selection).
    case noAssetsResolved
    /// The PhotoKit write itself failed.
    case writeFailed
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

    /// The asset ids belonging to any of `albumIDs` — the precomputed membership the
    /// exclude-album filter set-differences against (architecture §3). An empty `albumIDs`
    /// yields an empty set (no enumeration).
    func assetIDs(inAlbums albumIDs: [String]) async throws -> Set<String>

    /// Create-or-find the target album and add the selected assets that aren't already in it (dupe
    /// guard; natural capture-date order — membership only, no sequencing, architecture §8).
    /// `existingAlbumID` non-nil re-exports to that album, throwing `.albumMissing` if it was deleted.
    /// A one-way copy — the album/originals are never read back into our state (D31). Returns the
    /// resolved album id + this run's added count + the album's new total (#39, D19).
    func export(assetIDs: Set<String>, toAlbumNamed name: String, existingAlbumID: String?) async throws -> ExportResult
}
