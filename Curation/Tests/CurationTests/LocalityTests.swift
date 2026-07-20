//
//  LocalityTests.swift
//  CurationTests — the day-cluster home/away classifier (#201 level A).
//
//  Pure set-math over (cluster members, home cluster members, no-location bucket), coverage-gated so a
//  patchy-GPS day degrades to `.unknown` (→ the caption falls back to media) rather than mislabeling.
//

import Testing
@testable import Curation

@Suite("Locality — home/away classification")
struct LocalityTests {
    private let ids = (0..<10).map { "a\($0)" }   // a0…a9

    @Test("most located photos at home → .mostlyHome")
    func home() {
        // located = a0…a7 (a8,a9 no-GPS); 7 of 8 at home → 0.875 ≥ 0.6
        #expect(Locality.of(clusterAssetIDs: ids,
                            homeAssetIDs: ["a0", "a1", "a2", "a3", "a4", "a5", "a6"],
                            noLocationIDs: ["a8", "a9"]) == .mostlyHome)
    }

    @Test("most located photos away → .mostlyAway")
    func away() {
        // located = a0…a7; only a0 at home → 0.125 ≤ 0.4
        #expect(Locality.of(clusterAssetIDs: ids,
                            homeAssetIDs: ["a0"],
                            noLocationIDs: ["a8", "a9"]) == .mostlyAway)
    }

    @Test("a split day → .mixed (no confident label)")
    func mixed() {
        // located = a0…a7; 4 of 8 at home → 0.5, between the thresholds
        #expect(Locality.of(clusterAssetIDs: ids,
                            homeAssetIDs: ["a0", "a1", "a2", "a3"],
                            noLocationIDs: ["a8", "a9"]) == .mixed)
    }

    @Test("patchy GPS (below the coverage floor) → .unknown, even if what's located is all home")
    func patchy() {
        // only a0,a1 located (20% < 35%), both home — still .unknown (don't guess)
        #expect(Locality.of(clusterAssetIDs: ids,
                            homeAssetIDs: ["a0", "a1"],
                            noLocationIDs: ["a2", "a3", "a4", "a5", "a6", "a7", "a8", "a9"]) == .unknown)
    }

    @Test("no located photos → .unknown; empty cluster → .unknown")
    func degenerate() {
        #expect(Locality.of(clusterAssetIDs: ["a0", "a1"], homeAssetIDs: [],
                            noLocationIDs: ["a0", "a1"]) == .unknown)
        #expect(Locality.of(clusterAssetIDs: [], homeAssetIDs: [], noLocationIDs: []) == .unknown)
    }

    @Test("exactly at the coverage floor still asserts (the >= boundary, not .unknown)")
    func coverageFloorBoundary() {
        let ids20 = (0..<20).map { "a\($0)" }
        // 7 of 20 located = 0.35 exactly; all 7 at home → .mostlyHome (not gated out)
        #expect(Locality.of(clusterAssetIDs: ids20,
                            homeAssetIDs: Set(ids20.prefix(7)),
                            noLocationIDs: Set(ids20.suffix(13))) == .mostlyHome)
    }

    @Test("homeFraction exactly at each threshold is inclusive (0.6 → home, 0.4 → away)")
    func thresholdBoundaries() {
        let five = (0..<5).map { "a\($0)" }   // all located
        // 3/5 == 0.6 → .mostlyHome (>= boundary)
        #expect(Locality.of(clusterAssetIDs: five, homeAssetIDs: ["a0", "a1", "a2"],
                            noLocationIDs: []) == .mostlyHome)
        // 2/5 == 0.4 == 1 - 0.6 → .mostlyAway (<= boundary, incl. the float subtraction)
        #expect(Locality.of(clusterAssetIDs: five, homeAssetIDs: ["a0", "a1"],
                            noLocationIDs: []) == .mostlyAway)
    }

    @Test("away = located-and-not-home, regardless of how many away places; all-home is .mostlyHome")
    func awaySemanticsAndExtremes() {
        // All located, none at home (they may span several away places — irrelevant) → .mostlyAway.
        #expect(Locality.of(clusterAssetIDs: ids, homeAssetIDs: [], noLocationIDs: []) == .mostlyAway)
        // The all-home extreme (fraction 1.0).
        #expect(Locality.of(clusterAssetIDs: ids, homeAssetIDs: Set(ids), noLocationIDs: []) == .mostlyHome)
    }
}
