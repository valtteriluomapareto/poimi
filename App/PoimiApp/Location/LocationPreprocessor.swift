//
//  LocationPreprocessor.swift
//  PoimiApp — the location naming pass + its name cache (issue #130, preprocessing §7–§9).
//
//  Orchestrates the ONE expensive, network-bound step of the location feature: turning each trip's
//  place into a name. Everything else (clustering, trips) is cheap+pure and stays live. It runs off the
//  main actor (its own actor), calls the serial `PlaceNaming` seam, and persists each name as it
//  resolves (partial progress) through a `@ModelActor` cache so a cancelled/throttled pass never
//  re-burns the geocode budget. Only VALUES cross the actor boundary — a `@Model` is never held or
//  written from the preprocessor actor (§9, the SwiftData `PersistentIdentifier` SIGTRAP trap); the
//  `@ModelActor` owns its own context.
//

import Foundation
import SwiftData
import Curation

/// Rounds a coordinate to a cache CELL — a place, not an exact point (§8; the plan-review fix against
/// churn-prone exact-medoid keys). See `GeocodedPlaceName` for why cell-keying is correct for a
/// per-place cache (and subsumes the D18 per-asset modification-date key).
enum GeocodeCell {
    /// Decimal places to round to. 3 dp ≈ 111 m at the equator (finer toward the poles) — small enough
    /// that distinct places don't collide, coarse enough that a medoid shifting a few metres stays put.
    static let precision = 3

    static func key(for coordinate: Coordinate) -> String {
        let factor = pow(10.0, Double(precision))
        let lat = (coordinate.latitude * factor).rounded() / factor
        let lon = (coordinate.longitude * factor).rounded() / factor
        return String(format: "%.\(precision)f,%.\(precision)f", lat, lon)
    }
}

/// A `@ModelActor` owning the SwiftData reads/writes for the name cache — off the main actor, returning
/// only values (never `@Model`s across the boundary, §9). Fetch-or-create on write (no `.unique`
/// constraint — SIGTRAP).
@ModelActor
actor NameCacheStore {
    /// ALL cached names as a cell→name dict, in ONE fetch. The naming pass loads this once and looks up
    /// in memory — a per-place fetch cost ~0.5 s per SwiftData round-trip on device, so 12 of them was
    /// ~6 s (the "slow cache"). One fetch of the whole small table is a single round-trip.
    func allNames() -> [String: String] {
        let rows = (try? modelContext.fetch(FetchDescriptor<GeocodedPlaceName>())) ?? []
        return Dictionary(rows.map { ($0.cellKey, $0.name) }, uniquingKeysWith: { first, _ in first })
    }

    /// Insert freshly-geocoded cell→name rows in ONE save (skipping cells already present). No `.unique`
    /// constraint (SIGTRAP), so the existing-set check keeps it idempotent.
    func store(_ entries: [(cell: String, name: String)], at date: Date) {
        guard !entries.isEmpty else { return }
        let existing = Set(((try? modelContext.fetch(FetchDescriptor<GeocodedPlaceName>())) ?? []).map(\.cellKey))
        for entry in entries where !existing.contains(entry.cell) {
            modelContext.insert(GeocodedPlaceName(cellKey: entry.cell, name: entry.name, fetchedAt: date))
        }
        do {
            try modelContext.save()
        } catch {
            // A silent `try?` here would look exactly like "the cache never persists" — log it instead.
            Log.location.error("Name-cache save failed: \(String(describing: error))")
        }
    }

    /// Total cached rows — a diagnostic: 0 right after a geocoding pass ⇒ saves aren't persisting.
    func count() -> Int { (try? modelContext.fetchCount(FetchDescriptor<GeocodedPlaceName>())) ?? -1 }
}

