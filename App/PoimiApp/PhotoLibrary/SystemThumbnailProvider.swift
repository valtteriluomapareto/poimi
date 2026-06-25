//
//  SystemThumbnailProvider.swift
//  PoimiApp — the real PhotoKit thumbnail provider (issue #35).
//
//  Promoted from the spike's `ThumbnailImageManager` (the fiddliest, most reusable render code:
//  per-cell cancellation, opportunistic delivery, the `PHCachingImageManager` prefetch window).
//  Promoted as an `actor` (not `@MainActor`) so it satisfies the `Sendable` seam and can back the
//  `\.thumbnailProvider` environment default. PhotoKit's image manager is thread-safe, so driving it
//  off the main actor is fine; the decode happens on PhotoKit's own queues regardless.
//
//  The grid passes `localIdentifier`s; resolution to live `PHAsset`s happens here and the assets
//  never escape (D17/§2). Resolved assets are cached so a thumbnail request after the prefetch
//  window has primed them needs no extra fetch.
//

import Photos
import UIKit

actor SystemThumbnailProvider: ThumbnailProviding {
    private let cachingManager = PHCachingImageManager()

    /// One quantized request size for every thumbnail, so the cache keys stay stable as the grid
    /// recycles cells. Oversized vs the on-screen point size on purpose (Retina + headroom for a
    /// density change without a re-fetch).
    private let cacheTargetSize = CGSize(width: 400, height: 400)

    /// Resolved `localIdentifier → PHAsset`, primed by the prefetch window so single requests are
    /// fetch-free once the window covers them.
    private var assetsByID: [String: PHAsset] = [:]
    /// The currently-cached window, to diff add/remove when the visible range moves.
    private var cachedWindow: [PHAsset] = []

    func thumbnail(for assetID: String, targetSize: CGSize) async -> UIImage? {
        guard let asset = resolve(assetID) else { return nil }
        let manager = cachingManager
        // Box the request id so the cancellation handler can read it even if cancellation lands
        // between issuing the request and the box being set.
        let requestIDBox = LockedBox<PHImageRequestID>()

        return await withTaskCancellationHandler {
            if Task.isCancelled { return nil }
            return await withCheckedContinuation { (continuation: CheckedContinuation<UIImage?, Never>) in
                let options = PHImageRequestOptions()
                options.deliveryMode = .opportunistic
                options.resizeMode = .fast
                options.isNetworkAccessAllowed = true   // iCloud-optimized assets
                options.isSynchronous = false

                // Opportunistic delivery may call back twice (degraded then final); resume once.
                let resumed = LockedFlag()
                let id = manager.requestImage(
                    for: asset, targetSize: targetSize,
                    contentMode: .aspectFill, options: options
                ) { image, info in
                    let isDegraded = (info?[PHImageResultIsDegradedKey] as? NSNumber)?.boolValue ?? false
                    // The opportunistic low-res first is fine for the grid; resume on the first
                    // image we actually get. PhotoKit upgrades the cached copy for the next request.
                    guard !isDegraded || image != nil else { return }
                    if resumed.setOnce() { continuation.resume(returning: image) }
                }
                requestIDBox.value = id
                if Task.isCancelled { manager.cancelImageRequest(id) }
            }
        } onCancel: {
            if let id = requestIDBox.value { manager.cancelImageRequest(id) }
        }
    }

    func updateCachingWindow(to assetIDs: [String]) {
        // Built per call as a local: PHImageRequestOptions is mutable / non-Sendable, so it can't be
        // a shared static in an actor. Cheap to construct.
        let cachingOptions = PHImageRequestOptions()
        cachingOptions.deliveryMode = .opportunistic
        cachingOptions.resizeMode = .fast
        cachingOptions.isNetworkAccessAllowed = true

        // Batch-resolve any not-yet-cached ids in a single fetch (cheaper than per-id fetches).
        let missing = assetIDs.filter { assetsByID[$0] == nil }
        if !missing.isEmpty {
            PHAsset.fetchAssets(withLocalIdentifiers: missing, options: nil).enumerateObjects { asset, _, _ in
                self.assetsByID[asset.localIdentifier] = asset
            }
        }
        let window = assetIDs.compactMap { assetsByID[$0] }

        let newIDs = Set(window.map(\.localIdentifier))
        let oldIDs = Set(cachedWindow.map(\.localIdentifier))
        let added = window.filter { !oldIDs.contains($0.localIdentifier) }
        let removed = cachedWindow.filter { !newIDs.contains($0.localIdentifier) }

        if !removed.isEmpty {
            cachingManager.stopCachingImages(
                for: removed, targetSize: cacheTargetSize,
                contentMode: .aspectFill, options: cachingOptions)
        }
        if !added.isEmpty {
            cachingManager.startCachingImages(
                for: added, targetSize: cacheTargetSize,
                contentMode: .aspectFill, options: cachingOptions)
        }
        cachedWindow = window
    }

    func resetCache() {
        cachingManager.stopCachingImagesForAllAssets()
        cachedWindow = []
        // Also drop the resolved-asset map: without this it grows unbounded across a session and
        // isn't freed when the grid disappears (the one moment we'd expect it released). Re-entry
        // simply re-resolves, fetch-cheap.
        assetsByID = [:]
    }

    private func resolve(_ id: String) -> PHAsset? {
        if let cached = assetsByID[id] { return cached }
        let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject
        if let asset { assetsByID[id] = asset }
        return asset
    }
}

/// A tiny lock-protected optional box, `Sendable` so it can cross into the cancellation handler.
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
