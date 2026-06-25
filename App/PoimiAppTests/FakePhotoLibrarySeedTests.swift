//
//  FakePhotoLibrarySeedTests.swift
//  PoimiAppTests — the canonical fake seeds (#28, D25/D29).
//

import Testing
import Foundation
import Curation
@testable import PoimiApp

@Suite("FakePhotoLibrary seeds (#28)")
struct FakePhotoLibrarySeedTests {

    @Test("yearMixed: the undated asset is excluded, the screenshot retained, 2 albums")
    func yearMixed() async throws {
        let library = FakePhotoLibrary.yearMixed()

        let status = await library.authorizationStatus()
        #expect(status == .authorized)

        // Assert the *contract* (undated excluded by a range fetch; screenshots retained — not a
        // source filter at this layer), not a hand-counted total the seed owns.
        let seed = FakePhotoLibrary.yearMixedSeed()
        let fetched = try await library.fetchAssets(in: .everything)
        #expect(fetched.count == seed.count - 1)                 // exactly the one undated, dropped
        let droppedUndated = !fetched.contains { $0.id == "fake/undated" }
        #expect(droppedUndated)
        let keptScreenshot = fetched.contains { $0.isScreenshot }
        #expect(keptScreenshot)

        let albums = try await library.albums()
        #expect(albums.count == 2)
    }

    @Test("empty: no assets, no albums, no membership, authorized")
    func empty() async throws {
        let library = FakePhotoLibrary.empty()
        let assets = try await library.fetchAssets(in: .everything)
        #expect(assets.isEmpty)
        let albums = try await library.albums()
        #expect(albums.isEmpty)
        // No albums ⇒ no membership: excluding anything yields nothing (the default WhatsApp
        // membership must not leak into the empty seed).
        let members = try await library.assetIDs(inAlbums: ["album/whatsapp"])
        #expect(members.isEmpty)
    }

    @Test("assetIDs(inAlbums:): WhatsApp resolves to its two members; empty input → empty set")
    func albumMembership() async throws {
        let library = FakePhotoLibrary.yearMixed()
        let members = try await library.assetIDs(inAlbums: ["album/whatsapp"])
        #expect(members == ["fake/busy/0", "fake/busy/1"])
        // Unknown album contributes nothing; empty input enumerates nothing (the seam contract).
        #expect(try await library.assetIDs(inAlbums: ["album/nope"]).isEmpty)
        #expect(try await library.assetIDs(inAlbums: []).isEmpty)
    }

    @Test("limited: reports .limited authorization")
    func limited() async throws {
        let status = await FakePhotoLibrary.limited().authorizationStatus()
        #expect(status == .limited)
    }

    @Test("scale: 10k seed fetches whole + satisfies the contract (perf smoke, NOT the D29 lazy guard)")
    func scale() async throws {
        // A generator / perf smoke over 10k assets — it exercises the EAGER, fully-materialized
        // path. This is NOT the D29 access-counting guard (which fails if the whole result is
        // materialized); that needs the windowed AssetRef-by-index API (D17), tracked in #47.
        let library = FakePhotoLibrary.scale(10_000)
        let assets = try await library.fetchAssets(in: .year2025)
        #expect(assets.count == 10_000)
        try await assertFetchContract(library, in: .year2025)    // in-range + sorted + unique over 10k
    }
}
