//
//  DayKey.swift
//  Curation — the stable calendar-day key (issue #19).
//
//  A `DayKey` is the atom on which day-grouping and (issue #20) completion are keyed. It
//  is a calendar day as integer components — NOT a `Date` instant — so it stays stable
//  across timezone changes and DST (architecture §13 / D32(d)). Two photos on the same
//  calendar day share a key regardless of time-of-day; an asset with no capture date maps
//  to the single `.undated` key.
//
//  The projection from a `Date` to a `DayKey` is parameterized by an injected `Calendar`
//  so the timezone policy is explicit and testable. The grouping function (#19) and the
//  completion derivation (#20) MUST use the identical calendar so the keys line up.
//

import Foundation

public enum DayKey: Sendable, Equatable, Hashable, Codable, Comparable, CustomStringConvertible {
    /// A real calendar day.
    case day(year: Int, month: Int, day: Int)
    /// Assets with no capture date — collected into one trailing "Undated" section so
    /// they remain reviewable (architecture §13). Sorts after every real day.
    case undated

    /// Project a `Date` (or its absence) onto a calendar day using `calendar`.
    public init(date: Date?, calendar: Calendar) {
        guard let date else { self = .undated; return }
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        self = .day(year: c.year ?? 0, month: c.month ?? 0, day: c.day ?? 0)
    }

    /// `"2025-06-20"` for a real day, `"undated"` for the sentinel — the persisted form.
    public var description: String {
        switch self {
        case let .day(year, month, day):
            return String(format: "%04d-%02d-%02d", year, month, day)
        case .undated:
            return "undated"
        }
    }

    /// A midday anchor `Date` for this day, used for calendar gap math (midday dodges DST
    /// edge surprises). `nil` for `.undated`.
    public func anchorDate(in calendar: Calendar) -> Date? {
        guard case let .day(year, month, day) = self else { return nil }
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))
    }

    /// Chronological order; `.undated` sorts after every real day.
    public static func < (lhs: DayKey, rhs: DayKey) -> Bool {
        switch (lhs, rhs) {
        case let (.day(y1, m1, d1), .day(y2, m2, d2)):
            return (y1, m1, d1) < (y2, m2, d2)
        case (.day, .undated):
            return true
        case (.undated, .day), (.undated, .undated):
            return false
        }
    }
}
