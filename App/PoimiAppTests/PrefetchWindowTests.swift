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
