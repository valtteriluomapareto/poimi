//
//  ClusterIndexBuilderTests.swift
//  PoimiAppTests — the overview's month-sectioning of day-clusters (#37, design 3BL).
//
//  ClusterIndexBuilder is the thin, pure layer between the store's `[DayGroup]` and the cluster-index
//  Overview: it buckets clusters by calendar month, formats each label once, and carries the totals
//  the header + bar chart need. These pin the sectioning, ordering, the undated bucket, and the totals
//  (the pure `ClusterState` derivation is covered in the Curation tier).
//

import Testing
import Foundation
import Curation
@testable import PoimiApp

@Suite("ClusterIndexBuilder — month-sectioned cluster index (#37)")
struct ClusterIndexBuilderTests {
    private let cal = utcCalendar()
    private let locale = Locale(identifier: "en_US")

    private func group(_ id: String, _ year: Int, _ month: Int, _ day: Int, count: Int) -> ReviewCluster {
        .day(DayGroup(id: id,
                      assetIDs: (0..<count).map { "\(id)-\($0)" },
                      days: [.day(year: year, month: month, day: day)],
                      isBusyDay: true))
    }

    private func undatedGroup(count: Int) -> ReviewCluster {
        .day(DayGroup(id: "undated", assetIDs: (0..<count).map { "u\($0)" }, days: [.undated], isBusyDay: false))
    }

    /// A dated asset at a given day + hour (UTC), optionally a video / favorite — for the caption path.
    private func asset(_ id: String, _ y: Int, _ mo: Int, _ d: Int, hour: Int,
                       video: Bool = false, favorite: Bool = false) -> AssetRef {
        let date = cal.date(from: DateComponents(year: y, month: mo, day: d, hour: hour))!
        return AssetRef(id: id, captureDate: date, isFavorite: favorite, isVideo: video)
    }

    @Test("clusters group into month sections in chronological order, with the header/chart totals")
    func sectionsByMonth() {
        let groups = [
            group("a", 2025, 2, 1, count: 6),
            group("b", 2025, 2, 5, count: 8),
            group("c", 2025, 5, 10, count: 5)
        ]
        let index = ClusterIndexBuilder.build(from: groups, calendar: cal, locale: locale)

        #expect(index.sections.map(\.title) == ["February", "May"])
        #expect(index.sections.map { $0.rows.count } == [2, 1])
        #expect(index.totalClusters == 3)
    }

    @Test("orderedIDs + totalClusters mirror the clusters exactly — the pacing-denominator contract (#200)")
    func pacingDenominatorContract() {
        // The grid builds its "~N est." denominator as `clusters.flatMap(\.assetIDs)` + gates on
        // `clusters.count`; the Overview feeds `index.orderedIDs` + `index.totalClusters`. If these ever
        // diverge, the two projections silently disagree — the whole point of the shared readout. Lock it,
        // including the undated tail (whose ids must still land in the frontier universe).
        let groups = [
            group("a", 2025, 2, 1, count: 6),
            group("b", 2025, 5, 10, count: 3),
            undatedGroup(count: 2)
        ]
        let index = ClusterIndexBuilder.build(from: groups, calendar: cal, locale: locale)
        #expect(index.orderedIDs == groups.flatMap(\.assetIDs))
        #expect(index.totalClusters == groups.count)
    }

    @Test("a single-cluster album reports totalClusters == 1 (the >1 projection-gate boundary)")
    func singleClusterGate() {
        let index = ClusterIndexBuilder.build(
            from: [group("solo", 2025, 3, 3, count: 4)], calendar: cal, locale: locale)
        #expect(index.totalClusters == 1)
    }

    @Test("each row carries its formatted title, representative thumb, and drill target")
    func rowContents() throws {
        let groups = [group("a", 2025, 2, 1, count: 6)]
        let index = ClusterIndexBuilder.build(from: groups, calendar: cal, locale: locale)
        let row = try #require(index.sections.first?.rows.first)

        #expect(row.title == DayGroupHeader.title(for: groups[0], calendar: cal, locale: locale))
        #expect(row.thumbID == "a-0")                      // the cluster's first asset
        #expect(row.firstDay == .day(year: 2025, month: 2, day: 1))
        #expect(row.count == 6)
    }

