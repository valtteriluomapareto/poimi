//
//  AssetModelTests.swift
//  CurationTests — the #18 value model + protocol seam.
//

import Testing
import Foundation
@testable import Curation

@Suite("Asset model (#18)")
struct AssetModelTests {

    @Test("AssetRef round-trips through Codable")
    func assetRefCodable() throws {
        let ref = AssetRef(
            id: "asset/1",
            captureDate: Date(timeIntervalSince1970: 1_700_000_000),
            coordinate: Coordinate(latitude: 60.17, longitude: 24.94),
            pixelSize: PixelSize(width: 4032, height: 3024),
            isScreenshot: false,
            isFavorite: true
        )
        let data = try JSONEncoder().encode(ref)
        let decoded = try JSONDecoder().decode(AssetRef.self, from: data)
        #expect(decoded == ref)
        #expect(decoded.id == "asset/1")
        #expect(decoded.pixelSize.pixelCount == 4032 * 3024)
    }

    @Test("AssetRef identity is its localIdentifier; optional fields default to nil/empty")
    func assetRefIdentity() {
        let ref = AssetRef(id: "abc", captureDate: nil)
        #expect(ref.id == "abc")
        #expect(ref.captureDate == nil)
        #expect(ref.coordinate == nil)
        #expect(ref.pixelSize == .zero)
        #expect(ref.isScreenshot == false)
        #expect(ref.isFavorite == false)
    }

    @Test("AssetRef is Hashable on its full value")
    func assetRefHashable() {
        let a = AssetRef(id: "x", captureDate: nil)
        let b = AssetRef(id: "x", captureDate: nil)
        #expect(Set([a, b]).count == 1)
    }

    @Test("AlbumRef carries id / title / count")
    func albumRef() {
        let album = AlbumRef(id: "alb/1", title: "Screenshots", count: 412)
        #expect(album.title == "Screenshots")
        #expect(album.count == 412)
        #expect(AlbumRef(id: "alb/2", title: "WhatsApp").count == nil)
    }

    @Test("AssetMetadata holds the deferred resource size, nil until fetched")
    func assetMetadata() {
        #expect(AssetMetadata(id: "abc").recordedByteSize == nil)
        #expect(AssetMetadata(id: "abc", recordedByteSize: 4_200_000).recordedByteSize == 4_200_000)
    }

    @Test("LibraryAuthorization and PhotoLibraryError are equatable value types")
    func authAndErrorValues() {
        #expect(LibraryAuthorization.limited != .authorized)
        #expect(PhotoLibraryError.notAuthorized == .notAuthorized)
        #expect(PhotoLibraryError.notAuthorized != .fetchFailed)
    }
}
