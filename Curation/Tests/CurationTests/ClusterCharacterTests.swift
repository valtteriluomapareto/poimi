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

    // Pin EVERY band edge (5/11/14/17/21 + the night wrap) — this is exactly where an off-by-one
    // would hide, and the mid-band cases above wouldn't catch it. Bands: 5–10 morning, 11–13 midday,
    // 14–16 afternoon, 17–20 evening, else (21–4) night.
    @Test("part-of-day boundary hours land in the right band")
    func boundaries() {
        #expect(ClusterCharacter.PartOfDay(hour: 0) == .night)
        #expect(ClusterCharacter.PartOfDay(hour: 4) == .night)      // last night hour before morning
        #expect(ClusterCharacter.PartOfDay(hour: 5) == .morning)    // morning opens
        #expect(ClusterCharacter.PartOfDay(hour: 10) == .morning)   // last morning hour
        #expect(ClusterCharacter.PartOfDay(hour: 11) == .midday)    // midday opens
        #expect(ClusterCharacter.PartOfDay(hour: 13) == .midday)    // last midday hour
        #expect(ClusterCharacter.PartOfDay(hour: 14) == .afternoon) // afternoon opens
        #expect(ClusterCharacter.PartOfDay(hour: 16) == .afternoon) // last afternoon hour
        #expect(ClusterCharacter.PartOfDay(hour: 17) == .evening)   // evening opens
        #expect(ClusterCharacter.PartOfDay(hour: 20) == .evening)   // last evening hour
        #expect(ClusterCharacter.PartOfDay(hour: 21) == .night)     // night resumes
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
