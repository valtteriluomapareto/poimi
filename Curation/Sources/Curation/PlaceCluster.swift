//
//  PlaceCluster.swift
//  Curation — the pure spatial clustering core for the v1.1 location feature (issue #131 / #130).
//
//  Front-loads the *durable, CI-verifiable* half of the location-bucketing feature ahead of the
//  on-device spike (#129): the pure DBSCAN clustering over `AssetRef` coordinates + medoid identity
//  + no-location routing + home detection. All pure `Curation` domain — no Photos/CoreLocation/UI,
//  no `@MainActor` (D14/D21) — so it runs in fast headless property tests with synthetic coordinate
//  fields. See the design in `docs/plans/preprocessing-and-caching.md` §5 (clustering / metric /
//  medoid / no-location) and §11 (rollout step 1).
//
//  Naming (deliberate, #131): the spatial type is **`PlaceCluster`**, NEVER `Cluster`/`ClusterState`
//  — `ClusterState.swift` already means the *day-group review state*, a completely different concept.
//
//  Design choices, pinned by tests (`PlaceClusterTests`):
//    • **Metric:** reuse `Coordinate.distance(to:)` (haversine, metres — `GeoDistance.swift`). No new
//      metric, no equirectangular reference latitude. Anti-meridian-safe for free (haversine).
//    • **`eps` fixed in metres; `minPts` adapts to shooting density** (`adaptiveMinPts` mirrors
//      `DayGrouping.adaptiveThreshold`'s mean-per-active-day, computed over the located set). A single
//      global radius can't separate a dense home from sparse trip cities, so the *density* requirement
//      scales with how much this person shoots — the scale-invariance mapping (§5.2).
//    • **Medoid representative; cluster identity = medoid asset id** (§5.3), not an ordinal — a real
//      photographed place, anti-meridian-safe, and a stable handle across re-clustering.
//    • **Determinism:** a pinned input sort `(lat, lon, id)` + border points assigned to their
//      *nearest* core point (tie-break: lower id) make the output order-*independent*, not merely
//      order-deterministic (§5.2). Cores are grouped by density-connectivity (union-find).
//    • **No-location routing:** `(0,0)` null-island sentinels, missing coordinates, and DBSCAN noise
//      (sub-`minPts`, no core neighbour) all route to the no-location bucket (§5.4) — never a cluster.
//
//  Scale note: neighbour discovery is the deliberately-simple O(n²) form. The grid spatial index that
//  makes it O(n log n) (§5.2) is the *deferred* optimization — the pure core is the correctness anchor
//  it will build on (the same "correctness first, fast-path later" posture as `GeoDistance.swift`), and
//  the 10k perf smoke that would need it is the deferred integration tier (§10).
//

import Foundation

/// One spatial cluster of located assets — a "place." Identified by its **medoid asset id** (§5.3),
/// so a cached handle survives re-clustering. `medoid` is the representative coordinate (the point a
/// later geocode step queries). `assetIDs` are the members, sorted ascending for byte-stable output.
public struct PlaceCluster: Sendable, Identifiable, Equatable, Hashable, Codable {
    /// Cluster identity = the medoid member's asset id (`AssetRef.id`). Stable, not an ordinal.
    public let id: String
    /// The medoid coordinate — the actual member coordinate minimizing summed intra-cluster distance
    /// (a real photographed place, never a mid-bay centroid; anti-meridian-safe).
    public let medoid: Coordinate
    /// Member asset ids, sorted ascending (deterministic, order-independent).
    public let assetIDs: [String]

    public var count: Int { assetIDs.count }

    public init(id: String, medoid: Coordinate, assetIDs: [String]) {
        self.id = id
        self.medoid = medoid
        self.assetIDs = assetIDs
    }
}

/// The result of clustering a candidate set: the place clusters (sorted by medoid id) plus the
/// no-location bucket (`(0,0)` sentinels, missing coordinates, and DBSCAN noise — §5.4). Together
/// they partition every input asset id (no loss, no dup).
public struct PlaceClusters: Sendable, Equatable, Codable {
    /// The clusters, sorted by medoid id (ascending) for byte-stable output.
    public let clusters: [PlaceCluster]
    /// Asset ids with no place: null-island `(0,0)`, no coordinate, or DBSCAN noise. Sorted ascending.
    public let noLocationIDs: [String]

    public init(clusters: [PlaceCluster], noLocationIDs: [String]) {
        self.clusters = clusters
        self.noLocationIDs = noLocationIDs
    }

    /// `assetID → cluster id` for every clustered asset (empty value for no-location assets, which
    /// are simply absent). Built on demand — convenient for the trip overlay and for tests.
    public var clusterIDByAsset: [String: String] {
        var map: [String: String] = [:]
        for cluster in clusters {
            for assetID in cluster.assetIDs { map[assetID] = cluster.id }
        }
        return map
    }
}

