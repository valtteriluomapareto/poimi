//
//  ReviewTimelineTests.swift
//  CurationTests — the location-aware review timeline merge (issue #130).
//
//  The assembler is an ADDITIVE overlay (D33): it folds whole day-groups into trip clusters and never
//  splits one. These pin (1) the partition — every asset + every day-group lands in exactly one cluster,
//  no loss/dup; (2) the gate — location off / no trips ⇒ byte-identical to `DayGrouping`; (3) the merge
//  seams — whole-group ownership, boundary non-leakage, gap-tolerance, undated placement, chronological
//  interleave, straddle; (4) `TripShape` thresholds incl. the calendar-honest weekend + count-not-span;
//  (5) determinism + DST/antimeridian robustness through the composed pipeline. Style: Swift Testing +
//  `SeededRNG`, matching `PlaceClusterTests` / `TripOverlayTests`.
//

import Testing
import Foundation
@testable import Curation

@Suite("ReviewTimeline — the location overlay merge")
struct ReviewTimelineTests {
    private let cal = utcCalendar()
    private let base = utcCalendar().date(from: DateComponents(year: 2025, month: 1, day: 1))!   // Wed

    private func date(_ offset: Int) -> Date { cal.date(byAdding: .day, value: offset, to: base)! }
    private func key(_ offset: Int) -> DayKey { DayKey(date: date(offset), calendar: cal) }
    private func located(_ id: String, _ lat: Double, _ lon: Double, dayOffset: Int) -> AssetRef {
        AssetRef(id: id, captureDate: date(dayOffset), coordinate: Coordinate(latitude: lat, longitude: lon))
    }
    /// `perDay` located photos at a coordinate on each offset.
    private func place(_ prefix: String, _ lat: Double, _ lon: Double, offsets: [Int], perDay: Int) -> [AssetRef] {
        var out: [AssetRef] = []
        for offset in offsets {
            for shot in 0..<perDay { out.append(located("\(prefix)-\(offset)-\(shot)", lat, lon, dayOffset: offset)) }
        }
        return out
    }

    private static let helsinki = (lat: 60.17, lon: 24.94)   // home
    private static let aland = (lat: 60.10, lon: 19.90)      // an away place, distinct cluster
    private static let rome = (lat: 41.90, lon: 12.50)       // another away place

    // MARK: — the gate: location off / no trips ⇒ exactly DayGrouping

    @Test("locationEnabled == false is byte-identical to DayGrouping.groups(adaptiveFor:)", arguments: 0..<100)
    func locationDisabledEqualsDayGrouping(seed: Int) {
        var rng = SeededRNG(seed: UInt64(seed))
        let assets = field(&rng)
        let timeline = ReviewTimeline.clusters(for: assets, calendar: cal, locationEnabled: false)
        let dayGroups = DayGrouping.groups(adaptiveFor: assets, calendar: cal)
        // Every element is a `.day` and equals the corresponding DayGroup, in order.
        #expect(timeline == dayGroups.map(ReviewCluster.day))
    }

    @Test("a home-only album (no away days) yields no trips ⇒ all .day == DayGrouping")
    func noTripsFoundEqualsDayGrouping() {
        let assets = place("home", Self.helsinki.lat, Self.helsinki.lon, offsets: Array(0..<40), perDay: 3)
        let timeline = ReviewTimeline.clusters(for: assets, calendar: cal)
        #expect(timeline.allSatisfy { $0.tripCluster == nil })
        #expect(timeline == DayGrouping.groups(adaptiveFor: assets, calendar: cal).map(ReviewCluster.day))
    }

    // MARK: — partition (no loss, no dup) of both assets AND day-groups

