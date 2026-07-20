//
//  ReviewTimeline.swift
//  Curation — the location-aware review timeline: trip/visit clusters interleaved with date day-groups
//  (issue #130, the productization of the #129 spike; §6 preprocessing).
//
//  The one merge that turns the date-only v1 timeline into the v1.1 location timeline the signed-off
//  Overview/grid designs render (Paper `3ZP-0` / `43P-0`). It is an **additive overlay** over the
//  existing `DayGrouping` output (D33), not a re-partition:
//
//    • The unit is still the `DayGroup`. A trip only *relabels* a contiguous set of WHOLE day-groups
//      into one reviewable cluster — it never splits, merges partial, or moves an asset between
//      day-groups. So the done-day atom (`section.days ⊆ doneDays`, `Completion`) is untouched: a
//      trip's done-state is simply "all its day-groups' days are done" (Phase 3 wiring).
//    • Ownership rule: a `DayGroup` is owned by the UNIQUE trip whose away-day span [first…last]
//      contains ALL of the group's days. A group that straddles a span edge (partly outside) and the
//      trailing `.undated` group stay `.day` — the safe, no-split choice (a rare straddle means a trip
//      under-counts at its edge; a known v1.1 limitation, §6).
//    • With location OFF (or when no trips are found) the timeline is byte-identical to
//      `DayGrouping.groups(adaptiveFor:)` wrapped as `.day` clusters — the v1 behavior and the v1.1
//      gate, pinned by `ReviewTimelineTests.noTripsEqualsDayGrouping`.
//
//  Pure + string-free (D14/D21): the domain classifies a trip's *shape* (`TripShape`); the app tier
//  composes the localized sentence ("Week in …", "Weekend in …", "Visit to …") from the shape + the
//  geocoded name (D18). No user-facing text lives here.
//

import Foundation

/// The duration "shape" of a trip, derived purely from its away-day span. The app tier maps this to the
/// localized location sentence; the domain stays string-free (D14/D21).
public enum TripShape: Sendable, Equatable, Hashable, Codable {
    /// A single away day (→ "Visit to …").
    case visit
    /// A 2–3 day run that includes a calendar weekend day (→ "Weekend in …").
    case weekend
    /// A 2–4 day run with no weekend day, or a 4-day run (→ "Short trip to …").
    case shortTrip
    /// A 5–10 day run (→ "Week in …").
    case week
    /// An 11+ day run (→ "N days in …"). Carries the away-day count for the label.
    case longer(days: Int)

    /// Classify by the number of AWAY days (`Trip.days.count`), NOT the calendar span — a trip that
    /// bridges a neutral (no-located-photo) day counts only the away days it actually spans, so a
    /// two-photo-day trip across a five-day lull is a "weekend," not a "week." Weekend detection is
    /// calendar-honest (`Calendar.isDateInWeekend`), so a locale whose weekend isn't Sat/Sun still
    /// classifies correctly. Deterministic and order-independent (a count + an any-match).
    public static func classify(days: [DayKey], calendar: Calendar = .current) -> TripShape {
        let dated = days.filter { $0 != .undated }
        switch dated.count {
        case ...1:
            return .visit
        case 2...3:
            let hasWeekend = dated.contains { day in
                guard let date = day.anchorDate(in: calendar) else { return false }
                return calendar.isDateInWeekend(date)
            }
            return hasWeekend ? .weekend : .shortTrip
        case 4:
            return .shortTrip
        case 5...10:
            return .week
        default:
            return .longer(days: dated.count)
        }
    }
}

/// A trip/visit cluster in the review timeline: a contiguous set of WHOLE day-groups that fall within
/// one trip's day-span, presented as a single reviewable unit (one Overview strip, one grid page). It
/// never splits or re-cuts a day-group — the day-group stays the atom of done-tracking (D33) — so its
/// members are exactly the union of its constituent day-groups.
public struct TripCluster: Sendable, Identifiable, Equatable, Codable {
    /// The trip's stable id (`Trip.id` = `"<clusterID>@<startDay>"`).
    public let id: String
    /// The labeling place cluster's medoid id (`Trip.clusterID`) — the stable handle the app tier uses
    /// to look up the geocoded name (D18). NOT a re-derived medoid.
    public let clusterID: String
    /// The trip's duration shape, from its away-day span.
    public let shape: TripShape
    /// The constituent day-groups, chronological — the done-tracking substrate, preserved intact.
    public let dayGroups: [DayGroup]
    /// The labeling place cluster's medoid COORDINATE — carried so the app-tier naming pass can
    /// reverse-geocode without re-running clustering to recover it (the double-clustering fix). `nil`
    /// when a `TripCluster` is built without a cluster set (some unit tests) or when the trip's
    /// `clusterID` isn't found in `assemble`'s `medoidByCluster` (a defensive miss / empty default);
    /// the naming pass simply skips a `nil`-medoid trip and it stays unlabeled.
    public let medoid: Coordinate?

    /// The merged member ids, chronological (union of the day-groups).
    public var assetIDs: [String] { dayGroups.flatMap(\.assetIDs) }
    /// Every calendar day this cluster covers (union of the day-groups' days), chronological.
    public var days: [DayKey] { dayGroups.flatMap(\.days) }
    /// The member count.
    public var count: Int { dayGroups.reduce(0) { $0 + $1.count } }

