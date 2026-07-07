//
//  TripOverlayTests.swift
//  CurationTests — the §6 trip overlay + the D32(d)/D33 done-invariant tripwire (issue #131).
//
//  Invariants 5 (orthogonal axes), 6 (plurality label + tie-break), 7 (the §6 trip cases), 8 (done
//  survives regrouping — the tripwire), and 10 (precision/recall on the planted seed). Style matches
//  the repo (Swift Testing, `SeededRNG`, planted ground truth so recall is measured, not eyeballed).
//

import Testing
import Foundation
@testable import Curation

@Suite("TripOverlay — the §6 trip composition")
struct TripOverlayTests {
    private let cal = utcCalendar()
    private let base = utcCalendar().date(from: DateComponents(year: 2025, month: 1, day: 1))!

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

    private func pipeline(_ assets: [AssetRef], minPts: Int? = nil,
                          gapTolerance: Int = TripOverlay.defaultGapToleranceDays) -> (PlaceClusters, [Trip]) {
        let clusters = PlaceClustering.clusters(for: assets, minPts: minPts, calendar: cal)
        let home = PlaceClustering.homeCluster(clusters.clusters, assets: assets, calendar: cal)
        let trips = TripOverlay.trips(assets: assets, clusters: clusters, home: home,
                                      gapToleranceDays: gapTolerance, calendar: cal)
        return (clusters, trips)
    }

    // MARK: Invariant 5 — orthogonal axes (§5.4)

    @Test("a dated-but-no-GPS asset keeps its real day, gets no trip, and is never forced to .undated")
    func orthogonalAxes() {
        let datedNoGPS = AssetRef(id: "dated-nogps", captureDate: date(5), coordinate: nil)
        let undatedNoGPS = AssetRef(id: "undated-nogps", captureDate: nil, coordinate: nil)
        // A home cluster elsewhere so clustering + trips run normally.
        let home = place("home", 60.17, 24.94, offsets: Array(20..<40), perDay: 3)
        let assets = [datedNoGPS, undatedNoGPS] + home

        // Real day preserved; only the genuinely undated asset uses `.undated`.
        #expect(datedNoGPS.dayKey(in: cal) == key(5))
        #expect(datedNoGPS.dayKey(in: cal) != .undated)
        #expect(undatedNoGPS.dayKey(in: cal) == .undated)

        let (clusters, trips) = pipeline(assets, minPts: 3)
        // Both no-GPS assets route to no-location; neither joins a cluster.
        #expect(clusters.noLocationIDs.contains("dated-nogps"))
        #expect(clusters.noLocationIDs.contains("undated-nogps"))
        #expect(clusters.clusters.allSatisfy { !$0.assetIDs.contains("dated-nogps") })
        // The dated-no-GPS day carries no trip overlay (no located photos there).
        let tripDays = TripOverlay.tripIDByDay(trips)
        #expect(tripDays[key(5)] == nil)
    }

    // MARK: Invariant 6 — plurality label + deterministic tie-break

    @Test("a run is labeled by the plurality cluster, and shuffling doesn't change the winner")
    func pluralityLabel() {
        // One isolated day: City B has more photos than City A → the day's trip is labeled City B.
        // home: nil so both cities are away (no home base in this focused fixture).
        let cityA = place("aaa", 41.9, 12.5, offsets: [10], perDay: 3)     // Rome-ish
        let cityB = place("bbb", 48.86, 2.35, offsets: [10], perDay: 6)    // Paris-ish (plurality)
        let assets = cityA + cityB

        let clusters = PlaceClustering.clusters(for: assets, minPts: 3, calendar: cal)
        let trips = TripOverlay.trips(assets: assets, clusters: clusters, home: nil, calendar: cal)
        #expect(trips.count == 1)
        let bCluster = clusters.clusters.first { $0.assetIDs.contains(where: { $0.hasPrefix("bbb") }) }
        #expect(trips[0].clusterID == bCluster?.id)

        var rng = SeededRNG(seed: 42)
        let shuffledAssets = assets.shuffled(using: &rng)   // shuffle BOTH the cluster and trip inputs
        let shuffled = PlaceClustering.clusters(for: shuffledAssets, minPts: 3, calendar: cal)
        let shuffledTrips = TripOverlay.trips(assets: shuffledAssets, clusters: shuffled, home: nil, calendar: cal)
        #expect(shuffledTrips == trips)   // determinism: same label, same days for the plurality step
    }