    @Test("every asset + every day-group lands in exactly one cluster; undated never in a trip",
          arguments: 0..<100)
    func partition(seed: Int) {
        var rng = SeededRNG(seed: UInt64(seed))
        let assets = field(&rng)
        let timeline = ReviewTimeline.clusters(for: assets, calendar: cal)

        // Asset-id partition.
        let ids = timeline.flatMap(\.assetIDs)
        #expect(ids.count == assets.count)                       // no loss, no dup
        #expect(Set(ids) == Set(assets.map(\.id)))

        // Day-group partition: the merge folds whole groups, never splits/loses one. Compare by id
        // (unique) AND full value (each group preserved intact, not just its id).
        let dayGroups = DayGrouping.groups(adaptiveFor: assets, calendar: cal)
        let folded = timeline.flatMap(\.dayGroups)
        #expect(folded.count == dayGroups.count)
        #expect(folded.sorted { $0.id < $1.id } == dayGroups.sorted { $0.id < $1.id })

        // Undated assets are always in a `.day` — a trip never covers the undated sentinel.
        let undatedIDs = Set(assets.filter { $0.captureDate == nil }.map(\.id))
        let tripIDs = Set(timeline.compactMap(\.tripCluster).flatMap(\.assetIDs))
        #expect(tripIDs.isDisjoint(with: undatedIDs))
        // A trip's days never include `.undated`.
        #expect(timeline.compactMap(\.tripCluster).allSatisfy { !$0.days.contains(.undated) })
    }

    @Test("a dated-but-no-GPS asset on a non-trip day rides in a date cluster (never vanishes)")
    func datedNoGPSStaysDay() {
        // Day 25 is a home day (no trip), so the no-GPS photo there lands in a date cluster.
        let datedNoGPS = AssetRef(id: "dated-nogps", captureDate: date(25), coordinate: nil)
        let assets = [datedNoGPS]
            + place("home", Self.helsinki.lat, Self.helsinki.lon, offsets: Array(20..<40), perDay: 3)
            + place("trip", Self.rome.lat, Self.rome.lon, offsets: [5, 6], perDay: 20)
        let timeline = ReviewTimeline.clusters(for: assets, minPts: 3, calendar: cal)
        let owning = timeline.first { $0.assetIDs.contains("dated-nogps") }
        #expect(owning != nil)                                   // never vanishes
        #expect(owning?.tripCluster == nil)                      // and it's a date cluster
    }

    // MARK: — the merge seams

    @Test("a real multi-day away trip folds its whole day-groups into one trip cluster")
    func tripMergesWholeDayGroups() {
        // You're away on days 10–11, so no home photos those days → the trip is exactly the away set.
        let homeOffsets = Array(0..<40).filter { $0 != 10 && $0 != 11 }
        let home = place("home", Self.helsinki.lat, Self.helsinki.lon, offsets: homeOffsets, perDay: 3)
        let trip = place("aland", Self.aland.lat, Self.aland.lon, offsets: [10, 11], perDay: 20)   // 2 busy days
        let timeline = ReviewTimeline.clusters(for: home + trip, minPts: 3, calendar: cal)

        let trips = timeline.compactMap(\.tripCluster)
        #expect(trips.count == 1)
        // The trip cluster owns exactly the two away days' photos, merged.
        #expect(Set(trips[0].assetIDs) == Set(trip.map(\.id)))
        #expect(Set(trips[0].days) == Set([key(10), key(11)]))
    }

    @Test("a home-minority photo on an away day rides with the trip (the day-group is the atom, D33)")
    func daySplitHomeMinorityRidesWithTrip() {
        // Home shoots a few photos on days 10–11 too, but the away place has the plurality → those days
        // are trip days, and their WHOLE day-groups (home-minority included) fold into the trip.
        let home = place("home", Self.helsinki.lat, Self.helsinki.lon, offsets: Array(0..<40), perDay: 3)
        let trip = place("aland", Self.aland.lat, Self.aland.lon, offsets: [10, 11], perDay: 20)
        let timeline = ReviewTimeline.clusters(for: home + trip, minPts: 3, calendar: cal)

        let trips = timeline.compactMap(\.tripCluster)
        #expect(trips.count == 1)
        #expect(trips[0].assetIDs.contains("home-10-0"))         // home-minority rides along
        #expect(trips[0].assetIDs.contains("home-11-0"))
        #expect(Set(trips[0].days) == Set([key(10), key(11)]))
        // …and only in the trip — not also duplicated in a date cluster (partition intact).
        let dayClusters = timeline.filter { $0.tripCluster == nil }
        #expect(!dayClusters.contains { $0.assetIDs.contains("home-10-0") })
    }

