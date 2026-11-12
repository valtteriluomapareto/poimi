//
//  AlbumSessionExportTests.swift
//  PoimiAppTests — the album session's export lifecycle (#297): one run per visit to the export screen
//  (concurrent starts, a re-appearing screen and a retry double-tap can't create a second Photos album),
//  a fresh run on the next visit, and a reset that leaves the completion screen alone. Gates on the
//  library hold a run in flight deterministically — never a fixed sleep.
//

import Testing
import Foundation
import Curation
@testable import PoimiApp

@MainActor
@Suite("AlbumSession — export runs once per visit (#297)")
struct AlbumSessionExportTests {

    private struct Ready {
        let harness: SessionHarness
        let project: CurationProject
        let picks: Set<String>
    }

    /// An album opened on the grid with a few picks, its export screen on the path.
    private func exportReady() async throws -> Ready {
        let harness = try SessionHarness()
        let project = harness.album()
        harness.actions.open(project)
        harness.coordinator.openReview(project.id)
        let store = await harness.session.openReview(project)
        let picks = Set(store.assetsByID.keys.sorted().prefix(3))
        harness.selection.select(picks)
        harness.coordinator.finishToExport()
        return Ready(harness: harness, project: project, picks: picks)
    }

    @Test("concurrent starts + a re-appearing screen run the export once (no second Photos album)")
    func exportRunsOnce() async throws {
        let ready = try await exportReady()
        let (harness, project, picks) = (ready.harness, ready.project, ready.picks)
        #expect(harness.session.export.phase == .idle)   // nothing reads "exporting" before a run

        // The screen's `.task` and a second caller (a re-mounted screen, a control action) race.
        let first = Task { await harness.session.startExport(project) }
        let second = Task { await harness.session.startExport(project) }
        _ = (await first.value, await second.value)
        guard case .done(let result, let wasReExport) = harness.session.export.phase else {
            Issue.record("export did not settle .done: \(harness.session.export.phase)")
            return
        }
        #expect(!wasReExport)
        #expect(result.added == picks.count)
        #expect(await harness.gate.exportCount == 1)
        // Two first-export runs would each CREATE a Photos album — a duplicate album for the user.
        #expect(await harness.library.exportedAssetIDs(inAlbum: "album/exported/2").isEmpty)

        await harness.session.startExport(project)   // the screen appears again: still the one run
        #expect(harness.session.export.phase == .done(result, wasReExport: false))
        #expect(await harness.gate.exportCount == 1)
    }

    @Test("a retry while a run is in flight is a no-op (a double-tap on Create new can't make two albums)")
    func retryIgnoredWhileRunning() async throws {
        let ready = try await exportReady()
        let (harness, project) = (ready.harness, ready.project)
        await harness.gate.hold(exports: true)
        let run = Task { await harness.session.startExport(project) }
        await harness.gate.waitUntilHeld()
        #expect(harness.session.isExporting(project))

        let doubleTap = Task { await harness.session.retryExport(project, forceNewAlbum: true) }
        for _ in 0..<10 { await Task.yield() }   // let it reach the library, if it would
        #expect(await harness.gate.exportCount == 1)

        await harness.gate.release()
        _ = (await run.value, await doubleTap.value)
        #expect(await harness.gate.exportCount == 1)
        #expect(!harness.session.isExporting(project))
        // An explicit retry once it settled does run.
        await harness.session.retryExport(project)
        #expect(await harness.gate.exportCount == 2)
    }

    @Test("leaving the export screen and finishing again runs a fresh export")
    func nextVisitRunsAgain() async throws {
        let ready = try await exportReady()
        let (harness, project) = (ready.harness, ready.project)
        await harness.session.startExport(project)
        #expect(harness.session.export.phase != .idle)

        harness.coordinator.pop()                          // the export screen leaves the path
        #expect(harness.session.export.phase == .idle)
        harness.coordinator.finishToExport()               // … and "Update in Photos" again
        await harness.session.startExport(project)
        guard case .done(_, let wasReExport) = harness.session.export.phase else {
            Issue.record("second visit did not export: \(harness.session.export.phase)")
            return
        }
        #expect(wasReExport)
        #expect(await harness.gate.exportCount == 2)
    }

    /// iPad: the sidebar's Reset stays tappable over a completion screen. It used to swap in an `.idle`
    /// export, which the mounted screen renders as "working…" forever (its `.task` already ran).
    @Test("a reset while the completion screen shows leaves it showing its result")
    func resetKeepsCompletion() async throws {
        let ready = try await exportReady()
        let (harness, project) = (ready.harness, ready.project)
        await harness.session.startExport(project)
        let settled = harness.session.export.phase

        #expect(harness.actions.reset(project))

        #expect(harness.session.export.phase == settled)
        #expect(harness.session.export.phase != .idle)
    }

    @Test("delete / reset are refused while the album's export runs; allowed once it lands")
    func deleteRefusedWhileExporting() async throws {
        let ready = try await exportReady()
        let (harness, project) = (ready.harness, ready.project)
        await harness.gate.hold(exports: true)
        let run = Task { await harness.session.startExport(project) }
        await harness.gate.waitUntilHeld()

        #expect(!harness.actions.delete(project))
        #expect(!harness.actions.reset(project))
        #expect(harness.graph.projectStore.projects.contains { $0.id == project.id })

        await harness.gate.release()
        await run.value
        #expect(project.targetAlbumID != nil)   // the run landed on a live album
        #expect(harness.actions.delete(project))
        #expect(harness.graph.projectStore.projects.isEmpty)
    }

