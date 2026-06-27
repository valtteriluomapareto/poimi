//
//  PropertyTests.swift
//  CurationTests — genuinely property-based coverage of the pure math (D24, #56).
//
//  The other suites pin concrete examples; these explore the input space with randomized
//  inputs. Each case is seeded by its argument index, so runs are **deterministic and
//  reproducible** (a failure names the exact seed) while still covering thousands of inputs —
//  the property-based testing D24 called for, without flaky randomness.
//

import Testing
import Foundation
@testable import Curation

// `SeededRNG` and `utcCalendar` live in TestSupport.swift.

@Suite("Curation properties (#56, D24)")
struct PropertyTests {
    private let c = utcCalendar()
    private let base = utcCalendar().date(from: DateComponents(year: 2025, month: 1, day: 1))!

    /// Build a randomized asset set: unique ids, a mix of dated (spread across ~3 months) and
    /// undated assets, in arbitrary order.
    private func randomAssets(_ rng: inout SeededRNG, max: Int) -> [AssetRef] {
        let n = Int.random(in: 0...max, using: &rng)
        var assets: [AssetRef] = []
        for i in 0..<n {
            if Int.random(in: 0...5, using: &rng) == 0 {
                assets.append(AssetRef(id: "a\(i)", captureDate: nil))
            } else {
                let date = c.date(byAdding: DateComponents(day: Int.random(in: 0...90, using: &rng),
                                                            hour: Int.random(in: 0..<24, using: &rng)),
                                  to: base)!
                assets.append(AssetRef(id: "a\(i)", captureDate: date))
            }
        }
        assets.shuffle(using: &rng)   // the grouping must sort defensively
        return assets
    }

    @Test("DayGrouping output partitions the input, is chronological, and classifies busy days",
          arguments: 0..<250)
    func groupingProperties(seed: Int) {
        var rng = SeededRNG(seed: UInt64(seed))
        let assets = randomAssets(&rng, max: 60)
        let threshold = Int.random(in: 1...12, using: &rng)
        let gapTolerance = Int.random(in: 0...3, using: &rng)

        let groups = DayGrouping.groups(for: assets, threshold: threshold,
                                        gapToleranceDays: gapTolerance, calendar: c)
        let flat = groups.flatMap(\.assetIDs)

        // 1. Partition: every input id appears exactly once across the groups — no loss, no dup.
        #expect(flat.count == assets.count)
        #expect(Set(flat) == Set(assets.map(\.id)))
        // 2. Group ids are unique (DayGroup is Identifiable; a SwiftUI ForEach relies on it).
        #expect(Set(groups.map(\.id)).count == groups.count)
        // 3. No empty groups.
        #expect(groups.allSatisfy { !$0.assetIDs.isEmpty })
        // 4. A busy-day group is exactly one day with >= threshold assets.
        for group in groups where group.isBusyDay {
            #expect(group.days.count == 1)
            #expect(group.assetIDs.count >= threshold)
        }
        // 5. Chronological: dated assets are oldest→newest; all undated trail at the end.
        let dateByID = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0.captureDate) })
        let datesInOrder = flat.map { dateByID[$0] ?? nil }
        if let firstUndated = datesInOrder.firstIndex(where: { $0 == nil }) {
            #expect(datesInOrder[firstUndated...].allSatisfy { $0 == nil })   // nils only at the tail
        }
        let dated = datesInOrder.compactMap { $0 }
        #expect(dated == dated.sorted())
    }

    @Test("TargetProgress stays in bounds and its derived fields are consistent", arguments: 0..<250)
    func targetProgressProperties(seed: Int) {
        var rng = SeededRNG(seed: UInt64(seed))
        let picked = Int.random(in: -50...500, using: &rng)
        let target = Int.random(in: -20...300, using: &rng)
        let progress = TargetProgress(picked: picked, target: target)

        #expect(progress.fraction >= 0 && progress.fraction <= 1)        // clamped both ends
        #expect(progress.remaining >= 0)                                 // never negative
        #expect(progress.remaining == max(0, target - picked))
        #expect(progress.isComplete == (target > 0 && picked >= target))
        if progress.isComplete { #expect(progress.fraction == 1) }       // complete ⇒ full bar
    }

    @Test("CompletionStats invariants hold for arbitrary assets / done-days / selection",
          arguments: 0..<250)
    func completionStatsProperties(seed: Int) {
        var rng = SeededRNG(seed: UInt64(seed))
        let assets = randomAssets(&rng, max: 30)

        var doneDays: Set<DayKey> = []
        for day in Set(assets.map { $0.dayKey(in: c) }) where Bool.random(using: &rng) {
            doneDays.insert(day)
        }
        var selection: Set<String> = []
        for asset in assets where Bool.random(using: &rng) { selection.insert(asset.id) }
        if Bool.random(using: &rng) { selection.insert("ghost") }   // a selected id NOT in assets

        let stats = CompletionStats(assets: assets, doneDays: doneDays, selection: selection, calendar: c)
        #expect(stats.kept >= 0)
        #expect(stats.kept <= stats.markedDone)              // kept is a subset of marked-done
        #expect(stats.kept <= stats.totalPicked)
        #expect(stats.markedDone <= assets.count)
        #expect(stats.totalPicked <= assets.count)           // the "ghost" id never inflates it
        #expect(stats.fractionKept >= 0 && stats.fractionKept <= 1)   // %-kept can't exceed 100
    }

    @Test("gapToleranceDays decides whether a quiet run merges across a calendar gap",
          arguments: 0..<60)
    func gapToleranceControlsRunBreaks(seed: Int) {
        var rng = SeededRNG(seed: UInt64(seed))
        let gap = Int.random(in: 1...6, using: &rng)        // calendar days between two quiet days
        let tolerance = Int.random(in: 0...6, using: &rng)
        let first = AssetRef(id: "a", captureDate: base)
        let second = AssetRef(id: "b", captureDate: c.date(byAdding: .day, value: gap, to: base)!)

        // threshold high → both days are sub-threshold (quiet); only the gap rule can split them.
        let groups = DayGrouping.groups(for: [first, second], threshold: 100,
                                        gapToleranceDays: tolerance, calendar: c)
        #expect(groups.count == (gap <= tolerance ? 1 : 2))
    }

    @Test("suggestedPerSection rounds to nearest (away from zero) and guards non-positive inputs")
    func suggestedPerSectionRounding() {
        #expect(Target.suggestedPerSection(target: 200, sectionCount: 8) == 25)   // exact
        #expect(Target.suggestedPerSection(target: 10, sectionCount: 4) == 3)     // 2.5 → 3
        #expect(Target.suggestedPerSection(target: 7, sectionCount: 2) == 4)      // 3.5 → 4
        #expect(Target.suggestedPerSection(target: 5, sectionCount: 0) == nil)    // no sections
        #expect(Target.suggestedPerSection(target: 0, sectionCount: 8) == nil)    // no target
    }
}
