//
//  GroupingTests.swift
//  CurationTests — DayKey + adaptive day-grouping (#19).
//

import Testing
import Foundation
@testable import Curation

// MARK: - Fixtures

/// A fixed Gregorian calendar pinned to an explicit timezone, so tests are deterministic
/// and can pressure-test the timezone/DST stability the model promises.
private func fixedCalendar(_ tz: String = "UTC") -> Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: tz)!
    return c
}

/// Build an asset captured on a given y/m/d at `hour`, using `calendar`.
private func asset(_ id: String, _ y: Int, _ m: Int, _ d: Int, hour: Int = 12, calendar: Calendar) -> AssetRef {
    let date = calendar.date(from: DateComponents(year: y, month: m, day: d, hour: hour))!
    return AssetRef(id: id, captureDate: date)
}

/// N assets on one day.
private func assets(_ prefix: String, count: Int, _ y: Int, _ m: Int, _ d: Int, calendar: Calendar) -> [AssetRef] {
    (0..<count).map { asset("\(prefix)-\($0)", y, m, d, calendar: calendar) }
}

// MARK: - DayKey

@Suite("DayKey (#19)")
struct DayKeyTests {
    @Test("description is the persisted yyyy-MM-dd / undated form")
    func description() {
        #expect(DayKey.day(year: 2025, month: 6, day: 7).description == "2025-06-07")
        #expect(DayKey.undated.description == "undated")
    }

    @Test("init buckets by calendar day regardless of time-of-day")
    func bucketsByDay() {
        let cal = fixedCalendar()
        let morning = cal.date(from: DateComponents(year: 2025, month: 6, day: 7, hour: 0, minute: 5))!
        let night = cal.date(from: DateComponents(year: 2025, month: 6, day: 7, hour: 23, minute: 55))!
        #expect(DayKey(date: morning, calendar: cal) == DayKey(date: night, calendar: cal))
        #expect(DayKey(date: nil, calendar: cal) == .undated)
    }

    @Test("Comparable is chronological with undated last")
    func ordering() {
        let a = DayKey.day(year: 2025, month: 1, day: 31)
        let b = DayKey.day(year: 2025, month: 2, day: 1)
        #expect(a < b)
        #expect(b < .undated)
        #expect([DayKey.undated, b, a].sorted() == [a, b, .undated])
    }
}

// MARK: - Grouping

@Suite("Adaptive day-grouping (#19)")
struct DayGroupingTests {
    private let cal = fixedCalendar()

    @Test("empty input yields no groups")
    func empty() {
        #expect(DayGrouping.groups(for: [], calendar: cal).isEmpty)
    }

    @Test("a day with >= N photos is its own busy group")
    func busyDay() {
        let groups = DayGrouping.groups(for: assets("a", count: 10, 2025, 7, 5, calendar: cal), calendar: cal)
        #expect(groups.count == 1)
        #expect(groups[0].isBusyDay)
        #expect(groups[0].count == 10)
        #expect(groups[0].days == [.day(year: 2025, month: 7, day: 5)])
    }

    @Test("consecutive quiet days merge into one run")
    func quietRunMerges() {
        let input = [
            asset("a", 2025, 3, 16, calendar: cal),
            asset("b", 2025, 3, 17, calendar: cal),
            asset("c", 2025, 3, 18, calendar: cal),
        ]
        let groups = DayGrouping.groups(for: input, calendar: cal)
        #expect(groups.count == 1)
        #expect(!groups[0].isBusyDay)
        #expect(groups[0].days.count == 3)
        #expect(groups[0].assetIDs == ["a", "b", "c"])
    }

    @Test("a calendar gap beyond tolerance breaks the quiet run")
    func gapBreaksRun() {
        let input = [
            asset("a", 2025, 3, 1, calendar: cal),
            asset("b", 2025, 3, 10, calendar: cal),   // 9-day gap > tolerance(1)
        ]
        let groups = DayGrouping.groups(for: input, calendar: cal)
        #expect(groups.count == 2)
        let allQuiet = groups.allSatisfy { !$0.isBusyDay }
        #expect(allQuiet)
    }

