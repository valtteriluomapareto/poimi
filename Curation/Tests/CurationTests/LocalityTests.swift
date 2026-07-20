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
}