public enum PlaceClustering {
    /// Fixed neighbourhood radius in **metres** (§5.2 — the density adapts via `minPts`, not this).
    /// Chosen so a home *metro* stays one cluster while trip *cities* (~100–300 km apart, the seed's
    /// Rome/Florence/Venice) fall into separate clusters. Spike-tunable like `DayGrouping`'s threshold
    /// (§5.5). Sensitivity: below ~10 km a spread-out metro fragments; above ~60 km nearby cities merge.
    public static let defaultEps: Double = 25_000

    /// Clamp bounds for `adaptiveMinPts` (the DBSCAN density floor). A place needs at least a few
    /// photos to exist (floor); a heavy-shooting year still forms places without demanding an
    /// implausible crowd (ceiling). Distinct from `DayGrouping`'s threshold clamps — this governs a
    /// *spatial* neighbour count, not a busy-*day* count.
    public static let minAdaptiveMinPts = 3
    public static let maxAdaptiveMinPts = 20

    /// Is this asset a clustering candidate? A candidate has a coordinate that is not the `(0,0)`
    /// null-island EXIF sentinel (§5.4 routes `(0,0)` to no-location). A missing coordinate is not a
    /// candidate either.
    static func isLocated(_ asset: AssetRef) -> Bool {
        guard let coordinate = asset.coordinate else { return false }
        return !(coordinate.latitude == 0 && coordinate.longitude == 0)
    }

    /// The adaptive DBSCAN `minPts`: the **mean located-photos per active day** (a calendar day with
    /// ≥1 located photo), clamped to `[minAdaptiveMinPts, maxAdaptiveMinPts]` — the spatial mirror of
    /// `DayGrouping.adaptiveThreshold`. Ties the density a "place" needs to how much this person
    /// shoots: a light shooter's few photos still form a place; a heavy shooter needs a denser cluster
    /// (§5.2 scale-invariance). Undated/no-GPS assets and empty days are excluded (they'd drag the mean
    /// down); an empty located set returns the floor.
    public static func adaptiveMinPts(for assets: [AssetRef], calendar: Calendar = .current) -> Int {
        var countByDay: [DayKey: Int] = [:]
        for asset in assets where isLocated(asset) {
            let key = asset.dayKey(in: calendar)
            guard key != .undated else { continue }
            countByDay[key, default: 0] += 1
        }
        guard !countByDay.isEmpty else { return minAdaptiveMinPts }
        let mean = Double(countByDay.values.reduce(0, +)) / Double(countByDay.count)
        return Swift.min(maxAdaptiveMinPts, Swift.max(minAdaptiveMinPts, Int(mean.rounded())))
    }

