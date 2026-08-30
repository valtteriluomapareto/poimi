//
//  PrefetchWindowTests.swift
//  PoimiAppTests — the grid's scroll-driven prefetch slice (#35).
//
//  The windowing is the "stays smooth over thousands of assets" exit criterion, so its index math
//  is pinned here as a pure value, independent of the grid View.
//

import Testing
import Foundation
@testable import PoimiApp

@Suite("PrefetchWindow (#35)")
struct PrefetchWindowTests {

    private static let ids = (0..<100).map { "id\($0)" }
    private static let window = PrefetchWindow(orderedIDs: ids)

    @Test("no visible cells yet primes the head of the slice")
    func headPrime() {
        // headCount = columnCount * (rowMargin + 1) * 2 = 3 * 3 * 2 = 18.
        let slice = Self.window.slice(visibleIDs: [], columnCount: 3, rowMargin: 2)
        #expect(slice == Array(Self.ids.prefix(18)))
    }

    @Test("a mid-scroll visible range expands by columnCount * rowMargin on each side")
    func midRange() {
        // visible {id30}: margin = 3*2 = 6 → [24, 36].
        let slice = Self.window.slice(visibleIDs: ["id30"], columnCount: 3, rowMargin: 2)
        #expect(slice == (24...36).map { "id\($0)" })
    }

    @Test("the window clamps at the start and end of the slice")
    func clamps() {
        let atStart = Self.window.slice(visibleIDs: ["id0"], columnCount: 3, rowMargin: 2)
        #expect(atStart == (0...6).map { "id\($0)" })          // lower clamped to 0
        let atEnd = Self.window.slice(visibleIDs: ["id98", "id99"], columnCount: 3, rowMargin: 2)
        #expect(atEnd == (92...99).map { "id\($0)" })          // upper clamped to 99
    }

    @Test("spans the full visible min…max range across section boundaries")
    func spansVisibleRange() {
        let slice = Self.window.slice(visibleIDs: ["id40", "id50", "id45"], columnCount: 4, rowMargin: 1)
        // min 40, max 50, margin 4 → [36, 54].
        #expect(slice == (36...54).map { "id\($0)" })
    }

    @Test("an empty slice yields nothing; stale visible ids yield nothing")
    func emptyAndStale() {
        #expect(PrefetchWindow(orderedIDs: []).slice(visibleIDs: ["id0"], columnCount: 3, rowMargin: 2).isEmpty)
        // Visible ids that aren't in this grouping (a stale set after re-group) contribute no range.
        #expect(Self.window.slice(visibleIDs: ["gone/1", "gone/2"], columnCount: 3, rowMargin: 2).isEmpty)
    }
}

/// The bounded "warm the neighbours" set (#277) — which ids the grid primes for the pages either side
/// of the current one, so a swipe doesn't land on a screen of placeholders. Pure math, pinned here for
/// the same reason as `slice`: it is a memory bound as much as a smoothness one.
@Suite("PrefetchWindow.adjacentHeadIDs (#277)")
struct AdjacentHeadIDsTests {

    /// Three pages of 40 ids each, namespaced per page so a wrong page is obvious in a failure.
    private static let clusters: [[String]] = (0..<3).map { page in
        (0..<40).map { "p\(page)-\($0)" }
    }

    /// The head bound, the same formula `slice`'s empty-visible path uses: 3 * (2 + 1) * 2 = 18.
    private static func head(_ page: Int, _ count: Int = 18) -> [String] {
        Array(clusters[page].prefix(count))
    }

    @Test("a middle page warms the next page's head, then the previous page's")
    func middlePage() {
        let heads = PrefetchWindow.adjacentHeadIDs(clusters: Self.clusters, currentIndex: 1,
                                                   columnCount: 3, rowMargin: 2)
        // Next first (the likelier swipe direction), then previous — 18 ids each.
        #expect(heads == Self.head(2) + Self.head(0))
    }

    @Test("the first and last pages warm their single neighbour")
    func clampsAtTheEnds() {
        let atStart = PrefetchWindow.adjacentHeadIDs(clusters: Self.clusters, currentIndex: 0,
                                                     columnCount: 3, rowMargin: 2)
        #expect(atStart == Self.head(1))
        let atEnd = PrefetchWindow.adjacentHeadIDs(clusters: Self.clusters, currentIndex: 2,
                                                   columnCount: 3, rowMargin: 2)
        #expect(atEnd == Self.head(1))
    }

