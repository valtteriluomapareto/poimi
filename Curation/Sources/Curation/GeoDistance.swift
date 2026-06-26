//
//  GeoDistance.swift
//  Curation — the great-circle distance between two coordinates (the pure geometry primitive).
//
//  This is the *one* piece of the v1.1 location subsystem
//  ([docs/plans/preprocessing-and-caching.md](../../../docs/plans/preprocessing-and-caching.md) §5.1)
//  that is worth building ahead of the rest, because it is **decision-independent** (every
//  clustering approach — DBSCAN, grid, greedy — needs a correct distance), **drift-proof** (the math
//  doesn't change when the UI / SwiftData / geocoding decisions land), and **subtle enough that the
//  two easy ways to get it wrong are worth pinning with tests today**:
//
//    1. Treating latitude/longitude *degrees* as a flat (Euclidean) plane. A degree of longitude is
//       not a fixed distance — it shrinks with the cosine of latitude. At 60°N (Helsinki) a degree
//       of longitude is only ~half the metres of a degree of latitude, so a degree-space radius is
//       off by ~2×. Great-circle distance has no such error.
//    2. The anti-meridian (±180°). A naïve longitude subtraction puts +179.9° and −179.9° ~360°
//       apart instead of ~0.2°. Haversine handles this *for free* (see below), so no manual
//       wraparound is needed at this layer.
//
//  It is also the metric the plan **mandates** so nobody reaches for `CLLocation.distance(from:)` and
//  breaks the domain boundary (D14/D21): `Curation` must stay free of CoreLocation. Pure, `Sendable`,
//  headless-testable.
//
//  Deliberately NOT here (they arrive with the deferred clustering work, plan §5.2–§5.3, and need a
//  real-coordinate spike to validate *quality*, not just correctness): the clustering algorithm,
//  medoid selection, the equirectangular fast-path (a later optimization for clustering inner loops),
//  and radius/binding predicates. This file is only the correctness anchor those will build on.
//

import Foundation

public extension Coordinate {
    /// Mean Earth radius in metres (IUGG arithmetic mean radius R₁ = (2a + b) / 3 ≈ 6 371 008.8 m).
    /// Great-circle distances below are computed on a sphere of this radius — accurate to the
    /// sub-percent level the ellipsoid's flattening allows, which is far tighter than anything photo
    /// clustering needs.
    static let earthRadiusMeters: Double = 6_371_008.8

    /// The great-circle (shortest-path-over-the-sphere) distance in **metres** from this coordinate
    /// to `other`, via the haversine formula.
    ///
    /// Chosen as the canonical metric because it is:
    ///   - **Globally correct** — no flat-earth error that grows with latitude (see the file note).
    ///   - **Parameter-free** — unlike an equirectangular approximation, there is no reference
    ///     latitude to choose or get wrong; it is correct everywhere from the equator to the poles.
    ///   - **Anti-meridian-safe for free** — the longitude term enters only as `sin²(Δλ / 2)`, and
    ///     `sin²((Δλ ∓ 360°) / 2) == sin²(Δλ / 2)`, so +179° and −179° read as 2° apart, not 358°.
    ///
    /// Properties (pinned by tests): non-negative, symmetric (`a.distance(to: b) == b.distance(to: a)`),
    /// zero iff the coordinates are equal, bounded above by half the Earth's circumference (antipodal
    /// points, ≈ 20 015 km), and satisfies the triangle inequality.
    ///
    /// Expects valid EXIF coordinates (latitude in [−90, 90], longitude in [−180, 180]). `(0, 0)`
    /// is a *valid* coordinate here; whether to treat the "null island" sentinel as no-location is a
    /// caller decision (plan §5.4), not this function's.
    func distance(to other: Coordinate) -> Double {
        let lat1 = latitude.degreesToRadians
        let lat2 = other.latitude.degreesToRadians
        let deltaLat = (other.latitude - latitude).degreesToRadians
        let deltaLon = (other.longitude - longitude).degreesToRadians

        // Haversine: a = sin²(Δφ/2) + cos φ₁ · cos φ₂ · sin²(Δλ/2);  d = 2R · atan2(√a, √(1−a)).
        // The atan2 form is numerically stable across the whole range (including antipodal points,
        // where the alternative `asin(√a)` loses precision as a → 1).
        let sinHalfLat = sin(deltaLat / 2)
        let sinHalfLon = sin(deltaLon / 2)
        let a = sinHalfLat * sinHalfLat + cos(lat1) * cos(lat2) * sinHalfLon * sinHalfLon
        // For near-antipodal points `a` can round fractionally above 1; clamp so `√(1−a)` can't
        // become NaN (which would poison the distance). `a` is never negative for valid latitudes.
        let c = 2 * atan2(sqrt(a), sqrt(max(0, 1 - a)))
        return Coordinate.earthRadiusMeters * c
    }
}

private extension Double {
    /// Degrees → radians. Local + private so the domain stays dependency-light and the conversion
    /// lives next to its only use.
    var degreesToRadians: Double { self * .pi / 180 }
}
