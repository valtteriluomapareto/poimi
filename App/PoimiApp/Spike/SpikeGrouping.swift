// SPIKE — throwaway, delete in Phase 2
//
//  SpikeGrouping.swift
//  PoimiApp — Spike adaptive day-grouping (THROWAWAY housing, PRECURSOR logic)
//
//  THE headline Phase-0 finding: the flat chronological grid makes curating a year
//  *harder than Apple Photos*. This file is the spike's stand-in for the plan's
//  **adaptive day-grouping** (project-phases → "Timeline grouping (v1)"): the
//  deterministic, location-free heuristic that makes events stand out while quiet
//  stretches stay compact.
//
//  Although it lives in the throwaway tier for the spike, the *function* is written
//  as the clean precursor to `Curation`'s grouping — a **pure function of (capture
//  dates, N)** with no PhotoKit, no UIKit, no main-actor isolation, no `PHAsset`.
//  It takes value inputs (an `id` + a `Date` per asset) and returns value outputs
//  (groups of ids + display metadata). In Phase 1 this lifts into `Curation` almost
//  verbatim (swap the spike `(id, date)` tuples for `AssetRef`s) and gets the
//  property tests the boundary buys (off-by-one / empty-day / gap edges).
//
//  The rule (project-phases "Timeline grouping (v1)"):
//    • Threshold N = 10 photos/day (a tunable constant; the spike confirms it).
//    • A calendar day with ≥ N photos → its own group ("Sat 5 Jul · 53").
//    • A maximal run of consecutive days each with < N photos → one merged group
//      ("16–18 Mar · 7").
//    • A run breaks on (a) a busy day, or (b) a calendar gap with no photos beyond a
//      small tolerance (so quiet runs stay tight — no "Days 2–40" over an empty
//      month). The gap tolerance is spike-tunable.
//    • No per-group quota — show the count only.

import Foundation

/// One adaptive day-group: a contiguous run of the chronological slice that the UI
/// renders as a single titled section. Value-shaped (ids + display metadata, no
/// `PHAsset`), so the render layer stays PhotoKit-free.
struct AssetDayGroup: Identifiable, Equatable {
    /// Stable id for the group within a slice — the first asset id in the run, which
    /// is unique and order-stable (the slice is sorted oldest → newest). Lets
    /// `LazyVGrid` `Section`s and the prefetch window key off the group cheaply.
    let id: String

    /// The ordered asset ids in this group (a contiguous slice of `assetIDs`).
    let assetIDs: [String]

    /// Section header label — a single day ("Sat 5 Jul") or a date range
    /// ("16–18 Mar"), computed from the run's span. No quota, count rendered
    /// separately so the view can style it.
    let title: String

    /// Photo count in the group (== `assetIDs.count`), surfaced as " · 53".
    var count: Int { assetIDs.count }

    /// Whether this is a single busy day (≥ N) standing alone, vs a merged quiet
    /// run. Spike-only: lets the harness tint busy-day headers so the author can
    /// *see* the heuristic at work while re-evaluating the feel.
    let isBusyDay: Bool
}

/// The pure adaptive day-grouping. Throwaway housing, precursor logic.
///
/// Deliberately free of PhotoKit / UIKit / main-actor: it takes `(id, captureDate)`
/// pairs (already sorted oldest → newest, as the fetch delivers them) and the
/// threshold `N`, and returns `[AssetDayGroup]`. That is the exact shape the
/// `Curation` function will have, minus the `(id, Date)` → `AssetRef` swap.
enum SpikeGrouping {

    /// Default busy-day threshold (project-phases: N ≈ 10/day). A constant here; the
    /// spike confirms the value on a real year.
    static let defaultThreshold = 10

    /// Gap tolerance in days: a quiet run breaks when the calendar gap to the next
    /// photographed day exceeds this, so a quiet run stays tight rather than spanning
    /// an empty month. `1` means "consecutive or next-day"; a 2-day gap breaks the
    /// run. Spike-tunable.
    static let defaultGapToleranceDays = 1

