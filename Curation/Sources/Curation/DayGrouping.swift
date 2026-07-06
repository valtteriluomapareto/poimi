//
//  DayGrouping.swift
//  Curation — the adaptive day-grouping of the timeline (issue #19).
//
//  THE headline curation aid (project-phases → "Timeline grouping (v1)"): a deterministic,
//  location-free heuristic that makes events stand out while quiet stretches stay compact.
//  A pure function of `[AssetRef]` + a threshold + a calendar — no PhotoKit, no UIKit, no
//  main-actor — so it runs in fast property tests with synthetic data.
//
//  The rule:
//    • Threshold N = 10 photos/day (tunable; spike-confirmed).
//    • A calendar day with ≥ N photos → its own group (a "busy day").
//    • A maximal run of consecutive days each with < N photos → one merged group.
//    • A run breaks on (a) a busy day, or (b) a calendar gap beyond `gapToleranceDays`
//      (so a quiet run stays tight rather than spanning an empty month).
//    • No per-group quota (D5).
//    • Assets with no capture date collect into one trailing "Undated" group.
//
//  Output is structural (asset ids + the `DayKey`s each group spans); localized section
//  titles are a UI concern formatted from `days` in Phase 2, kept out of the pure domain.
//

import Foundation

/// One adaptive day-group: a contiguous run the UI renders as a single titled section.
public struct DayGroup: Sendable, Identifiable, Equatable, Codable {
    /// Stable id within a slice — the first asset id in the run (the slice is ordered
    /// oldest → newest, so this is unique and order-stable).
    public let id: String
    /// The ordered asset ids in this group (a contiguous slice of the input).
    public let assetIDs: [String]
    /// The calendar days this group spans — the key surface for the §20 completion
    /// derivation (`section.days ⊆ doneDays`). Chronological, but a quiet run may be
    /// NON-contiguous: a tiny stranded day folds in across a gap (`foldTinyQuietRuns`),
    /// so don't assume consecutive days — use `days.first`/`days.last` for a range label.
    public let days: [DayKey]
    /// A single busy day (≥ N) standing alone, vs a merged quiet run.
    public let isBusyDay: Bool

    public var count: Int { assetIDs.count }
    public var isUndated: Bool { days == [.undated] }

    /// Up to `count` asset ids sampled **evenly across the whole group** (first + last included),
    /// preserving chronological order — a representative preview of the cluster for the Overview
    /// thumbnail strip (#35 paged-clusters). `count <= 0` → empty; `count >= self.count` → all ids.
    /// Indices are de-duplicated, so a group only slightly larger than `count` yields distinct thumbs
    /// (a repeated preview thumbnail would read as a bug), possibly returning fewer than `count`.
    public func evenlySampledIDs(_ count: Int) -> [String] {
        guard count > 0 else { return [] }
        let n = assetIDs.count
        guard n > count else { return assetIDs }
        if count == 1 { return [assetIDs[0]] }
        var seen = Set<Int>()
        var out: [String] = []
        out.reserveCapacity(count)
        for i in 0..<count {
            let idx = Int((Double(i) * Double(n - 1) / Double(count - 1)).rounded())
            if seen.insert(idx).inserted { out.append(assetIDs[idx]) }
        }
        return out
    }

    public init(id: String, assetIDs: [String], days: [DayKey], isBusyDay: Bool) {
        self.id = id
        self.assetIDs = assetIDs
        self.days = days
        self.isBusyDay = isBusyDay
    }
}

public enum DayGrouping {
    /// Default busy-day threshold (project-phases: N ≈ 10/day). The static fallback; production uses
    /// `adaptiveThreshold(for:)` instead so the "busy day" bar tracks how much this person shoots.
    public static let defaultThreshold = 10
    /// Max calendar gap (in days) before a quiet run breaks. `1` = consecutive/next-day.
    public static let defaultGapToleranceDays = 1
    /// Clamp bounds for `adaptiveThreshold` (busy-day DETECTION): a handful of photos is never a "busy
    /// day" (floor); a heavy-shooting year still gets standalone days, not one giant run (ceiling).
    /// Distinct from `minStandaloneQuietRun` below — that governs a quiet run's *section-worthiness*,
    /// this governs whether a *single day* is busy. (They're adjacent small numbers on purpose, not a typo.)
    public static let minAdaptiveThreshold = 9
    public static let maxAdaptiveThreshold = 100
    /// A quiet run with fewer photos than this is too small to be its own section — if the gap rule
    /// stranded it (a lone low-photo day between runs), it folds into the adjacent quiet run instead.
    /// (On-device call: 10 — a section worth its own header/peek/mark-done should hold ~10+ photos.)
    public static let minStandaloneQuietRun = 10

