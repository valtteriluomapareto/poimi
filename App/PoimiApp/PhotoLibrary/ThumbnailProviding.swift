//
//  ThumbnailProviding.swift
//  PoimiApp — the image-loading seam (issue #35; promoted from the spike's ThumbnailImageManager).
//
//  The review grid needs thumbnails, and thumbnail loading is inherently UIKit (`UIImage`,
//  `PHCachingImageManager`) — so, unlike `PhotoLibraryProviding`, this seam lives in the app, not
//  in pure `Curation` (D14). It mirrors the same shape: an abstract `Sendable` contract with a real
//  `SystemThumbnailProvider` (PhotoKit) and a deterministic, DEBUG-only `FakeThumbnailProvider`,
//  injected via the environment and chosen at the composition root (D30).
//
//  It is value/id-shaped: callers pass `localIdentifier`s, never live `PHAsset`s (D17/§2), so the
//  grid stays decoupled from PhotoKit exactly as the spike's render layer was written to allow.
//

import SwiftUI
import UIKit

/// The abstract image-loading seam. `Sendable` because the implementations are actors and their
/// `UIImage` results cross the actor boundary; methods are `async` for the same reason.
protocol ThumbnailProviding: Sendable {
    /// A thumbnail for `assetID` at roughly `targetSize`, awaiting the first usable (opportunistic)
    /// image. Cancellation-aware: cancelling the calling `Task` cancels the underlying PhotoKit
    /// request — exactly what SwiftUI's `.task(id:)` does when a grid cell recycles. `nil` if the
    /// asset can't be resolved or the request is cancelled before any image arrives.
    func thumbnail(for assetID: String, targetSize: CGSize) async -> UIImage?

    /// Set the prefetch/caching window to `assetIDs` (the grid's visible range ± a row margin), so
    /// PhotoKit pre-decodes just ahead of the scroll. Diffs against the previous window internally.
    func updateCachingWindow(to assetIDs: [String]) async

    /// Stop caching everything (e.g. when the grid disappears).
    func resetCache() async
}

enum ThumbnailProvider {
    /// Build the thumbnail dependency for this launch — the fake only in DEBUG and only under
    /// `-PoimiUseFakeLibrary`, matching `PhotoLibraryProvider.make()` so the two seams stay in lock-
    /// step (a fake photo library always pairs with fake thumbnails).
    static func make() -> any ThumbnailProviding {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-PoimiUseFakeLibrary") {
            Log.photoLibrary.notice("Composition root: using FakeThumbnailProvider (-PoimiUseFakeLibrary)")
            return FakeThumbnailProvider()
        }
        #endif
        Log.photoLibrary.notice("Composition root: using SystemThumbnailProvider")
        return SystemThumbnailProvider()
    }
}

extension EnvironmentValues {
    /// The injected thumbnail seam. The grid reads it via `@Environment(\.thumbnailProvider)`;
    /// `@main` injects the composition-root instance. As with `\.photoLibrary`, the DEBUG default is
    /// the deterministic fake (safe for previews / un-injected readers) and release defaults to the
    /// real provider (never reached at runtime — `@main` always injects).
    #if DEBUG
    @Entry var thumbnailProvider: any ThumbnailProviding = FakeThumbnailProvider()
    #else
    @Entry var thumbnailProvider: any ThumbnailProviding = SystemThumbnailProvider()
    #endif
}
