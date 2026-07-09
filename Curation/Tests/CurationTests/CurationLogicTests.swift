//
//  CurationLogicTests.swift
//  CurationTests — filtering, target math, completion, resume, stats (#20).
//

import Testing
import Foundation
@testable import Curation

// Fixtures (`utcCalendar`, `asset`, `dk`) live in TestSupport.swift.

// MARK: - Filtering

@Suite("Filtering (#20)")
struct FilteringTests {
    private let calendar = utcCalendar()

    @Test("excludes screenshots only when the flag is on")
    func screenshots() {
        let shot = AssetRef(id: "s", captureDate: nil, isScreenshot: true)
        let photo = AssetRef(id: "p", captureDate: nil)
        #expect(Filtering.included([shot, photo], excludeScreenshots: true).map(\.id) == ["p"])
        #expect(Filtering.included([shot, photo], excludeScreenshots: false).count == 2)
    }

    @Test("excludes assets belonging to excluded albums")
    func excludedAlbums() {
        let a = AssetRef(id: "a", captureDate: nil)
        let b = AssetRef(id: "b", captureDate: nil)
        let kept = Filtering.included([a, b], excludeScreenshots: false, excludedAssetIDs: ["b"])
        #expect(kept.map(\.id) == ["a"])
    }

    @Test("drops videos unless includeVideos is on (default off = images only, #125)")
    func videos() {
        let photo = AssetRef(id: "p", captureDate: nil)
        let video = AssetRef(id: "v", captureDate: nil, isVideo: true, duration: 14)
        // Default (off) → images only.
        #expect(Filtering.included([photo, video], excludeScreenshots: false).map(\.id) == ["p"])
        // On → both.
        #expect(Filtering.included([photo, video], excludeScreenshots: false, includeVideos: true)
            .map(\.id) == ["p", "v"])
    }

    @Test("an excluded-album video is dropped even when includeVideos is on (#125)")
    func excludedAlbumVideo() {
        let photo = AssetRef(id: "p", captureDate: nil)
        let video = AssetRef(id: "v", captureDate: nil, isVideo: true, duration: 9)
        // Videos on, but the video is a member of an excluded album → still dropped.
        let kept = Filtering.included([photo, video], excludeScreenshots: false,
                                      includeVideos: true, excludedAssetIDs: ["v"])
        #expect(kept.map(\.id) == ["p"])
    }
}

// MARK: - Target math

@Suite("Target math (#20)")
struct TargetTests {
    @Test("remaining / fraction / complete behave at and past the target")
    func progress() {
        let under = TargetProgress(picked: 147, target: 200)
        #expect(under.remaining == 53)
        #expect(!under.isComplete)
        #expect(abs(under.fraction - 0.735) < 0.001)

        let over = TargetProgress(picked: 210, target: 200)
        #expect(over.remaining == 0)
        #expect(over.isComplete)
        #expect(over.fraction == 1)               // clamped

        let noTarget = TargetProgress(picked: 5, target: 0)
        #expect(noTarget.fraction == 0)
        #expect(!noTarget.isComplete)
    }

    @Test("suggested per-section share is advisory and nil-safe")
    func perSection() {
        #expect(Target.suggestedPerSection(target: 200, sectionCount: 8) == 25)
        #expect(Target.suggestedPerSection(target: 200, sectionCount: 0) == nil)
        #expect(Target.suggestedPerSection(target: 0, sectionCount: 8) == nil)
    }
}

// MARK: - Completion / resume / stats

@Suite("Completion, resume & stats (#20)")
struct CompletionTests {
    private let calendar = utcCalendar()

    private func quietRun() -> [AssetRef] {
        [asset("a", 2025, 3, 16, calendar: calendar),
         asset("b", 2025, 3, 17, calendar: calendar),
         asset("c", 2025, 3, 18, calendar: calendar)]
    }

    @Test("isDone iff every spanned day is in doneDays")
    func isDone() {
        let group = DayGrouping.groups(for: quietRun(), threshold: 10, calendar: calendar)[0]
        #expect(!Completion.isDone(group, doneDays: []))
        let partial: Set<DayKey> = [dk(2025, 3, 16), dk(2025, 3, 17)]
        #expect(!Completion.isDone(group, doneDays: partial))
        let full = partial.union([dk(2025, 3, 18)])
        #expect(Completion.isDone(group, doneDays: full))
    }

    @Test("marking a section done flags all its days; unmarking removes them")
    func markUnmark() {
        let group = DayGrouping.groups(for: quietRun(), threshold: 10, calendar: calendar)[0]
        let done = Completion.markingDone(group, in: [])
        #expect(done == [dk(2025, 3, 16), dk(2025, 3, 17), dk(2025, 3, 18)])
        #expect(Completion.markingUndone(group, in: done).isEmpty)
    }

    @Test("daysWithPhotos is sorted unique with undated last")
    func daysWithPhotos() {
        var input = quietRun()
        input.append(asset("a2", 2025, 3, 16, calendar: calendar))   // dup day
        input.append(AssetRef(id: "u", captureDate: nil))            // undated
        let days = Completion.daysWithPhotos(in: input, calendar: calendar)
        #expect(days == [dk(2025, 3, 16), dk(2025, 3, 17), dk(2025, 3, 18), .undated])
    }