    public init(id: String, clusterID: String, shape: TripShape, dayGroups: [DayGroup],
                medoid: Coordinate? = nil) {
        self.id = id
        self.clusterID = clusterID
        self.shape = shape
        self.dayGroups = dayGroups
        self.medoid = medoid
    }
}

/// One element of the review timeline: either a plain date day-group (the v1 unit) or a trip/visit
/// cluster (the v1.1 location overlay). Passthrough accessors (`assetIDs`/`days`/`count`/`dayGroups`)
/// mean consumers that only need members or the done substrate never branch on the case.
public enum ReviewCluster: Sendable, Identifiable, Equatable, Codable {
    case day(DayGroup)
    case trip(TripCluster)

    public var id: String {
        switch self {
        case let .day(group): return group.id
        case let .trip(trip): return trip.id
        }
    }
    /// The member asset ids, chronological.
    public var assetIDs: [String] {
        switch self {
        case let .day(group): return group.assetIDs
        case let .trip(trip): return trip.assetIDs
        }
    }
    /// The calendar days this cluster covers (the done-tracking key surface).
    public var days: [DayKey] {
        switch self {
        case let .day(group): return group.days
        case let .trip(trip): return trip.days
        }
    }
    /// The member count.
    public var count: Int {
        switch self {
        case let .day(group): return group.count
        case let .trip(trip): return trip.count
        }
    }
    /// The constituent day-groups — one for a date cluster, the trip's run for a trip. The done atom
    /// stays the day-group (D33): `DoneStore`/`Completion` operate over these unchanged.
    public var dayGroups: [DayGroup] {
        switch self {
        case let .day(group): return [group]
        case let .trip(trip): return trip.dayGroups
        }
    }
    /// The trip, if this is a trip/visit cluster (`nil` for a plain date cluster).
    public var tripCluster: TripCluster? {
        if case let .trip(trip) = self { return trip }
        return nil
    }
    /// Whether this is the trailing undated bucket (never a trip). Mirrors `DayGroup.isUndated`.
    public var isUndated: Bool { days == [.undated] }
    /// The cluster's first calendar day — the Overview's drill target + chronological anchor.
    public var firstDay: DayKey? { days.first }

    /// Up to `count` asset ids sampled evenly across the whole cluster (first + last included) — the
    /// Overview thumbnail-strip preview (#35). Delegates to the day-group's sampler for a date cluster;
    /// for a trip it samples across the merged members via the same algorithm.
    public func evenlySampledIDs(_ count: Int) -> [String] {
        switch self {
        case let .day(group):
            return group.evenlySampledIDs(count)
        case let .trip(trip):
            // Reuse the pinned sampler over the trip's merged ids (a throwaway carrier — cheap; called
            // once per visible cluster, off the body).
            return DayGroup(id: trip.id, assetIDs: trip.assetIDs, days: trip.days, isBusyDay: false)
                .evenlySampledIDs(count)
        }
    }
}

public enum ReviewTimeline {
    /// The default trip gap tolerance (mirrors `TripOverlay`).
    public static let defaultTripGapToleranceDays = TripOverlay.defaultGapToleranceDays

    /// The production entry: assemble the review timeline from an album's assets.
    ///
    /// With `locationEnabled == false` the result is byte-identical to `DayGrouping.groups(adaptiveFor:)`
    /// wrapped as `.day` clusters — the v1 date-only behavior and the v1.1 gate. With it on, trips
    /// (`PlaceClustering` → `homeCluster` → `TripOverlay`) relabel the day-groups they span.
    ///
    /// - Important: ONE `calendar` threads through every sub-step (clustering, home, trips, grouping)
    ///   so all the day keys line up — a mismatch silently misaligns days.
    /// - Note: `DayGrouping` keeps its own gap tolerance (the shipped date-grouping); `tripGapToleranceDays`
    ///   governs only trip-run bridging.
    public static func clusters(
        for assets: [AssetRef],
        eps: Double = PlaceClustering.defaultEps,
        minPts: Int? = nil,
        tripGapToleranceDays: Int = defaultTripGapToleranceDays,
        calendar: Calendar = .current,
        locationEnabled: Bool = true
    ) -> [ReviewCluster] {
        timeline(for: assets, eps: eps, minPts: minPts, tripGapToleranceDays: tripGapToleranceDays,
                 calendar: calendar, locationEnabled: locationEnabled).clusters
    }