    @Test("a busy day breaks a surrounding quiet run into three groups")
    func busyDayBreaksRun() {
        var input = [asset("q1", 2025, 5, 1, calendar: cal)]
        input += assets("busy", count: 12, 2025, 5, 2, calendar: cal)
        input += [asset("q2", 2025, 5, 3, calendar: cal)]
        let groups = DayGrouping.groups(for: input, calendar: cal)
        #expect(groups.count == 3)
        #expect(groups.map(\.isBusyDay) == [false, true, false])
    }

    @Test("concatenating groups reproduces the input order exactly")
    func orderPreserved() {
        var input = assets("busy", count: 11, 2025, 8, 4, calendar: cal)
        input += [asset("q", 2025, 8, 6, calendar: cal)]
        input += assets("busy2", count: 10, 2025, 8, 20, calendar: cal)
        let flattened = DayGrouping.groups(for: input, calendar: cal).flatMap(\.assetIDs)
        #expect(flattened == input.map(\.id))
    }

    @Test("threshold = 1 makes every day its own busy group")
    func thresholdTuning() {
        let input = [
            asset("a", 2025, 3, 16, calendar: cal),
            asset("b", 2025, 3, 17, calendar: cal),
        ]
        let groups = DayGrouping.groups(for: input, threshold: 1, calendar: cal)
        #expect(groups.count == 2)
        let allBusy = groups.allSatisfy(\.isBusyDay)
        #expect(allBusy)
    }

    @Test("no-capture-date assets collect into one trailing Undated group")
    func undatedHome() {
        var input = assets("dated", count: 10, 2025, 7, 5, calendar: cal)
        input += [AssetRef(id: "u1", captureDate: nil), AssetRef(id: "u2", captureDate: nil)]
        let groups = DayGrouping.groups(for: input, calendar: cal)
        #expect(groups.count == 2)
        let undated = groups.last!
        #expect(undated.isUndated)
        #expect(undated.days == [.undated])
        #expect(undated.assetIDs == ["u1", "u2"])
    }

    @Test("grouping is deterministic for the same input + calendar")
    func deterministic() {
        var input = assets("busy", count: 10, 2025, 7, 5, calendar: cal)
        input += [asset("q", 2025, 7, 7, calendar: cal), AssetRef(id: "u", captureDate: nil)]
        #expect(DayGrouping.groups(for: input, calendar: cal) == DayGrouping.groups(for: input, calendar: cal))
    }

    // MARK: timezone / DST stability — the core D32(d) safety

    @Test("photos either side of a DST spring-forward share one day")
    func dstSameDay() {
        // America/New_York springs forward 02:00→03:00 on 2025-03-09.
        let ny = fixedCalendar("America/New_York")
        let before = asset("a", 2025, 3, 9, hour: 1, calendar: ny)   // 01:00 (pre-skip)
        let after = asset("b", 2025, 3, 9, hour: 3, calendar: ny)    // 03:00 (post-skip)
        let groups = DayGrouping.groups(for: [before, after], threshold: 1, calendar: ny)
        // Same calendar day → not two separate day groups.
        #expect(DayKey(date: before.captureDate, calendar: ny) == DayKey(date: after.captureDate, calendar: ny))
        #expect(groups.count == 1)
    }

    @Test("calendar gap across a DST day counts whole days, not 24h chunks")
    func dstGapIsCalendarCorrect() {
        let ny = fixedCalendar("America/New_York")
        // 8 Mar → 10 Mar spans the 23-hour DST day; the calendar gap must be 2 days.
        let gap = DayGrouping.dayGap(
            from: .day(year: 2025, month: 3, day: 8),
            to: .day(year: 2025, month: 3, day: 10),
            calendar: ny
        )
        #expect(gap == 2)
    }
}
