//
//  ViewerWindowTests.swift
//  PoimiAppTests — the photo viewer's render-window slice (#36 freeze guard).
//
//  `viewerWindow` is the load-bearing arithmetic of the viewer's freeze fix: a `LazyHStack`
//  positioned at a mid-list id materializes its whole prefix, so the viewer renders only a bounded
//  window around the current photo. These pin the invariants a flipped bound would silently break
//  (re-introducing the thousands-of-pages hang) — the same "pull it out of the View and test it"
//  pattern as `clampedColumnCount` / `PrefetchWindow`.
//

import Testing
@testable import PoimiApp

@Suite("Viewer render window (#36)")
struct ViewerWindowTests {

    @Test("a mid-list window spans back…forward around the index, bounded")
    func midList() {
        let range = viewerWindow(count: 8118, around: 4000, back: 34, forward: 34)
        #expect(range == 3966..<4035)        // 4000-34 … 4000+34+1
        #expect(range.contains(4000))
        #expect(range.count == 69)
        #expect(range.count <= 34 + 34 + 1)
    }

    @Test("clamps at the low end without going negative")
    func clampLow() {
        let range = viewerWindow(count: 8118, around: 3, back: 34, forward: 34)
        #expect(range.lowerBound == 0)
        #expect(range.contains(3))
    }

    @Test("clamps at the high end to count (never past the last index)")
    func clampHigh() {
        let range = viewerWindow(count: 8118, around: 8116, back: 34, forward: 34)
        #expect(range.upperBound == 8118)
        #expect(range.contains(8116))
    }

    @Test("a tiny album yields the whole list")
    func tinyAlbum() {
        #expect(viewerWindow(count: 5, around: 2, back: 34, forward: 34) == 0..<5)
    }

    @Test("an out-of-range index is clamped into the list (no trap)")
    func outOfRangeIndex() {
        #expect(viewerWindow(count: 10, around: 999, back: 3, forward: 3).contains(9))
        #expect(viewerWindow(count: 10, around: -5, back: 3, forward: 3).contains(0))
    }

    @Test("an empty list yields an empty range rather than trapping")
    func emptyList() {
        #expect(viewerWindow(count: 0, around: 0, back: 34, forward: 34) == 0..<0)
    }

    @Test("invariant: for every index the window contains it and stays bounded")
    func invariant() {
        let count = 500, back = 34, forward = 34
        for index in 0..<count {
            let range = viewerWindow(count: count, around: index, back: back, forward: forward)
            #expect(range.contains(index), "window must contain its center index \(index)")
            #expect(range.count <= back + forward + 1, "window must not exceed back+forward+1")
            #expect(range.lowerBound >= 0 && range.upperBound <= count, "window must stay in bounds")
        }
    }
}