    /// Group a chronological slice into adaptive day-groups.
    ///
    /// - Parameters:
    ///   - assets: asset value models in any order — sorted internally (oldest → newest,
    ///     undated last), stable within a day.
    ///   - threshold: busy-day cutoff `N` (≥ N photos in a day → its own group).
    ///   - gapToleranceDays: max calendar gap before a quiet run breaks.
    ///   - calendar: injected so day bucketing + gap math use one explicit calendar /
    ///     timezone policy (the same one §20 completion uses). DST-safe — bucketing keys on
    ///     day components and gaps use `dateComponents(_:from:to:)`, never 24h arithmetic.
    /// - Returns: groups in chronological order (dated first, then one "Undated" group if
    ///   any). Concatenating their `assetIDs` yields every asset id in that chronological
    ///   order (undated last) — a partition of the input ids, regardless of input order.
    public static func groups(
        for assets: [AssetRef],
        threshold: Int = defaultThreshold,
        gapToleranceDays: Int = defaultGapToleranceDays,
        calendar: Calendar = .current
    ) -> [DayGroup] {
        guard !assets.isEmpty else { return [] }

        // Sort defensively (oldest → newest, undated last) then bucket by day, so callers
        // need not pre-sort and an out-of-order slice can't yield a negative gap.
        let buckets = bucketByDay(chronological(assets), calendar: calendar)
        let dayOrder = buckets.order
        let idsByDay = buckets.idsByDay
        let undatedIDs = buckets.undated

        var groups: [DayGroup] = []
        var quietRun: [DayKey] = []

        func flushQuietRun() {
            guard !quietRun.isEmpty else { return }
            let ids = quietRun.flatMap { idsByDay[$0] ?? [] }
            groups.append(DayGroup(
                id: ids.first ?? quietRun[0].description,
                assetIDs: ids,
                days: quietRun,
                isBusyDay: false
            ))
            quietRun = []
        }

        var previous: DayKey?
        for key in dayOrder {
            // A calendar gap beyond tolerance ends the current quiet run first.
            if let previous, dayGap(from: previous, to: key, calendar: calendar) > gapToleranceDays {
                flushQuietRun()
            }

            let count = idsByDay[key]?.count ?? 0
            if count >= threshold {
                flushQuietRun()
                let ids = idsByDay[key] ?? []
                groups.append(DayGroup(
                    id: ids.first ?? key.description,
                    assetIDs: ids,
                    days: [key],
                    isBusyDay: true
                ))
            } else {
                quietRun.append(key)
            }
            previous = key
        }
        flushQuietRun()
        groups = foldTinyQuietRuns(groups)

        if !undatedIDs.isEmpty {
            groups.append(DayGroup(
                id: undatedIDs[0],
                assetIDs: undatedIDs,
                days: [.undated],
                isBusyDay: false
            ))
        }
        return groups
    }

    /// The adaptive busy-day threshold: the **mean photos per ACTIVE day** (a calendar day with ≥1
    /// dated photo), clamped to `[minAdaptiveThreshold, maxAdaptiveThreshold]`. Photo-per-day counts are
    /// right-skewed (a few big trip days), so the mean sits *above* the typical day — only
    /// heavier-than-usual days clear the bar and stand alone, while ordinary days merge into runs, which
    /// is the intent. Undated assets and empty calendar days are excluded (they'd drag the mean down).
    /// Empty / all-undated input → the floor. Pure + deterministic; a percentile is the tunable
    /// alternative centre if we later want to move the bar (spike, D27).
    public static func adaptiveThreshold(for assets: [AssetRef], calendar: Calendar = .current) -> Int {
        var countByDay: [DayKey: Int] = [:]
        for asset in assets {
            let key = asset.dayKey(in: calendar)
            guard key != .undated else { continue }
            countByDay[key, default: 0] += 1
        }
        guard !countByDay.isEmpty else { return minAdaptiveThreshold }
        let mean = Double(countByDay.values.reduce(0, +)) / Double(countByDay.count)
        // Rounded to nearest; the [floor, ceiling] clamp makes the tie-direction moot.
        return Swift.min(maxAdaptiveThreshold, Swift.max(minAdaptiveThreshold, Int(mean.rounded())))
    }

    /// Convenience: group using the album's OWN adaptive busy-day threshold — the production entry, so a
    /// caller can't silently fall back to the static `defaultThreshold`. (Tests pass an explicit
    /// `threshold:` to `groups(for:…)` to pin exact behaviour.)
    public static func groups(
        adaptiveFor assets: [AssetRef],
        gapToleranceDays: Int = defaultGapToleranceDays,
        calendar: Calendar = .current
    ) -> [DayGroup] {
        groups(for: assets,
               threshold: adaptiveThreshold(for: assets, calendar: calendar),
               gapToleranceDays: gapToleranceDays,
               calendar: calendar)
    }