    /// Cluster the located assets with DBSCAN over `Coordinate.distance(to:)`.
    ///
    /// - Parameters:
    ///   - assets: asset value models in any order (sorted internally — callers need not pre-sort).
    ///   - eps: neighbourhood radius in metres (default `defaultEps`).
    ///   - minPts: the density floor; `nil` → `adaptiveMinPts(for:)` (the production path).
    ///   - calendar: used only by the adaptive `minPts` estimate (mean per active day).
    /// - Returns: clusters (sorted by medoid id) + the no-location bucket. Their union is exactly the
    ///   input id set (a partition — no loss, no dup), and the output is byte-identical under any input
    ///   permutation or order-preserving id relabelling.
    public static func clusters(
        for assets: [AssetRef],
        eps: Double = defaultEps,
        minPts: Int? = nil,
        calendar: Calendar = .current
    ) -> PlaceClusters {
        let resolvedMinPts = minPts ?? adaptiveMinPts(for: assets, calendar: calendar)

        // Partition input into located candidates and the rest (no coordinate / null-island `(0,0)`).
        var located: [(id: String, coord: Coordinate)] = []
        var noLocation: [String] = []
        for asset in assets {
            if isLocated(asset), let coordinate = asset.coordinate {
                located.append((asset.id, coordinate))
            } else {
                noLocation.append(asset.id)
            }
        }

        // Pinned canonical order `(lat, lon, id)` — the defensive-sort discipline `DayGrouping`
        // uses, here the source of the algorithm's order-independence (§5.2).
        located.sort { lhs, rhs in
            if lhs.coord.latitude != rhs.coord.latitude { return lhs.coord.latitude < rhs.coord.latitude }
            if lhs.coord.longitude != rhs.coord.longitude { return lhs.coord.longitude < rhs.coord.longitude }
            return lhs.id < rhs.id
        }

        let count = located.count
        guard count > 0 else {
            noLocation.sort()
            return PlaceClusters(clusters: [], noLocationIDs: noLocation)
        }

        // Neighbour lists within `eps` (inclusive), self-inclusive — the DBSCAN convention where a
        // point counts toward its own `minPts`. O(n²); a grid index is the deferred scale optimization.
        var neighbours: [[Int]] = (0..<count).map { [$0] }
        for i in 0..<count {
            for j in (i + 1)..<count where located[i].coord.distance(to: located[j].coord) <= eps {
                neighbours[i].append(j)
                neighbours[j].append(i)
            }
        }

        let isCore = (0..<count).map { neighbours[$0].count >= resolvedMinPts }

        // Group cores by density-connectivity: two cores within `eps` are in the same cluster.
        // Union-find over the canonically-ordered indices; the chosen root is irrelevant since the
        // final identity is the medoid id.
        var parent = Array(0..<count)
        func find(_ node: Int) -> Int {
            var root = node
            while parent[root] != root { parent[root] = parent[parent[root]]; root = parent[root] }
            return root
        }
        func union(_ lhs: Int, _ rhs: Int) {
            let (rootLHS, rootRHS) = (find(lhs), find(rhs))
            if rootLHS != rootRHS { parent[Swift.max(rootLHS, rootRHS)] = Swift.min(rootLHS, rootRHS) }
        }
        for i in 0..<count where isCore[i] {
            for j in neighbours[i] where isCore[j] { union(i, j) }
        }

        // Collect members per cluster: every core, plus each border point assigned to its NEAREST
        // core (tie-break: lower core id) — the rule that makes border assignment order-independent
        // rather than "whichever core discovered it first" (§5.2). A non-core with no core neighbour
        // is noise → no-location (§5.4).
        var memberIndicesByRoot: [Int: [Int]] = [:]
        for i in 0..<count where isCore[i] {
            memberIndicesByRoot[find(i), default: []].append(i)
        }
        for i in 0..<count where !isCore[i] {
            var bestRoot = -1
            var bestID = ""
            var bestDistance = Double.infinity
            for j in neighbours[i] where isCore[j] {
                let distance = located[i].coord.distance(to: located[j].coord)
                if bestRoot < 0 || distance < bestDistance
                    || (distance == bestDistance && located[j].id < bestID) {
                    bestRoot = j
                    bestID = located[j].id
                    bestDistance = distance
                }
            }
            if bestRoot >= 0 {
                memberIndicesByRoot[find(bestRoot), default: []].append(i)
            } else {
                noLocation.append(located[i].id)
            }
        }

        var clusters: [PlaceCluster] = []
        for (_, indices) in memberIndicesByRoot {
            let members = indices.map { located[$0] }
            let medoid = members[medoidIndex(of: members)]
            clusters.append(PlaceCluster(
                id: medoid.id,
                medoid: medoid.coord,
                assetIDs: members.map { $0.id }.sorted()
            ))
        }
        clusters.sort { $0.id < $1.id }
        noLocation.sort()
        return PlaceClusters(clusters: clusters, noLocationIDs: noLocation)
    }

    /// The index of the medoid within `members`: the member minimizing summed distance to the others,
    /// tie-broken by lower id. Deterministic and order-independent (a min over the set). For an
    /// identical-coordinate burst every sum is 0, so the tie collapses to the lowest id (invariant 9).
    static func medoidIndex(of members: [(id: String, coord: Coordinate)]) -> Int {
        var bestIndex = 0
        var bestSum = Double.infinity
        var bestID = ""
        for i in members.indices {
            var sum = 0.0
            for j in members.indices where j != i {
                sum += members[i].coord.distance(to: members[j].coord)
            }
            if bestSum == Double.infinity || sum < bestSum
                || (sum == bestSum && members[i].id < bestID) {
                bestIndex = i
                bestSum = sum
                bestID = members[i].id
            }
        }
        return bestIndex
    }

    /// The **home** cluster: the one spanning the most distinct calendar days (home is where you are
    /// across the year, not where you took the most photos on one trip). Tie-break: more photos, then
    /// lower medoid id. Home is excluded from trip formation and never surfaced as a "trip"
    /// (`TripOverlay`, §6). `nil` when there are no clusters. Undated days don't count toward the span.
    public static func homeCluster(
        _ clusters: [PlaceCluster],
        assets: [AssetRef],
        calendar: Calendar = .current
    ) -> PlaceCluster? {
        guard !clusters.isEmpty else { return nil }
        let dayByID = Dictionary(assets.map { ($0.id, $0.dayKey(in: calendar)) },
                                 uniquingKeysWith: { first, _ in first })
        func distinctDays(_ cluster: PlaceCluster) -> Int {
            var days = Set<DayKey>()
            for assetID in cluster.assetIDs {
                if let key = dayByID[assetID], key != .undated { days.insert(key) }
            }
            return days.count
        }
        var best = clusters[0]
        var bestDays = distinctDays(clusters[0])
        for cluster in clusters.dropFirst() {
            let days = distinctDays(cluster)
            let better = days > bestDays
                || (days == bestDays && cluster.count > best.count)
                || (days == bestDays && cluster.count == best.count && cluster.id < best.id)
            if better {
                best = cluster
                bestDays = days
            }
        }
        return best
    }
}
