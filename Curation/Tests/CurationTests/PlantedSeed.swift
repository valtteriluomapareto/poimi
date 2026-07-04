//
//  PlantedSeed.swift
//  CurationTests — a synthetic planted-trip fixture with declared ground truth (issue #131, scope 1).
//
//  A pure `[AssetRef]` coordinate field where the trips are *planted*, so tests can assert exact
//  precision/recall instead of eyeballing. Covers the cases the design review flagged: a dense **home
//  base** present across most days, a **multi-city foreign trip** (Rome/Florence/Venice, ~200 km
//  apart → three place clusters but one contiguous trip), a **weekend city trip** (Stockholm), the
//  **concurrent-location family case** (Barcelona on the same days as home photos), **fly-home-
//  between-two-trips** (Paris → one home day → London), an **antimeridian** cluster straddling ±180°
//  (Fiji), **null-island `(0,0)`**, **dated-but-no-GPS**, and **undated + no-GPS**.
//
//  Determinism: all jitter comes from `SeededRNG` (no `Date.now`/`Math.random`); a fixed seed yields
//  a fixed field. Coordinates are real cities so the distances are realistic, but nothing depends on
//  the exact values — only on the planted structure recorded in `groundTruthTrips`.
//

import Foundation
@testable import Curation

/// A planted ground-truth trip: a contiguous away-from-home run at a known place, over known days.
struct PlantedTrip {
    let name: String
    /// Approximate place centre — the detected trip's label cluster medoid should sit near here.
    let centre: Coordinate
    /// The exact away days (as `DayKey`s) this trip spans.
    let days: [DayKey]
}

/// The whole synthetic field plus its declared ground truth.
struct PlantedSeed {
    let assets: [AssetRef]
    let groundTruthTrips: [PlantedTrip]
    let homeCentre: Coordinate
    let nullIslandIDs: Set<String>
    let datedNoGPSIDs: Set<String>
    let undatedNoGPSIDs: Set<String>
    /// The set of every id that must land in the no-location bucket.
    var expectedNoLocationIDs: Set<String> {
        nullIslandIDs.union(datedNoGPSIDs).union(undatedNoGPSIDs)
    }

    // Real-city anchors (lat, lon).
    static let helsinki = Coordinate(latitude: 60.17, longitude: 24.94)
    static let stockholm = Coordinate(latitude: 59.33, longitude: 18.07)
    static let rome = Coordinate(latitude: 41.90, longitude: 12.50)
    static let florence = Coordinate(latitude: 43.77, longitude: 11.26)
    static let venice = Coordinate(latitude: 45.44, longitude: 12.33)
    static let paris = Coordinate(latitude: 48.86, longitude: 2.35)
    static let london = Coordinate(latitude: 51.51, longitude: -0.13)
    static let barcelona = Coordinate(latitude: 41.39, longitude: 2.17)
    /// Fiji, straddling the ±180° antimeridian — points are placed on BOTH sides of the date line.
    static let fiji = Coordinate(latitude: -17.0, longitude: 180.0)

    /// Build the field. `calendar` projects day-offsets (from 2025-01-01) to real dates.
    static func make(seed: UInt64 = 0x50A1, calendar: Calendar) -> PlantedSeed {
        var rng = SeededRNG(seed: seed)
        let base = calendar.date(from: DateComponents(year: 2025, month: 1, day: 1))!

        func date(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: base)! }
        func key(_ offset: Int) -> DayKey { DayKey(date: date(offset), calendar: calendar) }

        // Jittered located photos: `perDay` photos on each offset, within ~±`jitter`° of `centre`.
        func place(_ prefix: String, _ centre: Coordinate, offsets: [Int], perDay: Int,
                   jitter: Double = 0.02) -> [AssetRef] {
            var out: [AssetRef] = []
            for offset in offsets {
                for shot in 0..<perDay {
                    let lat = centre.latitude + Double.random(in: -jitter...jitter, using: &rng)
                    let lon = centre.longitude + Double.random(in: -jitter...jitter, using: &rng)
                    out.append(AssetRef(id: "\(prefix)-\(offset)-\(shot)",
                                        captureDate: date(offset),
                                        coordinate: Coordinate(latitude: lat, longitude: lon)))
                }
            }
            return out
        }

