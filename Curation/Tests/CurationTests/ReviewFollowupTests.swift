//
//  ReviewFollowupTests.swift
//  CurationTests — fixes + property/edge coverage from the #25 review panel.
//

import Testing
import Foundation
@testable import Curation

// Fixtures (`utcCalendar`, `asset`, `dk`) live in TestSupport.swift.

// MARK: - DayKey string round-trip (Architect minor)

@Suite("DayKey string round-trip (review)")
struct DayKeyStringTests {
    @Test("description and init(_:) round-trip")
    func roundTrip() {
        for key in [DayKey.day(year: 2025, month: 6, day: 20), .day(year: 1, month: 1, day: 1), .undated] {
            #expect(DayKey(key.description) == key)
        }
    }

    @Test("Codable encodes as the canonical string")
    func codableIsString() throws {
        let data = try JSONEncoder().encode(dk(2025, 6, 20))
        #expect(String(data: data, encoding: .utf8) == "\"2025-06-20\"")
        let undated = try JSONEncoder().encode(DayKey.undated)
        #expect(String(data: undated, encoding: .utf8) == "\"undated\"")
        #expect(try JSONDecoder().decode(DayKey.self, from: data) == dk(2025, 6, 20))
    }

    @Test("invalid strings fail to parse / decode")
    func invalid() {
        #expect(DayKey("nope") == nil)
        #expect(DayKey("2025-06") == nil)
        #expect(DayKey("2025--20") == nil)
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(DayKey.self, from: Data("\"bad\"".utf8))
        }
    }

    @Test("a doneDays set survives the [String] persistence round-trip")
    func persistenceRoundTrip() {
        let days: Set<DayKey> = [dk(2025, 3, 16), dk(2025, 3, 17), .undated]
        let stored = days.map(\.description)                 // what SwiftData persists ([String])
        let restored = Set(stored.compactMap(DayKey.init))
        #expect(restored == days)
    }
}

// MARK: - Grouping robustness (Tester + Codex)

@Suite("Grouping robustness (review)")
struct GroupingRobustnessTests {
    private let c = utcCalendar()

    @Test("unsorted / descending input still groups chronologically")
    func unsortedInput() {
        let input = [asset("d2", 2025, 1, 2, calendar: c), asset("d1", 2025, 1, 1, calendar: c)]
        let groups = DayGrouping.groups(for: input, threshold: 10, gapToleranceDays: 1, calendar: c)
        #expect(groups.count == 1)
        #expect(groups[0].days == [dk(2025, 1, 1), dk(2025, 1, 2)])
        #expect(groups[0].assetIDs == ["d1", "d2"])          // chronological, not input order
    }

    @Test("interleaved duplicate days group together, ordered by time")
    func interleavedDuplicateDay() {
        let input = [asset("a", 2025, 1, 1, hour: 9, calendar: c),
                     asset("b", 2025, 1, 2, calendar: c),
                     asset("c", 2025, 1, 1, hour: 18, calendar: c)]
        let flat = DayGrouping.groups(for: input, calendar: c).flatMap(\.assetIDs)
        #expect(flat == ["a", "c", "b"])                     // Jan-1 (a then c), then Jan-2
        #expect(Set(flat) == Set(input.map(\.id)))           // partition: no loss / dup
    }

    @Test("all-undated input yields one trailing Undated group")
    func allUndated() {
        let input = [AssetRef(id: "u1", captureDate: nil), AssetRef(id: "u2", captureDate: nil)]
        let groups = DayGrouping.groups(for: input, calendar: c)
        #expect(groups.count == 1)
        #expect(groups[0].isUndated)
        #expect(groups[0].assetIDs == ["u1", "u2"])
    }

    @Test("threshold <= 0 makes every dated day a busy group")
    func thresholdZero() {
        let input = [asset("a", 2025, 1, 1, calendar: c), asset("b", 2025, 1, 2, calendar: c)]
        let groups = DayGrouping.groups(for: input, threshold: 0, calendar: c)
        #expect(groups.count == 2)
        let allBusy = groups.allSatisfy(\.isBusyDay)
        #expect(allBusy)
    }

