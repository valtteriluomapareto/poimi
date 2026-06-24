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

    @Test("yearMixed: 16 dated assets in range (undated excluded), 2 albums, authorized")
    func yearMixed() async throws {
        let library = FakePhotoLibrary.yearMixed()

        let status = await library.authorizationStatus()
        #expect(status == .authorized)

        // 12 busy + 3 quiet + 1 screenshot = 16 dated; the undated asset is excluded by a
        // range fetch (the shared contract).
        let assets = try await library.fetchAssets(in: .everything)
        #expect(assets.count == 16)

        let albums = try await library.albums()
        #expect(albums.count == 2)
    }

    @Test("empty: no assets, no albums, authorized")
    func empty() async throws {
        let library = FakePhotoLibrary.empty()
        let assets = try await library.fetchAssets(in: .everything)
        #expect(assets.isEmpty)
        let albums = try await library.albums()
        #expect(albums.isEmpty)
    }

    @Test("limited: reports .limited authorization")
    func limited() async throws {
        let status = await FakePhotoLibrary.limited().authorizationStatus()
        #expect(status == .limited)
    }

    @Test("scale: returns the requested count, in range and sorted (D29 scale smoke)")
    func scale() async throws {
        let library = FakePhotoLibrary.scale(10_000)
        let assets = try await library.fetchAssets(in: .year2025)
        #expect(assets.count == 10_000)
        let dates = assets.compactMap(\.captureDate)
        #expect(dates == dates.sorted())
    }
}
