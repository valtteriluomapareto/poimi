//
//  AdaptiveThresholdTests.swift
//  CurationTests — the adaptive busy-day threshold (dynamic clustering spike).
//
//  `DayGrouping.adaptiveThreshold` = mean photos per ACTIVE day, clamped to [9, 100]. These pin the
//  mean, the clamps, undated/empty handling, and — the payoff — that the derived threshold makes a
//  right-skewed year cluster the way we want (only the heavy day stands alone; ordinary days merge).
//

import Testing
import Foundation
@testable import Curation

@Suite("DayGrouping.adaptiveThreshold (dynamic clustering)")
struct AdaptiveThresholdTests {
    private let c = utcCalendar()

    /// `n` assets on one calendar day, uniquely id'd.
    private func onDay(_ n: Int, _ y: Int, _ m: Int, _ d: Int, _ prefix: String) -> [AssetRef] {
        (0..<n).map { asset("\(prefix)\($0)", y, m, d, calendar: c) }
    }

    @Test("threshold is the mean photos per active day")
    func meanOfActiveDays() {
        // 20 + 10 + 30 photos over 3 active days → mean 20.
        let input = onDay(20, 2025, 1, 1, "a") + onDay(10, 2025, 1, 3, "b") + onDay(30, 2025, 1, 5, "c")
        #expect(DayGrouping.adaptiveThreshold(for: input, calendar: c) == 20)
    }

    @Test("a sparse album clamps up to the floor (9)")
    func clampsToFloor() {
        // mean 3 → clamped to 9 (a handful of photos is never a "busy day").
        let input = onDay(2, 2025, 1, 1, "a") + onDay(3, 2025, 1, 3, "b") + onDay(4, 2025, 1, 5, "c")
        #expect(DayGrouping.adaptiveThreshold(for: input, calendar: c) == 9)
    }

    @Test("a dense album clamps down to the ceiling (100)")
    func clampsToCeiling() {
        // mean 175 → clamped to 100 (so a heavy year still gets standalone days).
        let input = onDay(200, 2025, 1, 1, "a") + onDay(150, 2025, 1, 3, "b")
        #expect(DayGrouping.adaptiveThreshold(for: input, calendar: c) == 100)
    }

    @Test("undated assets are excluded from the mean (active days only)")
    func undatedExcluded() {
        // 10 + 20 over 2 dated days → mean 15. 50 undated must NOT count (else it'd be ~27).
        let undated = (0..<50).map { AssetRef(id: "u\($0)", captureDate: nil) }
        let input = onDay(10, 2025, 1, 1, "a") + onDay(20, 2025, 1, 2, "b") + undated
        #expect(DayGrouping.adaptiveThreshold(for: input, calendar: c) == 15)
    }

    @Test("empty and all-undated input fall back to the floor")
    func emptyAndUndated() {
        #expect(DayGrouping.adaptiveThreshold(for: [], calendar: c) == 9)
        let allUndated = (0..<8).map { AssetRef(id: "u\($0)", captureDate: nil) }
        #expect(DayGrouping.adaptiveThreshold(for: allUndated, calendar: c) == 9)
    }

    @Test("a mean landing exactly on a clamp bound is kept (inclusive), incl. a single active day")
    func exactClampBounds() {
        // One active day of 9 → mean exactly 9 (the floor is inclusive, not pushed up).
        #expect(DayGrouping.adaptiveThreshold(for: onDay(9, 2025, 1, 1, "a"), calendar: c) == 9)
        // Two days of 100 → mean exactly 100 (the ceiling is inclusive, not pushed down).
        let atCeiling = onDay(100, 2025, 1, 1, "a") + onDay(100, 2025, 1, 3, "b")
        #expect(DayGrouping.adaptiveThreshold(for: atCeiling, calendar: c) == 100)
    }

    @Test("a .5 mean rounds to nearest (away from zero)")
    func roundsHalf() {
        // 25 + 24 over 2 active days = 24.5 → 25.
        let input = onDay(25, 2025, 1, 1, "a") + onDay(24, 2025, 1, 3, "b")
        #expect(DayGrouping.adaptiveThreshold(for: input, calendar: c) == 25)
    }