    @Test("midnight in a non-UTC zone keys to the local day")
    func midnightLocalDay() {
        let helsinki = utcCalendar("Europe/Helsinki")
        // Local 2025-06-20 00:00 Helsinki is the prior UTC day — must key to the local 20th.
        let midnight = helsinki.date(from: DateComponents(year: 2025, month: 6, day: 20, hour: 0))!
        #expect(DayKey(date: midnight, calendar: helsinki) == dk(2025, 6, 20))
    }

    @Test("output is a partition of the input ids across several sizes (reversed input)")
    func partitionProperty() {
        for n in [1, 5, 37, 200] {
            var input = (0..<n).map { i in
                asset("a\(i)", 2025, (i / 28) + 1, (i % 28) + 1, calendar: c)
            }
            input.reverse()                                  // exercise the defensive sort
            let flat = DayGrouping.groups(for: input, threshold: 3, calendar: c).flatMap(\.assetIDs)
            #expect(flat.count == input.count)               // no loss / dup
            #expect(Set(flat) == Set(input.map(\.id)))       // partition
        }
    }
}

// MARK: - Done-but-changed reconcile (Architect + Tester, D32(d))

@Suite("Done-but-changed reconcile (review)")
struct ReconcileTests {
    private let c = utcCalendar()

    @Test("a new photo on a done day re-opens that day")
    func newPhotoReopens() {
        let previous = [asset("a", 2025, 3, 16, calendar: c)]
        let current = previous + [asset("b", 2025, 3, 16, calendar: c)]   // count 1 → 2
        let reconciled = Completion.reopening(doneDays: [dk(2025, 3, 16)], from: previous, to: current, calendar: c)
        #expect(!reconciled.contains(dk(2025, 3, 16)))
    }

    @Test("a deletion on a done day does NOT re-open it")
    func deletionKeepsDone() {
        let previous = [asset("a", 2025, 3, 16, calendar: c), asset("b", 2025, 3, 16, calendar: c)]
        let current = [asset("a", 2025, 3, 16, calendar: c)]              // count 2 → 1
        let reconciled = Completion.reopening(doneDays: [dk(2025, 3, 16)], from: previous, to: current, calendar: c)
        #expect(reconciled.contains(dk(2025, 3, 16)))
    }

    @Test("unchanged stays done; a new photo on a not-done day is a no-op")
    func unchangedAndNotDone() {
        let previous = [asset("a", 2025, 3, 16, calendar: c)]
        let current = previous + [asset("b", 2025, 3, 17, calendar: c)]   // grows a NOT-done day
        let reconciled = Completion.reopening(doneDays: [dk(2025, 3, 16)], from: previous, to: current, calendar: c)
        #expect(reconciled == [dk(2025, 3, 16)])
    }

    // Regression (whole-repo review): add-and-delete churn must re-open even when the count is
    // equal or smaller, because the day gained brand-new, unreviewed ids. Count-based reconcile
    // (the old impl) wrongly kept these days "done".
    @Test("equal-count replacement (all ids new) re-opens the done day")
    func equalCountReplacementReopens() {
        let previous = [asset("a", 2025, 3, 16, calendar: c), asset("b", 2025, 3, 16, calendar: c)]
        let current = [asset("c", 2025, 3, 16, calendar: c), asset("d", 2025, 3, 16, calendar: c)]  // 2 → 2, new ids
        let reconciled = Completion.reopening(doneDays: [dk(2025, 3, 16)], from: previous, to: current, calendar: c)
        #expect(!reconciled.contains(dk(2025, 3, 16)))
    }

