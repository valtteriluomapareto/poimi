//
//  FullImageLoader.swift
//  PoimiApp — Spike render layer
//
//  RENDER LAYER — promotable. Progressive full-resolution loading for the
//  full-screen pager: opportunistic degraded→final delivery with iCloud network
//  access allowed. The make-or-break "does progressive full-res feel instant"
//  load path (Phase 0 task 3) lives here so it survives into the real app.
//
//  Not throwaway: this is the salvageable tier.

import Photos
import UIKit

/// Loads progressively-improving full-resolution images for a single asset,
/// yielding each delivery (degraded first, then final) as an async stream so the
/// pager can show something instantly and sharpen in place.
@MainActor
enum FullImageLoader {
    /// Stream of images for `asset`: a fast degraded image first (if PhotoKit
    /// has one), then the full-quality image. Network access is allowed so
    /// iCloud-optimized originals download. Cancels the underlying request when
    /// the consuming task is cancelled.
    static func images(for asset: PHAsset) -> AsyncStream<UIImage> {
        AsyncStream { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .opportunistic   // degraded → final
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = true
            options.isSynchronous = false

            let manager = PHImageManager.default()
            let id = manager.requestImage(
                for: asset,
                targetSize: PHImageManagerMaximumSize,
                contentMode: .aspectFit,
                options: options
            ) { image, info in
                if let image {
                    continuation.yield(image)
                }
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? NSNumber)?.boolValue ?? false
                let isError = info?[PHImageErrorKey] != nil
                let isCancelled = (info?[PHImageCancelledKey] as? NSNumber)?.boolValue ?? false
                // Finish once the final (non-degraded) image has arrived, or on
                // terminal error/cancel.
                if (!isDegraded && image != nil) || isError || isCancelled {
                    continuation.finish()
                }
            }

            continuation.onTermination = { _ in
                manager.cancelImageRequest(id)
            }
        }
    }
}
