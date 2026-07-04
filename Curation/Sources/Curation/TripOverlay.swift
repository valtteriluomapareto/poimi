//
//  TripOverlay.swift
//  Curation — trips as a time-contiguous overlay over the date day-groups (issue #131 / #130, §6).
//
//  The D33 composition: a **trip** is `place ∩ contiguous-time-run` — but formed as an *additive
//  annotation*, NEVER a re-partition of the day-groups (D32(d)/D33). The day-group stays the unit of
//  done-tracking; the place clusters stay the unit of by-location browsing; a trip only *labels* a run
//  of days. So the overlay can never move an asset between day-groups, split `assetIDs`, or introduce a
//  parallel done-key — the done-day atom (`section.days ⊆ doneDays`, `Completion`) is untouched. See
//  `docs/plans/preprocessing-and-caching.md` §6.
//
//  The rules (§6), pinned by `TripOverlayTests`:
//    • **Away-from-home days only.** A day is "away" iff its plurality located cluster is not the home
//      cluster (`PlaceClustering.homeCluster`). Forming runs from away days (not from the raw
//      day-groups) is what stops a short trip inside a home month from being out-voted and buried.
//    • **Contiguous time-run.** A run is a maximal chain of away days each within `gapToleranceDays`
//      of the previous (reuse `DayGrouping.dayGap`). A **home day breaks the run** (fly-home-between-
//      two-trips → two trips); intervening days with no located photos are neutral and bridged.
//    • **Label = plurality, not merge.** The run is named by the cluster holding the plurality of its
//      located (non-home) assets — ties broken by lower medoid id, the canonical cluster identity.
//      *Label*-by-dominant, not *merge*-by-dominant: the clusters stay distinct, every place keeps its
//      own browsable bucket, and only the run's *name* goes to the winner (the concurrent-location
//      family case: both buckets exist, the mixed week is merely *named* by the plurality).
//    • Sub-day place splits are out of scope (they'd break the done-day atom); two trips on one day
//      resolve to that day's dominant label — a known v1.1 limitation (§6).
//

import Foundation

/// One trip: a contiguous run of away-from-home days, labeled by its dominant (plurality) place
/// cluster. A pure annotation over the day timeline — it never owns or re-cuts assets.
public struct Trip: Sendable, Identifiable, Equatable, Hashable, Codable {
    /// Stable id: `"<clusterID>@<startDay>"`. Unique because one cluster can't start two runs on the
    /// same day; distinguishes two separate trips to the *same* place (e.g. a cabin in Jan and June).
    public let id: String
    /// The labeling cluster's medoid id (the plurality winner). The place's `PlaceCluster.id`.
    public let clusterID: String
    /// The away days this run spans, chronological. May be non-contiguous across bridged neutral
    /// (no-located-photo) days, but never across a home day.
    public let days: [DayKey]

    public init(clusterID: String, days: [DayKey]) {
        self.id = "\(clusterID)@\(days.first?.description ?? "?")"
        self.clusterID = clusterID
        self.days = days
    }
}

public enum TripOverlay {
    /// Max calendar gap (in days) a trip run bridges across neutral days. `DayGrouping` uses `1` for
    /// quiet-run merging; a trip tolerates a slightly longer no-GPS lull (a travel day with the phone
    /// away) without splitting — spike-tunable (§5.5).
    public static let defaultGapToleranceDays = 2

    /// Form the trip overlay from a clustering + the detected home cluster.
    ///
    /// - Parameters:
    ///   - assets: the same asset set that was clustered (any order).
    ///   - clusters: the `PlaceClustering.clusters(for:)` result.
    ///   - home: the home cluster (`PlaceClustering.homeCluster`), excluded from trips; `nil` treats
    ///     every cluster as away (no home base).
    ///   - gapToleranceDays: max gap a run bridges across neutral days.
    ///   - calendar: the same calendar used elsewhere, so day keys line up.
    /// - Returns: the trips in chronological order (by start day, then label).
    public static func trips(
        assets: [AssetRef],
        clusters: PlaceClusters,
        home: PlaceCluster?,
        gapToleranceDays: Int = defaultGapToleranceDays,
        calendar: Calendar = .current
    ) -> [Trip] {
        let clusterByAsset = clusters.clusterIDByAsset
        let homeID = home?.id

        // Per-day tally of located, clustered assets by cluster id (dated only — an undated asset
        // carries no trip overlay, §5.4/invariant 5).
        var tallyByDay: [DayKey: [String: Int]] = [:]
        for asset in assets {
            guard let clusterID = clusterByAsset[asset.id] else { continue }
            let key = asset.dayKey(in: calendar)
            guard key != .undated else { continue }
            tallyByDay[key, default: [:]][clusterID, default: 0] += 1
        }
        guard !tallyByDay.isEmpty else { return [] }

        // Walk located-photo days in order. An away day extends the current run (if within the gap of
        // the previous away day); a home day flushes it; a gap beyond tolerance starts a new run.
        // Neutral days (no located photos) simply aren't in this list — the gap check bridges them.
        let orderedDays = tallyByDay.keys.sorted()
        var runs: [[DayKey]] = []
        var current: [DayKey] = []
        var lastAway: DayKey?
        for day in orderedDays {
            let dayLabel = plurality(tallyByDay[day] ?? [:])
            let isAway = dayLabel != homeID
            if !isAway {
                if !current.isEmpty { runs.append(current); current = [] }
                lastAway = nil
                continue
            }
            if let last = lastAway,
               DayGrouping.dayGap(from: last, to: day, calendar: calendar) <= gapToleranceDays {
                current.append(day)
            } else {
                if !current.isEmpty { runs.append(current) }
                current = [day]
            }
            lastAway = day
        }
        if !current.isEmpty { runs.append(current) }

        // Label each run by the plurality of its located NON-home assets (an away run always has
        // some, since every away day's plurality is non-home). Home is excluded from the label so a
        // run is never named "home."
        return runs.compactMap { runDays in
            var runTally: [String: Int] = [:]
            for day in runDays {
                for (clusterID, quantity) in tallyByDay[day] ?? [:] where clusterID != homeID {
                    runTally[clusterID, default: 0] += quantity
                }
            }
            guard let label = plurality(runTally) else { return nil }
            return Trip(clusterID: label, days: runDays)
        }
    }

    /// A single `tripID?` per `DayKey` — the additive annotation the review overlay reads. A day not in
    /// any trip is simply absent (no home/no-location day carries a trip). Never a re-partition (§6.3).
    public static func tripIDByDay(_ trips: [Trip]) -> [DayKey: String] {
        var map: [DayKey: String] = [:]
        for trip in trips {
            for day in trip.days { map[day] = trip.id }
        }
        return map
    }

    /// The plurality cluster id in a tally: max count, ties broken by lower id (the canonical
    /// deterministic tie-break, §6). `nil` for an empty tally. Order-independent (a max over the set).
    private static func plurality(_ tally: [String: Int]) -> String? {
        var bestID: String?
        var bestCount = -1
        for (clusterID, quantity) in tally {
            if quantity > bestCount || (quantity == bestCount && clusterID < (bestID ?? clusterID)) {
                bestCount = quantity
                bestID = clusterID
            }
        }
        return bestID
    }
}
