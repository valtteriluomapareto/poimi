//
//  ClusterCharacterTests.swift
//  CurationTests — the string-free cluster "character" facts (day-cluster personality).
//
//  Pins the pure summary the app tier phrases into a media-highlight subtitle: the total / video /
//  favourite counts over a cluster's assets. (An earlier time-of-day span was dropped as low-signal; a
//  locality descriptor is tracked in #201.)
//

import Testing
import Foundation
@testable import Curation

@Suite("Cluster character — day personality")
struct ClusterCharacterTests {
    @Test("videos + favourites are counted across all assets, dated or not")
    func counts() {
        let character = ClusterCharacter.of(assets: [
            AssetRef(id: "a", captureDate: Date(timeIntervalSince1970: 0), isFavorite: true),
            AssetRef(id: "b", captureDate: Date(timeIntervalSince1970: 100), isVideo: true),
            AssetRef(id: "c", captureDate: nil),   // undated → still counted
        ])
        #expect(character.assetCount == 3)
        #expect(character.videoCount == 1)
        #expect(character.favoriteCount == 1)
    }

    @Test("multiple videos + favourites accumulate")
    func multiple() {
        let character = ClusterCharacter.of(assets: [
            AssetRef(id: "a", captureDate: nil, isVideo: true),
            AssetRef(id: "b", captureDate: nil, isVideo: true),
            AssetRef(id: "c", captureDate: nil, isFavorite: true),
            AssetRef(id: "d", captureDate: nil),
        ])
        #expect(character.assetCount == 4)
        #expect(character.videoCount == 2)
        #expect(character.favoriteCount == 1)
    }

    @Test("an empty cluster → zero counts")
    func empty() {
        let character = ClusterCharacter.of(assets: [])
        #expect(character.assetCount == 0)
        #expect(character.videoCount == 0)
        #expect(character.favoriteCount == 0)
    }
}