    @Test("the payoff: a right-skewed year lifts the bar so only the heavy day stands alone")
    func rightSkewGroupsCorrectly() {
        // Four ordinary 5-photo days (Jan 1–4, consecutive) + one 100-photo day (Jan 5).
        let ordinary = onDay(5, 2025, 1, 1, "a") + onDay(5, 2025, 1, 2, "b")
            + onDay(5, 2025, 1, 3, "e") + onDay(5, 2025, 1, 4, "f")
        let heavy = onDay(100, 2025, 1, 5, "h")
        let input = ordinary + heavy

        // mean = (20 + 100) / 5 active days = 24 → the ordinary 5-photo days fall well under it.
        let threshold = DayGrouping.adaptiveThreshold(for: input, calendar: c)
        #expect(threshold == 24)

        // With that threshold, the four quiet days merge into one run and the heavy day stands alone.
        let groups = DayGrouping.groups(for: input, threshold: threshold, gapToleranceDays: 1, calendar: c)
        #expect(groups.count == 2)
        #expect(groups[0].isBusyDay == false)                       // the merged quiet run …
        #expect(groups[0].days == [dk(2025, 1, 1), dk(2025, 1, 2), dk(2025, 1, 3), dk(2025, 1, 4)])
        #expect(groups[1].isBusyDay == true)                        // … then the standalone heavy day
        #expect(groups[1].days == [dk(2025, 1, 5)])
        // Sanity: a fixed threshold of 10 would ALSO isolate the 100-day here — but on a heavy shooter
        // (mean 40) the adaptive bar rises so 15-photo days merge instead of each standing alone.
    }
}

@Suite("DayGrouping — tiny quiet-run folding")
struct TinyQuietRunFoldingTests {
    private let c = utcCalendar()

    private func onDay(_ n: Int, _ y: Int, _ m: Int, _ d: Int, _ prefix: String) -> [AssetRef] {
        (0..<n).map { asset("\(prefix)\($0)", y, m, d, calendar: c) }
    }

    @Test("a lone tiny quiet day, stranded by gaps, folds into the preceding quiet run")
    func foldsLoneTinyDay() {
        // Two substantial quiet days (12 photos each; threshold 30 keeps them quiet) with a stranded
        // 2-photo Jan 5 between them — exactly the "2 pic cluster" weirdness. The 3-day gaps isolate all
        // three. 2 < floor(10) → the orphan folds into the preceding run; the 12-photo runs don't.
        let input = onDay(12, 2025, 1, 1, "a") + onDay(2, 2025, 1, 5, "orphan") + onDay(12, 2025, 1, 8, "c")
        let groups = DayGrouping.groups(for: input, threshold: 30, gapToleranceDays: 1, calendar: c)
        #expect(groups.count == 2)                                   // not 3 — the orphan folded
        #expect(groups[0].days == [dk(2025, 1, 1), dk(2025, 1, 5)])  // Jan 5 folded back into Jan 1
        #expect(groups[0].count == 14)
        #expect(groups[0].isBusyDay == false)
        #expect(groups[1].days == [dk(2025, 1, 8)])
    }

    @Test("isolated but substantial quiet runs (≥ floor) are NOT folded")
    func keepsSubstantialRuns() {
        // Three 12-photo days (threshold 30 keeps them quiet), each isolated by 3-day gaps.
        // 12 ≥ minStandaloneQuietRun(10) → each stays its own section.
        let input = onDay(12, 2025, 1, 1, "a") + onDay(12, 2025, 1, 4, "b") + onDay(12, 2025, 1, 7, "c")
        let groups = DayGrouping.groups(for: input, threshold: 30, gapToleranceDays: 1, calendar: c)
        #expect(groups.count == 3)
    }

    @Test("a tiny quiet day after a busy day stays its own group (never folds into a busy day)")
    func doesNotFoldIntoBusyDay() {
        let input = onDay(12, 2025, 1, 1, "busy") + onDay(2, 2025, 1, 4, "tiny")
        let groups = DayGrouping.groups(for: input, threshold: 10, gapToleranceDays: 1, calendar: c)
        #expect(groups.count == 2)
        #expect(groups[0].isBusyDay == true)
        #expect(groups[1].days == [dk(2025, 1, 4)])
        #expect(groups[1].count == 2)
    }

    @Test("chained tiny quiet days each fold into the growing preceding run (accumulator path)")
    func foldsChainedTinyDays() {
        // A 12-photo anchor, then TWO stranded tiny days (3, then 4), each isolated by 3-day gaps. The
        // second folds into the run the first already grew — the transitive-chaining branch.
        let input = onDay(12, 2025, 1, 1, "a") + onDay(3, 2025, 1, 5, "x") + onDay(4, 2025, 1, 9, "y")
        let groups = DayGrouping.groups(for: input, threshold: 30, gapToleranceDays: 1, calendar: c)
        #expect(groups.count == 1)
        #expect(groups[0].count == 19)
        #expect(groups[0].days == [dk(2025, 1, 1), dk(2025, 1, 5), dk(2025, 1, 9)])   // chronological, non-contiguous
        #expect(groups[0].isBusyDay == false)
    }

    @Test("a tiny quiet run at the very start stays its own group (nothing precedes it)")
    func doesNotFoldLeadingTinyRun() {
        // The `out.last == nil` branch — a leading orphan has no preceding run to fold into.
        let input = onDay(2, 2025, 1, 1, "tiny") + onDay(12, 2025, 1, 5, "a")
        let groups = DayGrouping.groups(for: input, threshold: 30, gapToleranceDays: 1, calendar: c)
        #expect(groups.count == 2)
        #expect(groups[0].days == [dk(2025, 1, 1)])
        #expect(groups[0].count == 2)
    }
}
