//
//  GeoDistanceTests.swift
//  CurationTests — the great-circle distance primitive (plan: preprocessing-and-caching §5.1).
//
//  Concrete cases pin the two bugs the haversine choice exists to avoid — latitude-dependent
//  longitude scaling (the flat-degrees error) and the anti-meridian — plus the obvious anchors
//  (1° ≈ 111 km, identity, antipodal). The property suite then explores the input space for the
//  metric axioms (non-negativity, symmetry, the half-circumference bound, the triangle inequality),
//  seeded per case so failures are reproducible (the D24 idiom from PropertyTests).
//

import Testing
import Foundation
@testable import Curation

@Suite("GeoDistance — great-circle metric")
struct GeoDistanceTests {

    /// One degree of latitude (a meridian is a great circle) ≈ 111.19 km on the mean-radius sphere.
    private static let oneDegreeMeters = Coordinate.earthRadiusMeters * .pi / 180   // ≈ 111_195 m

    private func expect(_ value: Double, near target: Double, within tolerance: Double,
                        _ comment: Comment) {
        #expect(abs(value - target) < tolerance, comment)
    }

    @Test("identical coordinates are exactly zero apart")
    func identityIsZero() {
        let p = Coordinate(latitude: 45, longitude: 45)
        #expect(p.distance(to: p) == 0)
    }

    @Test("one degree of latitude is ~111.19 km (the great-circle anchor)")
    func oneDegreeLatitude() {
        let d = Coordinate(latitude: 0, longitude: 0).distance(to: Coordinate(latitude: 1, longitude: 0))
        expect(d, near: Self.oneDegreeMeters, within: 1, "1° latitude")
    }

    @Test("one degree of longitude at the equator equals one degree of latitude")
    func oneDegreeLongitudeAtEquator() {
        let d = Coordinate(latitude: 0, longitude: 0).distance(to: Coordinate(latitude: 0, longitude: 1))
        expect(d, near: Self.oneDegreeMeters, within: 1, "1° longitude at equator")
    }

    @Test("a degree of longitude SHRINKS with latitude — ~cos(60°)=½ at 60°N (the flat-degrees bug)")
    func longitudeScalesWithLatitude() {
        // This is the case naive Euclidean-on-degrees gets wrong: it would report the same distance
        // as at the equator. Great-circle distance must be ~half (cos 60° = 0.5).
        let atSixty = Coordinate(latitude: 60, longitude: 0).distance(to: Coordinate(latitude: 60, longitude: 1))
        expect(atSixty, near: Self.oneDegreeMeters * cos(60 * .pi / 180), within: 50, "1° lon at 60°N")
        // And unmistakably shorter than at the equator (~half), not equal.
        let atEquator = Coordinate(latitude: 0, longitude: 0).distance(to: Coordinate(latitude: 0, longitude: 1))
        #expect(atSixty < atEquator * 0.55)
        #expect(atSixty > atEquator * 0.45)
    }

    @Test("the anti-meridian is handled: ±179.5° read as ~1° apart, not ~359°")
    func antiMeridianIsClose() {
        let d = Coordinate(latitude: 0, longitude: 179.5)
            .distance(to: Coordinate(latitude: 0, longitude: -179.5))
        // True separation across the date line is 1°; a naive longitude subtraction would give 359°
        // (~39 900 km). Assert it's the small value.
        expect(d, near: Self.oneDegreeMeters, within: 5, "±179.5° across the date line")
        #expect(d < 200_000)   // nowhere near the naive 359° result
    }

    @Test("antipodal points are half the Earth's circumference apart (the upper bound)")
    func antipodalIsMaxDistance() {
        let half = Coordinate.earthRadiusMeters * .pi   // ≈ 20 015 km
        let d = Coordinate(latitude: 0, longitude: 0).distance(to: Coordinate(latitude: 0, longitude: 180))
        expect(d, near: half, within: 1, "antipodal")
    }

    // MARK: Properties (seeded, reproducible — D24)

    private func randomCoordinate(_ rng: inout SeededRNG64) -> Coordinate {
        Coordinate(latitude: Double.random(in: -90...90, using: &rng),
                   longitude: Double.random(in: -180...180, using: &rng))
    }

    @Test("distance is non-negative, symmetric, and within the half-circumference bound",
          arguments: 0..<300)
    func metricAxioms(seed: Int) {
        var rng = SeededRNG64(seed: UInt64(seed))
        let a = randomCoordinate(&rng)
        let b = randomCoordinate(&rng)
        let ab = a.distance(to: b)
        let ba = b.distance(to: a)

        #expect(ab >= 0)
        #expect(ab == ba)                                                    // symmetric
        #expect(ab <= Coordinate.earthRadiusMeters * .pi + 1e-3)             // ≤ half circumference
    }

    @Test("the triangle inequality holds for arbitrary triples", arguments: 0..<300)
    func triangleInequality(seed: Int) {
        var rng = SeededRNG64(seed: UInt64(seed) &+ 1)
        let a = randomCoordinate(&rng)
        let b = randomCoordinate(&rng)
        let c = randomCoordinate(&rng)
        // 1 mm of slack absorbs floating-point error; the geometric inequality is exact.
        #expect(a.distance(to: c) <= a.distance(to: b) + b.distance(to: c) + 1e-3)
    }
}

/// A small seedable PRNG (SplitMix64) so generated inputs are reproducible per seed — mirrors the
/// `SeededRNG` in PropertyTests (kept local: that one is `private` to its file).
struct SeededRNG64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }
}