/// Orchestrates the naming pass (§7): cluster + trips (pure) → for each trip's plurality place, resolve
/// a name via cache → geocode → cache, returning `clusterID → name`. Its own actor; the geocoder and
/// the SwiftData writes stay off the main actor. Run lazily on first location-view open (P3); one pass
/// at a time (callers serialise — Phase 3's lazy trigger).
actor LocationPreprocessor {
    private let naming: any PlaceNaming
    private let cache: NameCacheStore
    private let now: @Sendable () -> Date
    /// Diagnostics for the last `resolveTripNames` — cache hits vs fresh geocodes (a healthy cache is
    /// mostly hits on repeat opens).
    private(set) var lastCacheHits = 0
    private(set) var lastGeocoded = 0

    init(naming: any PlaceNaming, cache: NameCacheStore, now: @escaping @Sendable () -> Date = Date.init) {
        self.naming = naming
        self.cache = cache
        self.now = now
    }

    /// Standalone entry (tests / a caller without a precomputed timeline): cluster the assets, then name
    /// the trip places. The production path uses `resolveNames(forPlaces:)` with the timeline's already-
    /// computed trip clusters, so an album-open never clusters twice (the double-clustering fix).
    func resolveTripNames(
        for assets: [AssetRef],
        eps: Double = PlaceClustering.defaultEps,
        minPts: Int? = nil,
        gapToleranceDays: Int = TripOverlay.defaultGapToleranceDays,
        calendar: Calendar = .current
    ) async -> [String: String] {
        let placeClusters = PlaceClustering.clusters(for: assets, eps: eps, minPts: minPts, calendar: calendar)
        let home = PlaceClustering.homeCluster(placeClusters.clusters, assets: assets, calendar: calendar)
        let trips = TripOverlay.trips(assets: assets, clusters: placeClusters, home: home,
                                      gapToleranceDays: gapToleranceDays, calendar: calendar)
        let clusterByID = Dictionary(placeClusters.clusters.map { ($0.id, $0) },
                                     uniquingKeysWith: { first, _ in first })
        let places = Set(trips.map(\.clusterID)).sorted().compactMap { id -> (clusterID: String, medoid: Coordinate)? in
            clusterByID[id].map { (id, $0.medoid) }
        }
        return await resolveNames(forPlaces: places)
    }

    /// Name a PRECOMPUTED set of trip places (`clusterID` + medoid coordinate) — NO clustering. Loads the
    /// whole (small) cache in ONE fetch, looks up in memory, geocodes only misses (serially), and batches
    /// the save. Returns `clusterID → name` for the places that resolved (a failure / valid-unnamed omits
    /// that place; it's retried on a later pass). This is the production path (`CandidateStore` hands over
    /// the timeline's trip clusters), so an album-open never re-clusters just to name.
    func resolveNames(forPlaces places: [(clusterID: String, medoid: Coordinate)]) async -> [String: String] {
        lastCacheHits = 0
        lastGeocoded = 0
        var seenCluster = Set<String>()                        // one place per cluster id (dedupe trips)
        let cachedByCell = await cache.allNames()              // ONE fetch; look up in memory
        var namesByClusterID: [String: String] = [:]
        var freshByCell: [String: String] = [:]                // within-pass reuse for co-located places
        var freshlyGeocoded: [(cell: String, name: String)] = []
        for place in places where seenCluster.insert(place.clusterID).inserted {
            let cell = GeocodeCell.key(for: place.medoid)
            if let cached = cachedByCell[cell] {
                lastCacheHits += 1
                namesByClusterID[place.clusterID] = cached
                continue
            }
            if let fresh = freshByCell[cell] {                 // already geocoded this cell this pass
                namesByClusterID[place.clusterID] = fresh
                continue
            }
            do {
                if let name = try await naming.name(for: place.medoid) {
                    lastGeocoded += 1
                    namesByClusterID[place.clusterID] = name
                    freshByCell[cell] = name
                    freshlyGeocoded.append((cell, name))
                }
                // A `nil` name is a valid "unnamed" place — leave it unresolved (don't cache "").
            } catch {
                // Partial-failure by nature (§7): skip this place; it stays unnamed and is retried on a
                // later pass. One failure never fails the whole pass.
                Log.location.notice(
                    "Reverse-geocode failed (\(place.clusterID, privacy: .public)): \(String(describing: error))")
            }
        }
        await cache.store(freshlyGeocoded, at: now())   // one save for all new names (cache-hit pass → none)
        return namesByClusterID
    }
}
