//
//  TestSupport.swift
//  PoimiAppTests — shared fixtures/helpers (consolidated from per-file copies).
//
//  A UTC calendar, the year-2025 date anchors, and a monotonic clock were hand-rolled across the
//  store/conformance/header suites. One definition each, here.
//

import Foundation

/// A fixed Gregorian calendar pinned to a timezone (default UTC) so date tests don't depend on the
/// runner's locale/zone.
func utcCalendar(_ tz: String = "UTC") -> Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: tz)!
    return c
}

/// Canonical test date anchors — calendar year 2025 (UTC), end-exclusive.
enum TestDates {
    static let year2025Start = Date(timeIntervalSince1970: 1_735_689_600)   // 2025-01-01T00:00:00Z
    static let year2025End = Date(timeIntervalSince1970: 1_767_225_600)     // 2026-01-01T00:00:00Z
}

extension DateInterval {
    /// Calendar year 2025 (UTC), end-exclusive.
    static let year2025 = DateInterval(start: TestDates.year2025Start, end: TestDates.year2025End)
    /// All representable time — for "fetch everything" assertions against the fake. Note:
    /// `.distantPast`/`.distantFuture` bridged into an `NSPredicate` is a PhotoKit sharp edge, so the
    /// on-device System conformance run (#46) should use a bounded interval, not this.
    static let everything = DateInterval(start: .distantPast, end: .distantFuture)
}

/// A deterministic, strictly-increasing clock (1-second steps) so created/opened ordering is
/// assertable. Each call returns the next instant.
func monotonicClock(from start: Date = Date(timeIntervalSince1970: 1_000_000_000)) -> () -> Date {
    var tick = start
    return { defer { tick += 1 }; return tick }
}
