//
//  NewAlbumDraft.swift
//  PoimiApp — the in-flight new-album configuration (issue #33, D2; architecture §8).
//
//  The editable model behind the setup form: name, period, target count, exclusion settings, and
//  the export target (a new album, or an existing one to add to). Pure value type with a
//  deterministic default (the prior calendar year), so the defaulting is unit-tested without a view.
//

import Foundation

struct NewAlbumDraft: Equatable {
    var title: String
    /// Source period. `rangeEnd` is **end-exclusive** — `[rangeStart, rangeEnd)` — matching the
    /// fetch contract (#34); the default spans a full calendar year.
    var rangeStart: Date
    var rangeEnd: Date
    var targetCount: Int
    var excludeScreenshots: Bool
    /// `PHAssetCollection` localIdentifiers to drop from the source pool (WhatsApp, Downloads, …).
    var excludedAlbumIDs: Set<String>
    /// Include videos in the candidate set (#125). Opt-in — defaults `false` (images-only), matching
    /// `CurationProject.includeVideos`.
    var includeVideos: Bool
    /// The export target: `nil` → create a new album on first export (D19); set → add to this
    /// existing album.
    var targetAlbumID: String?

    /// The default new album: the **prior full calendar year**, screenshots excluded, target 100,
    /// exporting to a new album. Deterministic given `now`/`calendar` (injected in tests).
    static func priorCalendarYear(now: Date, calendar: Calendar) -> NewAlbumDraft {
        let year = calendar.component(.year, from: now) - 1
        let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1)) ?? now
        let endExclusive = calendar.date(from: DateComponents(year: year + 1, month: 1, day: 1)) ?? now
        return NewAlbumDraft(
            // `String(year)` (not `\(year)`) so the year interpolates ungrouped — a bare `\(Int)` in a
            // localized string groups by locale ("2 024"), which is wrong for a year.
            title: String(localized: "Best of \(String(year))", comment: "Default album name for a calendar year, e.g. “Best of 2025”"),
            rangeStart: start,
            rangeEnd: endExclusive,
            targetCount: 100,
            excludeScreenshots: true,
            excludedAlbumIDs: [],
            includeVideos: false,
            targetAlbumID: nil)
    }

    /// The **inclusive** last day to show in the UI for an end-exclusive `rangeEnd` (one day
    /// before it). Pure + calendar-injectable so the off-by-one is unit-tested, not buried in a view.
    static func inclusiveEndDay(forExclusiveEnd end: Date, calendar: Calendar) -> Date {
        calendar.date(byAdding: .day, value: -1, to: end) ?? end
    }

    /// The end-exclusive `rangeEnd` for an inclusive last day picked in the UI (one day after it).
    /// Inverse of `inclusiveEndDay(forExclusiveEnd:calendar:)` for day-aligned dates.
    static func exclusiveEnd(forInclusiveDay day: Date, calendar: Calendar) -> Date {
        calendar.date(byAdding: .day, value: 1, to: day) ?? day
    }
}
