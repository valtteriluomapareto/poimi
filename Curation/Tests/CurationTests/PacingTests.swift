//
//  PacingTests.swift
//  CurationTests — pick-vs-target pacing + over-target math (#170, docs/design/pacing.md).
//
//  Pins the pure domain the pacing UI leans on: the unclamped over-target reading on `TargetProgress`,
//  the `pickFrontierFraction` denominator, and the `Pacing` projection (confidence gate + pace bands).
//  Orientation only (D5) — this math never enforces; the view maps it to colour/copy.
//

import Testing
import Foundation
@testable import Curation

@Suite("Over-target (unclamped) — #170")
struct OverTargetTests {
    @Test("overage / isOver are 0 / false at or under the target")
    func atOrUnder() {
        let under = TargetProgress(picked: 96, target: 200)
        #expect(under.overage == 0)
        #expect(!under.isOver)

        let exactly = TargetProgress(picked: 200, target: 200)
        #expect(exactly.overage == 0)
        #expect(!exactly.isOver)          // reached, not OVER (strict)
        #expect(exactly.isComplete)       // still counts as complete (unchanged)
    }

    @Test("overage is the unclamped surplus past the target; isOver is true")
    func over() {
        let over = TargetProgress(picked: 212, target: 200)
        #expect(over.overage == 12)
        #expect(over.isOver)
        #expect(over.remaining == 0)      // the clamped reading the overage exposes
    }

    @Test("a non-positive target never reads as over")
    func noTarget() {
        let none = TargetProgress(picked: 5, target: 0)
        #expect(none.overage == 0)
        #expect(!none.isOver)
    }
}

@Suite("Pick frontier — #170")
struct PickFrontierTests {
    private let ids = ["a", "b", "c", "d"]

    @Test("nothing picked → frontier 0")
    func none() {
        #expect(pickFrontierFraction(orderedIDs: ids, selected: []) == 0)
    }

    @Test("the frontier is the position of the LATEST-dated pick, not the count")
    func latestPosition() {
        #expect(pickFrontierFraction(orderedIDs: ids, selected: ["a"]) == 0.25)          // idx 0 → 1/4
        #expect(pickFrontierFraction(orderedIDs: ids, selected: ["b", "c"]) == 0.75)     // idx 2 → 3/4
        // Two picks far apart: only the latest (d) sets the frontier — a single early pick doesn't matter.
        #expect(pickFrontierFraction(orderedIDs: ids, selected: ["a", "d"]) == 1.0)      // idx 3 → 4/4
    }

    @Test("a lone last pick → frontier 1")
    func loneLast() {
        #expect(pickFrontierFraction(orderedIDs: ids, selected: ["d"]) == 1.0)
    }

    @Test("unknown ids are ignored (not in the ordered universe)")
    func unknownIgnored() {
        #expect(pickFrontierFraction(orderedIDs: ids, selected: ["zzz"]) == 0)
    }

    @Test("an empty candidate list → frontier 0 (no trap)")
    func emptyList() {
        #expect(pickFrontierFraction(orderedIDs: [], selected: ["a"]) == 0)
    }

    @Test("undated sorts LAST → an undated pick collapses the frontier to ~1 (graceful under-warn)")
    func undatedTailCollapses() {
        // The ordered list is dated-then-undated; picking only an undated photo lands at the tail.
        let withUndated = ["jan1", "jan2", "feb1", "undated1"]
        #expect(pickFrontierFraction(orderedIDs: withUndated, selected: ["undated1"]) == 1.0)
        // → a Pacing built on this frontier projects ≈ picked and the card goes quiet (never false-alarms).
    }
}

@Suite("Pacing projection — #170")
struct PacingProjectionTests {
    @Test("the headline case: under target now, projected to OVERSHOOT")
    func projectedOvershoot() {
        // 96 picks reaching 30% of the album → ~320 projected; well past the 200 target.
        let pacing = Pacing(picked: 96, frontier: 0.30, target: 200)
        #expect(pacing.projectedTotal == 320)
        #expect(pacing.pace == .ahead)
    }

    @Test("no projection below the confidence floor (thin coverage is noise)")
    func belowFloor() {
        let pacing = Pacing(picked: 8, frontier: 0.04, target: 200)
        #expect(pacing.projectedTotal == nil)
        #expect(pacing.pace == nil)
    }

    @Test("picked == 0 → frontier 0 → no projection")
    func nothingPicked() {
        let pacing = Pacing(picked: 0, frontier: 0, target: 200)
        #expect(pacing.projectedTotal == nil)
        #expect(pacing.pace == nil)
    }

    @Test("a non-positive target → no projection / no pace")
    func noTarget() {
        let pacing = Pacing(picked: 50, frontier: 0.5, target: 0)
        #expect(pacing.projectedTotal == nil)
        #expect(pacing.pace == nil)
    }

    @Test("the confidence floor is inclusive (0.15 → shown), and projected == target reads onPace")
    func floorBoundaryAndExactTarget() {
        let pacing = Pacing(picked: 30, frontier: 0.15, target: 200)   // 30 / 0.15 = 200
        #expect(pacing.projectedTotal == 200)
        #expect(pacing.pace == .onPace)
    }

    @Test("rounding: projectedTotal is the rounded density projection")
    func rounding() {
        // 10 / 0.30 = 33.33… → 33
        #expect(Pacing(picked: 10, frontier: 0.30, target: 100).projectedTotal == 33)
        // 10 / 0.28 = 35.71… → 36
        #expect(Pacing(picked: 10, frontier: 0.28, target: 100).projectedTotal == 36)
    }
}

@Suite("Pace bands — #170")
struct PaceBandTests {
    /// frontier 1.0 makes projectedTotal == picked, so these pin the band edges against the ROUNDED
    /// projection the UI shows (target 200).
    @Test("±10% dead-band edges: <0.90 behind · [0.90, 1.10] onPace · >1.10 ahead")
    func bands() {
        func pace(_ picked: Int) -> Pace? { Pacing(picked: picked, frontier: 1.0, target: 200).pace }
        #expect(pace(179) == .behind)    // 0.895
        #expect(pace(180) == .onPace)    // 0.90  — inclusive lower edge
        #expect(pace(200) == .onPace)    // 1.00
        #expect(pace(220) == .onPace)    // 1.10  — inclusive upper edge
        #expect(pace(221) == .ahead)     // 1.105
    }

    @Test("a small target still bands correctly through the rounding")
    func smallTarget() {
        #expect(Pacing(picked: 11, frontier: 1.0, target: 10).pace == .onPace)   // 1.10
        #expect(Pacing(picked: 12, frontier: 1.0, target: 10).pace == .ahead)    // 1.20
    }
}