    /// The full review timeline: the `clusters` PLUS a per-DATE-cluster **locality** map (#201 level A) —
    /// `cluster.id → .mostlyHome / .mostlyAway` for the everyday days confident enough to label (only
    /// those two are stored; a `.mixed`/`.unknown` day is absent, so the caller defaults to `.unknown`
    /// and falls back to its media caption). Trips are excluded (their place sentence is the personality).
    /// Locality is cheap set-math over the home cluster + no-location bucket ALREADY computed in this
    /// pass — no extra clustering. `clusters(for:)` is the thin convenience over this.
    public static func timeline(
        for assets: [AssetRef],
        eps: Double = PlaceClustering.defaultEps,
        minPts: Int? = nil,
        tripGapToleranceDays: Int = defaultTripGapToleranceDays,
        calendar: Calendar = .current,
        locationEnabled: Bool = true
    ) -> (clusters: [ReviewCluster], localityByCluster: [String: Locality]) {
        let dayGroups = DayGrouping.groups(adaptiveFor: assets, calendar: calendar)
        guard locationEnabled else { return (dayGroups.map(ReviewCluster.day), [:]) }

        let placeClusters = PlaceClustering.clusters(for: assets, eps: eps, minPts: minPts, calendar: calendar)
        let home = PlaceClustering.homeCluster(placeClusters.clusters, assets: assets, calendar: calendar)
        let trips = TripOverlay.trips(
            assets: assets, clusters: placeClusters, home: home,
            gapToleranceDays: tripGapToleranceDays, calendar: calendar
        )
        // The place medoid COORDINATE per cluster id — carried onto each trip so the app-tier naming
        // pass geocodes without re-clustering to recover it (the double-clustering fix).
        let medoidByCluster = Dictionary(placeClusters.clusters.map { ($0.id, $0.medoid) },
                                         uniquingKeysWith: { first, _ in first })
        let clusters = assemble(dayGroups: dayGroups, trips: trips,
                                medoidByCluster: medoidByCluster, calendar: calendar)

        // Per-date-cluster locality (#201): home membership vs the no-location bucket, coverage-gated.
        let homeIDs = Set(home?.assetIDs ?? [])
        let noLocationIDs = Set(placeClusters.noLocationIDs)
        var localityByCluster: [String: Locality] = [:]
        for cluster in clusters where cluster.tripCluster == nil {
            let locality = Locality.of(clusterAssetIDs: cluster.assetIDs,
                                       homeAssetIDs: homeIDs, noLocationIDs: noLocationIDs)
            // Store only the confident, labelable states (keeps the map + cache small).
            if locality == .mostlyHome || locality == .mostlyAway {
                localityByCluster[cluster.id] = locality
            }
        }
        return (clusters, localityByCluster)
    }

    /// The pure merge: fold whole day-groups into trip clusters, leaving the rest as date clusters.
    ///
    /// A day-group is owned by the (unique) trip whose day-span [first…last] contains ALL of its days;
    /// a straddling group (partly outside a span) and the undated group stay `.day` — never split (D33).
    /// Order-preserving: a single pass over the already-chronological `dayGroups`, each trip emitted at
    /// its first owned group. No trips ⇒ `dayGroups.map(.day)` verbatim.
    public static func assemble(
        dayGroups: [DayGroup],
        trips: [Trip],
        medoidByCluster: [String: Coordinate] = [:],
        calendar: Calendar = .current
    ) -> [ReviewCluster] {
        guard !trips.isEmpty else { return dayGroups.map(ReviewCluster.day) }

        let tripByID = Dictionary(trips.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // Each trip's away-day span [lo…hi]. Trips are contiguous runs separated by home days, so the
        // spans never overlap — a group falls within at most one.
        let spans: [TripSpan] = trips.compactMap { trip in
            let dated = trip.days.filter { $0 != .undated }
            guard let lo = dated.min(), let hi = dated.max() else { return nil }
            return TripSpan(id: trip.id, lo: lo, hi: hi)
        }

        func owner(of group: DayGroup) -> String? {
            let dated = group.days.filter { $0 != .undated }
            // An undated group (or one that mixes in undated) is never owned.
            guard dated.count == group.days.count, let gLo = dated.min(), let gHi = dated.max() else {
                return nil
            }
            return spans.first { $0.lo <= gLo && gHi <= $0.hi }?.id
        }

        // Collect each trip's owned groups in chronological (input) order.
        var groupsByTrip: [String: [DayGroup]] = [:]
        var ownerByGroupID: [String: String] = [:]
        for group in dayGroups where owner(of: group) != nil {
            let tid = owner(of: group)!
            groupsByTrip[tid, default: []].append(group)
            ownerByGroupID[group.id] = tid
        }

        var out: [ReviewCluster] = []
        var emitted = Set<String>()
        for group in dayGroups {
            guard let tid = ownerByGroupID[group.id] else {
                out.append(.day(group))
                continue
            }
            // Emit the trip once, at its first owned group; later owned groups are already folded in.
            guard emitted.insert(tid).inserted, let trip = tripByID[tid] else { continue }
            let owned = groupsByTrip[tid] ?? [group]
            let shape = TripShape.classify(days: trip.days, calendar: calendar)
            out.append(.trip(TripCluster(
                id: trip.id, clusterID: trip.clusterID, shape: shape, dayGroups: owned,
                medoid: medoidByCluster[trip.clusterID]
            )))
        }
        return out
    }

    /// A trip's away-day span [lo…hi] — a named type rather than a wide tuple (the `DayGrouping`
    /// convention). Spans never overlap, so a day-group falls within at most one.
    private struct TripSpan {
        let id: String
        let lo: DayKey
        let hi: DayKey
    }
}
