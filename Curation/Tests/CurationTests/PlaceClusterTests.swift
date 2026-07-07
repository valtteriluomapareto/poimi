//
//  PlaceClusterTests.swift
//  CurationTests — the pure DBSCAN place-clustering core (issue #131, invariants 1–4, 9).
//
//  Match the repo's Swift Testing idiom (`@Test`/`@Suite`, `@Test(arguments:)`, `SeededRNG`; see
//  GeoDistanceTests / PropertyTests). Determinism is *proven by shuffling + relabelling*, not asserted.
//

import Testing
import Foundation
@testable import Curation

@Suite("PlaceClustering — pure DBSCAN core")
struct PlaceClusterTests {
    private let cal = utcCalendar()
    private let base = utcCalendar().date(from: DateComponents(year: 2025, month: 1, day: 1))!

    // MARK: helpers

    /// A located asset at a fixed coordinate on a fixed day (day offset from 2025-01-01).
    private func located(_ id: String, _ lat: Double, _ lon: Double, dayOffset: Int = 0) -> AssetRef {
        AssetRef(id: id,
                 captureDate: cal.date(byAdding: .day, value: dayOffset, to: base)!,
                 coordinate: Coordinate(latitude: lat, longitude: lon))
    }

    /// A blob of `n` points jittered ±`jitter`° around a centre, one per day so density is realistic.
    private func blob(_ prefix: String, _ centre: Coordinate, n: Int, jitter: Double,
                      _ rng: inout SeededRNG) -> [AssetRef] {
        (0..<n).map { i in
            AssetRef(id: "\(prefix)-\(i)",
                     captureDate: cal.date(byAdding: .day, value: i, to: base)!,
                     coordinate: Coordinate(latitude: centre.latitude + Double.random(in: -jitter...jitter, using: &rng),
                                            longitude: centre.longitude + Double.random(in: -jitter...jitter, using: &rng)))
        }
    }

    /// An order-preserving id relabelling: the k-th smallest original id maps to a fresh zero-padded
    /// id, so id-based tie-breaks resolve identically (proves the algorithm depends on id *order*, not
    /// on the id string values — the churn the smoke seed uses).
    private func orderPreservingMap(_ ids: [String]) -> [String: String] {
        let sorted = Set(ids).sorted()
        var map: [String: String] = [:]
        for (index, id) in sorted.enumerated() { map[id] = String(format: "churn-%05d", index) }
        return map
    }

    private func relabel(_ assets: [AssetRef], _ map: [String: String]) -> [AssetRef] {
        assets.map { AssetRef(id: map[$0.id] ?? $0.id, captureDate: $0.captureDate, coordinate: $0.coordinate) }
    }

    private func relabel(_ result: PlaceClusters, _ map: [String: String]) -> PlaceClusters {
        let clusters = result.clusters.map {
            PlaceCluster(id: map[$0.id] ?? $0.id, medoid: $0.medoid,
                         assetIDs: $0.assetIDs.map { map[$0] ?? $0 }.sorted())
        }.sorted { $0.id < $1.id }
        return PlaceClusters(clusters: clusters, noLocationIDs: result.noLocationIDs.map { map[$0] ?? $0 }.sorted())
    }

    /// A random field: a few blobs + some no-coordinate + some null-island assets, shuffled.
    private func randomField(_ rng: inout SeededRNG) -> [AssetRef] {
        var assets: [AssetRef] = []
        let blobCount = Int.random(in: 1...4, using: &rng)
        for b in 0..<blobCount {
            let centre = Coordinate(latitude: Double.random(in: -60...60, using: &rng),
                                    longitude: Double.random(in: -170...170, using: &rng))
            assets += blob("b\(b)", centre, n: Int.random(in: 1...12, using: &rng), jitter: 0.02, &rng)
        }
        for i in 0..<Int.random(in: 0...5, using: &rng) {
            assets.append(AssetRef(id: "nc\(i)", captureDate: base, coordinate: nil))
        }
        for i in 0..<Int.random(in: 0...4, using: &rng) {
            assets.append(AssetRef(id: "ni\(i)", captureDate: base, coordinate: Coordinate(latitude: 0, longitude: 0)))
        }
        assets.shuffle(using: &rng)
        return assets
    }

