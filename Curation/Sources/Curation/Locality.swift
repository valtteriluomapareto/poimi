//
//  Locality.swift
//  Curation — a day-cluster's home/away "shape" (issue #201, level A).
//
//  Everyday (non-trip) day-clusters read as a bare date; trips already carry a place sentence ("Week in
//  Salo"). This distils a cheap, deterministic locality for the everyday days — "Mostly at home" / "Out
//  and about" — from data the location subsystem (#129/#130) ALREADY computes on every scan: the home
//  place cluster + which assets have no usable GPS. Pure set-math, no geocoding, no new permission (D7,
//  EXIF only). String-free (D14/D21): the domain classifies; the app tier phrases + localizes it, the
//  same `TripShape → TripLabel` pattern.
//
//  The real caveat (§201): home/indoor photos often have NO EXIF GPS — so a naive read under-detects
//  home. The classifier gates on COVERAGE: below a located-fraction floor it returns `.unknown` and the
//  caption falls back to the media highlights, rather than guess. A soft label, not a claim.
//

import Foundation

public enum Locality: String, Sendable, Equatable, Codable {
    /// Enough located photos, and most were at the home place cluster.
    case mostlyHome
    /// Enough located photos, and most were away from home (unnamed under level A).
    case mostlyAway
    /// Located, but split between home and away — no confident single label.
    case mixed
    /// Too few located photos to say (patchy GPS) — the caller falls back to the media caption.
    case unknown

    /// Classify a cluster's locality from its member ids vs the home cluster + the no-location bucket
    /// (both from `PlaceClustering`). Pure; deterministic; no distance math (membership only).
    ///
    /// - `homeAssetIDs`: the home place cluster's members (`PlaceClustering.homeCluster`).
    /// - `noLocationIDs`: assets with no PLACE — missing/null-island GPS **and** DBSCAN noise (a real
    ///   coordinate that didn't join any cluster). So "located" here means *in a place cluster*.
    /// - `coverageFloor`: minimum fraction of the cluster that must be located (clustered) to assert
    ///   anything, else `.unknown`. This gates not only missing-EXIF days but also a day of scattered
    ///   single-GPS errands (each shot its own noise point) — conservative by design ("don't guess").
    /// - `homeThreshold`: located-at-home fraction at/above which the day reads `.mostlyHome`; at/below
    ///   `1 - homeThreshold` it reads `.mostlyAway`; between, `.mixed`.
    public static func of(
        clusterAssetIDs: [String],
        homeAssetIDs: Set<String>,
        noLocationIDs: Set<String>,
        coverageFloor: Double = 0.35,
        homeThreshold: Double = 0.6
    ) -> Locality {
        guard !clusterAssetIDs.isEmpty else { return .unknown }
        let locatedCount = clusterAssetIDs.reduce(into: 0) { if !noLocationIDs.contains($1) { $0 += 1 } }
        guard locatedCount > 0,
              Double(locatedCount) / Double(clusterAssetIDs.count) >= coverageFloor else { return .unknown }
        let homeCount = clusterAssetIDs.reduce(into: 0) { if homeAssetIDs.contains($1) { $0 += 1 } }
        let homeFraction = Double(homeCount) / Double(locatedCount)
        if homeFraction >= homeThreshold { return .mostlyHome }
        if homeFraction <= 1 - homeThreshold { return .mostlyAway }
        return .mixed
    }
}