    @Test("same month in DIFFERENT years are distinct sections, and the header shows the year (#119)")
    func yearBoundarySplitsSections() {
        // Two Februaries a year apart must NOT collapse into one section (keyed on "yyyy-MM"). And since
        // the album spans >1 year, the headers include the year so they aren't ambiguously both "February".
        let groups = [
            group("a", 2024, 2, 10, count: 6),
            group("b", 2025, 2, 10, count: 6)
        ]
        let index = ClusterIndexBuilder.build(from: groups, calendar: cal, locale: locale)
        #expect(index.sections.count == 2)
        #expect(index.sections.map(\.id) == ["2024-02", "2025-02"])
        #expect(index.sections.map(\.title) == ["February 2024", "February 2025"])
    }

    @Test("year appears in month headers only when the album spans multiple years (#119)")
    func yearShownOnlyForMultiYearAlbums() {
        // Single-year album → bare month (no noise). The undated bucket doesn't count as a "year", so an
        // otherwise single-year album with undated photos still omits the year.
        let singleYear = ClusterIndexBuilder.build(
            from: [group("a", 2025, 2, 1, count: 3), group("b", 2025, 11, 1, count: 3), undatedGroup(count: 2)],
            calendar: cal, locale: locale)
        #expect(singleYear.sections.map(\.title) == ["February", "November", "Undated"])
        // Multi-year album → every month header carries its year.
        let multiYear = ClusterIndexBuilder.build(
            from: [group("a", 2024, 12, 20, count: 3), group("b", 2025, 1, 5, count: 3)],
            calendar: cal, locale: locale)
        #expect(multiYear.sections.map(\.title) == ["December 2024", "January 2025"])

        // Three+ years → all year-qualified (guards against a `== 2` off-by-one instead of `> 1`).
        let threeYear = ClusterIndexBuilder.build(
            from: [group("a", 2023, 6, 1, count: 2), group("b", 2024, 6, 1, count: 2),
                   group("c", 2025, 6, 1, count: 2)],
            calendar: cal, locale: locale)
        #expect(threeYear.sections.map(\.title) == ["June 2023", "June 2024", "June 2025"])
    }

    @Test("a single run straddling a year boundary keys off its first day → no year (firstDay-only, #119)")
    func yearFromFirstDayOfAStraddlingRun() {
        // "Multi-year" is derived from each cluster's FIRST day (matching how sections are keyed), so a
        // lone run spanning Dec 31 2024 → Jan 1 2025 registers only 2024 ⇒ single-year ⇒ bare "December".
        // This locks the firstDay-only semantics rather than leaving them incidental.
        let run = ReviewCluster.day(DayGroup(id: "nye", assetIDs: ["nye-0", "nye-1"],
                           days: [.day(year: 2024, month: 12, day: 31), .day(year: 2025, month: 1, day: 1)],
                           isBusyDay: false))
        let index = ClusterIndexBuilder.build(from: [run], calendar: cal, locale: locale)
        #expect(index.sections.map(\.title) == ["December"])
    }

    @Test("a multi-day (folded quiet-run) cluster sits in its FIRST day's month section")
    func multiDayRunSectionsByFirstDay() {
        // A run spanning Jan 30 → Feb 2 buckets by its first day (January), not its last.
        let run = ReviewCluster.day(DayGroup(id: "run",
                           assetIDs: ["run-0", "run-1", "run-2"],
                           days: [.day(year: 2025, month: 1, day: 30), .day(year: 2025, month: 2, day: 2)],
                           isBusyDay: false))
        let index = ClusterIndexBuilder.build(from: [run], calendar: cal, locale: locale)
        #expect(index.sections.map(\.title) == ["January"])
        #expect(index.sections.first?.rows.first?.firstDay == .day(year: 2025, month: 1, day: 30))
    }

    @Test("the undated bucket becomes a trailing 'Undated' list section")
    func undatedLast() {
        let groups = [
            group("a", 2025, 2, 1, count: 6),
            undatedGroup(count: 3)
        ]
        let index = ClusterIndexBuilder.build(from: groups, calendar: cal, locale: locale)

        #expect(index.sections.map(\.title) == ["February", "Undated"])
        #expect(index.sections.last?.rows.count == 1)
        #expect(index.totalClusters == 2)
    }

    @Test("an empty group list yields no sections and zero totals")
    func empty() {
        let index = ClusterIndexBuilder.build(from: [], calendar: cal, locale: locale)
        #expect(index.sections.isEmpty)
        #expect(index.totalClusters == 0)
        #expect(index.totalDays == 0)
    }