    @Test("an exact plurality tie is broken by the lower medoid id")
    func pluralityTieBreak() {
        // Two equal-size clusters on one isolated day. Identical-coordinate bursts → medoid = lowest
        // id in each ("aaa-10-0", "bbb-10-0"). No home (home: nil) so both are away. Tie → lower id.
        let cityA = place("aaa", 41.9, 12.5, offsets: [10], perDay: 4)
        let cityB = place("bbb", 48.86, 2.35, offsets: [10], perDay: 4)
        let assets = cityA + cityB
        let clusters = PlaceClustering.clusters(for: assets, minPts: 3, calendar: cal)
        let trips = TripOverlay.trips(assets: assets, clusters: clusters, home: nil, calendar: cal)
        #expect(trips.count == 1)
        // Lower medoid id wins: "aaa-10-0" < "bbb-10-0".
        #expect(trips[0].clusterID == "aaa-10-0")
    }

    @Test("a run is labelled by where the most DAYS were spent, not where the most photos were taken")
    func labelByTimeNotPhotoVolume() {
        // A 4-day away run: BASED in city A for 3 days (few photos each), with a single photo-heavy
        // day-excursion to city B (the "amusement park day" — one day, many photos). home: nil so both
        // are away; gap 1 ≤ tolerance so it's ONE run. Photo-plurality would name it B (60 > 9); the
        // time-based label names it A (3 days > 1). The Naantali case, distilled.
        let cityA = place("aaa", 60.0, 24.0, offsets: [10, 11, 12], perDay: 3)   //  9 photos, 3 days
        let cityB = place("bbb", 61.0, 25.0, offsets: [13], perDay: 60)          // 60 photos, 1 day
        let assets = cityA + cityB
        let clusters = PlaceClustering.clusters(for: assets, minPts: 3, calendar: cal)
        let trips = TripOverlay.trips(assets: assets, clusters: clusters, home: nil,
                                      gapToleranceDays: 2, calendar: cal)
        #expect(trips.count == 1)
        let cityACluster = clusters.clusters.first { $0.assetIDs.contains { $0.hasPrefix("aaa-") } }
        #expect(trips[0].clusterID == cityACluster?.id)   // A (most days) wins over B (most photos)
        #expect(Set(trips[0].days) == Set([key(10), key(11), key(12), key(13)]))
    }

    // MARK: Invariant 7 — the §6 trip cases

    @Test("the same place visited in two separate months → two trips, same cluster")
    func samePlaceTwoTrips() {
        // A destination (cabin) visited in Jan and June; a home base present across many other days.
        // §6: same cluster, two time-runs → two trips. (The literal home base is excluded from trips —
        // see homeBaseNeverATrip — so we exercise "two runs of one cluster" with a destination.)
        let home = place("home", 60.17, 24.94, offsets: Array(stride(from: 0, through: 200, by: 2)), perDay: 3)
        let cabinJan = place("cabin", 66.5, 25.7, offsets: [11, 12, 13], perDay: 8)     // away, Jan
        let cabinJun = place("cabin", 66.5, 25.7, offsets: [161, 162, 163], perDay: 8)  // away, June
        let assets = home + cabinJan + cabinJun

        let (clusters, trips) = pipeline(assets, minPts: 3)
        let cabin = clusters.clusters.first { $0.assetIDs.contains(where: { $0.hasPrefix("cabin") }) }
        let cabinTrips = trips.filter { $0.clusterID == cabin?.id }
        #expect(cabinTrips.count == 2)                          // two distinct time-runs
        #expect(Set(cabinTrips.map(\.id)).count == 2)           // distinct trip ids
    }

    @Test("the home base is detected but never surfaced as a trip")
    func homeBaseNeverATrip() {
        let home = place("home", 60.17, 24.94, offsets: Array(0..<40), perDay: 4)
        let trip = place("trip", 41.9, 12.5, offsets: [50, 51], perDay: 8)
        let assets = home + trip
        let (clusters, trips) = pipeline(assets, minPts: 3)
        let homeCluster = PlaceClustering.homeCluster(clusters.clusters, assets: assets, calendar: cal)
        #expect(homeCluster?.assetIDs.contains(where: { $0.hasPrefix("home") }) == true)
        #expect(trips.allSatisfy { $0.clusterID != homeCluster?.id })   // home is never a trip label
    }