    /// Group a chronological slice into adaptive day-groups.
    ///
    /// - Parameters:
    ///   - assets: `(id, captureDate)` pairs, **sorted oldest → newest** (the fetch
    ///     order). `captureDate` is the asset's creation date; a `nil` capture date
    ///     is bucketed under a sentinel "Unknown date" group at its position in the
    ///     order (it can't merge into a dated run since it has no day).
    ///   - threshold: busy-day cutoff `N` (≥ N photos in a day → its own group).
    ///   - gapToleranceDays: max calendar gap (in days) before a quiet run breaks.
    ///   - calendar: injected so grouping is testable with a fixed calendar/timezone
    ///     (the precursor's seam; the spike passes `.current`).
    /// - Returns: groups in chronological order; concatenating their `assetIDs`
    ///   reproduces the input order exactly (the grid still scrolls as one flow).
    static func groups(
        for assets: [(id: String, captureDate: Date?)],
        threshold: Int = defaultThreshold,
        gapToleranceDays: Int = defaultGapToleranceDays,
        calendar: Calendar = .current
    ) -> [AssetDayGroup] {
        guard !assets.isEmpty else { return [] }

        // 1. Bucket the slice by calendar day, preserving chronological order. A `nil`
        //    capture date gets a distinct sentinel day (keyed by its slice index) so
        //    it never merges into a dated run and the grouping stays a pure function
        //    of the inputs — calling it twice yields identical ids.
        var dayOrder: [Day] = []
        var idsByDay: [Day: [String]] = [:]
        for (index, asset) in assets.enumerated() {
            let day = Day(date: asset.captureDate, sentinelIndex: index, calendar: calendar)
            if idsByDay[day] == nil {
                idsByDay[day] = []
                dayOrder.append(day)
            }
            idsByDay[day]?.append(asset.id)
        }

        // 2. Walk the days in order, emitting a busy day as its own group and
        //    accumulating consecutive quiet days into a merged run that breaks on a
        //    busy day or a calendar gap beyond tolerance.
        var groups: [AssetDayGroup] = []
        var quietRun: [Day] = []

        func flushQuietRun() {
            guard !quietRun.isEmpty else { return }
            let ids = quietRun.flatMap { idsByDay[$0] ?? [] }
            groups.append(AssetDayGroup(
                id: ids.first ?? UUID().uuidString,
                assetIDs: ids,
                title: rangeTitle(from: quietRun.first!, to: quietRun.last!, calendar: calendar),
                isBusyDay: false
            ))
            quietRun = []
        }

        var previousDay: Day?
        for day in dayOrder {
            // A calendar gap beyond tolerance ends the current quiet run before this
            // day starts a fresh one (keeps quiet runs tight across empty stretches).
            if let previousDay,
               day.dayGap(since: previousDay, calendar: calendar) > gapToleranceDays {
                flushQuietRun()
            }

            let count = idsByDay[day]?.count ?? 0
            if day.isDated && count >= threshold {
                // Busy day → its own group. Ends any open quiet run first.
                flushQuietRun()
                let ids = idsByDay[day] ?? []
                groups.append(AssetDayGroup(
                    id: ids.first ?? UUID().uuidString,
                    assetIDs: ids,
                    title: singleDayTitle(day, calendar: calendar),
                    isBusyDay: true
                ))
            } else {
                // Quiet day (or undated) → accumulate into the running merge.
                quietRun.append(day)
            }
            previousDay = day
        }
        flushQuietRun()
        return groups
    }

    // MARK: - Day key

    /// A calendar day, or a sentinel for an undated asset. Hashing/equality is by the
    /// integer day components (year/month/day) so assets land in the same bucket
    /// regardless of time-of-day; undated assets each get a unique sentinel so they
    /// never merge with a dated run or each other's gaps.
    private struct Day: Hashable {
        let year: Int
        let month: Int
        let day: Int
        /// `true` for a real calendar day; `false` for the undated sentinel.
        let isDated: Bool
        /// Disambiguates undated sentinels — the asset's slice index, so each undated
        /// asset day is unique *and deterministic* (the function stays pure). Zero and
        /// ignored for dated days (they equate by year/month/day).
        private let sentinel: Int

