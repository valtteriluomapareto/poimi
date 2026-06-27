//
//  NewAlbumDraftTests.swift
//  PoimiAppTests — the new-album setup defaults (#33, D2).
//

import Testing
import Foundation
@testable import PoimiApp

@Suite("NewAlbumDraft (#33)")
struct NewAlbumDraftTests {

    // `utcCalendar()` lives in TestSupport.swift.

    @Test("prior-calendar-year default: title + a full end-exclusive prior year, screenshots off-source")
    func priorYearDefault() {
        let calendar = utcCalendar()
        let now = calendar.date(from: DateComponents(year: 2026, month: 6, day: 15))!
        let draft = NewAlbumDraft.priorCalendarYear(now: now, calendar: calendar)

        #expect(draft.title == "Best of 2025")
        #expect(draft.rangeStart == calendar.date(from: DateComponents(year: 2025, month: 1, day: 1)))
        #expect(draft.rangeEnd == calendar.date(from: DateComponents(year: 2026, month: 1, day: 1)))  // exclusive
        let span = calendar.dateComponents([.day], from: draft.rangeStart, to: draft.rangeEnd).day
        #expect(span == 365)   // a full prior year (2025 non-leap)
        #expect(draft.targetCount == 100)
        #expect(draft.excludeScreenshots)
        #expect(draft.excludedAlbumIDs.isEmpty)
        #expect(draft.targetAlbumID == nil)
    }

    @Test("the default tracks the clock's year")
    func tracksYear() {
        let calendar = utcCalendar()
        let now = calendar.date(from: DateComponents(year: 2031, month: 1, day: 2))!
        #expect(NewAlbumDraft.priorCalendarYear(now: now, calendar: calendar).title == "Best of 2030")
    }

    @Test("a leap prior year spans 366 days (the span isn't hardcoded to 365)")
    func leapYearSpan() {
        let calendar = utcCalendar()
        let now = calendar.date(from: DateComponents(year: 2025, month: 6, day: 15))!   // prior year 2024 (leap)
        let draft = NewAlbumDraft.priorCalendarYear(now: now, calendar: calendar)
        #expect(draft.title == "Best of 2024")
        #expect(draft.rangeEnd == calendar.date(from: DateComponents(year: 2025, month: 1, day: 1)))
        #expect(calendar.dateComponents([.day], from: draft.rangeStart, to: draft.rangeEnd).day == 366)
    }

    @Test("inclusive-end ↔ exclusive-end round-trips (the To-picker off-by-one)")
    func inclusiveEndRoundTrip() {
        let calendar = utcCalendar()
        let exclusiveEnd = calendar.date(from: DateComponents(year: 2026, month: 1, day: 1))!
        let inclusiveDay = NewAlbumDraft.inclusiveEndDay(forExclusiveEnd: exclusiveEnd, calendar: calendar)
        #expect(inclusiveDay == calendar.date(from: DateComponents(year: 2025, month: 12, day: 31)))   // shows Dec 31
        let roundTripped = NewAlbumDraft.exclusiveEnd(forInclusiveDay: inclusiveDay, calendar: calendar)
        #expect(roundTripped == exclusiveEnd)
    }
}
