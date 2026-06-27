//
//  TestSupport.swift
//  CurationTests — shared fixtures/helpers (consolidated from per-file copies).
//
//  These were hand-rolled identically across GroupingTests / CurationLogicTests /
//  ReviewFollowupTests / PropertyTests / GeoDistanceTests. One definition each, here.
//

import Foundation
@testable import Curation

/// A fixed Gregorian calendar pinned to a timezone (default UTC), so tests are deterministic and
/// can pressure-test the timezone/DST stability the model promises.
func utcCalendar(_ tz: String = "UTC") -> Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: tz)!
    return c
}

/// Build an asset captured on a given y/m/d at `hour`, using `calendar`.
func asset(_ id: String, _ y: Int, _ m: Int, _ d: Int, hour: Int = 12, calendar: Calendar) -> AssetRef {
    AssetRef(id: id, captureDate: calendar.date(from: DateComponents(year: y, month: m, day: d, hour: hour))!)
}

/// `DayKey` shorthand for a real calendar day.
func dk(_ y: Int, _ m: Int, _ d: Int) -> DayKey { .day(year: y, month: m, day: d) }

/// A small seedable PRNG (SplitMix64) so generated property inputs are reproducible per seed.
struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }
}
