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

    // MARK: - nonInvertedEnd: the From-past-To auto-correct (#259)

    private func day(_ y: Int, _ m: Int, _ d: Int, _ cal: Calendar) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d))!
    }

    @Test("nonInvertedEnd: a start before the end leaves the end untouched (the common case)")
    func nonInvertedEndKeepsValidRange() {
        let cal = utcCalendar()
        // Default-style range: start 2025-01-01, end-exclusive 2026-01-01. Nudge start forward but keep
        // it well before the end — nothing should move.
        let end = day(2026, 1, 1, cal)
        let corrected = NewAlbumDraft.nonInvertedEnd(start: day(2025, 6, 15, cal), end: end, calendar: cal)
        #expect(corrected == end)
    }

    @Test("nonInvertedEnd: From == To (single-day range, start = inclusive last day) is kept, not collapsed")
    func nonInvertedEndKeepsSingleDay() {
        let cal = utcCalendar()
        // Inclusive To = Dec 31 → exclusive end = Jan 1. Start ON Dec 31 is a valid one-day range: start
        // (Dec 31) < end (Jan 1), so it must NOT be treated as inverted.
        let end = day(2026, 1, 1, cal)
        let corrected = NewAlbumDraft.nonInvertedEnd(start: day(2025, 12, 31, cal), end: end, calendar: cal)
        #expect(corrected == end)
    }

    @Test("nonInvertedEnd: From dragged past To collapses To to a single day at the new start (#259)")
    func nonInvertedEndCollapsesWhenPast() {
        let cal = utcCalendar()
        // The reported bug: default end is in 2025, user drags From into 2026. Start (2026-06-15) is well
        // past the exclusive end (2026-01-01) → collapse to a single day: end becomes 2026-06-16.
        let newStart = day(2026, 6, 15, cal)
        let corrected = NewAlbumDraft.nonInvertedEnd(start: newStart, end: day(2026, 1, 1, cal), calendar: cal)
        #expect(corrected == day(2026, 6, 16, cal))
        // The result is a valid, non-inverted single-day range, and its inclusive To reads back as the start.
        #expect(corrected > newStart)
        #expect(NewAlbumDraft.inclusiveEndDay(forExclusiveEnd: corrected, calendar: cal) == newStart)
    }

    @Test("nonInvertedEnd: start exactly AT the exclusive end (one past inclusive To) still collapses")
    func nonInvertedEndCollapsesAtBoundary() {
        let cal = utcCalendar()
        // Start == end-exclusive (the day after the inclusive To) makes [start, end) empty → collapse.
        let end = day(2026, 1, 1, cal)
        let corrected = NewAlbumDraft.nonInvertedEnd(start: end, end: end, calendar: cal)
        #expect(corrected == day(2026, 1, 2, cal))
    }
}
