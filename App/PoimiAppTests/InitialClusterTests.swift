//
//  InitialClusterTests.swift
//  PoimiAppTests — the review grid's initial-cluster decision (#35 accordion; #37 drill).
//
//  Pure unit tests for `initialCluster` — the drill-vs-resume choice pulled out of `ReviewGridView`
//  so it's testable without rendering. Regression cover for the "drill from Overview lands blank until
//  you scroll" bug: a drill must OPEN the target cluster AND return its first cell as the pending scroll
//  target (the caller defers the actual scroll to a `.task`, after layout); everything else must NOT
//  scroll (`pendingScrollID == nil`), and a matched-but-empty group must scroll nowhere.
//

import Testing
import Curation
@testable import PoimiApp

@Suite("initialCluster (review grid drill / resume)")
struct InitialClusterTests {

    private func group(_ id: String, days: [DayKey], assets: [String]? = nil) -> DayGroup {
        DayGroup(id: id, assetIDs: assets ?? [id], days: days, isBusyDay: false)
    }

    private let jul5 = DayKey.day(year: 2025, month: 7, day: 5)
    private let jul6 = DayKey.day(year: 2025, month: 7, day: 6)
    private let jul7 = DayKey.day(year: 2025, month: 7, day: 7)

    @Test("a drill to a matching day opens that cluster AND targets its first cell to scroll")
    func drillMatches() {
        let groups = [group("a", days: [jul5], assets: ["a", "a2"]),
                      group("b", days: [jul6], assets: ["b", "b2"]),
                      group("c", days: [jul7])]
        let choice = initialCluster(groups: groups, scrollToDay: jul6, isDone: { _ in false })
        #expect(choice.expandedID == "b")
        #expect(choice.pendingScrollID == "b")   // first asset id of the drilled group
    }

    @Test("a drill day matching NO group falls back to first-unreviewed and does not scroll")
    func drillNoMatch() {
        let groups = [group("a", days: [jul5]), group("b", days: [jul6])]
        let missing = DayKey.day(year: 2030, month: 1, day: 1)
        let choice = initialCluster(groups: groups, scrollToDay: missing, isDone: { $0.id == "a" })
        #expect(choice.expandedID == "b")        // a is done → resume at b
        #expect(choice.pendingScrollID == nil)   // not a real drill → no scroll
    }

    @Test("no drill opens the first UNREVIEWED cluster (resume) without scrolling")
    func resumeFirstUnreviewed() {
        let groups = [group("a", days: [jul5]), group("b", days: [jul6]), group("c", days: [jul7])]
        let choice = initialCluster(groups: groups, scrollToDay: nil, isDone: { $0.id == "a" })
        #expect(choice.expandedID == "b")
        #expect(choice.pendingScrollID == nil)
    }

    @Test("no drill with every cluster done falls back to the first cluster")
    func resumeAllDone() {
        let groups = [group("a", days: [jul5]), group("b", days: [jul6])]
        let choice = initialCluster(groups: groups, scrollToDay: nil, isDone: { _ in true })
        #expect(choice.expandedID == "a")        // all done → first
        #expect(choice.pendingScrollID == nil)
    }

    @Test("a drill to a matching but EMPTY group opens it but scrolls nowhere (the blank-fix edge)")
    func drillEmptyGroup() {
        let groups = [group("a", days: [jul5], assets: [])]
        let choice = initialCluster(groups: groups, scrollToDay: jul5, isDone: { _ in false })
        #expect(choice.expandedID == "a")
        #expect(choice.pendingScrollID == nil)   // empty assetIDs → nothing to scroll to
    }

    @Test("no groups → nothing to open")
    func emptyGroups() {
        let choice = initialCluster(groups: [], scrollToDay: jul5, isDone: { _ in false })
        #expect(choice.expandedID == nil)
        #expect(choice.pendingScrollID == nil)
    }
}