    @Test("two trips on one day resolve to that day's dominant label")
    func twoTripsOneDay() {
        // A single isolated day holding two cities; the day (and its trip) takes the dominant one.
        let cityA = place("aaa", 41.9, 12.5, offsets: [10], perDay: 3)
        let cityB = place("bbb", 48.86, 2.35, offsets: [10], perDay: 7)   // dominant
        let assets = cityA + cityB
        let clusters = PlaceClustering.clusters(for: assets, minPts: 3, calendar: cal)
        let trips = TripOverlay.trips(assets: assets, clusters: clusters, home: nil, calendar: cal)
        #expect(trips.count == 1)
        #expect(trips[0].days == [key(10)])
        let bCluster = clusters.clusters.first { $0.assetIDs.contains(where: { $0.hasPrefix("bbb") }) }
        #expect(trips[0].clusterID == bCluster?.id)
    }

    @Test("concurrent-location family case: both buckets stay browsable, the run is named by plurality")
    func concurrentLocation() {
        // Partner A abroad (Barcelona) while partner B is home (Helsinki) on the SAME days.
        let home = place("home", 60.17, 24.94, offsets: Array(stride(from: 0, through: 60, by: 2)), perDay: 3)
        let abroad = place("bcn", 41.39, 2.17, offsets: [30, 31, 32], perDay: 8)   // plurality on those days
        let assets = home + abroad

        let (clusters, trips) = pipeline(assets, minPts: 3)
        // Both places exist as browsable buckets.
        #expect(clusters.clusters.contains { $0.assetIDs.contains(where: { $0.hasPrefix("home") }) })
        let bcn = clusters.clusters.first { $0.assetIDs.contains(where: { $0.hasPrefix("bcn") }) }
        #expect(bcn != nil)
        // The mixed run is named by the plurality (Barcelona), not the home minority on those days.
        #expect(trips.contains { $0.clusterID == bcn?.id })
    }

    @Test("a short trip inside a home month still surfaces (the away-from-home rule)")
    func shortTripInHomeMonth() {
        // Home every day of the month; a 2-day trip mid-month must not be out-voted by the home month.
        let home = place("home", 60.17, 24.94, offsets: Array(0..<30), perDay: 3)
        let trip = place("trip", 41.9, 12.5, offsets: [14, 15], perDay: 8)   // plurality on 14,15
        let assets = home + trip
        let (clusters, trips) = pipeline(assets, minPts: 3)
        let tripCluster = clusters.clusters.first { $0.assetIDs.contains(where: { $0.hasPrefix("trip") }) }
        #expect(trips.count == 1)
        #expect(trips[0].clusterID == tripCluster?.id)
        #expect(Set(trips[0].days) == [key(14), key(15)])
    }

    @Test("a trip spanning a merged quiet run overlays it without splitting the day-group")
    func tripSpansMergedQuietRun() {
        // A sparse away city on gapped days (10, 12, 14; the odd days are empty) that DayGrouping folds
        // into ONE quiet day-group (each tiny run folds across the 2-day gaps). Home sits far away in
        // time so no home day breaks the run. The trip (gap tolerance 2) must span all three days as a
        // single trip while the day-group stays merged — the §6 "overlay spans, never cuts" property.
        let home = place("home", 60.17, 24.94, offsets: Array(stride(from: 100, through: 160, by: 2)), perDay: 3)
        let city = place("city", 41.9, 12.5, offsets: [10, 12, 14], perDay: 4)
        let assets = home + city

        let groups = DayGrouping.groups(adaptiveFor: assets, calendar: cal)
        let cityDays: Set<DayKey> = [key(10), key(12), key(14)]
        let cityGroups = groups.filter { !cityDays.isDisjoint(with: Set($0.days)) }
        #expect(cityGroups.count == 1)                               // one merged quiet group
        #expect(cityDays.isSubset(of: Set(cityGroups[0].days)))

        let (_, trips) = pipeline(assets)
        #expect(trips.contains { Set($0.days) == cityDays })         // one trip spans the whole run
    }

    // MARK: Invariant 8 — done survives regrouping (D32(d)/D33 tripwire)