    @Test("a trip abutting a home day does not leak: only the away day is in the trip")
    func boundaryAbutment() {
        let home = place("home", Self.helsinki.lat, Self.helsinki.lon, offsets: Array(0..<40), perDay: 3)
        // Day 10 away+busy (own group), day 11 home+busy (own group) — adjacent.
        let awayDay = place("rome", Self.rome.lat, Self.rome.lon, offsets: [10], perDay: 25)
        let homeBusy = place("home", Self.helsinki.lat, Self.helsinki.lon, offsets: [11], perDay: 25)
        let timeline = ReviewTimeline.clusters(for: home + awayDay + homeBusy, minPts: 3, calendar: cal)

        let trips = timeline.compactMap(\.tripCluster)
        #expect(trips.count == 1)
        #expect(Set(trips[0].days) == Set([key(10)]))                       // trip = day 10 only
        #expect(!trips[0].assetIDs.contains { $0.hasPrefix("home-11") })    // no home-11 leak
        // Day 11's photos live in a date cluster, not the trip.
        let day11 = timeline.first { $0.assetIDs.contains { $0.hasPrefix("home-11") } }
        #expect(day11?.tripCluster == nil)
    }

    @Test("a NEUTRAL day within trip gap tolerance is bridged into one trip; beyond it splits in two")
    func gapToleranceBoundary() {
        // Case A: away days 2 apart (== TripOverlay default tolerance) with a genuinely empty day 11
        // between (home shoots nothing there) → the neutral day is bridged → one trip.
        let homeA = place("home", Self.helsinki.lat, Self.helsinki.lon,
                          offsets: Array(0..<20).filter { ![10, 11, 12].contains($0) }, perDay: 3)
        let awayA = place("rome", Self.rome.lat, Self.rome.lon, offsets: [10, 12], perDay: 25)
        let one = ReviewTimeline.clusters(for: homeA + awayA, minPts: 3, calendar: cal)
        #expect(one.compactMap(\.tripCluster).count == 1)

        // Case B: away days 4 apart, the neutral days between exceed the tolerance → two trips.
        let homeB = place("home", Self.helsinki.lat, Self.helsinki.lon,
                          offsets: Array(30..<50).filter { !(40...44).contains($0) }, perDay: 3)
        let awayB = place("rome", Self.rome.lat, Self.rome.lon, offsets: [40, 44], perDay: 25)
        let two = ReviewTimeline.clusters(for: homeB + awayB, minPts: 3, calendar: cal)
        #expect(two.compactMap(\.tripCluster).count == 2)
    }

    @Test("trips interleave chronologically with the home date clusters between them")
    func chronologicalInterleave() {
        let home = place("home", Self.helsinki.lat, Self.helsinki.lon, offsets: Array(0..<40), perDay: 3)
        let tripA = place("aland", Self.aland.lat, Self.aland.lon, offsets: [5, 6], perDay: 20)
        let tripB = place("rome", Self.rome.lat, Self.rome.lon, offsets: [20, 21], perDay: 20)
        let timeline = ReviewTimeline.clusters(for: home + tripA + tripB, minPts: 3, calendar: cal)

        // First-day order is strictly ascending across the whole timeline (undated last).
        let firsts = timeline.map { $0.days.first! }
        #expect(firsts == firsts.sorted())
        // Two trips, and a home date cluster exists between them.
        let tripIdx = timeline.indices.filter { timeline[$0].tripCluster != nil }
        #expect(tripIdx.count == 2)
        #expect(tripIdx[1] - tripIdx[0] >= 2)   // ≥1 date cluster sits between the trips
    }

    // MARK: — TripShape (string-free, calendar-honest)

    @Test("TripShape thresholds by away-day count")
    func tripShapeThresholds() {
        func shape(_ offsets: [Int]) -> TripShape { TripShape.classify(days: offsets.map(key), calendar: cal) }
        #expect(shape([0]) == .visit)                       // 1 day (Wed)
        #expect(shape([6, 7]) == .shortTrip)                // Tue+Wed, 2 days, no weekend
        #expect(shape([3, 4]) == .weekend)                  // Sat+Sun, 2 days, weekend
        #expect(shape([2, 3, 4]) == .weekend)               // Fri–Sun, 3 days, weekend
        #expect(shape([5, 6, 7, 8]) == .shortTrip)          // Mon–Thu, 4 days, no weekend
        #expect(shape([5, 6, 7, 8, 9]) == .week)            // 5 days
        #expect(shape(Array(0..<10)) == .week)              // 10 days
        #expect(shape(Array(0..<11)) == .longer(days: 11))  // 11 days
    }

