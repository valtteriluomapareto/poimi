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
    /// The cached name for a cell, or `nil` on a miss.
    func cachedName(forCell cell: String) -> String? {
        var descriptor = FetchDescriptor<GeocodedPlaceName>(predicate: #Predicate { $0.cellKey == cell })
        descriptor.fetchLimit = 1
        return (try? modelContext.fetch(descriptor))?.first?.name
    }

    /// Store (or refresh) a cell's name.
    func store(name: String, forCell cell: String, at date: Date) {
        var descriptor = FetchDescriptor<GeocodedPlaceName>(predicate: #Predicate { $0.cellKey == cell })
        descriptor.fetchLimit = 1
        if let existing = (try? modelContext.fetch(descriptor))?.first {
            existing.name = name
            existing.fetchedAt = date
        } else {
            modelContext.insert(GeocodedPlaceName(cellKey: cell, name: name, fetchedAt: date))
        }
        do {
            try modelContext.save()
        } catch {
            // A silent `try?` here would look exactly like "the cache never persists" — log it instead.
            Log.location.error("Name-cache save failed (\(cell, privacy: .public)): \(String(describing: error))")
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

    /// Resolve names for the album's trip places. Returns `clusterID → name` for the places that
    /// resolved; a geocode failure or a valid "unnamed" result simply omits that cluster (it still
    /// exists — retried on a later pass). Persists each name as it resolves (partial progress). One
    /// `calendar` threads through every pure sub-step so the day keys line up.
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
        // Distinct places that name a trip (the same place can name several trips — geocode it once).
        let tripClusterIDs = Set(trips.map(\.clusterID)).sorted()   // sorted → deterministic order

        lastCacheHits = 0
        lastGeocoded = 0
        var namesByClusterID: [String: String] = [:]
        for clusterID in tripClusterIDs {
            guard let cluster = clusterByID[clusterID] else { continue }
            let cell = GeocodeCell.key(for: cluster.medoid)

            if let cached = await cache.cachedName(forCell: cell) {
                lastCacheHits += 1
                namesByClusterID[clusterID] = cached
                continue
            }
            do {
                if let name = try await naming.name(for: cluster.medoid) {
                    lastGeocoded += 1
                    await cache.store(name: name, forCell: cell, at: now())
                    namesByClusterID[clusterID] = name
                }
                // A `nil` name is a valid "unnamed" place — leave it unresolved (don't cache "").
            } catch {
                // Partial-failure by nature (§7): skip this place; it stays unnamed and is retried on a
                // later pass. One failure never fails the whole pass.
                Log.location.notice(
                    "Reverse-geocode failed for place \(clusterID, privacy: .public): \(String(describing: error))")
            }
        }
        return namesByClusterID
    }
}
