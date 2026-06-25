//
//  ThumbnailMemoryCache.swift
//  PoimiApp — a synchronous decoded-thumbnail cache (smoothness review, Finding 2).
//
//  `PHCachingImageManager` pre-*decodes* thumbnails, but it only ever hands them back through an
//  *async* `requestImage` callback — there is no synchronous accessor. So a recycled grid cell, even
//  for an asset whose image is effectively in memory, still has to clear to a placeholder and make
//  the async actor round-trip again, flashing a spinner during a fast scroll-back.
//
//  This is the missing synchronous front: a tiny, bounded, thread-safe `NSCache` the provider fills
//  on each successful load and the cell reads *synchronously* (so a hit paints immediately, no
//  placeholder). It complements — does not replace — `PHCachingImageManager`: the manager solves the
//  decode latency, this solves the mandatory-async-hop placeholder frame. `NSCache` self-evicts under
//  memory pressure, so the bound is a soft cap, not a leak.
//

import UIKit

/// A bounded, thread-safe, synchronous cache of decoded thumbnails keyed by asset id + request size.
///
/// `@unchecked Sendable`: `NSCache` is documented thread-safe, and the binding is an immutable `let`,
/// so this is safe to share across isolation domains — in particular to read from a `nonisolated`
/// actor method and the main actor without hopping.
final class ThumbnailMemoryCache: @unchecked Sendable {
    private let cache = NSCache<NSString, UIImage>()

    /// `countLimit` is a soft cap (NSCache also evicts under memory pressure). ~600 keeps a few
    /// screens of a dense grid resident so a scroll-back is flash-free, without unbounded growth.
    init(countLimit: Int = 600) {
        cache.countLimit = countLimit
    }

    func image(for assetID: String, targetSize: CGSize) -> UIImage? {
        cache.object(forKey: Self.key(assetID, targetSize))
    }

    func store(_ image: UIImage, for assetID: String, targetSize: CGSize) {
        cache.setObject(image, forKey: Self.key(assetID, targetSize))
    }

    /// Drop everything — paired with the provider's `resetCache()` when the grid leaves review.
    func removeAll() {
        cache.removeAllObjects()
    }

    /// Quantize the key on the integer pixel size so the same id at the same request size shares a
    /// slot as cells recycle (the grid uses one fixed target, but keying on size keeps it correct if
    /// a second size is ever requested).
    private static func key(_ assetID: String, _ size: CGSize) -> NSString {
        "\(assetID)@\(Int(size.width))x\(Int(size.height))" as NSString
    }
}
