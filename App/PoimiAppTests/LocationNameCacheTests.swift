//
//  LocationNameCacheTests.swift
//  PoimiAppTests — the location naming pass + the D18 name cache (issue #130, preprocessing §10).
//
//  Integration tier: the real `LocationPreprocessor` + `NameCacheStore` (a `@ModelActor` on an
//  in-memory v2 container) against a deterministic offline `FakePlaceNaming` with error injection.
//  Pins: geocode-once-then-cache, home-never-geocoded, partial-failure isolation, unnamed-not-cached,
//  cache persistence across preprocessor instances, and the cell-key contract.
//

import Testing
import Foundation
import SwiftData
import Curation
@testable import PoimiApp

@Suite("LocationPreprocessor — naming pass + name cache")
struct LocationNameCacheTests {
    private let cal = utcCalendar()
    private let base = utcCalendar().date(from: DateComponents(year: 2025, month: 1, day: 1))!

    private func date(_ offset: Int) -> Date { cal.date(byAdding: .day, value: offset, to: base)! }
    private func located(_ id: String, _ lat: Double, _ lon: Double, dayOffset: Int) -> AssetRef {
        AssetRef(id: id, captureDate: date(dayOffset), coordinate: Coordinate(latitude: lat, longitude: lon))
    }
    private func place(_ prefix: String, _ lat: Double, _ lon: Double, offsets: [Int], perDay: Int) -> [AssetRef] {
        offsets.flatMap { offset in
            (0..<perDay).map { located("\(prefix)-\(offset)-\($0)", lat, lon, dayOffset: offset) }
        }
    }

    private static let helsinki = (lat: 60.17, lon: 24.94)   // home
    private static let aland = (lat: 60.10, lon: 19.90)      // away trip A
    private static let rome = (lat: 41.90, lon: 12.50)       // away trip B

    /// Home spanning many days + two disjoint away trips → two trip places.
    private func homePlusTwoTrips() -> [AssetRef] {
        place("home", Self.helsinki.lat, Self.helsinki.lon, offsets: Array(0..<40), perDay: 3)
            + place("aland", Self.aland.lat, Self.aland.lon, offsets: [10, 11], perDay: 20)
            + place("rome", Self.rome.lat, Self.rome.lon, offsets: [20, 21], perDay: 20)
    }

    private func makeCache() throws -> NameCacheStore {
        NameCacheStore(modelContainer: try AppModelContainer.make(inMemory: true))
    }

    // MARK: — geocode once, then serve from cache

    @Test("each trip place is geocoded once; a second pass is served entirely from cache")
    func geocodesOnceThenCaches() async throws {
        let assets = homePlusTwoTrips()
        let alandCell = GeocodeCell.key(for: Coordinate(latitude: Self.aland.lat, longitude: Self.aland.lon))
        let romeCell = GeocodeCell.key(for: Coordinate(latitude: Self.rome.lat, longitude: Self.rome.lon))
        let fake = FakePlaceNaming(names: [alandCell: "Åland", romeCell: "Rome"])
        let pre = LocationPreprocessor(naming: fake, cache: try makeCache())

        let first = await pre.resolveTripNames(for: assets, minPts: 3, calendar: cal)
        #expect(first.count == 2)                                    // both trip places named
        #expect(await fake.callCount == 2)                           // geocoded exactly twice
        #expect(Set(first.values) == ["Åland", "Rome"])

        let second = await pre.resolveTripNames(for: assets, minPts: 3, calendar: cal)
        #expect(second == first)                                     // identical result
        #expect(await fake.callCount == 2)                           // no new geocodes — all cache hits
    }

    @Test("two trip places in the same geocode cell are geocoded once within a pass (freshByCell reuse)")
    func coLocatedPlacesGeocodeOnce() async throws {
        // `resolveNames(forPlaces:)` dedups by CELL within a single fresh pass: two distinct trip
        // clusters whose medoids round to the same `GeocodeCell` trigger exactly one geocode, both
        // resolving to that name — even before anything is persisted.
        let coordA = Coordinate(latitude: 60.1701, longitude: 24.9402)
        let coordB = Coordinate(latitude: 60.1699, longitude: 24.9398)   // ~metres away → same cell
        #expect(GeocodeCell.key(for: coordA) == GeocodeCell.key(for: coordB))
        let fake = FakePlaceNaming(names: [GeocodeCell.key(for: coordA): "Helsinki"])
        let pre = LocationPreprocessor(naming: fake, cache: try makeCache())

        let names = await pre.resolveNames(forPlaces: [(clusterID: "c1", medoid: coordA),
                                                       (clusterID: "c2", medoid: coordB)])
        #expect(names == ["c1": "Helsinki", "c2": "Helsinki"])
        #expect(await fake.callCount == 1)                           // one geocode, reused within the pass
    }

    // MARK: — home is never a trip, so never geocoded

    @Test("a home-only album yields no trips and geocodes nothing")
    func homeIsNeverGeocoded() async throws {
        let assets = place("home", Self.helsinki.lat, Self.helsinki.lon, offsets: Array(0..<40), perDay: 3)
        let fake = FakePlaceNaming()
        let pre = LocationPreprocessor(naming: fake, cache: try makeCache())

        let names = await pre.resolveTripNames(for: assets, minPts: 3, calendar: cal)
        #expect(names.isEmpty)
        #expect(await fake.callCount == 0)
    }