    @Test("resume is the earliest undone day, nil when all done")
    func resume() {
        let input = quietRun()
        #expect(Completion.resumeDay(assets: input, doneDays: [], calendar: calendar) == dk(2025, 3, 16))
        let someDone: Set<DayKey> = [dk(2025, 3, 16), dk(2025, 3, 17)]
        #expect(Completion.resumeDay(assets: input, doneDays: someDone, calendar: calendar) == dk(2025, 3, 18))
        let allDone = someDone.union([dk(2025, 3, 18)])
        #expect(Completion.resumeDay(assets: input, doneDays: allDone, calendar: calendar) == nil)
    }

    @Test("stats: denominator is marked-done assets; %-kept never exceeds 100")
    func stats() {
        // 16th & 17th done (4 assets total: 2 on the 16th, 1 on 17th, 1 on 18th).
        let input = [
            asset("a", 2025, 3, 16, calendar: calendar),
            asset("a2", 2025, 3, 16, calendar: calendar),
            asset("b", 2025, 3, 17, calendar: calendar),
            asset("c", 2025, 3, 18, calendar: calendar)   // NOT done
        ]
        let doneDays: Set<DayKey> = [dk(2025, 3, 16), dk(2025, 3, 17)]
        // Select one done asset + the not-done one (c). The not-done pick must NOT inflate %.
        let selection: Set<String> = ["a", "c"]
        let stats = CompletionStats(assets: input, doneDays: doneDays, selection: selection, calendar: calendar)
        #expect(stats.markedDone == 3)        // a, a2, b
        #expect(stats.kept == 1)              // only a is both selected AND on a done day
        #expect(stats.totalPicked == 2)       // a + c
        #expect(stats.fractionKept <= 1.0)    // regression: never > 100%
        #expect(abs(stats.fractionKept - 1.0 / 3.0) < 0.001)
    }

    @Test("zero marked-done yields 0% (no divide-by-zero)")
    func statsEmpty() {
        let stats = CompletionStats(assets: quietRun(), doneDays: [], selection: ["a"], calendar: calendar)
        #expect(stats.markedDone == 0)
        #expect(stats.fractionKept == 0)
        #expect(stats.totalPicked == 1)
    }

    @Test("stats from the dayByID map (the completion screen's no-rescan path) match the asset-based stats")
    func statsFromDayByID() {
        // Same shape as `stats()`: 16th & 17th done; select one done asset + the not-done one (c).
        let dayByID: [String: DayKey] = [
            "a": dk(2025, 3, 16), "a2": dk(2025, 3, 16),
            "b": dk(2025, 3, 17), "c": dk(2025, 3, 18)
        ]
        let doneDays: Set<DayKey> = [dk(2025, 3, 16), dk(2025, 3, 17)]
        let stats = CompletionStats(dayByID: dayByID, doneDays: doneDays, selection: ["a", "c"])
        #expect(stats.markedDone == 3)                        // a, a2, b
        #expect(stats.kept == 1)                              // a
        #expect(stats.totalPicked == 2)                       // whole selection (a + c)
        #expect(abs(stats.fractionKept - 1.0 / 3.0) < 0.001)
    }

    @Test("dayByID stats: totalPicked counts the whole selection even when a pick is absent from the map")
    func statsFromDayByIDCountsWholeSelection() {
        // "a" is on a done day in the map; "z" is a pick with NO map entry (dropped from the last scan).
        let dayByID: [String: DayKey] = ["a": dk(2025, 3, 16)]
        let stats = CompletionStats(dayByID: dayByID, doneDays: [dk(2025, 3, 16)], selection: ["a", "z"])
        #expect(stats.totalPicked == 2)   // whole selection — map-independent (the intended semantic)
        #expect(stats.markedDone == 1)    // only "a", from the map ∩ done days
        #expect(stats.kept == 1)
    }

    // THE core D32(d) guarantee: progress lives on days, so it survives regrouping.
    @Test("done-state survives a merge/split regrouping")
    func doneStateInvariantUnderRegrouping() {
        var input = quietRun()                                              // 16–18, quiet
        input += (0..<12).map { asset("busy\($0)", 2025, 3, 25, calendar: calendar) }  // busy day

        // Mark the quiet run done via the COARSE grouping (16–18 merged into one).
        let coarse = DayGrouping.groups(for: input, threshold: 10, calendar: calendar)
        let quietGroup = coarse.first { !$0.isBusyDay }!
        let doneDays = Completion.markingDone(quietGroup, in: [])
        #expect(Completion.isDone(quietGroup, doneDays: doneDays))

        // Regroup FINELY (threshold 1 → every day its own group). Each of 16/17/18 must
        // still read done; the busy day (25) must not. Progress is preserved.
        let fine = DayGrouping.groups(for: input, threshold: 1, calendar: calendar)
        let d16 = fine.first { $0.days == [dk(2025, 3, 16)] }!
        let d17 = fine.first { $0.days == [dk(2025, 3, 17)] }!
        let d18 = fine.first { $0.days == [dk(2025, 3, 18)] }!
        let busy = fine.first { $0.days == [dk(2025, 3, 25)] }!
        #expect(Completion.isDone(d16, doneDays: doneDays))
        #expect(Completion.isDone(d17, doneDays: doneDays))
        #expect(Completion.isDone(d18, doneDays: doneDays))
        let busyDone = Completion.isDone(busy, doneDays: doneDays)
        #expect(!busyDone)

        // Resume is day-level, so it points at the busy day regardless of grouping.
        #expect(Completion.resumeDay(assets: input, doneDays: doneDays, calendar: calendar) == dk(2025, 3, 25))
    }
}
