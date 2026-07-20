//
//  PreviewStripTests.swift
//  CurationTests — the Overview cluster preview-strip sampling (#203).
//
//  Pins the picked-first preview ("what I kept from this day") + the even-sample fallback, and that the
//  picks-block leads the unpicked-block with chronological order preserved within each.
//

import Testing
@testable import Curation

@Suite("PreviewStrip — picked-first cluster preview")
struct PreviewStripTests {
    private let ids = (0..<10).map { "a\($0)" }   // a0…a9, chronological

    // MARK: even-sample fallback

    @Test("no picks → the even sample (unchanged v1 behavior)")
    func noPicksIsEvenSample() {
        #expect(PreviewStrip.pickedFirst(orderedIDs: ids, selected: [], count: 4)
                == PreviewStrip.evenlySampled(ids, count: 4))
    }

    @Test("evenlySampled: count bounds, count==1, all-when-small")
    func evenSampleBounds() {
        #expect(PreviewStrip.evenlySampled(ids, count: 0) == [])
        #expect(PreviewStrip.evenlySampled(ids, count: 1) == ["a0"])
        #expect(PreviewStrip.evenlySampled(["x", "y"], count: 5) == ["x", "y"])   // n <= count → all
        let sample = PreviewStrip.evenlySampled(ids, count: 4)
        #expect(sample.first == "a0" && sample.last == "a9")                      // first + last included
        #expect(sample.count == 4)
    }

    // MARK: picked-first

    @Test("some picks (< count) lead the strip, chronological, then an even spread of the unpicked")
    func picksThenBackfill() {
        let selected: Set<String> = ["a2", "a5"]
        let strip = PreviewStrip.pickedFirst(orderedIDs: ids, selected: selected, count: 5)
        #expect(strip.count == 5)
        #expect(Array(strip.prefix(2)) == ["a2", "a5"])              // all picks first, chronological
        let tail = Array(strip.dropFirst(2))
        #expect(tail.allSatisfy { !selected.contains($0) })          // then only unpicked
        #expect(tail == tail.sorted())                               // …chronological within the block
    }

    @Test("more picks than fit → an even spread ACROSS the picks, picks only (no unpicked)")
    func picksOverflowIsEvenSpreadOfPicks() {
        let selected: Set<String> = ["a0", "a1", "a2", "a3", "a4", "a5"]
        let strip = PreviewStrip.pickedFirst(orderedIDs: ids, selected: selected, count: 4)
        #expect(strip.count == 4)
        #expect(strip.allSatisfy { selected.contains($0) })          // picks only
        #expect(strip.first == "a0" && strip.last == "a5")           // spread across the picks
        #expect(strip == strip.sorted())                             // chronological
    }

    @Test("picks that exactly fill → those picks, in order (no unpicked backfill)")
    func picksExactlyFill() {
        let selected: Set<String> = ["a0", "a1", "a2", "a3"]
        #expect(PreviewStrip.pickedFirst(orderedIDs: ids, selected: selected, count: 4)
                == ["a0", "a1", "a2", "a3"])
    }

    @Test("all of a small cluster picked → every pick shown (backfill has nothing to add)")
    func allPickedSmallCluster() {
        let small = ["a0", "a1", "a2", "a3"]
        #expect(PreviewStrip.pickedFirst(orderedIDs: small, selected: Set(small), count: 6) == small)
    }

    @Test("count 0 → empty; a pick set with ids outside the cluster is ignored")
    func degenerate() {
        #expect(PreviewStrip.pickedFirst(orderedIDs: ids, selected: ["a1"], count: 0) == [])
        // "z9" isn't in the cluster → no picks in-cluster → even-sample fallback.
        #expect(PreviewStrip.pickedFirst(orderedIDs: ids, selected: ["z9"], count: 3)
                == PreviewStrip.evenlySampled(ids, count: 3))
    }

    @Test("result is independent of the selected-set's iteration (order comes from orderedIDs)")
    func deterministicOrder() {
        // The picks block always follows orderedIDs order, not Set iteration.
        let strip = PreviewStrip.pickedFirst(orderedIDs: ids, selected: ["a7", "a1", "a4"], count: 6)
        #expect(Array(strip.prefix(3)) == ["a1", "a4", "a7"])
    }

    @Test("ReviewCluster.previewStripIDs delegates to pickedFirst over the cluster's chronological ids")
    func clusterConvenience() {
        let group = DayGroup(id: "g", assetIDs: ids, days: [.day(year: 2025, month: 7, day: 5)], isBusyDay: true)
        let cluster = ReviewCluster.day(group)
        #expect(cluster.previewStripIDs(selected: ["a2", "a5"], count: 5)
                == PreviewStrip.pickedFirst(orderedIDs: ids, selected: ["a2", "a5"], count: 5))
    }
}