        init(date: Date?, sentinelIndex: Int, calendar: Calendar) {
            if let date {
                let c = calendar.dateComponents([.year, .month, .day], from: date)
                year = c.year ?? 0
                month = c.month ?? 0
                day = c.day ?? 0
                isDated = true
                sentinel = 0
            } else {
                year = 0; month = 0; day = 0
                isDated = false
                sentinel = sentinelIndex
            }
        }

        /// Midday anchor for this day, used for gap/label date math (midday avoids
        /// DST edge surprises). `nil` for the undated sentinel.
        func date(in calendar: Calendar) -> Date? {
            guard isDated else { return nil }
            return calendar.date(from: DateComponents(
                year: year, month: month, day: day, hour: 12))
        }

        /// Whole-day gap to a prior day (`self` is later). Returns a large value when
        /// either side is undated so an undated boundary always breaks the run.
        func dayGap(since other: Day, calendar: Calendar) -> Int {
            guard isDated, other.isDated,
                  let a = other.date(in: calendar), let b = date(in: calendar) else {
                return Int.max
            }
            return calendar.dateComponents([.day], from: a, to: b).day ?? 0
        }
    }

    // MARK: - Labels

    private static func singleDayTitle(_ day: Day, calendar: Calendar) -> String {
        guard day.isDated, let date = day.date(in: calendar) else { return "Unknown date" }
        return Self.dayFormatter(calendar: calendar).string(from: date)   // "Sat 5 Jul"
    }

    /// Range title: collapses to a single day when the run is one day, else
    /// "16–18 Mar" / "29 Dec – 2 Jan" depending on whether month/year differ.
    private static func rangeTitle(from first: Day, to last: Day, calendar: Calendar) -> String {
        guard first.isDated, let firstDate = first.date(in: calendar) else {
            return "Unknown date"
        }
        guard last.isDated, let lastDate = last.date(in: calendar) else {
            // Mixed/undated run — label by what we can.
            return Self.dayFormatter(calendar: calendar).string(from: firstDate)
        }
        if first == last {
            return Self.dayFormatter(calendar: calendar).string(from: firstDate)
        }
        if first.month == last.month && first.year == last.year {
            // "16–18 Mar": day-only start, day + month end.
            let startDay = Self.dayNumberFormatter(calendar: calendar).string(from: firstDate)
            let endDayMonth = Self.dayMonthFormatter(calendar: calendar).string(from: lastDate)
            return "\(startDay)–\(endDayMonth)"
        }
        // Crosses a month (or year) boundary: spell both ends ("29 Dec – 2 Jan").
        let start = Self.dayMonthFormatter(calendar: calendar).string(from: firstDate)
        let end = Self.dayMonthFormatter(calendar: calendar).string(from: lastDate)
        return "\(start) – \(end)"
    }

    // MARK: - Formatters (cached; the spike re-evaluates the label feel)

    /// "Sat 5 Jul" — weekday + day + abbreviated month, no quota.
    private static func dayFormatter(calendar: Calendar) -> DateFormatter {
        let f = DateFormatter()
        f.calendar = calendar
        f.locale = .autoupdatingCurrent
        f.setLocalizedDateFormatFromTemplate("EEE d MMM")
        return f
    }

    /// "5 Jul" — day + abbreviated month.
    private static func dayMonthFormatter(calendar: Calendar) -> DateFormatter {
        let f = DateFormatter()
        f.calendar = calendar
        f.locale = .autoupdatingCurrent
        f.setLocalizedDateFormatFromTemplate("d MMM")
        return f
    }

    /// "16" — day number only (start of a same-month range).
    private static func dayNumberFormatter(calendar: Calendar) -> DateFormatter {
        let f = DateFormatter()
        f.calendar = calendar
        f.locale = .autoupdatingCurrent
        f.setLocalizedDateFormatFromTemplate("d")
        return f
    }
}
