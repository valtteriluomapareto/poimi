//
//  ClusterCharacterTests.swift
//  CurationTests — the string-free cluster "character" facts (day-cluster personality).
//
//  Pins the pure summary the app tier phrases into a descriptive subtitle: the time-of-day span of a
//  cluster's dated assets and the video / favourite counts. Deterministic under an injected calendar.
//

import Testing
import Foundation
@testable import Curation

@Suite("Cluster character — day personality")
struct ClusterCharacterTests {
    /// A UTC calendar so an hour component is exactly the hour we encode into the test dates.
    private var utc: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    /// A dated asset at `hour` on 2025-07-05 (UTC), tagged video / favourite as asked.
    private func asset(id: String, hour: Int, isVideo: Bool = false, isFavorite: Bool = false) -> AssetRef {
        let date = utc.date(from: DateComponents(year: 2025, month: 7, day: 5, hour: hour))!
        return AssetRef(id: id, captureDate: date, isFavorite: isFavorite, isVideo: isVideo)
    }

    @Test("part-of-day buckets the hour by the documented boundaries")
    func buckets() {
        #expect(ClusterCharacter.PartOfDay(hour: 7) == .morning)
        #expect(ClusterCharacter.PartOfDay(hour: 12) == .midday)
        #expect(ClusterCharacter.PartOfDay(hour: 15) == .afternoon)
        #expect(ClusterCharacter.PartOfDay(hour: 19) == .evening)
        #expect(ClusterCharacter.PartOfDay(hour: 23) == .night)
        #expect(ClusterCharacter.PartOfDay(hour: 3) == .night)   // early hours wrap to night
    }

    @Test("earliest / latest span the dated assets' parts of day")
    func span() {
        let character = ClusterCharacter.of(
            assets: [asset(id: "a", hour: 8), asset(id: "b", hour: 15), asset(id: "c", hour: 19)],
            calendar: utc)
        #expect(character.earliest == .morning)
        #expect(character.latest == .evening)
        #expect(character.assetCount == 3)
    }

    @Test("a single part of day reads earliest == latest")
    func singlePart() {
        let character = ClusterCharacter.of(
            assets: [asset(id: "a", hour: 9), asset(id: "b", hour: 10)], calendar: utc)
        #expect(character.earliest == .morning)
        #expect(character.latest == .morning)
    }

    @Test("videos + favourites are counted; undated assets count but don't set the span")
    func counts() {
        let character = ClusterCharacter.of(
            assets: [
                asset(id: "a", hour: 9, isFavorite: true),
                asset(id: "b", hour: 20, isVideo: true),
                AssetRef(id: "c", captureDate: nil),           // undated → count only
            ],
            calendar: utc)
        #expect(character.assetCount == 3)
        #expect(character.videoCount == 1)
        #expect(character.favoriteCount == 1)
        #expect(character.earliest == .morning)                // set by the dated assets only
        #expect(character.latest == .evening)
    }

    @Test("no dated assets → a nil span (but the counts still hold)")
    func allUndated() {
        let character = ClusterCharacter.of(
            assets: [AssetRef(id: "a", captureDate: nil), AssetRef(id: "b", captureDate: nil, isVideo: true)],
            calendar: utc)
        #expect(character.earliest == nil)
        #expect(character.latest == nil)
        #expect(character.assetCount == 2)
        #expect(character.videoCount == 1)
    }
}