    @Test("TripShape weekend detection is calendar-honest, and counts away-days not calendar span")
    func tripShapeWeekendAndSpan() {
        // Tue–Wed (no weekend) is a short trip; Sat–Sun (weekend) is a weekend — same count, diff shape.
        #expect(TripShape.classify(days: [key(6), key(7)], calendar: cal) == .shortTrip)
        #expect(TripShape.classify(days: [key(3), key(4)], calendar: cal) == .weekend)
        // A bridged 2-away-day run across a 5-day span (Mon…Fri, no weekend) is a SHORT trip, not a week
        // — the shape counts away days, not the span.
        #expect(TripShape.classify(days: [key(5), key(9)], calendar: cal) == .shortTrip)
    }

    // MARK: — direct `assemble` edges

    @Test("empty input yields an empty timeline")
    func emptyInput() {
        #expect(ReviewTimeline.clusters(for: [], calendar: cal).isEmpty)
        #expect(ReviewTimeline.assemble(dayGroups: [], trips: [], calendar: cal).isEmpty)
    }

    @Test("a day-group straddling a trip-span edge stays a date cluster (never split)")
    func straddlingGroupStaysDay() {
        // A quiet-run day-group spanning day 10 (in-span) and day 11 (out-of-span); trip covers day 10.
        let straddler = DayGroup(id: "s0", assetIDs: ["s0", "s1"], days: [key(10), key(11)], isBusyDay: false)
        let trip = Trip(clusterID: "place", days: [key(10)])
        let out = ReviewTimeline.assemble(dayGroups: [straddler], trips: [trip], calendar: cal)
        #expect(out == [.day(straddler)])                   // stays a date cluster; trip owns nothing → not emitted
    }

    @Test("a trip that owns bridged neutral day-groups folds them into one contiguous cluster")
    func absorbsBridgedGroupWithinSpan() {
        // Two away busy days (10, 12) + a neutral no-away day-group on 11 within the span → one trip.
        let g10 = DayGroup(id: "a", assetIDs: ["a0"], days: [key(10)], isBusyDay: true)
        let g11 = DayGroup(id: "n", assetIDs: ["n0"], days: [key(11)], isBusyDay: false)   // bridged neutral
        let g12 = DayGroup(id: "b", assetIDs: ["b0"], days: [key(12)], isBusyDay: true)
        let trip = Trip(clusterID: "place", days: [key(10), key(12)])   // away days; 11 bridged (absent)
        let out = ReviewTimeline.assemble(dayGroups: [g10, g11, g12], trips: [trip], calendar: cal)
        #expect(out.count == 1)
        #expect(out[0].tripCluster?.dayGroups == [g10, g11, g12])       // all three folded, in order
    }

    // MARK: — determinism + robustness through the composed pipeline

    @Test("the timeline is order-independent (byte-identical under input shuffle)", arguments: 0..<50)
    func shuffleInvariant(seed: Int) {
        var rng = SeededRNG(seed: UInt64(seed))
        // Undated assets have no sort key (their group is input-ordered), so byte-identity is a
        // dated-only guarantee — real photos carry distinct capture timestamps (which the field gives).
        let assets = field(&rng, undated: false)
        let once = ReviewTimeline.clusters(for: assets, calendar: cal)
        for _ in 0..<3 {
            #expect(ReviewTimeline.clusters(for: assets.shuffled(using: &rng), calendar: cal) == once)
        }
    }

