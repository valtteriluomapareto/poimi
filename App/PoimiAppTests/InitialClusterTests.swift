//
//  InitialClusterTests.swift
//  PoimiAppTests — the review grid's entry-page decision (#35 paged-clusters; #37 drill).
//
//  Pure unit tests for `initialPage` — the drill-vs-resume choice pulled out of `ReviewGridView` so
//  it's testable without rendering. A drill from the Overview (`scrollToDay` matching a cluster's days)
//  opens THAT cluster's page; otherwise the first UNREVIEWED cluster (resume), else the first. Returns
//  a page index into `groups` (0 for an empty slice — the view guards it).
//

import Testing
import Curation
@testable import PoimiApp

@Suite("initialPage (review grid drill / resume)")
struct InitialPageTests {

    private func group(_ id: String, days: [DayKey], assets: [String]? = nil) -> DayGroup {
        DayGroup(id: id, assetIDs: assets ?? [id], days: days, isBusyDay: false)
    }

    private let jul5 = DayKey.day(year: 2025, month: 7, day: 5)
    private let jul6 = DayKey.day(year: 2025, month: 7, day: 6)
    private let jul7 = DayKey.day(year: 2025, month: 7, day: 7)

    @Test("a drill to a matching day opens that cluster's page")
    func drillMatches() {
        let groups = [group("a", days: [jul5], assets: ["a", "a2"]),
                      group("b", days: [jul6], assets: ["b", "b2"]),
                      group("c", days: [jul7])]
        #expect(initialPage(clusters: groups.map(ReviewCluster.day), scrollToDay: jul6, isDone: { _ in false }) == 1)
    }

    @Test("a drill day matching NO group falls back to first-unreviewed")
    func drillNoMatch() {
        let groups = [group("a", days: [jul5]), group("b", days: [jul6])]
        let missing = DayKey.day(year: 2030, month: 1, day: 1)
        #expect(initialPage(clusters: groups.map(ReviewCluster.day), scrollToDay: missing, isDone: { $0.id == "a" }) == 1)  // a done → b
    }

    @Test("no drill opens the first UNREVIEWED cluster (resume)")
    func resumeFirstUnreviewed() {
        let groups = [group("a", days: [jul5]), group("b", days: [jul6]), group("c", days: [jul7])]
        #expect(initialPage(clusters: groups.map(ReviewCluster.day), scrollToDay: nil, isDone: { $0.id == "a" }) == 1)
    }

    @Test("no drill with every cluster done falls back to the first page")
    func resumeAllDone() {
        let groups = [group("a", days: [jul5]), group("b", days: [jul6])]
        #expect(initialPage(clusters: groups.map(ReviewCluster.day), scrollToDay: nil, isDone: { _ in true }) == 0)
    }

    @Test("a drill lands on the matching cluster even if a later one is the first unreviewed")
    func drillWinsOverResume() {
        let groups = [group("a", days: [jul5]), group("b", days: [jul6]), group("c", days: [jul7])]
        // a is unreviewed (resume would pick 0), but the drill targets jul7 → page 2.
        #expect(initialPage(clusters: groups.map(ReviewCluster.day), scrollToDay: jul7, isDone: { _ in false }) == 2)
    }

    @Test("no groups → page 0")
    func emptyGroups() {
        #expect(initialPage(clusters: [], scrollToDay: jul5, isDone: { _ in false }) == 0)
    }
}

@Suite("nextUnreviewedPage (mark-done → next-day heartbeat)")
struct NextUnreviewedPageTests {

    @Test("jumps to the first UNREVIEWED cluster after the current page (skipping done ones)")
    func jumpsToNextUnreviewed() {
        // index 1 done; from 0 → skip 1, land on 2
        #expect(nextUnreviewedPage(after: 0, count: 4, isDone: { $0 == 1 }) == 2)
    }

    @Test("no unreviewed ahead falls back to the literal next page")
    func literalNextWhenAllAheadDone() {
        // indices 2 and 3 done; from 1 → no unreviewed ahead → literal next = 2
        #expect(nextUnreviewedPage(after: 1, count: 4, isDone: { $0 >= 2 }) == 2)
    }

    @Test("the last cluster stays put (nothing after it)")
    func lastStaysPut() {
        #expect(nextUnreviewedPage(after: 3, count: 4, isDone: { _ in false }) == 3)
    }

    @Test("a single-cluster album stays on page 0")
    func singleCluster() {
        #expect(nextUnreviewedPage(after: 0, count: 1, isDone: { _ in false }) == 0)
    }

    @Test("an empty album → page 0 (no trap on the empty range)")
    func empty() {
        #expect(nextUnreviewedPage(after: 0, count: 0, isDone: { _ in false }) == 0)
    }
}

@Suite("isReviewComplete (review-grid forward path, #187)")
struct ReviewCompleteTests {
    private func group(_ id: String) -> DayGroup {
        DayGroup(id: id, assetIDs: [id], days: [DayKey.day(year: 2025, month: 7, day: 5)], isBusyDay: false)
    }

    @Test("every cluster done → review complete")
    func allDone() {
        let clusters = [group("a"), group("b")].map(ReviewCluster.day)
        #expect(isReviewComplete(clusters: clusters, isDone: { _ in true }))
    }

    @Test("any cluster still open → not complete")
    func oneOutstanding() {
        let clusters = [group("a"), group("b")].map(ReviewCluster.day)
        #expect(!isReviewComplete(clusters: clusters, isDone: { $0.id == "a" }))
    }

    @Test("empty clusters → NOT complete (guards the vacuous allSatisfy that would offer to create from nothing)")
    func emptyIsNotComplete() {
        #expect(!isReviewComplete(clusters: [], isDone: { _ in true }))
    }
}
