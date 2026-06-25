//
//  NewAlbumDraftTests.swift
//  PoimiAppTests — the new-album setup defaults (#33, D2).
//

import Testing
import Foundation
@testable import PoimiApp

@Suite("NewAlbumDraft (#33)")
struct NewAlbumDraftTests {

    private func utc() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    @Test("prior-calendar-year default: title + a full end-exclusive prior year, screenshots off-source")
    func priorYearDefault() {
        let calendar = utc()
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
        let calendar = utc()
        let now = calendar.date(from: DateComponents(year: 2031, month: 1, day: 2))!
        #expect(NewAlbumDraft.priorCalendarYear(now: now, calendar: calendar).title == "Best of 2030")
    }
}