    @Test("net-shrink with an addition re-opens the done day")
    func shrinkWithAdditionReopens() {
        let previous = [asset("a", 2025, 3, 16, calendar: c),
                        asset("b", 2025, 3, 16, calendar: c),
                        asset("e", 2025, 3, 16, calendar: c)]
        let current = [asset("e", 2025, 3, 16, calendar: c), asset("d", 2025, 3, 16, calendar: c)]  // 3 → 2, "d" is new
        let reconciled = Completion.reopening(doneDays: [dk(2025, 3, 16)], from: previous, to: current, calendar: c)
        #expect(!reconciled.contains(dk(2025, 3, 16)))
    }

    @Test("a pure-deletion that lands on an .undated done section keeps it done")
    func undatedDeletionKeepsDone() {
        // covers the .undated bucket in reconcile (previously only dated days were tested)
        let previous = [asset("a", 2025, 3, 16, calendar: c), AssetRef(id: "u1", captureDate: nil)]
        let current = [asset("a", 2025, 3, 16, calendar: c)]   // undated section lost its only asset
        let reconciled = Completion.reopening(doneDays: [.undated], from: previous, to: current, calendar: c)
        #expect(reconciled.contains(.undated))                 // deletion never re-opens
    }
}

// MARK: - Bounds & filters as properties (Codex + Tester / D24)

@Suite("Bounds & filters (review)")
struct BoundsTests {
    private let c = utcCalendar()

    @Test("TargetProgress stays in bounds across a grid incl. negatives")
    func targetBounds() {
        let cases: [(picked: Int, target: Int)] =
            [(0, 0), (5, 0), (-5, 10), (0, 10), (5, 10), (10, 10), (20, 10), (-3, -2), (7, 3)]
        for value in cases {
            let progress = TargetProgress(picked: value.picked, target: value.target)
            #expect(progress.fraction >= 0 && progress.fraction <= 1)
            #expect(progress.remaining >= 0)
            if progress.isComplete { #expect(progress.fraction == 1) }
        }
    }

    @Test("negative picked clamps the fraction to 0")
    func negativePicked() {
        #expect(TargetProgress(picked: -5, target: 10).fraction == 0)
    }

    @Test("CompletionStats invariants hold across selection / doneDays combos")
    func statsInvariants() {
        let assets = [
            asset("a", 2025, 3, 16, calendar: c),
            asset("b", 2025, 3, 16, calendar: c),
            asset("c", 2025, 3, 17, calendar: c),
            AssetRef(id: "u", captureDate: nil)
        ]
        let dayCombos: [Set<DayKey>] = [
            [], [dk(2025, 3, 16)], [dk(2025, 3, 16), dk(2025, 3, 17)], [.undated], [dk(2025, 3, 16), .undated]
        ]
        let selectionCombos: [Set<String>] = [[], ["a"], ["a", "c"], ["a", "b", "c", "u"], ["u"]]
        for days in dayCombos {
            for selection in selectionCombos {
                let stats = CompletionStats(assets: assets, doneDays: days, selection: selection, calendar: c)
                #expect(stats.kept <= stats.markedDone)
                #expect(stats.kept <= stats.totalPicked)
                #expect(stats.markedDone <= assets.count)
                #expect(stats.totalPicked <= assets.count)
                #expect(stats.fractionKept >= 0 && stats.fractionKept <= 1)
            }
        }
    }

    @Test("filters compose; empty inputs are no-ops")
    func filterComposition() {
        let shot = AssetRef(id: "s", captureDate: nil, isScreenshot: true)
        let whatsApp = AssetRef(id: "w", captureDate: nil)
        let keep = AssetRef(id: "k", captureDate: nil)
        let out = Filtering.included([shot, whatsApp, keep], excludeScreenshots: true, excludedAssetIDs: ["w"])
        #expect(out.map(\.id) == ["k"])
        #expect(Filtering.included([], excludeScreenshots: true).isEmpty)
        #expect(Filtering.included([keep], excludeScreenshots: false).count == 1)
    }
}