    @Test("a single-cluster album warms nothing")
    func singleCluster() {
        let heads = PrefetchWindow.adjacentHeadIDs(clusters: [Self.clusters[0]], currentIndex: 0,
                                                   columnCount: 3, rowMargin: 2)
        #expect(heads.isEmpty)
    }

    @Test("no clusters, or a page index out of range, warms nothing")
    func emptyAndOutOfRange() {
        #expect(PrefetchWindow.adjacentHeadIDs(clusters: [], currentIndex: 0,
                                               columnCount: 3, rowMargin: 2).isEmpty)
        #expect(PrefetchWindow.adjacentHeadIDs(clusters: Self.clusters, currentIndex: 7,
                                               columnCount: 3, rowMargin: 2).isEmpty)
        #expect(PrefetchWindow.adjacentHeadIDs(clusters: Self.clusters, currentIndex: -1,
                                               columnCount: 3, rowMargin: 2).isEmpty)
    }

    @Test("a neighbour shorter than the head bound contributes all of its ids, not a padded head")
    func shortNeighbour() {
        let short = [["a", "b"], Self.clusters[1], ["y", "z"]]
        let heads = PrefetchWindow.adjacentHeadIDs(clusters: short, currentIndex: 1,
                                                   columnCount: 3, rowMargin: 2)
        #expect(heads == ["y", "z", "a", "b"])
    }

    @Test("the current page's own ids are never re-warmed, and neighbours don't repeat each other")
    func dedupes() {
        // A pathological timeline: the neighbours share ids with the current page and with each other
        // (a re-scan can hand the grid overlapping groupings). Every returned id must be unique and
        // none may belong to the current page — the live window already owns those.
        let overlapping = [["a", "b", "c"], ["c", "d"], ["d", "e", "b"]]
        let heads = PrefetchWindow.adjacentHeadIDs(clusters: overlapping, currentIndex: 1,
                                                   columnCount: 3, rowMargin: 2)
        // Page 2 minus the current page's {c, d} → ["e", "b"]; then page 0 minus everything seen → ["a"].
        #expect(heads == ["e", "b", "a"])
        #expect(Set(heads).count == heads.count)
        #expect(heads.allSatisfy { !overlapping[1].contains($0) })
    }

    @Test("the head bound scales with the column count (an iPad page warms more)")
    func boundScalesWithColumns() {
        // 8 columns, rowMargin 2 → 8 * 3 * 2 = 48 ids per neighbour, capped by the cluster's length.
        let heads = PrefetchWindow.adjacentHeadIDs(clusters: Self.clusters, currentIndex: 1,
                                                   columnCount: 8, rowMargin: 2)
        #expect(heads == Self.clusters[2] + Self.clusters[0])   // 40 < 48 → the whole page, both sides
        #expect(heads.count == 80)

        // 2 columns, rowMargin 1 → 2 * 2 * 2 = 8 per neighbour.
        let narrow = PrefetchWindow.adjacentHeadIDs(clusters: Self.clusters, currentIndex: 1,
                                                    columnCount: 2, rowMargin: 1)
        #expect(narrow == Self.head(2, 8) + Self.head(0, 8))
    }

    @Test("degenerate column/margin inputs still yield a bounded, non-empty head")
    func degenerateInputs() {
        // columnCount 0 (a pre-layout width) clamps to 1 → 1 * (0 + 1) * 2 = 2 ids per neighbour.
        let heads = PrefetchWindow.adjacentHeadIDs(clusters: Self.clusters, currentIndex: 1,
                                                   columnCount: 0, rowMargin: 0)
        #expect(heads == Self.head(2, 2) + Self.head(0, 2))
        // A negative margin behaves like 0 rather than emptying (or inverting) the head.
        let negative = PrefetchWindow.adjacentHeadIDs(clusters: Self.clusters, currentIndex: 1,
                                                      columnCount: 3, rowMargin: -5)
        #expect(negative == Self.head(2, 6) + Self.head(0, 6))
    }
}
