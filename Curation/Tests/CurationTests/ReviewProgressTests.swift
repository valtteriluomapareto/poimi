//
//  ReviewProgressTests.swift
//  CurationTests — the album's review-progress facts (#202): days reviewed + the resume target.
//
//  Pins the two pure signals the Overview's "Continue reviewing" card + bookmark rely on: how many
//  dated days are marked done, and the index of the first cluster still needing review (nil = all done).
//

import Testing
import Foundation
@testable import Curation

@Suite("Review progress — days reviewed + resume target")
struct ReviewProgressTests {
    private func group(_ id: String, days: [DayKey], assets: [String]? = nil) -> DayGroup {
        DayGroup(id: id, assetIDs: assets ?? [id], days: days, isBusyDay: false)
    }
    private let jul5 = DayKey.day(year: 2025, month: 7, day: 5)
    private let jul6 = DayKey.day(year: 2025, month: 7, day: 6)
    private let jul7 = DayKey.day(year: 2025, month: 7, day: 7)

    @Test("reviewedDayCount counts distinct dated days marked done")
    func reviewedCount() {
        let clusters = [group("a", days: [jul5]), group("b", days: [jul6]), group("c", days: [jul7])]
            .map(ReviewCluster.day)
        #expect(ReviewProgress.reviewedDayCount(clusters: clusters, doneDays: [jul5, jul7]) == 2)
    }

    @Test("a multi-day cluster contributes each of its done days")
    func multiDay() {
        // one trip-like day-group spanning two days; both done → 2
        let clusters = [group("trip", days: [jul5, jul6], assets: ["x", "y"])].map(ReviewCluster.day)
        #expect(ReviewProgress.reviewedDayCount(clusters: clusters, doneDays: [jul5, jul6]) == 2)
    }

    @Test("the undated bucket never counts as a reviewed day")
    func undatedNeverCounts() {
        let clusters = [group("u", days: [.undated], assets: ["u"])].map(ReviewCluster.day)
        #expect(ReviewProgress.reviewedDayCount(clusters: clusters, doneDays: [.undated]) == 0)
    }

    @Test("nothing done → zero reviewed days")
    func noneDone() {
        let clusters = [group("a", days: [jul5]), group("b", days: [jul6])].map(ReviewCluster.day)
        #expect(ReviewProgress.reviewedDayCount(clusters: clusters, doneDays: []) == 0)
    }

    @Test("firstUnreviewedIndex is the earliest cluster not fully done")
    func firstUnreviewed() {
        let clusters = [group("a", days: [jul5]), group("b", days: [jul6]), group("c", days: [jul7])]
            .map(ReviewCluster.day)
        // a done → resume at b (index 1)
        #expect(ReviewProgress.firstUnreviewedIndex(clusters: clusters, doneDays: [jul5]) == 1)
    }

    @Test("firstUnreviewedIndex catches a straggler left behind an already-reviewed later day")
    func stragglerBehind() {
        let clusters = [group("a", days: [jul5]), group("b", days: [jul6]), group("c", days: [jul7])]
            .map(ReviewCluster.day)
        // only the middle day is done; the earliest unreviewed is a (index 0), even though b is done
        #expect(ReviewProgress.firstUnreviewedIndex(clusters: clusters, doneDays: [jul6]) == 0)
    }

    @Test("a partially-done multi-day cluster is still the resume target; fully done → advances past it")
    func partialMultiDay() {
        let clusters = [group("trip", days: [jul5, jul6], assets: ["x", "y"]), group("c", days: [jul7])]
            .map(ReviewCluster.day)
        // only jul5 done → the multi-day cluster isn't fully done → it's still the resume target (index 0)
        #expect(ReviewProgress.firstUnreviewedIndex(clusters: clusters, doneDays: [jul5]) == 0)
        // both its days done → advance past it to c (index 1)
        #expect(ReviewProgress.firstUnreviewedIndex(clusters: clusters, doneDays: [jul5, jul6]) == 1)
    }

    @Test("the undated bucket is never a resume target — once every dated day is done, it's nil")
    func undatedNotAResumeTarget() {
        let clusters = [group("a", days: [jul5]), group("b", days: [jul6]),
                        group("u", days: [.undated], assets: ["u"])].map(ReviewCluster.day)
        // both dated days done, undated still open → nil (no contradiction with "N of N days reviewed")
        #expect(ReviewProgress.firstUnreviewedIndex(clusters: clusters, doneDays: [jul5, jul6]) == nil)
        // a dated day still open → that dated day, never the undated bucket
        #expect(ReviewProgress.firstUnreviewedIndex(clusters: clusters, doneDays: [jul5]) == 1)
    }

    @Test("every cluster done → nil (nowhere to resume)")
    func allDone() {
        let clusters = [group("a", days: [jul5]), group("b", days: [jul6])].map(ReviewCluster.day)
        #expect(ReviewProgress.firstUnreviewedIndex(clusters: clusters, doneDays: [jul5, jul6]) == nil)
    }

    @Test("an empty album → nil")
    func empty() {
        #expect(ReviewProgress.firstUnreviewedIndex(clusters: [], doneDays: []) == nil)
    }

    @Test("reviewedDayCount never exceeds the album's dated-day total, for any done set")
    func countNeverExceedsTotal() {
        let clusters = [group("a", days: [jul5]), group("trip", days: [jul6, jul7], assets: ["x", "y"]),
                        group("u", days: [.undated], assets: ["u"])].map(ReviewCluster.day)
        let totalDatedDays = 3   // jul5, jul6, jul7 (undated excluded)
        for done in [Set<DayKey>(), [jul5], [jul6, jul7], [jul5, jul6, jul7], [jul5, jul6, jul7, .undated]] {
            #expect(ReviewProgress.reviewedDayCount(clusters: clusters, doneDays: done) <= totalDatedDays)
        }
    }
}
