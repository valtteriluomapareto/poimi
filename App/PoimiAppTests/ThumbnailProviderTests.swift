//
//  ThumbnailProviderTests.swift
//  PoimiAppTests — the image-loading seam (#35).
//
//  The fake's determinism is load-bearing for the screenshot harness: the same id must render the
//  same tile every run (so a grid capture is comparable). The System side gets an unauthorized
//  smoke — an unresolvable id yields nil and the cache lifecycle never traps.
//

import Testing
import Foundation
import UIKit
@testable import PoimiApp

@Suite("Thumbnail seam (#35)")
struct ThumbnailProviderTests {

    private static let size = CGSize(width: 64, height: 64)

    @Test("fake: a tile is rendered at the requested size")
    func fakeRendersAtSize() async throws {
        let image = await FakeThumbnailProvider().thumbnail(for: "fake/busy/0", targetSize: Self.size)
        let unwrapped = try #require(image)
        #expect(unwrapped.size == Self.size)
    }

    @Test("fake: the same id renders an identical tile (deterministic across calls)")
    func fakeIsDeterministic() async throws {
        let provider = FakeThumbnailProvider()
        let first = await provider.thumbnail(for: "fake/busy/0", targetSize: Self.size)
        let second = await provider.thumbnail(for: "fake/busy/0", targetSize: Self.size)
        #expect(first?.pngData() == second?.pngData())
    }

    @Test("fake: a known id maps to a known hue (golden — catches a revert to a per-process hash)")
    func fakeHueIsStableAcrossProcesses() {
        // Within-process equality (above) holds even for `String.hashValue` (seeded once per
        // launch), so it can't catch the regression the comment warns against. A precomputed
        // golden value can: "fake/busy/0" folds to hash % 360 == 181 under the fixed-basis fold.
        #expect(FakeThumbnailProvider.stableHue("fake/busy/0") == CGFloat(181) / 360)
    }

    @Test("fake: different ids render different tiles")
    func fakeDistinguishesIDs() async throws {
        let provider = FakeThumbnailProvider()
        let a = await provider.thumbnail(for: "fake/busy/0", targetSize: Self.size)
        let b = await provider.thumbnail(for: "fake/busy/1", targetSize: Self.size)
        #expect(a?.pngData() != b?.pngData())
    }

    @Test("fake: the prefetch window + reset are no-ops that never throw")
    func fakeCacheLifecycle() async {
        let provider = FakeThumbnailProvider()
        await provider.updateCachingWindow(to: ["fake/busy/0", "fake/busy/1"])
        await provider.resetCache()
    }

    @Test("fake: fullImage renders at the requested size and matches the thumbnail's tile")
    func fakeFullImage() async throws {
        let provider = FakeThumbnailProvider()
        let big = CGSize(width: 256, height: 256)
        let full = try #require(await provider.fullImage(for: "fake/busy/0", targetSize: big))
        #expect(full.size == big)
        // Same id, same size → identical deterministic tile as a thumbnail at that size (the viewer
        // shows the same colour as the cell the user tapped).
        let asThumb = await provider.thumbnail(for: "fake/busy/0", targetSize: big)
        #expect(full.pngData() == asThumb?.pngData())
    }

    @Test("system: an unresolvable id yields nil; the cache lifecycle doesn't trap (unauthorized)")
    func systemUnresolvable() async {
        // On a fresh/unauthorized simulator, no id resolves to a PHAsset — so a request returns nil
        // and the window/reset calls run harmlessly over an empty resolution set. The authorized
        // window-resolution + start/stop-caching behavior needs real assets → on-device run (#46).
        let provider = SystemThumbnailProvider()
        await provider.updateCachingWindow(to: ["bogus/1", "bogus/2"])
        let image = await provider.thumbnail(for: "bogus/nonexistent", targetSize: Self.size)
        #expect(image == nil)
        let full = await provider.fullImage(for: "bogus/nonexistent", targetSize: Self.size)
        #expect(full == nil)
        await provider.resetCache()
    }
}
