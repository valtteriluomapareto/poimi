//
//  MonthGrouping.swift
//  Curation — calendar-month aggregation for the album overview (issue #37).
//
//  The zoom-out overview level groups candidates by calendar month — coarser than #19's adaptive
//  day-groups (which the review grid uses), so a year reads as ~12 rows rather than dozens. Like
//  `DayGrouping`, it's a pure function of `[AssetRef]` + an injected `Calendar` (no PhotoKit/UIKit/
//  main-actor), so it runs in headless property tests.
//
//  Assets with no capture date are omitted: a range fetch never returns them, and the overview is a
//  dated coverage summary (the "Undated" bucket only matters inside the review grid, #19).
//

import Foundation

/// One calendar month's worth of candidates — a row in the overview (#37) and a bar in its
/// "where your photos pile up" histogram.
public struct MonthSummary: Sendable, Identifiable, Equatable, Codable {
    public let year: Int
    /// 1...12.
    public let month: Int
    /// The month's asset ids, chronological (oldest → newest) — a contiguous slice of the input.
    public let assetIDs: [String]

    /// Stable, sortable id: `"2025-07"`.
    public var id: String { String(format: "%04d-%02d", year, month) }
    public var count: Int { assetIDs.count }

    public init(year: Int, month: Int, assetIDs: [String]) {
        self.year = year
        self.month = month
        self.assetIDs = assetIDs
    }
}

public enum MonthGrouping {
    /// Group a candidate set into calendar-month summaries, oldest → newest. Undated assets are
    /// dropped. `calendar` is injected so the month bucketing uses the same timezone policy as the
    /// rest of the pipeline (#19 day-grouping, #20 completion).
    public static func summaries(for assets: [AssetRef], calendar: Calendar = .current) -> [MonthSummary] {
        let dated = assets
            .compactMap { asset in asset.captureDate.map { (asset.id, $0) } }
            .sorted { $0.1 < $1.1 }   // oldest → newest; same month is then contiguous

        var result: [MonthSummary] = []
        var currentYear = 0
        var currentMonth = 0
        var currentIDs: [String] = []

        func flush() {
            guard !currentIDs.isEmpty else { return }
            result.append(MonthSummary(year: currentYear, month: currentMonth, assetIDs: currentIDs))
        }

        for (id, date) in dated {
            let components = calendar.dateComponents([.year, .month], from: date)
            guard let year = components.year, let month = components.month else { continue }
            if year != currentYear || month != currentMonth {
                flush()
                currentYear = year
                currentMonth = month
                currentIDs = []
            }
            currentIDs.append(id)
        }
        flush()
        return result
    }
}
