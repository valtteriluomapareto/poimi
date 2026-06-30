//
//  MonthGroupingTests.swift
//  CurationTests — calendar-month aggregation for the album overview (#37).
//
//  `utcCalendar` + `asset(...)` live in TestSupport.swift.
//

import Testing
import Foundation
@testable import Curation

@Suite("MonthGrouping (#37)")
struct MonthGroupingTests {
    private let cal = utcCalendar()

    @Test("empty input yields no summaries")
    func empty() {
        #expect(MonthGrouping.summaries(for: [], calendar: cal).isEmpty)
    }

    @Test("groups by calendar month, oldest → newest, ids chronological within a month")
    func groupsByMonth() {
        let input = [
            asset("jul-1", 2025, 7, 5, calendar: cal),
            asset("jun-1", 2025, 6, 10, calendar: cal),
            asset("jul-2", 2025, 7, 20, calendar: cal),
            asset("jun-2", 2025, 6, 2, calendar: cal)
        ]
        let summaries = MonthGrouping.summaries(for: input, calendar: cal)
        #expect(summaries.map(\.id) == ["2025-06", "2025-07"])   // oldest month first
        #expect(summaries[0].assetIDs == ["jun-2", "jun-1"])     // within-month chronological
        #expect(summaries[1].assetIDs == ["jul-1", "jul-2"])
        #expect(summaries[0].count == 2 && summaries[1].count == 2)
    }

    @Test("the same month collapses to one summary")
    func sameMonth() {
        let input = (1...5).map { asset("a\($0)", 2025, 3, $0, calendar: cal) }
        let summaries = MonthGrouping.summaries(for: input, calendar: cal)
        #expect(summaries.count == 1)
        #expect(summaries[0].year == 2025 && summaries[0].month == 3)
        #expect(summaries[0].count == 5)
    }

    @Test("undated assets are dropped (the overview is a dated summary)")
    func undatedDropped() {
        let input = [asset("a", 2025, 7, 5, calendar: cal), AssetRef(id: "undated", captureDate: nil)]
        let summaries = MonthGrouping.summaries(for: input, calendar: cal)
        #expect(summaries.count == 1)
        #expect(summaries[0].assetIDs == ["a"])
    }

    @Test("months across a year boundary stay distinct and ordered")
    func acrossYears() {
        let input = [
            asset("jan26", 2026, 1, 3, calendar: cal),
            asset("dec25", 2025, 12, 20, calendar: cal)
        ]
        #expect(MonthGrouping.summaries(for: input, calendar: cal).map(\.id) == ["2025-12", "2026-01"])
    }

    @Test("month bucketing follows the injected calendar at a month boundary")
    func respectsCalendar() {
        // 2025-06-30 23:00:00 UTC. Under UTC → June; under UTC+3 (02:00 on Jul 1) → July.
        let edge = AssetRef(id: "edge", captureDate: Date(timeIntervalSince1970: 1_751_324_400))
        #expect(MonthGrouping.summaries(for: [edge], calendar: utcCalendar()).map(\.id) == ["2025-06"])
        var plus3 = Calendar(identifier: .gregorian)
        plus3.timeZone = TimeZone(secondsFromGMT: 3 * 3600)!
        #expect(MonthGrouping.summaries(for: [edge], calendar: plus3).map(\.id) == ["2025-07"])
    }

    @Test("an all-undated input yields no summaries")
    func allUndated() {
        let input = [AssetRef(id: "a", captureDate: nil), AssetRef(id: "b", captureDate: nil)]
        #expect(MonthGrouping.summaries(for: input, calendar: cal).isEmpty)
    }

    @Test("concatenating the summaries' ids reproduces the dated input in chronological order")
    func partition() {
        let input = [
            asset("c", 2025, 8, 1, calendar: cal),
            asset("a", 2025, 6, 1, calendar: cal),
            asset("b", 2025, 7, 1, calendar: cal)
        ]
        let ids = MonthGrouping.summaries(for: input, calendar: cal).flatMap(\.assetIDs)
        #expect(ids == ["a", "b", "c"])   // oldest → newest, no loss or duplication
    }
}