    /// Fold a tiny isolated quiet run (a low-photo day the gap rule stranded — e.g. a lone 6-photo run
    /// between a busy day and another run) into an adjacent quiet run, so it isn't its own section.
    /// A dated quiet run with `< minStandaloneQuietRun` photos folds into the preceding quiet run if
    /// there is one (pass 1, backward), else into the FOLLOWING quiet run (pass 2, forward — this
    /// catches a tiny run at the very start, or one wedged after a busy day). Busy days are never
    /// touched (folding a 6-photo orphan into a 40-photo day would erase that day's identity), so a
    /// tiny run with no quiet neighbour on EITHER side stays standalone — genuinely bracketed by busy
    /// days, or at the album's edge next to a busy day, or the sole group. This deliberately overrides
    /// the gap rule for these orphans: the merged run's day span may cross the gap, which reads as one
    /// quiet stretch.
    private static func foldTinyQuietRuns(_ groups: [DayGroup]) -> [DayGroup] {
        // Pass 1 — fold each tiny quiet run into the PRECEDING quiet run.
        var back: [DayGroup] = []
        for group in groups {
            if let last = back.last, !last.isBusyDay, !group.isBusyDay, group.count < minStandaloneQuietRun {
                back[back.count - 1] = mergedQuietRun(last, group)
            } else {
                back.append(group)
            }
        }
        // Pass 2 — a tiny quiet run that couldn't fold back (leading, or after a busy day) folds
        // FORWARD into the following quiet run. `pending` holds it until the next group is seen. Pass 1
        // already chained any consecutive tiny quiet runs into one, so `pending` is only ever set right
        // after a busy day or at the start — the busy-flush + trailing-flush branches cover every exit.
        var forward: [DayGroup] = []
        var pending: DayGroup?
        for group in back {
            if let held = pending {
                pending = nil
                if !group.isBusyDay {
                    forward.append(mergedQuietRun(held, group))   // held precedes group → chronological
                    continue
                }
                forward.append(held)                              // next is busy → give up, flush standalone
            }
            if !group.isBusyDay, group.count < minStandaloneQuietRun {
                pending = group
            } else {
                forward.append(group)
            }
        }
        if let held = pending { forward.append(held) }            // trailing tiny, no following quiet → stays
        return forward
    }

    /// Merge two adjacent (chronologically ordered `earlier` → `later`) groups into one quiet run.
    private static func mergedQuietRun(_ earlier: DayGroup, _ later: DayGroup) -> DayGroup {
        DayGroup(id: earlier.id,
                 assetIDs: earlier.assetIDs + later.assetIDs,
                 days: earlier.days + later.days,
                 isBusyDay: false)
    }

    /// Defensive chronological sort: oldest → newest, undated (nil capture date) last,
    /// stable within equal dates via the original index.
    private static func chronological(_ assets: [AssetRef]) -> [AssetRef] {
        assets.enumerated().sorted { lhs, rhs in
            switch (lhs.element.captureDate, rhs.element.captureDate) {
            case let (left?, right?): return left != right ? left < right : lhs.offset < rhs.offset
            case (nil, _?): return false          // undated sorts after every dated asset
            case (_?, nil): return true
            case (nil, nil): return lhs.offset < rhs.offset
            }
        }.map(\.element)
    }

    /// The day-bucketing result (a named type rather than a wide tuple).
    private struct DayBuckets {
        let order: [DayKey]
        let idsByDay: [DayKey: [String]]
        let undated: [String]
    }

    /// Bucket pre-sorted assets by calendar day, preserving first-seen order; undated assets
    /// are collected separately for the single trailing group.
    private static func bucketByDay(_ assets: [AssetRef], calendar: Calendar) -> DayBuckets {
        var order: [DayKey] = []
        var idsByDay: [DayKey: [String]] = [:]
        var undated: [String] = []
        for asset in assets {
            let key = asset.dayKey(in: calendar)
            if key == .undated {
                undated.append(asset.id)
                continue
            }
            if idsByDay[key] == nil {
                idsByDay[key] = []
                order.append(key)
            }
            idsByDay[key]?.append(asset.id)
        }
        return DayBuckets(order: order, idsByDay: idsByDay, undated: undated)
    }

    /// Whole-day gap from an earlier day to a later one, computed through the calendar so a
    /// 23/25-hour DST day still counts as one day. Returns `.max` if either side is
    /// undated (not reached here — undated is grouped separately).
    static func dayGap(from earlier: DayKey, to later: DayKey, calendar: Calendar) -> Int {
        guard let a = earlier.anchorDate(in: calendar),
              let b = later.anchorDate(in: calendar) else {
            return .max
        }
        return calendar.dateComponents([.day], from: a, to: b).day ?? 0
    }
}
