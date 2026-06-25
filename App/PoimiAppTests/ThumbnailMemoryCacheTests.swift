//
//  ThumbnailMemoryCacheTests.swift
//  PoimiAppTests — the synchronous thumbnail cache + cell display rule (#35, smoothness Finding 2).
//
//  Two pure units, tested without rendering or PhotoKit:
//    • ThumbnailMemoryCache — the synchronous store/lookup the provider fills and the cell reads.
//    • thumbnailDisplay(...) — the rule that a recycle onto a cached asset shows the image, NOT a
//      placeholder (the spinner-flash regression Finding 2 is about).
//

import Testing
import Foundation
import UIKit
@testable import PoimiApp

@Suite("Thumbnail memory cache + cell display (Finding 2)")
struct ThumbnailMemoryCacheTests {

    private static let size = CGSize(width: 400, height: 400)

    @Test("store then read returns the same image; a miss is nil")
    func storeAndRead() {
        let cache = ThumbnailMemoryCache()
        let image = UIImage()
        #expect(cache.image(for: "a", targetSize: Self.size) == nil)   // cold miss
        cache.store(image, for: "a", targetSize: Self.size)
        #expect(cache.image(for: "a", targetSize: Self.size) === image)
        #expect(cache.image(for: "b", targetSize: Self.size) == nil)   // a different id still misses
    }

    @Test("the key is size-quantized: the same id at a different size is a separate slot")
    func keyedBySize() {
        let cache = ThumbnailMemoryCache()
        let image = UIImage()
        cache.store(image, for: "a", targetSize: Self.size)
        #expect(cache.image(for: "a", targetSize: CGSize(width: 100, height: 100)) == nil)
        #expect(cache.image(for: "a", targetSize: Self.size) === image)
    }

    @Test("removeAll drops everything")
    func removeAll() {
        let cache = ThumbnailMemoryCache()
        cache.store(UIImage(), for: "a", targetSize: Self.size)
        cache.removeAll()
        #expect(cache.image(for: "a", targetSize: Self.size) == nil)
    }

    // MARK: The placeholder rule (Finding 2)

    @Test("a loaded image matching the current id is shown")
    func showsMatchingLoaded() throws {
        let loaded = UIImage()
        let display = thumbnailDisplay(loadedID: "a", cellID: "a", loaded: loaded, cached: nil)
        guard case .image(let shown) = display else { Issue.record("expected .image"); return }
        #expect(shown === loaded)
    }

    @Test("a recycle onto a cached asset shows the cached image, NOT a placeholder")
    func recycleWithCacheHitSkipsPlaceholder() throws {
        // loadedID ("a") != cellID ("b"): the cell just recycled. The cache has "b" → it must paint
        // the image immediately. This is the spinner-flash regression guard.
        let cached = UIImage()
        let display = thumbnailDisplay(loadedID: "a", cellID: "b", loaded: UIImage(), cached: cached)
        guard case .image(let shown) = display else { Issue.record("expected .image"); return }
        #expect(shown === cached)
    }

    @Test("a recycle with no cache hit shows the placeholder, never the stale loaded image")
    func recycleWithoutCacheShowsPlaceholder() {
        // loadedID ("a") != cellID ("b") and the cache misses: the previous asset's `loaded` image
        // must NOT be painted onto the new cell — show the placeholder instead.
        let display = thumbnailDisplay(loadedID: "a", cellID: "b", loaded: UIImage(), cached: nil)
        guard case .placeholder = display else { Issue.record("expected .placeholder"); return }
    }

    @Test("mid-load (no loaded image yet) still adopts a cache hit")
    func midLoadUsesCache() throws {
        let cached = UIImage()
        let display = thumbnailDisplay(loadedID: nil, cellID: "a", loaded: nil, cached: cached)
        guard case .image(let shown) = display else { Issue.record("expected .image"); return }
        #expect(shown === cached)
    }

    @Test("nothing loaded and nothing cached → placeholder")
    func coldIsPlaceholder() {
        let display = thumbnailDisplay(loadedID: nil, cellID: "a", loaded: nil, cached: nil)
        guard case .placeholder = display else { Issue.record("expected .placeholder"); return }
    }

    @Test("system: cachedThumbnail is nil before any load (no synchronous hit on a cold provider)")
    func systemColdCacheMisses() {
        let provider = SystemThumbnailProvider()
        #expect(provider.cachedThumbnail(for: "bogus/nonexistent", targetSize: Self.size) == nil)
    }
}
