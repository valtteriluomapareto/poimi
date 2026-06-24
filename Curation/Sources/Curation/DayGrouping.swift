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
    /// derivation (`section.days ⊆ doneDays`).
    public let days: [DayKey]
    /// A single busy day (≥ N) standing alone, vs a merged quiet run.
    public let isBusyDay: Bool

    public var count: Int { assetIDs.count }
    public var isUndated: Bool { days == [.undated] }

    public init(id: String, assetIDs: [String], days: [DayKey], isBusyDay: Bool) {
        self.id = id
        self.assetIDs = assetIDs
        self.days = days
        self.isBusyDay = isBusyDay
    }
}

public enum DayGrouping {
    /// Default busy-day threshold (project-phases: N ≈ 10/day).
    public static let defaultThreshold = 10
    /// Max calendar gap (in days) before a quiet run breaks. `1` = consecutive/next-day.
    public static let defaultGapToleranceDays = 1

    /// Group a chronological slice into adaptive day-groups.
    ///
    /// - Parameters:
    ///   - assets: asset value models, **sorted oldest → newest** (the fetch order).
    ///   - threshold: busy-day cutoff `N` (≥ N photos in a day → its own group).
    ///   - gapToleranceDays: max calendar gap before a quiet run breaks.
    ///   - calendar: injected so day bucketing + gap math use one explicit calendar /
    ///     timezone policy (the same one §20 completion uses). DST-safe — bucketing keys on
    ///     day components and gaps use `dateComponents(_:from:to:)`, never 24h arithmetic.
    /// - Returns: groups in chronological order (dated first, then one "Undated" group if
    ///   any). Concatenating their `assetIDs` reproduces the input order exactly.
    public static func groups(
        for assets: [AssetRef],
        threshold: Int = defaultThreshold,
        gapToleranceDays: Int = defaultGapToleranceDays,
        calendar: Calendar = .current
    ) -> [DayGroup] {
        guard !assets.isEmpty else { return [] }

        // Bucket by day, preserving first-seen (chronological, given sorted input) order;
        // collect undated assets separately for one trailing group.
        var dayOrder: [DayKey] = []
        var idsByDay: [DayKey: [String]] = [:]
        var undatedIDs: [String] = []
        for asset in assets {
            let key = DayKey(date: asset.captureDate, calendar: calendar)
            if key == .undated {
                undatedIDs.append(asset.id)
                continue
            }
            if idsByDay[key] == nil {
                idsByDay[key] = []
                dayOrder.append(key)
            }
            idsByDay[key]?.append(asset.id)
        }

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