    /// A larger, denser field than `randomField` for stressing the grid index: several big blobs across a
    /// wide latitude band (incl. high latitudes, where longitude cells are widest) with jitter spanning
    /// multiple cell widths, so many pairs sit right at the `eps` boundary — the completeness edge. Kept
    /// off the ±180° seam so the grid path (not its brute fallback) is exercised.
    private func gridStressField(_ rng: inout SeededRNG) -> [AssetRef] {
        var assets: [AssetRef] = []
        for b in 0..<Int.random(in: 2...6, using: &rng) {
            let centre = Coordinate(latitude: Double.random(in: -70...70, using: &rng),
                                    longitude: Double.random(in: -170...170, using: &rng))
            assets += blob("g\(b)", centre, n: Int.random(in: 20...120, using: &rng), jitter: 0.4, &rng)
        }
        assets.shuffle(using: &rng)
        return assets
    }

    // MARK: Invariant 1 — partition of located assets

    @Test("clusters ∪ no-location partition the input exactly — no loss, no dup", arguments: 0..<200)
    func partition(seed: Int) {
        var rng = SeededRNG(seed: UInt64(seed))
        let assets = randomField(&rng)
        let result = PlaceClustering.clusters(for: assets, calendar: cal)

        let clustered = result.clusters.flatMap(\.assetIDs)
        let all = clustered + result.noLocationIDs
        // Every input id appears exactly once across clusters + no-location.
        #expect(all.count == assets.count)
        #expect(Set(all) == Set(assets.map(\.id)))
        // No id is in two clusters, and no cluster is empty.
        #expect(Set(clustered).count == clustered.count)
        #expect(result.clusters.allSatisfy { !$0.assetIDs.isEmpty })
        // Every clustered id is a genuinely located asset (never a `(0,0)` / no-coord one).
        let locatedIDs = Set(assets.filter { PlaceClustering.isLocated($0) }.map(\.id))
        #expect(Set(clustered).isSubset(of: locatedIDs))
        // A cluster's medoid is one of its own members.
        for cluster in result.clusters { #expect(cluster.assetIDs.contains(cluster.id)) }
        // Output-ordering contract (byte-stability): clusters sorted by medoid id, no-location ascending.
        #expect(result.clusters.map(\.id) == result.clusters.map(\.id).sorted())
        #expect(result.noLocationIDs == result.noLocationIDs.sorted())
        for cluster in result.clusters { #expect(cluster.assetIDs == cluster.assetIDs.sorted()) }
    }

    // MARK: Invariant 2 — order-independence (shuffle + id churn → byte-identical)

    @Test("output is byte-identical under input shuffle (order-independent)", arguments: 0..<200)
    func shuffleInvariant(seed: Int) {
        var rng = SeededRNG(seed: UInt64(seed))
        let assets = randomField(&rng)
        let once = PlaceClustering.clusters(for: assets, calendar: cal)
        for _ in 0..<3 {
            let again = PlaceClustering.clusters(for: assets.shuffled(using: &rng), calendar: cal)
            #expect(again == once)   // Equatable structs → byte-identical clusters, medoids, no-location
        }
    }

    @Test("clustering commutes with order-preserving id churn (no dependence on id strings)",
          arguments: 0..<200)
    func idChurnInvariant(seed: Int) {
        var rng = SeededRNG(seed: UInt64(seed))
        let assets = randomField(&rng)
        let map = orderPreservingMap(assets.map(\.id))
        let churned = relabel(assets, map).shuffled(using: &rng)

        let baseline = PlaceClustering.clusters(for: assets, calendar: cal)
        let after = PlaceClustering.clusters(for: churned, calendar: cal)
        #expect(after == relabel(baseline, map))   // cluster(relabel(x)) == relabel(cluster(x))
    }

    // MARK: Invariant 3 — medoid identity stability

    @Test("a far-away addition (new cluster / noise) never moves an existing cluster's medoid")
    func medoidStableUnderFarAddition() {
        var rng = SeededRNG(seed: 7)
        let helsinki = Coordinate(latitude: 60.17, longitude: 24.94)
        let stockholm = Coordinate(latitude: 59.33, longitude: 18.07)
        let city = blob("hel", helsinki, n: 10, jitter: 0.02, &rng)

        let before = PlaceClustering.clusters(for: city, minPts: 3, calendar: cal)
        #expect(before.clusters.count == 1)
        let medoid = before.clusters[0].id

        // Add a whole far-away cluster (new place) — the original medoid must not move.
        let withNewCluster = city + blob("sto", stockholm, n: 10, jitter: 0.02, &rng)
        let after = PlaceClustering.clusters(for: withNewCluster, minPts: 3, calendar: cal)
        let helCluster = after.clusters.first { $0.assetIDs.contains(where: { $0.hasPrefix("hel-") }) }
        #expect(helCluster?.id == medoid)

        // Add a single far-away noise point — likewise no drift, and it routes to no-location.
        let withNoise = city + [located("noise", -33.87, 151.21, dayOffset: 99)]   // Sydney, alone
        let afterNoise = PlaceClustering.clusters(for: withNoise, minPts: 3, calendar: cal)
        #expect(afterNoise.clusters.count == 1)
        #expect(afterNoise.clusters[0].id == medoid)
        #expect(afterNoise.noLocationIDs.contains("noise"))
    }

    @Test("re-clustering the same set yields the same medoid (stable identity)")
    func medoidStableAcrossReclustering() {
        var rng = SeededRNG(seed: 11)
        let city = blob("c", Coordinate(latitude: 48.86, longitude: 2.35), n: 12, jitter: 0.03, &rng)
        let first = PlaceClustering.clusters(for: city, minPts: 3, calendar: cal)
        let second = PlaceClustering.clusters(for: city.shuffled(using: &rng), minPts: 3, calendar: cal)
        #expect(first.clusters.map(\.id) == second.clusters.map(\.id))
    }

    // MARK: Invariant 4 — no-location routing

    @Test("null-island (0,0) points are never cluster members, even at minPts = 1")
    func nullIslandNeverClustered() {
        let assets = (0..<6).map { located("z\($0)", 0, 0, dayOffset: $0) }
        let result = PlaceClustering.clusters(for: assets, minPts: 1, calendar: cal)
        #expect(result.clusters.isEmpty)
        #expect(Set(result.noLocationIDs) == Set(assets.map(\.id)))
    }

    @Test("sub-minPts points are noise → no-location, not a cluster")
    func subMinPtsIsNoise() {
        // Two isolated points, minPts = 4 → neither is a core, neither has a core neighbour → noise.
        let assets = [located("p1", 10, 10, dayOffset: 0), located("p2", 40, 40, dayOffset: 1)]
        let result = PlaceClustering.clusters(for: assets, minPts: 4, calendar: cal)
        #expect(result.clusters.isEmpty)
        #expect(Set(result.noLocationIDs) == ["p1", "p2"])
    }

    // MARK: Invariant 9 — degenerate inputs

    @Test("zero located assets → all no-location, no crash")
    func zeroLocated() {
        let assets = (0..<5).map { AssetRef(id: "n\($0)", captureDate: base, coordinate: nil) }
        let result = PlaceClustering.clusters(for: assets, calendar: cal)
        #expect(result.clusters.isEmpty)
        #expect(Set(result.noLocationIDs) == Set(assets.map(\.id)))
    }

    @Test("a single located point under minPts > 1 is noise")
    func singleLocatedIsNoise() {
        let result = PlaceClustering.clusters(for: [located("solo", 51.5, -0.13)], minPts: 2, calendar: cal)
        #expect(result.clusters.isEmpty)
        #expect(result.noLocationIDs == ["solo"])
    }

    @Test("an identical-coordinate burst forms one cluster with the medoid tie resolved by lower id")
    func identicalCoordinateBurst() {
        // Ids intentionally out of order so the tie-break (lowest id), not input order, decides.
        let ids = ["m", "a", "z", "c", "b"]
        let assets = ids.enumerated().map { located($0.element, 45, 45, dayOffset: $0.offset) }
        let result = PlaceClustering.clusters(for: assets, minPts: 3, calendar: cal)
        #expect(result.clusters.count == 1)
        #expect(result.clusters[0].id == "a")   // lowest id wins the all-zero-distance tie
        #expect(Set(result.clusters[0].assetIDs) == Set(ids))
    }

    // MARK: adaptive minPts + antimeridian + home

    @Test("adaptiveMinPts is the clamped mean located-photos per active day")
    func adaptiveMinPtsMirrorsDensity() {
        // 3 located photos on each of 4 distinct days → mean 3 → minPts 3 (the floor).
        var light: [AssetRef] = []
        for day in 0..<4 { for shot in 0..<3 { light.append(located("l\(day)-\(shot)", 60, 24, dayOffset: day)) } }
        #expect(PlaceClustering.adaptiveMinPts(for: light, calendar: cal) == 3)

        // 30 located photos on a day → mean 30 → clamped to the ceiling (20).
        let heavy = (0..<30).map { located("h\($0)", 60, 24, dayOffset: 0) }
        #expect(PlaceClustering.adaptiveMinPts(for: heavy, calendar: cal) == PlaceClustering.maxAdaptiveMinPts)

        // No located assets → the floor, no divide-by-zero.
        let none = [AssetRef(id: "x", captureDate: base, coordinate: nil)]
        #expect(PlaceClustering.adaptiveMinPts(for: none, calendar: cal) == PlaceClustering.minAdaptiveMinPts)
    }

    @Test("a cluster straddling the ±180° antimeridian stays a single cluster (haversine)")
    func antimeridianClustersTogether() {
        var assets: [AssetRef] = []
        for i in 0..<8 {
            let east = i % 2 == 0
            assets.append(located("fij\(i)", -17.0, east ? 179.95 : -179.95, dayOffset: i))
        }
        // eps pinned to 25 km (not the 3 km default): the two seam sides sit ~10 km apart, so this
        // exercises the wrap-aware delta at a coarse radius — a naive subtraction would put ±179.95
        // ~40 000 km apart, never clustering at ANY eps.
        let result = PlaceClustering.clusters(for: assets, eps: 25_000, minPts: 3, calendar: cal)
        #expect(result.clusters.count == 1)
        #expect(result.clusters[0].count == 8)
    }

    @Test("home is the most-days-spanning cluster")
    func homeIsMostDaysSpanning() {
        var rng = SeededRNG(seed: 3)
        // Home: 30 photos across 30 distinct days. Trip: 30 photos on 2 days (denser, fewer days).
        var home: [AssetRef] = []
        for day in 0..<30 { home.append(located("home\(day)", 60.17, 24.94, dayOffset: day)) }
        let trip = blob("trip", Coordinate(latitude: 41.9, longitude: 12.5), n: 30, jitter: 0.02, &rng)
            .map { AssetRef(id: $0.id, captureDate: self.cal.date(byAdding: .day, value: 200, to: self.base)!,
                            coordinate: $0.coordinate) }
        let assets = home + trip
        let result = PlaceClustering.clusters(for: assets, minPts: 3, calendar: cal)
        let detectedHome = PlaceClustering.homeCluster(result.clusters, assets: assets, calendar: cal)
        #expect(detectedHome?.assetIDs.contains(where: { $0.hasPrefix("home") }) == true)
        // …and the denser-but-fewer-days trip cluster is NOT chosen as home.
        #expect(detectedHome?.assetIDs.allSatisfy { !$0.hasPrefix("trip") } == true)
    }

    @Test("a NEAR addition may move the medoid (identity is medoid-derived, not frozen — invariant 3)")
    func medoidDriftsWithNearMass() {
        // Invariant 3 pins stability under FAR additions; the complement is that a near addition is
        // *allowed* to move the medoid. Five identical points → medoid = lowest id; adding 20 points
        // ~5 km away (still one cluster at the pinned 25 km eps) pulls the medoid to the new centre.
        // eps pinned (not the 3 km default) so this behaviour test doesn't hinge on the default radius.
        var points = (0..<5).map { located("a\($0)", 41.90, 12.50, dayOffset: $0) }
        let before = PlaceClustering.clusters(for: points, eps: 25_000, minPts: 3, calendar: cal)
        #expect(before.clusters.count == 1)
        let originalMedoid = before.clusters[0].id
        points += (0..<20).map { located("b\($0)", 41.95, 12.50, dayOffset: 50 + $0) }
        let after = PlaceClustering.clusters(for: points, eps: 25_000, minPts: 3, calendar: cal)
        #expect(after.clusters.count == 1)          // 5 km < eps 25 km → still one cluster
        #expect(after.clusters[0].id != originalMedoid)   // medoid drifted toward the added mass
    }

    @Test("a huge cluster (> exactMedoidLimit) still gets a central, deterministic medoid (sampled)")
    func largeClusterMedoidIsCentralAndDeterministic() {
        // Above the exact-medoid limit the medoid is scored against a strided sample, not all members.
        // The result must still be (a) a real, central member — near the blob's centre — and (b) fully
        // deterministic: order-independent (canonical sort) and stable under an order-preserving relabel.
        var rng = SeededRNG(seed: 11)
        let centre = Coordinate(latitude: 60.0, longitude: 24.0)
        let n = PlaceClustering.exactMedoidLimit * 2   // 512 — comfortably over the limit
        let assets = blob("home", centre, n: n, jitter: 0.001, &rng)   // ~111 m spread → one cluster
        let result = PlaceClustering.clusters(for: assets, minPts: 3, calendar: cal)
        #expect(result.clusters.count == 1)
        #expect(result.clusters[0].count == n)
        // Central: the sampled medoid sits within the blob's own jitter radius of the true centre —
        // it is not dragged to an edge point (which would have a large summed distance to the sample).
        let medoid = result.clusters[0].medoid
        #expect(medoid.distance(to: centre) < 200)   // jitter 0.001° ≲ 124 m; a central member is well inside

        // Determinism under an order-preserving id relabel (churn the smoke seed uses) + input shuffle.
        let map = orderPreservingMap(assets.map(\.id))
        let shuffled = relabel(assets, map).shuffled(using: &rng)
        let again = PlaceClustering.clusters(for: shuffled, minPts: 3, calendar: cal)
        #expect(again.clusters[0].id == (map[result.clusters[0].id] ?? result.clusters[0].id))
    }

    // MARK: Spatial grid index — must equal the brute O(n²) form (§5.2)

    /// Canonical `(lat, lon, id)` order of the located points — mirrors `clusters(for:)` so grid/brute
    /// indices line up. (The neighbour builders take the pre-sorted `(id, coord)` pairs.)
    private func sortedLocated(_ assets: [AssetRef]) -> [(id: String, coord: Coordinate)] {
        assets.filter { PlaceClustering.isLocated($0) }
            .compactMap { asset in asset.coordinate.map { (asset.id, $0) } }
            .sorted { lhs, rhs in
                if lhs.coord.latitude != rhs.coord.latitude { return lhs.coord.latitude < rhs.coord.latitude }
                if lhs.coord.longitude != rhs.coord.longitude { return lhs.coord.longitude < rhs.coord.longitude }
                return lhs.id < rhs.id
            }
    }

    @Test("grid neighbour sets equal the brute-force sets (completeness + soundness)", arguments: 0..<200)
    func gridMatchesBruteForce(seed: Int) {
        var rng = SeededRNG(seed: UInt64(seed))
        let located = sortedLocated(gridStressField(&rng))
        for eps in [5_000.0, 25_000.0, 80_000.0] {
            let grid = PlaceClustering.neighbourLists(located, eps: eps)
            let brute = PlaceClustering.bruteForceNeighbourLists(located, eps: eps)
            #expect(grid.count == brute.count)
            // Sets, not arrays: DBSCAN here is order-independent, so grid may enumerate in cell order.
            for i in grid.indices { #expect(Set(grid[i]) == Set(brute[i])) }
        }
    }

    @Test("grid equals brute at high latitude (grid path) and near the poles (fallback)",
          arguments: 0..<80)
    func gridMatchesBruteForceHighLatitude(seed: Int) {
        var rng = SeededRNG(seed: UInt64(seed))
        // Two independent fields: ~80° stays on the grid path (cos ≈ 0.17, where longitude cells are
        // wide); ~89° trips the near-pole brute fallback (cos < 0.1). Both must match the reference —
        // this pins the completeness of the longitude cell sizing that the O(n²) form makes trivial.
        for centreLat in [80.0, 89.0] {
            let centre = Coordinate(latitude: centreLat,
                                    longitude: Double.random(in: -150...150, using: &rng))
            let located = sortedLocated(blob("hi", centre, n: Int.random(in: 20...80, using: &rng),
                                             jitter: 0.5, &rng))
            for eps in [5_000.0, 25_000.0, 120_000.0] {
                let grid = PlaceClustering.neighbourLists(located, eps: eps)
                let brute = PlaceClustering.bruteForceNeighbourLists(located, eps: eps)
                for i in grid.indices { #expect(Set(grid[i]) == Set(brute[i])) }
            }
        }
    }

    @Test("clusters() over a large field still partitions and stays order-independent", arguments: 0..<40)
    func gridScaleClustersHold(seed: Int) {
        var rng = SeededRNG(seed: UInt64(seed))
        let assets = gridStressField(&rng)
        let once = PlaceClustering.clusters(for: assets, calendar: cal)
        let all = once.clusters.flatMap(\.assetIDs) + once.noLocationIDs
        #expect(all.count == assets.count)
        #expect(Set(all) == Set(assets.map(\.id)))
        #expect(PlaceClustering.clusters(for: assets.shuffled(using: &rng), calendar: cal) == once)
    }
}
