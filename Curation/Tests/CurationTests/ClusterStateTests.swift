//
//  ClusterStateTests.swift
//  CurationTests — the pure cluster-state derivation (issue #37, the cluster index).
//

import Testing
@testable import Curation

@Suite("ClusterState — derivation from done + picks")
struct ClusterStateTests {
    @Test("done wins even with zero picks — a reviewed day that kept nothing is still done")
    func doneWithNoPicks() {
        #expect(ClusterState.of(isDone: true, pickedCount: 0) == .done)
    }

    @Test("done wins over picks")
    func doneWithPicks() {
        #expect(ClusterState.of(isDone: true, pickedCount: 12) == .done)
    }

    @Test("not done, at least one pick → in progress")
    func inProgress() {
        #expect(ClusterState.of(isDone: false, pickedCount: 1) == .inProgress)
        #expect(ClusterState.of(isDone: false, pickedCount: 40) == .inProgress)
    }

    @Test("not done, no picks → untouched")
    func untouched() {
        #expect(ClusterState.of(isDone: false, pickedCount: 0) == .untouched)
    }
}