    @Test("totalDays counts each dated day (a folded run's days all count); undated isn't a day")
    func totalDaysCountsDays() {
        let run = ReviewCluster.day(DayGroup(id: "run", assetIDs: ["r0", "r1", "r2"],
                           days: [.day(year: 2025, month: 1, day: 30), .day(year: 2025, month: 2, day: 2)],
                           isBusyDay: false))
        let undated = ReviewCluster.day(DayGroup(id: "u", assetIDs: ["u0"], days: [.undated], isBusyDay: false))
        let index = ClusterIndexBuilder.build(from: [run, group("b", 2025, 3, 5, count: 8), undated],
                                              calendar: cal, locale: locale)
        #expect(index.totalClusters == 3)   // three clusters (incl. undated)
        #expect(index.totalDays == 3)       // run's 2 days + busy's 1; undated contributes no day
    }

    @Test("a trip row carries the location sentence + date subline; date fallback until the name lands")
    func tripRow() throws {
        let g1 = DayGroup(id: "d1", assetIDs: ["a1"], days: [.day(year: 2025, month: 11, day: 8)], isBusyDay: true)
        let g2 = DayGroup(id: "d2", assetIDs: ["a2"], days: [.day(year: 2025, month: 11, day: 9)], isBusyDay: true)
        let trip = ReviewCluster.trip(TripCluster(id: "t", clusterID: "aland", shape: .weekend, dayGroups: [g1, g2]))
        let dateRange = DayGroupHeader.title(for: trip, calendar: cal, locale: locale)

        // Named → the sentence is the title; the date range is the subline; it's flagged a trip.
        let named = ClusterIndexBuilder.build(from: [trip], tripNames: ["aland": "Åland"], calendar: cal, locale: locale)
        let namedRow = try #require(named.sections.first?.rows.first)
        #expect(namedRow.isTrip)
        #expect(namedRow.title == TripLabel.sentence(for: .weekend, place: "Åland"))
        #expect(namedRow.dateSubtitle == dateRange)

        // Not-yet-resolved → the date range is the fallback title (the async name hasn't landed).
        let unnamed = ClusterIndexBuilder.build(from: [trip], tripNames: [:], calendar: cal, locale: locale)
        let unnamedRow = try #require(unnamed.sections.first?.rows.first)
        #expect(unnamedRow.title == dateRange)
        #expect(unnamedRow.dateSubtitle == dateRange)
        // A trip carries no characterful caption — its location sentence IS the personality.
        #expect(namedRow.caption == nil)
        #expect(unnamedRow.caption == nil)
    }

    // MARK: Cluster caption (day-cluster personality)

    @Test("a single-day date cluster gets a caption from its assets: time span leads, media appended")
    func dateClusterCaption() throws {
        let group = group("a", 2025, 2, 1, count: 3)   // asset ids a-0, a-1, a-2
        let assets = [
            "a-0": asset("a-0", 2025, 2, 1, hour: 9),                 // morning
            "a-1": asset("a-1", 2025, 2, 1, hour: 18, video: true),  // evening + a video
            "a-2": asset("a-2", 2025, 2, 1, hour: 20)                // evening
        ]
        let index = ClusterIndexBuilder.build(from: [group], assets: assets, calendar: cal, locale: locale)
        let caption = try #require(index.sections.first?.rows.first?.caption)
        #expect(caption.symbol == "clock")                       // single day → the span leads
        #expect(caption.text.hasPrefix("Morning – Evening"))     // 09:00 → 20:00
        #expect(caption.text.contains("video"))                  // the one video is a highlight
    }

    @Test("no assets supplied → no caption (the default empty map keeps the row clean)")
    func captionNilWithoutAssets() {
        let index = ClusterIndexBuilder.build(from: [group("a", 2025, 2, 1, count: 3)], calendar: cal, locale: locale)
        #expect(index.sections.first?.rows.first?.caption == nil)
    }

    @Test("the undated bucket never gets a caption, even when its assets carry media")
    func undatedNoCaption() {
        let assets = ["u0": AssetRef(id: "u0", captureDate: nil, isVideo: true),
                      "u1": AssetRef(id: "u1", captureDate: nil, isVideo: true)]
        let index = ClusterIndexBuilder.build(from: [group("a", 2025, 2, 1, count: 1), undatedGroup(count: 2)],
                                              assets: assets, calendar: cal, locale: locale)
        #expect(index.sections.last?.title == "Undated")
        #expect(index.sections.last?.rows.first?.caption == nil)
    }

