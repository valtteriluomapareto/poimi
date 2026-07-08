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
import Curation
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

@Suite("Pager neighbour (#80)")
struct PagerNeighbourTests {
    private let ids = ["a", "b", "c", "d"]

    @Test("the next / previous id mid-list")
    func midList() {
        #expect(adjacentID(in: ids, to: "b", offset: 1) == "c")
        #expect(adjacentID(in: ids, to: "b", offset: -1) == "a")
    }

    @Test("no neighbour past the ends — the swipe-to-first/last crash guard")
    func edges() {
        #expect(adjacentID(in: ids, to: "a", offset: -1) == nil)   // nothing before the first
        #expect(adjacentID(in: ids, to: "d", offset: 1) == nil)    // nothing after the last
        #expect(adjacentID(in: ids, to: "a", offset: 1) == "b")    // but forward from the first is fine
        #expect(adjacentID(in: ids, to: "d", offset: -1) == "c")
    }

    @Test("an unknown id has no neighbour")
    func unknown() {
        #expect(adjacentID(in: ids, to: "z", offset: 1) == nil)
        #expect(adjacentID(in: ids, to: "z", offset: -1) == nil)
    }

    @Test("a single-element list has no neighbour either way")
    func single() {
        #expect(adjacentID(in: ["only"], to: "only", offset: 1) == nil)
        #expect(adjacentID(in: ["only"], to: "only", offset: -1) == nil)
    }
}

@Suite("Viewer full-image load state — no permanent-black page (#158)")
struct FullImageLoadStateTests {

    @Test("a fresh page loads only once bounds are real")
    func loadsWhenReady() {
        var state = FullImageLoadState()
        #expect(!state.shouldLoad(boundsReady: false))   // no bounds yet → wait
        #expect(state.shouldLoad(boundsReady: true))
    }

    @Test("appear + first layout on first show start only ONE load")
    func appearThenLayoutLoadsOnce() {
        var state = FullImageLoadState()
        #expect(state.shouldLoad(boundsReady: true))     // viewWillAppear would load…
        _ = state.begin()
        #expect(!state.shouldLoad(boundsReady: true))    // …so viewDidLayoutSubviews must NOT double-load
    }

    @Test("a real image latches — never reloads")
    func successLatches() {
        var state = FullImageLoadState()
        let token = state.begin()
        let applied = state.completed(token: token, gotImage: true)
        #expect(applied)
        #expect(state.loaded)
        #expect(!state.shouldLoad(boundsReady: true))            // loaded → stays put
    }

    @Test("a terminal nil doesn't latch loaded, doesn't re-storm on layout, but retries on re-appear")
    func failureRetriesOnAppearNotLayout() {
        var state = FullImageLoadState()
        let token = state.begin()
        let applied = state.completed(token: token, gotImage: false)  // PhotoKit returned nil (unavailable)
        #expect(applied)
        #expect(!state.loaded)
        #expect(!state.shouldLoad(boundsReady: true))            // `failed` → layout passes don't hammer
        state.retryOnReappear()
        #expect(state.shouldLoad(boundsReady: true))             // …but showing the page again retries
    }

    @Test("a superseded completion is ignored — can't clobber a fresh load or paint a stale image")
    func staleCompletionIgnored() {
        var state = FullImageLoadState()
        let stale = state.begin()
        state.cancel()                                           // page disappeared → token bumped
        let applied = state.completed(token: stale, gotImage: true)
        #expect(!applied)                                        // stale result rejected
        #expect(!state.loaded)                                   // not latched by the stale completion
        #expect(state.shouldLoad(boundsReady: true))             // eligible to reload afresh
    }

    @Test("a cancelled in-flight load (page scrolled past) stays eligible to reload; doesn't unlatch")
    func cancelKeepsEligibilityAndLatch() {
        var cancelled = FullImageLoadState()
        _ = cancelled.begin()
        cancelled.cancel()
        #expect(cancelled.shouldLoad(boundsReady: true))         // never loaded → retry on re-appear

        var loaded = FullImageLoadState()
        let token = loaded.begin()
        _ = loaded.completed(token: token, gotImage: true)
        loaded.cancel()                                          // disappear AFTER a successful load
        #expect(!loaded.shouldLoad(boundsReady: true))           // stays latched — no needless reload/flicker
    }

    @Test("full recovery lifecycle: prebuild → cancelled → reappear → success ends latched")
    func fullRecoveryLifecycle() {
        var state = FullImageLoadState()
        _ = state.begin(); state.cancel()                        // prebuilt neighbour, scrolled past
        #expect(state.shouldLoad(boundsReady: true))
        let token = state.begin()                                // shown for real → reload
        let applied = state.completed(token: token, gotImage: true)
        #expect(applied)
        #expect(state.loaded)
        #expect(!state.shouldLoad(boundsReady: true))
    }
}

@Suite("Viewer auto-mark-done boundary (#128)")
struct ViewerAutoDoneTests {
    /// A date cluster from a list of asset ids (days/busy are irrelevant to the boundary logic).
    private func cluster(_ id: String, _ ids: [String]) -> ReviewCluster {
        .day(DayGroup(id: id, assetIDs: ids, days: [.day(year: 2025, month: 1, day: 1)], isBusyDay: false))
    }
    /// A / B / C: A and B multi-photo, C a single final photo.
    private var clusters: [ReviewCluster] {
        [cluster("A", ["a1", "a2"]), cluster("B", ["b1", "b2"]), cluster("C", ["c1"])]
    }

    @Test("forward past a cluster's LAST photo into the next cluster's FIRST → marks that cluster")
    func forwardPastLastMarks() {
        #expect(clusterFinishedByPagingPast(from: "a2", to: "b1", clusters: clusters)?.id == "A")
        #expect(clusterFinishedByPagingPast(from: "b2", to: "c1", clusters: clusters)?.id == "B")
    }

    @Test("mid-cluster paging never marks")
    func midClusterDoesNotMark() {
        #expect(clusterFinishedByPagingPast(from: "a1", to: "a2", clusters: clusters) == nil)
    }

    @Test("backward paging never marks (or un-marks)")
    func backwardDoesNotMark() {
        #expect(clusterFinishedByPagingPast(from: "b1", to: "a2", clusters: clusters) == nil)  // B.first → A.last
        #expect(clusterFinishedByPagingPast(from: "c1", to: "b2", clusters: clusters) == nil)  // C → B.last
    }

    @Test("a non-adjacent filmstrip jump from a last photo never marks")
    func nonAdjacentJumpDoesNotMark() {
        // a2 is A's last, but landing on C's first (skipping B) is a jump, not paging past into the next.
        #expect(clusterFinishedByPagingPast(from: "a2", to: "c1", clusters: clusters) == nil)
    }

    @Test("the final cluster has no next to page into → never marks")
    func finalClusterDoesNotMark() {
        // From C's only photo there's nowhere forward; and it's the last cluster.
        #expect(clusterFinishedByPagingPast(from: "c1", to: "a1", clusters: clusters) == nil)
    }

    @Test("an unknown previous id is a safe no-op")
    func unknownIsNoOp() {
        #expect(clusterFinishedByPagingPast(from: "zzz", to: "b1", clusters: clusters) == nil)
    }
}
