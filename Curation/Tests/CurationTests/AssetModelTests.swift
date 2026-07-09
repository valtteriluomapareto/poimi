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
            isFavorite: true,
            isVideo: true,
            duration: 14
        )
        let data = try JSONEncoder().encode(ref)
        let decoded = try JSONDecoder().decode(AssetRef.self, from: data)
        #expect(decoded == ref)
        #expect(decoded.id == "asset/1")
        #expect(decoded.pixelSize.pixelCount == 4032 * 3024)
        #expect(decoded.isVideo == true)      // media type + duration round-trip (#125)
        #expect(decoded.duration == 14)
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
        #expect(ref.isVideo == false)         // defaults to a still (#125)
        #expect(ref.duration == nil)
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

    @Test("sortedByTitle: A→Z, case-insensitive, natural-numeric, id-stable for ties (#124)")
    func albumsSortedByTitle() {
        // Fixture is intentionally ASCII-Latin: `localizedStandardCompare` reads the ambient locale, but
        // for pure-ASCII titles the ordering (case-fold + natural-numeric) is invariant across locales, so
        // this asserts real behavior without a locale seam and won't flake under CI's locale.
        let unsorted = [
            AlbumRef(id: "a5", title: "Album 10"),
            AlbumRef(id: "a1", title: "album 2"),        // lowercase must not sort after uppercase
            AlbumRef(id: "z", title: "Zoo"),
            AlbumRef(id: "dup-b", title: "Trip"),        // duplicate title, higher id
            AlbumRef(id: "dup-a", title: "Trip"),        // duplicate title, lower id → first
            AlbumRef(id: "a0", title: "Apples")
        ]
        let sorted = unsorted.sortedByTitle()
        #expect(sorted.map(\.title) == ["album 2", "Album 10", "Apples", "Trip", "Trip", "Zoo"])
        // "Album 2" before "Album 10" (natural numeric, not lexicographic "10" < "2").
        #expect(sorted.map(\.id) == ["a1", "a5", "a0", "dup-a", "dup-b", "z"])
        // Stable + idempotent: sorting the already-sorted list is a no-op (tie-break by id).
        #expect(sorted.sortedByTitle() == sorted)
        // Boundaries: empty and single-element are no-ops (not a crash / reorder).
        #expect([AlbumRef]().sortedByTitle().isEmpty)
        #expect([AlbumRef(id: "solo", title: "Only")].sortedByTitle().map(\.id) == ["solo"])
    }
}