    @Test("a multi-day run drops the time-span lead; the media highlight leads instead")
    func multiDayRunCaption() throws {
        let run = ReviewCluster.day(DayGroup(id: "run", assetIDs: ["run-0", "run-1"],
                           days: [.day(year: 2025, month: 1, day: 30), .day(year: 2025, month: 2, day: 2)],
                           isBusyDay: false))
        let assets = ["run-0": asset("run-0", 2025, 1, 30, hour: 9, video: true),
                      "run-1": asset("run-1", 2025, 2, 2, hour: 20)]
        let index = ClusterIndexBuilder.build(from: [run], assets: assets, calendar: cal, locale: locale)
        let caption = try #require(index.sections.first?.rows.first?.caption)
        #expect(caption.symbol == "video.fill")          // no span lead on a multi-day run
        #expect(caption.text.contains("–") == false)     // …so no time-of-day range either
        #expect(caption.text.contains("video"))
    }
}

@Suite("ChartBucketing — adaptive coverage-chart buckets (#37)")
struct ChartBucketingTests {
    private let cal = utcCalendar()
    private let locale = Locale(identifier: "en_US")

    private func group(_ id: String, _ year: Int, _ month: Int, _ day: Int, count: Int) -> ReviewCluster {
        .day(DayGroup(id: id,
                      assetIDs: (0..<count).map { "\(id)-\($0)" },
                      days: [.day(year: year, month: month, day: day)],
                      isBusyDay: true))
    }

    private func buckets(_ groups: [ReviewCluster]) -> [ChartBucket] {
        ClusterIndexBuilder.build(from: groups, calendar: cal, locale: locale).chartBuckets
    }

    @Test("the bar unit is chosen by span: ≤18d → day, ≤125d → week, else month")
    func unitByspan() {
        #expect(ChartBucketing.unit(spanDays: 0) == .day)
        #expect(ChartBucketing.unit(spanDays: 18) == .day)
        #expect(ChartBucketing.unit(spanDays: 19) == .weekOfYear)
        #expect(ChartBucketing.unit(spanDays: 125) == .weekOfYear)
        #expect(ChartBucketing.unit(spanDays: 126) == .month)
        #expect(ChartBucketing.unit(spanDays: 400) == .month)
    }

    @Test("a full year → 12 monthly bars, one per month, each opening a new month (ticked)")
    func yearIsMonthly() {
        let groups = (1...12).map { group("m\($0)", 2025, $0, 15, count: 5) }
        let bars = buckets(groups)
        #expect(bars.count == 12)
        #expect(bars.allSatisfy { $0.tick != nil })      // every bucket opens a new month
        #expect(bars.first?.tick == "J")                 // veryShortMonthSymbols[0] (en)
        #expect(bars.allSatisfy { $0.count == 5 })       // each month holds one 5-photo cluster
    }

    @Test("a multi-month album → weekly bars (≥ min), ticked at month starts, no phantom prior month")
    func multiMonthIsWeekly() {
        // Feb 1 → Apr 15 ≈ 73 days → weekly, ~11–12 buckets (≥ minBuckets, no floor). Feb 1's week
        // starts in late January, but the first tick must be "F" (the album's real start), not "J".
        let groups = [group("a", 2025, 2, 1, count: 10), group("b", 2025, 3, 5, count: 8),
                      group("c", 2025, 4, 15, count: 12)]
        let bars = buckets(groups)
        #expect(bars.count >= 10)
        #expect(bars.compactMap(\.tick) == ["F", "M", "A"])   // no leading "J" from the Jan week-start
    }

    @Test("a short/awkward span floors to minBuckets equal day-slices (never a sparse handful)")
    func shortSpanFloorsToMinBuckets() {
        // Feb 3 → Mar 10 ≈ 35 days → weekly would be ~6 bars (< 8), so it floors to 8 day-slices.
        let groups = [group("a", 2025, 2, 3, count: 10), group("b", 2025, 2, 17, count: 8),
                      group("c", 2025, 3, 1, count: 12), group("d", 2025, 3, 10, count: 6)]
        let bars = buckets(groups)
        #expect(bars.count == ChartBucketing.minBuckets)      // exactly the floor
        #expect(bars.first?.tick == "F")                      // opens in February
        #expect(bars.compactMap(\.tick) == ["F", "M"])        // crosses into March once
        #expect(bars.reduce(0) { $0 + $1.count } == 36)       // every photo placed (10+8+12+6)
    }