    // MARK: — partial failure is isolated

    @Test("a geocode failure leaves that place unnamed but others still resolve")
    func failureIsolatesToOnePlace() async throws {
        let romeCell = GeocodeCell.key(for: Coordinate(latitude: Self.rome.lat, longitude: Self.rome.lon))
        let alandCell = GeocodeCell.key(for: Coordinate(latitude: Self.aland.lat, longitude: Self.aland.lon))
        let fake = FakePlaceNaming(names: [alandCell: "Åland"], errors: [romeCell: .rateLimited])
        let pre = LocationPreprocessor(naming: fake, cache: try makeCache())

        let names = await pre.resolveTripNames(for: homePlusTwoTrips(), minPts: 3, calendar: cal)
        #expect(names.count == 1)                                    // rome failed, aland resolved
        #expect(names.values.contains("Åland"))
        #expect(!names.values.contains("Rome"))                      // rome errored → stays unnamed
    }

    @Test("a failed place is NOT cached — a later pass retries it")
    func failedPlaceIsRetried() async throws {
        let romeCell = GeocodeCell.key(for: Coordinate(latitude: Self.rome.lat, longitude: Self.rome.lon))
        let fake = FakePlaceNaming(errors: [romeCell: .network])
        let pre = LocationPreprocessor(naming: fake, cache: try makeCache())

        _ = await pre.resolveTripNames(for: homePlusTwoTrips(), minPts: 3, calendar: cal)
        _ = await pre.resolveTripNames(for: homePlusTwoTrips(), minPts: 3, calendar: cal)
        #expect(await fake.callsByCell[romeCell] == 2)               // retried (never cached), not 1
    }

    // MARK: — a valid "unnamed" result is not cached as a name

    @Test("a nil (unnamed) result leaves the place unresolved and is not cached")
    func unnamedIsNotCached() async throws {
        let alandCell = GeocodeCell.key(for: Coordinate(latitude: Self.aland.lat, longitude: Self.aland.lon))
        let fake = FakePlaceNaming(unnamed: [alandCell])
        let pre = LocationPreprocessor(naming: fake, cache: try makeCache())

        let names = await pre.resolveTripNames(for: homePlusTwoTrips(), minPts: 3, calendar: cal)
        #expect(!names.values.contains { $0.contains(alandCell) })   // aland unresolved
        // A second pass re-attempts aland (nil was not cached as a name).
        _ = await pre.resolveTripNames(for: homePlusTwoTrips(), minPts: 3, calendar: cal)
        #expect(await fake.callsByCell[alandCell] == 2)
    }

    // MARK: — the cache is durable across preprocessor instances

    @Test("the name cache persists across preprocessor instances (durable, app-wide)")
    func cachePersistsAcrossInstances() async throws {
        let container = try AppModelContainer.make(inMemory: true)
        let assets = homePlusTwoTrips()

        let warm = LocationPreprocessor(naming: FakePlaceNaming(), cache: NameCacheStore(modelContainer: container))
        let firstNames = await warm.resolveTripNames(for: assets, minPts: 3, calendar: cal)

        // A brand-new preprocessor + a fresh geocoder, but the SAME container → all cache hits.
        let coldFake = FakePlaceNaming()
        let cold = LocationPreprocessor(naming: coldFake, cache: NameCacheStore(modelContainer: container))
        let secondNames = await cold.resolveTripNames(for: assets, minPts: 3, calendar: cal)

        #expect(secondNames == firstNames)
        #expect(await coldFake.callCount == 0)                       // nothing re-geocoded
    }

    // MARK: — the cell key contract

    @Test("GeocodeCell keys nearby points together and distant points apart")
    func geocodeCellKey() {
        let a = GeocodeCell.key(for: Coordinate(latitude: 60.1701, longitude: 24.9402))
        let b = GeocodeCell.key(for: Coordinate(latitude: 60.1699, longitude: 24.9398))   // ~a few metres
        let far = GeocodeCell.key(for: Coordinate(latitude: 41.90, longitude: 12.50))
        #expect(a == b)                                              // same cell → one geocode
        #expect(a != far)
        #expect(a == "60.170,24.940")                               // stable, documented format
    }
}

@Suite("TripLabel — the location sentence")
struct TripLabelTests {
    @Test("each shape composes its designed phrasing (the signed-off wording)")
    func phrasing() {
        #expect(TripLabel.sentence(for: .visit, place: "Pori") == "Visit to Pori")
        #expect(TripLabel.sentence(for: .weekend, place: "Åland") == "Weekend in Åland")
        #expect(TripLabel.sentence(for: .shortTrip, place: "Oulu") == "Short trip to Oulu")
        #expect(TripLabel.sentence(for: .week, place: "Äkäslompolo") == "Week in Äkäslompolo")
        #expect(TripLabel.sentence(for: .longer(days: 12), place: "Italy") == "12 days in Italy")
    }
}
