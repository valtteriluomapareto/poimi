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

    private func group(_ id: String, _ year: Int, _ month: Int, _ day: Int, count: Int) -> DayGroup {
        DayGroup(id: id,
                 assetIDs: (0..<count).map { "\(id)-\($0)" },
                 days: [.day(year: year, month: month, day: day)],
                 isBusyDay: true)
    }

    private func undatedGroup(count: Int) -> DayGroup {
        DayGroup(id: "undated", assetIDs: (0..<count).map { "u\($0)" }, days: [.undated], isBusyDay: false)
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

    @Test("same month in DIFFERENT years are distinct sections — the yyyy-MM id, not just month")
    func yearBoundarySplitsSections() {
        // Two Februaries a year apart must NOT collapse into one section (the whole point of keying on
        // "yyyy-MM"). A month-only key would silently merge them.
        let groups = [
            group("a", 2024, 2, 10, count: 6),
            group("b", 2025, 2, 10, count: 6)
        ]
        let index = ClusterIndexBuilder.build(from: groups, calendar: cal, locale: locale)
        #expect(index.sections.count == 2)
        #expect(index.sections.map(\.id) == ["2024-02", "2025-02"])
        #expect(index.sections.map(\.title) == ["February", "February"])
    }

    @Test("a multi-day (folded quiet-run) cluster sits in its FIRST day's month section")
    func multiDayRunSectionsByFirstDay() {
        // A run spanning Jan 30 → Feb 2 buckets by its first day (January), not its last.
        let run = DayGroup(id: "run",
                           assetIDs: ["run-0", "run-1", "run-2"],
                           days: [.day(year: 2025, month: 1, day: 30), .day(year: 2025, month: 2, day: 2)],
                           isBusyDay: false)
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
    }
}

@Suite("ChartBucketing — adaptive coverage-chart buckets (#37)")
struct ChartBucketingTests {
    private let cal = utcCalendar()
    private let locale = Locale(identifier: "en_US")

    private func group(_ id: String, _ year: Int, _ month: Int, _ day: Int, count: Int) -> DayGroup {
        DayGroup(id: id,
                 assetIDs: (0..<count).map { "\(id)-\($0)" },
                 days: [.day(year: year, month: month, day: day)],
                 isBusyDay: true)
    }

    private func buckets(_ groups: [DayGroup]) -> [ChartBucket] {
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
        #expect(bars.allSatisfy { $0.rows.count == 1 })
    }

    @Test("a ~6-week album → weekly bars, contiguous (empty weeks included), ticked at month starts")
    func coupleMonthsIsWeekly() {
        // Feb 3 → Mar 17 ≈ 42 days → weekly; 4 clusters but ~7 contiguous week buckets.
        let groups = [group("a", 2025, 2, 3, count: 10), group("b", 2025, 2, 17, count: 8),
                      group("c", 2025, 3, 3, count: 12), group("d", 2025, 3, 17, count: 6)]
        let bars = buckets(groups)
        #expect(bars.count > 4)                           // more buckets than clusters → empty weeks
        #expect(bars.count <= 8)
        #expect(bars.compactMap(\.tick) == ["F", "M"])    // one tick where Feb opens, one where Mar opens
    }

    @Test("a few-day album → daily bars, with the empty days between kept as gaps")
    func shortAlbumIsDaily() {
        let groups = [group("a", 2025, 1, 1, count: 3), group("b", 2025, 1, 3, count: 4),
                      group("c", 2025, 1, 5, count: 2)]
        let bars = buckets(groups)
        #expect(bars.count == 5)                          // Jan 1…5 inclusive
        #expect(bars.map { $0.rows.count } == [1, 0, 1, 0, 1])   // gaps on the empty days
        #expect(bars.compactMap(\.tick) == ["J"])         // only the first bucket opens January
    }

    @Test("undated clusters get no bar (a timeline has no place for them)")
    func undatedExcluded() {
        let undated = DayGroup(id: "u", assetIDs: ["u0", "u1"], days: [.undated], isBusyDay: false)
        let bars = buckets([group("a", 2025, 3, 1, count: 5), undated])
        #expect(bars.count == 1)                          // just the one dated cluster
        #expect(bars.first?.rows.count == 1)
    }
}