    @Test("applying the trip overlay never perturbs day-groups, doneDays, or Completion.reopening")
    func doneSurvivesOverlay() {
        let seed = PlantedSeed.make(calendar: cal)
        let assets = seed.assets

        // Date-only truth: day-groups, a done set, and a reopening computation over a library change.
        let groupsBefore = DayGrouping.groups(adaptiveFor: assets, calendar: cal)
        let doneDays = Set(groupsBefore.prefix(3).flatMap(\.days))
        // A library change: add a brand-new photo on the earliest (done) day 2025-01-01 → it re-opens.
        let changed = assets + [located("newcomer", 60.17, 24.94, dayOffset: 0)]
        let reopenBefore = Completion.reopening(doneDays: doneDays, from: assets, to: changed, calendar: cal)
        #expect(doneDays.contains(key(0)))          // the earliest day is in the done set
        #expect(!reopenBefore.contains(key(0)))     // and the newcomer re-opened it (reopening works)

        // Apply the overlay (the "regrouping" the tripwire guards against).
        let (clusters, trips) = pipeline(assets)
        let tripMap = TripOverlay.tripIDByDay(trips)
        #expect(!tripMap.isEmpty)                 // the overlay actually annotated something

        // Falsifiable coupling (not just value-identity): the overlay ONLY ever annotates real
        // day-group days, each owned by exactly one group, and a trip never strays outside the
        // day-group partition. A future overlay that re-cut or invented days would fail here.
        let allGroupDays = Set(groupsBefore.flatMap(\.days))
        for day in tripMap.keys {
            #expect(allGroupDays.contains(day))
            #expect(groupsBefore.filter { $0.days.contains(day) }.count == 1)
        }
        for trip in trips {
            #expect(Set(trip.days).isSubset(of: allGroupDays))
        }

        // Every date-world output is byte-identical after the overlay — it is purely additive.
        let groupsAfter = DayGrouping.groups(adaptiveFor: assets, calendar: cal)
        #expect(groupsAfter == groupsBefore)
        #expect(groupsAfter.map(\.assetIDs) == groupsBefore.map(\.assetIDs))   // partition unchanged
        let reopenAfter = Completion.reopening(doneDays: doneDays, from: assets, to: changed, calendar: cal)
        #expect(reopenAfter == reopenBefore)
        // doneDays is an untouched value; the overlay never wrote a parallel done-key.
        #expect(doneDays == Set(groupsBefore.prefix(3).flatMap(\.days)))

        // The overlay's clusters/trips never claim an undated key.
        #expect(!clusters.clusters.contains { $0.assetIDs.contains(where: { seed.undatedNoGPSIDs.contains($0) }) })
        #expect(tripMap[.undated] == nil)
    }

    // MARK: Invariant 10 — precision/recall on the planted seed

    @Test("the chosen eps/minPts/gapTolerance recover the planted trips (precision-first)")
    func precisionRecallOnPlantedSeed() {
        let seed = PlantedSeed.make(calendar: cal)
        let assets = seed.assets

        let clusters = PlaceClustering.clusters(for: assets, calendar: cal)   // adaptive minPts + default eps
        let home = PlaceClustering.homeCluster(clusters.clusters, assets: assets, calendar: cal)
        let trips = TripOverlay.trips(assets: assets, clusters: clusters, home: home, calendar: cal)

        // The multi-city foreign trip splits into ≥3 distinct place clusters (Rome/Florence/Venice)
        // yet forms ONE trip — clusters stay distinct, the run is labeled once (§6).
        let italyClusters = clusters.clusters.filter {
            (40.0...47.0).contains($0.medoid.latitude) && (10.0...14.0).contains($0.medoid.longitude)
        }
        #expect(italyClusters.count >= 3)

        // Match each detected trip to a planted trip by exact day-set; label medoid near the centre.
        let medoidByID = Dictionary(uniqueKeysWithValues: clusters.clusters.map { ($0.id, $0.medoid) })
        func matches(_ trip: Trip, _ planted: PlantedTrip) -> Bool {
            guard Set(trip.days) == Set(planted.days) else { return false }
            guard let medoid = medoidByID[trip.clusterID] else { return false }
            return medoid.distance(to: planted.centre) < 60_000   // within 60 km of the planted place
        }

        let matchedPlanted = seed.groundTruthTrips.filter { planted in trips.contains { matches($0, planted) } }
        let matchedDetected = trips.filter { trip in seed.groundTruthTrips.contains { matches(trip, $0) } }

        let precision = trips.isEmpty ? 0 : Double(matchedDetected.count) / Double(trips.count)
        let recall = Double(matchedPlanted.count) / Double(seed.groundTruthTrips.count)

        // Precision-first (the product goal): no spurious trips, and all planted trips recovered.
        #expect(precision == 1.0)
        #expect(recall == 1.0)
        // Home is never surfaced as a trip.
        #expect(trips.allSatisfy { $0.clusterID != home?.id })
    }
}