    /// iPad (#300, found with the control plane's export gate): the sidebar stays tappable while the export
    /// screen shows. Re-opening the SAME album mid-export and tapping Save to Photos again used to start a
    /// second run beside the first — both saw no `targetAlbumID` yet, so each CREATED a Photos album.
    @Test("re-opening the album mid-export and saving again joins the run in flight (one Photos album)")
    func reopenMidExportJoinsTheRun() async throws {
        let ready = try await exportReady()
        let (harness, project, picks) = (ready.harness, ready.project, ready.picks)
        let (first, second, inFlight) = try await saveAgainMidExport(harness, project)
        #expect(await harness.gate.exportCount == 1)
        #expect(harness.session.export === inFlight)        // the run in flight, shown

        await harness.gate.release()
        _ = (await first.value, await second.value)
        #expect(await harness.gate.exportCount == 1)
        guard case .done(let result, false) = harness.session.export.phase else {
            Issue.record("the joined run didn't land on the screen: \(harness.session.export.phase)")
            return
        }
        #expect(result.added == picks.count)
        #expect(await harness.library.exportedAssetIDs(inAlbum: "album/exported/2").isEmpty)   // no 2nd album
    }

    /// The same, with more picks between the two Saves (#300 review): the joined run exported only the
    /// first Save's picks, and the completion screen reported them against the live selection ("22 photos",
    /// "14 couldn't be added"). The join now brings the album up to the live picks, in the album the run
    /// created, and the screen's counts are the result's own.
    @Test("picks added between the saves: the join exports them too, into the one album")
    func joinCatchesUpWithNewPicks() async throws {
        let ready = try await exportReady()
        let (harness, project) = (ready.harness, ready.project)
        let (first, second, _) = try await saveAgainMidExport(harness, project) {
            // (The re-open dropped the review context; these are the seed's, not among the first picks.)
            harness.selection.select(["fake/quiet/16", "fake/quiet/17", "fake/quiet/18", "fake/busy/11"])
        }
        let picks = harness.selection.selected
        #expect(picks.count == ready.picks.count + 4)

        await harness.gate.release()
        _ = (await first.value, await second.value)
        guard case .done(let result, let wasReExport) = harness.session.export.phase else {
            Issue.record("didn't land: \(harness.session.export.phase)")
            return
        }
        #expect(wasReExport)                                   // found the album the first run created
        #expect(result.added == 4)
        #expect(result.total == picks.count)
        #expect(harness.session.export.exportedPickCount == picks.count)
        #expect(await harness.library.exportedAssetIDs(inAlbum: "album/exported/1") == picks)
        #expect(await harness.library.exportedAssetIDs(inAlbum: "album/exported/2").isEmpty)
        let saved = try #require(try harness.persisted(project))
        #expect(saved.status(currentPicks: saved.persistedPicks) == .exported)
    }

    /// Hold an export, re-open the album from the sidebar (then `between`), and Save again; returns both
    /// runs' tasks and the store of the run in flight, once the second Save has joined it.
    private func saveAgainMidExport(
        _ harness: SessionHarness, _ project: CurationProject, between: () -> Void = {}
    ) async throws -> (Task<Void, Never>, Task<Void, Never>, ExportStore) {
        await harness.gate.hold(exports: true)
        let first = Task { await harness.session.startExport(project) }
        await harness.gate.waitUntilHeld()
        let inFlight = harness.session.export

        harness.actions.open(project)                       // the sidebar row: back to the overview
        #expect(harness.session.isExporting(project))
        between()
        harness.coordinator.finishToExport()               // … Save to Photos again
        let second = Task { await harness.session.startExport(project) }
        let deadline = ContinuousClock.now + .seconds(30)   // poll the real condition: the screen joined
        while harness.session.export !== inFlight, ContinuousClock.now < deadline { await Task.yield() }
        try #require(harness.session.export === inFlight, "the second Save didn't join the run in flight")
        return (first, second, inFlight)
    }

    /// The export saves its record of what it exported (`exportedSelectionSnapshot`) at once; the picks it
    /// recorded must be as durable. They used to wait for the debounce: a kill in that window (#300's relaunch
    /// journey) left the persisted picks behind the export record — an un-pick came back as "1 to add".
    @Test("an export persists the picks it exported, not only its record of them")
    func exportPersistsItsPicks() async throws {
        let ready = try await exportReady()
        let (harness, project, picks) = (ready.harness, ready.project, ready.picks)
        #expect(harness.selection.hasPendingFlush)   // the debounce (60 s here) hasn't fired
        await harness.session.startExport(project)
        guard case .done = harness.session.export.phase else {
            Issue.record("export did not land: \(harness.session.export.phase)")
            return
        }
        let saved = try #require(try harness.persisted(project))
        #expect(saved.persistedPicks == picks)
        #expect(saved.status(currentPicks: saved.persistedPicks) == .exported)
    }

    @Test("an album switch mid-export retires the run to its own store; the next album starts idle")
    func switchMidExport() async throws {
        let ready = try await exportReady()
        let (harness, project) = (ready.harness, ready.project)
        await harness.gate.hold(exports: true)
        let run = Task { await harness.session.startExport(project) }
        await harness.gate.waitUntilHeld()

        let other = harness.album("Other")
        harness.actions.open(other)
        #expect(harness.session.export.phase == .idle)   // B's export screen will run B's export
        #expect(harness.session.isExporting(project))     // A's run is still guarded

        await harness.gate.release()
        await run.value
        #expect(project.targetAlbumID != nil)
        #expect(harness.session.export.phase == .idle)    // A's result didn't leak into B's session
        #expect(!harness.session.isExporting(project))
    }
}