        // Trip day windows (offsets from Jan 1). Kept clear of one another; Barcelona deliberately
        // overlaps the home days (concurrent-location case). The fly-home day (123) is a HOME day
        // wedged between Paris (120–122) and London (124–126) so the run breaks into two trips.
        let stockholmDays = [60, 61]
        let italyDays = [90, 91, 92, 93, 94, 95]            // Rome 90–92, Florence 93–94, Venice 95
        let parisDays = [120, 121, 122]
        let londonDays = [124, 125, 126]
        let fijiDays = [150, 151, 152]
        let barcelonaDays = [180, 182, 184]                 // even → also home days (concurrent)
        let flyHomeDay = 123

        // Home base: photos on most even offsets across the year, EXCEPT trip windows (so a trip day
        // has no competing home photos — apart from the concurrent Barcelona days, which stay home).
        let tripWindow = Set(stockholmDays + italyDays + parisDays + londonDays + fijiDays)
        var homeDays = stride(from: 0, through: 300, by: 2).filter { !tripWindow.contains($0) }
        homeDays.append(flyHomeDay)                         // the fly-home day is a home day

        var assets: [AssetRef] = []
        assets += place("home", helsinki, offsets: homeDays, perDay: 3, jitter: 0.03)
        assets += place("sto", stockholm, offsets: stockholmDays, perDay: 8)
        assets += place("rom", rome, offsets: [90, 91, 92], perDay: 7)
        assets += place("flo", florence, offsets: [93, 94], perDay: 6)
        assets += place("ven", venice, offsets: [95], perDay: 6)
        assets += place("par", paris, offsets: parisDays, perDay: 7)
        assets += place("lon", london, offsets: londonDays, perDay: 7)
        assets += place("bcn", barcelona, offsets: barcelonaDays, perDay: 8)

        // Antimeridian: 16 Fiji photos, half at +179.9x and half at −179.9x — genuinely across ±180°.
        var fijiAssets: [AssetRef] = []
        for offset in fijiDays {
            for shot in 0..<6 {
                let east = shot % 2 == 0
                let lon = (east ? 179.93 : -179.93) + Double.random(in: -0.02...0.02, using: &rng)
                let lat = fiji.latitude + Double.random(in: -0.02...0.02, using: &rng)
                fijiAssets.append(AssetRef(id: "fij-\(offset)-\(shot)",
                                           captureDate: date(offset),
                                           coordinate: Coordinate(latitude: lat, longitude: lon)))
            }
        }
        assets += fijiAssets

        // Null-island `(0,0)`, dated-but-no-GPS, and undated+no-GPS edge assets → all no-location.
        var nullIsland: Set<String> = []
        for i in 0..<8 {
            let id = "null-\(i)"
            nullIsland.insert(id)
            assets.append(AssetRef(id: id, captureDate: date(40 + i % 2),
                                   coordinate: Coordinate(latitude: 0, longitude: 0)))
        }
        var datedNoGPS: Set<String> = []
        for i in 0..<5 {
            let id = "nogps-\(i)"
            datedNoGPS.insert(id)
            assets.append(AssetRef(id: id, captureDate: date(45 + i % 2), coordinate: nil))
        }
        var undatedNoGPS: Set<String> = []
        for i in 0..<4 {
            let id = "undated-\(i)"
            undatedNoGPS.insert(id)
            assets.append(AssetRef(id: id, captureDate: nil, coordinate: nil))
        }

        let trips = [
            PlantedTrip(name: "Stockholm", centre: stockholm, days: stockholmDays.map(key)),
            PlantedTrip(name: "Italy (Rome/Florence/Venice)", centre: rome, days: italyDays.map(key)),
            PlantedTrip(name: "Paris", centre: paris, days: parisDays.map(key)),
            PlantedTrip(name: "London", centre: london, days: londonDays.map(key)),
            PlantedTrip(name: "Fiji (antimeridian)", centre: fiji, days: fijiDays.map(key)),
            PlantedTrip(name: "Barcelona (concurrent)", centre: barcelona, days: barcelonaDays.map(key)),
        ]

        return PlantedSeed(assets: assets.shuffled(using: &rng),
                           groundTruthTrips: trips,
                           homeCentre: helsinki,
                           nullIslandIDs: nullIsland,
                           datedNoGPSIDs: datedNoGPS,
                           undatedNoGPSIDs: undatedNoGPS)
    }
}