    @Test("partition holds through a non-UTC calendar across a spring-forward DST boundary")
    func dstPartition() {
        let ny = utcCalendar("America/New_York")
        let dstBase = ny.date(from: DateComponents(year: 2025, month: 3, day: 1))!   // DST: Mar 9 2025
        func d(_ off: Int) -> Date { ny.date(byAdding: .day, value: off, to: dstBase)! }
        func loc(_ id: String, _ lat: Double, _ lon: Double, _ off: Int) -> AssetRef {
            AssetRef(id: id, captureDate: d(off), coordinate: Coordinate(latitude: lat, longitude: lon))
        }
        var assets: [AssetRef] = []
        for off in 0..<20 {
            for shot in 0..<3 { assets.append(loc("home-\(off)-\(shot)", Self.helsinki.lat, Self.helsinki.lon, off)) }
        }
        for off in [8, 9, 10] {   // straddles the Mar 9 2025 spring-forward
            for shot in 0..<20 { assets.append(loc("trip-\(off)-\(shot)", Self.rome.lat, Self.rome.lon, off)) }
        }

        let timeline = ReviewTimeline.clusters(for: assets, minPts: 3, calendar: ny)
        let ids = timeline.flatMap(\.assetIDs)
        #expect(ids.count == assets.count)
        #expect(Set(ids) == Set(assets.map(\.id)))
        #expect(timeline.compactMap(\.tripCluster).count == 1)   // the DST-straddling trip is still one trip
    }

    @Test("an antimeridian away trip surfaces as a single trip cluster")
    func antimeridianTrip() {
        let home = place("home", Self.helsinki.lat, Self.helsinki.lon, offsets: Array(0..<40), perDay: 3)
        // Fiji-ish, photos on both sides of the ±180° seam on the same trip.
        var fiji: [AssetRef] = []
        for off in [10, 11] {
            for shot in 0..<10 { fiji.append(located("fj-e-\(off)-\(shot)", -17.7, 179.6, dayOffset: off)) }
            for shot in 0..<10 { fiji.append(located("fj-w-\(off)-\(shot)", -17.7, -179.6, dayOffset: off)) }
        }
        let timeline = ReviewTimeline.clusters(for: home + fiji, minPts: 3, calendar: cal)
        #expect(timeline.compactMap(\.tripCluster).count == 1)
    }

    // MARK: — property field

    /// A realistic album: a home run spanning most days, 0–3 disjoint away trips (busy days), plus some
    /// dated-no-GPS and (optionally) undated assets — shuffled. Every dated asset gets a DISTINCT capture
    /// timestamp (sub-day seconds) so grouping is totally ordered — the order-independence real photos
    /// have. Random far coords may or may not cluster; the partition invariants hold regardless.
    private func field(_ rng: inout SeededRNG, undated: Bool = true) -> [AssetRef] {
        var assets: [AssetRef] = []
        func at(_ id: String, _ off: Int, _ second: Int, _ lat: Double, _ lon: Double) -> AssetRef {
            AssetRef(id: id, captureDate: date(off).addingTimeInterval(Double(second)),
                     coordinate: Coordinate(latitude: lat, longitude: lon))
        }
        var used = Set<Int>()
        for tripIdx in 0..<Int.random(in: 0...3, using: &rng) {
            let start = Int.random(in: 0...54, using: &rng)
            let offsets = (start..<(start + Int.random(in: 1...4, using: &rng))).filter { $0 < 58 }
            guard !offsets.isEmpty, offsets.allSatisfy({ !used.contains($0) }) else { continue }
            offsets.forEach { used.insert($0) }
            let lat = Double.random(in: -60...60, using: &rng)
            let lon = Double.random(in: -170...170, using: &rng)
            for off in offsets {
                for shot in 0..<Int.random(in: 15...30, using: &rng) {
                    assets.append(at("trip\(tripIdx)-\(off)-\(shot)", off, shot, lat, lon))
                }
            }
        }
        for off in 0..<58 where !used.contains(off) {
            for shot in 0..<Int.random(in: 2...4, using: &rng) {
                assets.append(at("home-\(off)-\(shot)", off, shot, Self.helsinki.lat, Self.helsinki.lon))
            }
        }
        for i in 0..<Int.random(in: 0...5, using: &rng) {
            let off = Int.random(in: 0...57, using: &rng)
            assets.append(AssetRef(id: "ng\(i)", captureDate: date(off).addingTimeInterval(Double(500 + i)),
                                   coordinate: nil))
        }
        if undated {
            for i in 0..<Int.random(in: 0...4, using: &rng) {
                assets.append(AssetRef(id: "ud\(i)", captureDate: nil, coordinate: nil))
            }
        }
        assets.shuffle(using: &rng)
        return assets
    }
}