    @Test("a few-day album → daily bars with gaps; a single month labels sparse dates (not month letters)")
    func shortAlbumIsDaily() {
        let groups = [group("a", 2025, 1, 1, count: 3), group("b", 2025, 1, 3, count: 4),
                      group("c", 2025, 1, 5, count: 2)]
        let bars = buckets(groups)
        #expect(bars.count == 5)                          // Jan 1…5 inclusive
        #expect(bars.map(\.count) == [3, 0, 4, 0, 2])     // photo counts; gaps on the empty days
        let ticks = bars.compactMap(\.tick)
        #expect(!ticks.isEmpty)                           // one month → date ticks, not empty
        #expect(ticks.count < bars.count)                 // …but not on every bar
        #expect(ticks.allSatisfy { !$0.contains(where: \.isLetter) })   // compact numeric dates, not "Jan"/"J"
    }

    @Test("a single-month span uses sparse DATE ticks (not stranded month letters)")
    func singleMonthUsesDateTicks() {
        // All within June → month letters would be a lone stranded "J", so label sparse June dates.
        let groups = [group("a", 2025, 6, 2, count: 10), group("b", 2025, 6, 10, count: 8),
                      group("c", 2025, 6, 20, count: 12)]
        let bars = buckets(groups)
        let ticks = bars.compactMap(\.tick)
        #expect(!ticks.isEmpty)
        #expect(ticks.count < bars.count)                 // not every bar
        #expect(ticks.allSatisfy { !$0.contains(where: \.isLetter) })   // compact numeric dates
    }

    @Test("undated clusters get no bar (a timeline has no place for them)")
    func undatedExcluded() {
        let undated = ReviewCluster.day(DayGroup(id: "u", assetIDs: ["u0", "u1"], days: [.undated], isBusyDay: false))
        let bars = buckets([group("a", 2025, 3, 1, count: 5), undated])
        #expect(bars.count == 1)                          // just the one dated cluster
        #expect(bars.first?.count == 5)                   // its 5 photos (undated's not counted)
    }

    @Test("a weekly span too short for 8 weeks floors to exactly minBuckets slices, every photo placed")
    func weeklySpanFloorsToMinBuckets() {
        // Jan 1 → Jan 20 ≈ 19 days → weekly (~3 weeks < 8) → floors to 8 day-slices (a denser slice
        // layout than the ~5-week case, so it also guards against two slice-starts collapsing).
        let bars = buckets([group("a", 2025, 1, 1, count: 10), group("b", 2025, 1, 20, count: 8)])
        #expect(bars.count == ChartBucketing.minBuckets)
        #expect(bars.reduce(0) { $0 + $1.count } == 18)   // both clusters land in a slice
    }

    @Test("a single dated cluster yields exactly one bar (the view gates the chart above one cluster)")
    func singleClusterOneBar() {
        let bars = buckets([group("a", 2025, 5, 10, count: 12)])
        #expect(bars.count == 1)
        #expect(bars.first?.count == 12)
    }

    @Test("date ticks follow the caller's locale (order/separator differ), never month letters")
    func dateTicksAreLocalized() {
        let groups = [group("a", 2025, 6, 2, count: 10), group("b", 2025, 6, 20, count: 8)]
        func ticks(_ id: String) -> [String] {
            ClusterIndexBuilder.build(from: groups, calendar: cal, locale: Locale(identifier: id))
                .chartBuckets.compactMap(\.tick)
        }
        let en = ticks("en_US"), fi = ticks("fi_FI")
        #expect(!en.isEmpty)
        #expect((en + fi).allSatisfy { !$0.contains(where: \.isLetter) })   // numeric in both
        #expect(en != fi)                                                   // e.g. "6/2" vs "2.6."
    }

    @Test("a ~5-month album crosses week→month, giving monthly bars with month-letter ticks")
    func multiMonthUsesMonthlyBars() {
        // Feb 10 → Jun 20 ≈ 130 days (≥ 126) → monthly unit; ≥ 2 months → single-letter month ticks.
        let bars = buckets([group("a", 2025, 2, 10, count: 5), group("b", 2025, 6, 20, count: 8)])
        let ticks = bars.compactMap(\.tick)
        #expect(ticks.count >= 2)
        #expect(ticks.allSatisfy { $0.count == 1 })       // month initials, not numeric dates
    }
}
