//
//  ThumbnailImageManager.swift
//  PoimiApp — Spike render layer
//
//  RENDER LAYER — written cleanly so it can be PROMOTED in Phase 1 behind the
//  `PhotoLibraryProviding` / image-loading protocol seam (D1, D17). This file is
//  the fiddliest, most reusable part of the spike: thumbnail requests, per-cell
//  cancellation, and the `PHCachingImageManager` prefetch window. Keep it free of
//  spike-only data shortcuts so it survives into the real app.
//
//  It is NOT marked `// SPIKE — throwaway`: this is the salvageable tier.

import Photos
import UIKit

/// Thin, promotable wrapper over `PHCachingImageManager` that owns the prefetch
/// window for a grid and serves single thumbnail requests with cancellation.
///
/// Isolation: `@MainActor`. The caching manager is touched only from the main
/// actor here (the grid drives it). The image *decode* happens on PhotoKit's own
/// queues; results are delivered back on the main actor via the async API below.
@MainActor
final class ThumbnailImageManager {
    private let cachingManager = PHCachingImageManager()

    /// The single quantized target size for every thumbnail request, so the
    /// underlying cache keys stay stable as the grid recycles cells. Oversized
    /// vs the on-screen point size on purpose (Retina + a little headroom for
    /// pinch-to-enlarge density changes without re-fetching).
    private let targetSize = CGSize(width: 400, height: 400)

    /// The currently-cached window of assets, so we can compute the diff to add
    /// and remove when the visible range moves.
    private var cachedWindow: [PHAsset] = []

    // MARK: - Prefetch window

    /// Update the caching window to `window`, diffing against the previous window
    /// so PhotoKit only starts/stops the assets that actually changed. Driven by
    /// the grid's visible range expanded by a lead/trail margin.
    func updateCachingWindow(to window: [PHAsset]) {
        let newIDs = Set(window.map(\.localIdentifier))
        let oldIDs = Set(cachedWindow.map(\.localIdentifier))

        let added = window.filter { !oldIDs.contains($0.localIdentifier) }
        let removed = cachedWindow.filter { !newIDs.contains($0.localIdentifier) }

        if !removed.isEmpty {
            cachingManager.stopCachingImages(
                for: removed, targetSize: targetSize,
                contentMode: .aspectFill, options: Self.cachingOptions)
        }
        if !added.isEmpty {
            cachingManager.startCachingImages(
                for: added, targetSize: targetSize,
                contentMode: .aspectFill, options: Self.cachingOptions)
        }
        cachedWindow = window
    }

    /// Stop caching everything (e.g. when the grid disappears).
    func reset() {
        cachingManager.stopCachingImagesForAllAssets()
        cachedWindow = []
    }

    // MARK: - Single requests

    /// Request a thumbnail for `asset`, awaiting the final (non-degraded) image.
    /// The request is automatically cancelled if the calling `Task` is cancelled
    /// — which is exactly what SwiftUI's `.task(id:)` does when a cell recycles.
    func thumbnail(for asset: PHAsset) async -> UIImage? {
        let manager = cachingManager
        let size = targetSize

        // Box the request ID so the cancellation handler can read it even if
        // cancellation lands between issuing the request and the box being set.
        let requestIDBox = LockedBox<PHImageRequestID>()

        return await withTaskCancellationHandler {
            if Task.isCancelled { return nil }
            return await withCheckedContinuation { (continuation: CheckedContinuation<UIImage?, Never>) in
                let options = PHImageRequestOptions()
                options.deliveryMode = .opportunistic
                options.resizeMode = .fast
                options.isNetworkAccessAllowed = true   // iCloud-optimized assets
                options.isSynchronous = false

                // Guard against the opportunistic delivery resuming twice
                // (PhotoKit may deliver a degraded image then the final one).
                let resumed = LockedFlag()

                let id = manager.requestImage(
                    for: asset, targetSize: size,
                    contentMode: .aspectFill, options: options
                ) { image, info in
                    let isDegraded = (info?[PHImageResultIsDegradedKey] as? NSNumber)?.boolValue ?? false
                    // Surface the degraded image only if no final one is coming
                    // soon; for the grid the opportunistic low-res first is fine,
                    // so resume on the first image we actually get. PhotoKit will
                    // still upgrade the cached copy for the next request.
                    guard !isDegraded || image != nil else { return }
                    if resumed.setOnce() {
                        continuation.resume(returning: image)
                    }
                }
                requestIDBox.value = id
                if Task.isCancelled {
                    manager.cancelImageRequest(id)
                }
            }
        } onCancel: {
            if let id = requestIDBox.value {
                cachingManager.cancelImageRequest(id)
            }
        }
    }

    private static let cachingOptions: PHImageRequestOptions = {
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        return options
    }()
}

/// A tiny lock-protected optional box, `Sendable` so it can cross into the
/// cancellation handler closure under strict concurrency.
private final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T?
    var value: T? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// A one-shot flag guarding a single continuation resume.
private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    /// Returns `true` exactly once.
    func setOnce() -> Bool {
        lock.withLock {
            if fired { return false }
            fired = true
            return true
        }
    }
}
