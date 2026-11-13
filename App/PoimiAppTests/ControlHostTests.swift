//
//  ControlHostTests.swift
//  PoimiAppTests — in-process journeys through `ControlHost` (#298, docs/plans/control-plane.md §4 C):
//  the headless happy path, and tripwires for regressions the history shows (#59, #258, #285, #289).
//  Every step is an action decoded from the same JSON an agent sends; every wait awaits the actions'
//  real work (`awaitSettled`) or the host's own `wait` — never a fixed sleep.
//

import Testing
import Foundation
import Curation
@testable import PoimiApp

extension ControlHarness {
    var host: ControlHost { runtime.host }

    /// Decode `json` as an action (exactly as the mailbox would) and perform it.
    @discardableResult
    func send(_ json: String) async throws -> ControlOutcome {
        let action = try JSONDecoder().decode(ControlAction.self, from: Data(json.utf8))
        return host.perform(action)
    }

    /// Decode `json` as a fixture op and perform it.
    @discardableResult
    func fixtureOp(_ json: String) async throws -> ControlOutcome {
        let op = try JSONDecoder().decode(ControlFixtureOp.self, from: Data(json.utf8))
        return await host.perform(op)
    }

    /// Await every accepted action's work.
    func settled() async { await runtime.progress.awaitSettled() }

    /// The live snapshot (what `snapshot` / `wait` see).
    func value(_ path: String) -> ControlLookup { runtime.stateJSON().lookup(path) }

    /// `wait` through the host (predicates as `(path, op, value)`), `timeoutMs` 0 = assert now.
    func wait(_ predicates: [(String, ControlPredicate.Op, ControlJSON)],
              timeoutMs: Int = 30_000) async -> Result<ControlJSON, ControlRequestError> {
        await host.wait(predicates.map { ControlPredicate(path: $0.0, op: $0.1, value: $0.2) }, timeoutMs: timeoutMs)
    }

    func project(_ alias: String) -> CurationProject? {
        runtime.albumAliases.projectID(for: alias).flatMap { id in
            graph.projectStore.projects.first { $0.id == id }
        }
    }
}

extension ControlOutcome {
    var isAccepted: Bool {
        if case .accepted = self { return true }
        return false
    }

    var isNoop: Bool {
        if case .noop = self { return true }
        return false
    }

    var refusal: ControlRefusal? {
        if case .refused(let reason, _) = self { return reason }
        return nil
    }

    var seq: Int? {
        if case .accepted(let seq, _) = self { return seq }
        return nil
    }
}

@MainActor
@Suite("Control plane: journeys through the host (#298)")
struct ControlHostJourneyTests {

    /// The whole loop with NO view mounted, entirely through actions a user could take: open → scan ready
    /// → grid → the cluster's select-all chip → its done seal → flush → back → Save to Photos → exported.
    @Test("headless happy path: open → scan → pick a cluster → done → flush → export → exported")
    func headlessHappyPath() async throws {
        let harness = ControlHarness(.oneAlbum, headless: true)
        await harness.runtime.bootstrap()
        #expect(harness.value("app.host") == .value(.string("headless")))

        let open = try await harness.send(#"{"type":"nav.openAlbum","album":"album-1"}"#)
        let seq = try #require(open.seq)
        // Admitted, not finished: the scan runs after the reply.
        if case .value(.int(let settled)) = harness.value("settledSeq") { #expect(settled < seq) }
        // The host's own wait (Observation-driven): blocks until the scan the action started settles.
        let ready = await harness.wait([("settledSeq", .gte, .int(seq)), ("active.scan.phase", .eq, .string("ready")),
                                        ("idle", .eq, .bool(true))])
        #expect((try? ready.get()) != nil, "\(ready)")
        #expect(harness.value("nav.screen") == .value(.string("overview")))

        #expect(try await harness.send(#"{"type":"nav.openReview","album":"album-1"}"#).isAccepted)
        await harness.settled()
        #expect(harness.value("nav.screen") == .value(.string("review")))

        let day = ControlFixture.yearDays[0].description   // a one-day cluster of 8 photos
        #expect(try await harness.send(#"{"type":"selection.toggleCluster","day":"\#(day)"}"#).isAccepted)
        #expect(try await harness.send(#"{"type":"done.toggle","day":"\#(day)"}"#).isAccepted)
        #expect(harness.value("active.selection.count") == .value(.int(8)))
        #expect(harness.value("active.done.days") == .value(.int(1)))
        #expect(harness.value("pending.selectionFlush") == .value(.bool(true)))
        // A pending flush doesn't hold `idle` (it would never settle under the day-long debounce).
        await harness.settled()
        #expect(harness.value("idle") == .value(.bool(true)))

        #expect(try await harness.fixtureOp(#"{"op":"flush"}"#).isAccepted)
        #expect(harness.value("pending.selectionFlush") == .value(.bool(false)))
        #expect(harness.project("album-1")?.persistedPickedCount == 8)

        // Save to Photos isn't on a grid that's not fully reviewed — it's on the overview.
        #expect(try await harness.send(#"{"type":"nav.openExport"}"#).refusal == .notShown)
        #expect(try await harness.send(#"{"type":"nav.back"}"#).isAccepted)
        #expect(try await harness.send(#"{"type":"nav.openExport"}"#).isAccepted)
        let exported = await harness.wait([("active.export.phase", .eq, .string("done")), ("idle", .eq, .bool(true))])
        #expect((try? exported.get()) != nil, "\(exported)")
        #expect(harness.value("albums.album-1.status") == .value(.string("exported")))
        #expect(harness.value("albums.album-1.exported") == .value(.bool(true)))
        #expect(harness.value("active.export.wasReExport") == .value(.bool(false)))
        // A second openExport is the coordinator's re-entrancy guard → noop.
        #expect(try await harness.send(#"{"type":"nav.openExport"}"#).isNoop)
    }

    /// #59: deleting an album must leave no live store holding it (a late debounce wrote a deleted model);
    /// deleting ANOTHER album must not touch the open one's unflushed picks.
    @Test("#59: delete releases only the deleted album's stores; nothing stale is left pending")
    func deleteLeavesNoStaleDebounce() async throws {
        let harness = ControlHarness(.fourStatuses, iPad: true)   // the sidebar: the list stays on screen
        await harness.runtime.bootstrap()
        try await harness.send(#"{"type":"nav.openAlbum","album":"album-3"}"#)
        try await harness.send(#"{"type":"nav.openReview","album":"album-3"}"#)
        await harness.settled()
        let photo = try #require(harness.runtime.assetAliases.alias(for: ControlFixture.yearDatedIDs[100]))
        #expect(try await harness.send(#"{"type":"selection.toggle","photo":"\#(photo)"}"#).isAccepted)
        #expect(harness.value("pending.selectionFlush") == .value(.bool(true)))

        // Another album: the open one keeps its live, unflushed picks.
        #expect(try await harness.send(#"{"type":"albums.delete","album":"album-1"}"#).isAccepted)
        #expect(harness.value("pending.selectionFlush") == .value(.bool(true)))
        #expect(harness.selection.isActive)
        #expect(harness.value("albums.album-1") == .missing)

        // The open album: its stores flush + let go, the detail returns to the library.
        #expect(try await harness.send(#"{"type":"albums.delete","album":"album-3"}"#).isAccepted)
        await harness.settled()
        #expect(harness.value("pending.selectionFlush") == .value(.bool(false)))
        #expect(harness.value("pending.doneFlush") == .value(.bool(false)))
        #expect(!harness.selection.isActive && !harness.done.isActive)
        #expect(harness.value("nav.screen") == .value(.string("albums")))
        // …so a selection now is refused, never a silent accepted.
        #expect(try await harness.send(#"{"type":"selection.toggle","photo":"\#(photo)"}"#).refusal == .invalidState)
        // And the deleted alias names nothing.
        #expect(try await harness.send(#"{"type":"nav.openAlbum","album":"album-3"}"#).refusal == .unknownAlias)
    }

    /// Review blocker: deleting an album while its scan is still fetching trapped in SwiftData — the load
    /// read the deleted model's fields after its `await`. The same `CandidateStore.load` path runs from
    /// the Overview's / grid's `.task` in the app (e.g. the iPad sidebar's Delete during the scan).
    @Test("deleting an album while its scan is in flight doesn't trap; nothing is published for it")
    func deleteDuringScan() async throws {
        let gated = GatedLibrary(ControlFixture.scale.makeLibrary())
        let harness = ControlHarness(.scale, library: gated, iPad: true)
        await harness.runtime.bootstrap()
        await gated.hold(fetches: true)
        #expect(try await harness.send(#"{"type":"nav.openAlbum","album":"album-1"}"#).isAccepted)
        await gated.waitUntilHeld()
        #expect(harness.value("pending.scan") == .value(.bool(true)))
        #expect(try await harness.send(#"{"type":"albums.delete","album":"album-1"}"#).isAccepted)
        await gated.release()
        await harness.settled()
        #expect(harness.value("albums.album-1") == .missing)
        #expect(harness.value("nav.screen") == .value(.string("albums")))
        #expect(harness.graph.session.candidateStore == nil)
        #expect(harness.graph.session.reviewOrderedIDs.isEmpty)
        #expect(harness.value("idle") == .value(.bool(true)))
    }

    /// #258: on iPad the cog stays tappable while App settings shows; a repeat must not stack a copy.
    @Test("#258: openAppSettings twice → the second is a noop, one copy on the path (iPhone + iPad)")
    func appSettingsIdempotent() async throws {
        let phone = ControlHarness(.oneAlbum)
        await phone.runtime.bootstrap()
        #expect(try await phone.send(#"{"type":"nav.openAppSettings"}"#).isAccepted)
        #expect(try await phone.send(#"{"type":"nav.openAppSettings"}"#).isNoop)
        #expect(phone.coordinator.path == [.appSettings])

        let pad = ControlHarness(.oneAlbum, iPad: true)
        await pad.runtime.bootstrap()
        try await pad.send(#"{"type":"nav.openAlbum","album":"album-1"}"#)
        #expect(try await pad.send(#"{"type":"nav.openAppSettings"}"#).isAccepted)
        #expect(try await pad.send(#"{"type":"nav.openAppSettings"}"#).isNoop)
        let id = try #require(pad.project("album-1")?.id)
        #expect(pad.coordinator.path == [.albumOverview(id), .appSettings])
        // Back returns to the album the detail was showing.
        #expect(try await pad.send(#"{"type":"nav.back"}"#).isAccepted)
        #expect(pad.coordinator.path == [.albumOverview(id)])
        await pad.settled()
    }

    /// #285: "Mark all days unreviewed" clears the day marks — including one not yet flushed — and keeps
    /// every pick; the done store's live set must not write the old marks back.
    @Test("#285: markAllUnreviewed clears day marks (even unflushed), keeps the picks, and stays cleared")
    func markAllUnreviewedKeepsPicks() async throws {
        let harness = ControlHarness(.midReview)
        await harness.runtime.bootstrap()
        try await harness.send(#"{"type":"nav.openAlbum","album":"album-1"}"#)
        try await harness.send(#"{"type":"nav.openReview","album":"album-1"}"#)
        await harness.settled()
        let fifth = ControlFixture.yearDays[4].description
        #expect(try await harness.send(#"{"type":"done.toggle","day":"\#(fifth)"}"#).isAccepted)
        // The cluster holding that day may span the next quiet day too — a cluster toggles all its days.
        let marked = await harness.wait([("active.done.days", .gte, .int(5))], timeoutMs: 0)
        #expect((try? marked.get()) != nil, "\(marked)")
        #expect(harness.value("pending.doneFlush") == .value(.bool(true)))

        // It's on the album's settings screen.
        #expect(try await harness.send(#"{"type":"albums.markAllUnreviewed","album":"album-1"}"#).refusal == .notShown)
        #expect(try await harness.send(#"{"type":"nav.back"}"#).isAccepted)
        #expect(try await harness.send(#"{"type":"nav.openSettings","album":"album-1"}"#).isAccepted)
        #expect(try await harness.send(#"{"type":"albums.markAllUnreviewed","album":"album-1"}"#).isAccepted)
        #expect(try await harness.fixtureOp(#"{"op":"flush"}"#).isAccepted)
        #expect(harness.value("active.done.days") == .value(.int(0)))
        #expect(harness.value("albums.album-1.picked") == .value(.int(34)))
        let project = try #require(harness.project("album-1"))
        #expect(project.doneDays.isEmpty)
        #expect(project.persistedPickedCount == 34)
        await harness.settled()
    }

    /// #289: an album carried over from before per-lens baselines; switching the media lens in Settings
    /// (from the Overview, which never reconciles) and then entering the grid must not un-mark the done
    /// day that holds a video.
    @Test("#289: done days survive a lens switch through albums.update (legacy baseline, video on a done day)")
    func doneSurvivesLensSwitch() async throws {
        let harness = ControlHarness(.legacyBaseline)
        await harness.runtime.bootstrap()
        try await harness.send(#"{"type":"nav.openAlbum","album":"album-1"}"#)
        await harness.settled()
        let photosOnly = harness.value("active.scan.candidates")
        #expect(harness.value("active.done.days") == .value(.int(4)))

        #expect(try await harness.send(#"{"type":"nav.openSettings","album":"album-1"}"#).isAccepted)
        #expect(try await harness.send(#"{"type":"albums.update","album":"album-1","media":"photosAndVideos"}"#)
            .isAccepted)
        #expect(try await harness.send(#"{"type":"nav.back"}"#).isAccepted)
        #expect(try await harness.send(#"{"type":"nav.openReview","album":"album-1"}"#).isAccepted)
        await harness.settled()
        #expect(harness.value("active.scan.phase") == .value(.string("ready")))
        #expect(harness.value("active.scan.candidates") != photosOnly)   // the video is in now

        #expect(harness.value("active.done.days") == .value(.int(4)))
        #expect(try await harness.fixtureOp(#"{"op":"flush"}"#).isAccepted)
        let project = try #require(harness.project("album-1"))
        #expect(project.doneDays == ControlFixture.yearDays.prefix(4).map(\.description))
    }

    /// One mapping from screen to session call: the Overview's task is keyed on the scan inputs, so a
    /// Settings edit rescans while Settings is still on top — headless too.
    @Test("albums.update with Settings on top rescans the Overview beneath it (headless)")
    func updateRescansUnderSettings() async throws {
        let harness = ControlHarness(.legacyBaseline, headless: true)
        await harness.runtime.bootstrap()
        try await harness.send(#"{"type":"nav.openAlbum","album":"album-1"}"#)
        try await harness.send(#"{"type":"nav.openSettings","album":"album-1"}"#)
        await harness.settled()
        let before = harness.value("active.scan.candidates")
        #expect(try await harness.send(#"{"type":"albums.update","album":"album-1","media":"photosAndVideos"}"#)
            .isAccepted)
        await harness.settled()
        #expect(harness.value("nav.screen") == .value(.string("settings")))
        #expect(harness.value("active.scan.phase") == .value(.string("ready")))
        #expect(harness.value("active.scan.candidates") != before)
        #expect(harness.value("idle") == .value(.bool(true)))
    }

    @Test("selection.toggleCluster is the grid's chip: a trip cluster's photos across all its days")
    func toggleClusterMatchesChip() async throws {
        let harness = ControlHarness(.located)
        await harness.runtime.bootstrap()
        try await harness.send(#"{"type":"nav.openAlbum","album":"album-1"}"#)
        try await harness.send(#"{"type":"nav.openReview","album":"album-1"}"#)
        await harness.settled()
        let trip = try #require(harness.graph.session.reviewClusters.first { $0.days.count > 1 })
        let laterDay = try #require(trip.days.last).description
        #expect(try await harness.send(#"{"type":"selection.toggleCluster","day":"\#(laterDay)"}"#).isAccepted)
        #expect(harness.selection.selected == Set(trip.assetIDs))   // every day of the trip, not just that day
        #expect(harness.selection.containsAll(trip.assetIDs))
        #expect(try await harness.send(#"{"type":"selection.toggleCluster","day":"\#(laterDay)"}"#).isAccepted)
        #expect(harness.selection.selected.isEmpty)
    }

    @Test("a running or queued export makes delete / reset refuse busy; it finishes and settles")
    func busyWhileExporting() async throws {
        let gated = GatedLibrary(ControlFixture.midReview.makeLibrary())
        let harness = ControlHarness(.midReview, library: gated, iPad: true)
        await harness.runtime.bootstrap()
        try await harness.send(#"{"type":"nav.openAlbum","album":"album-1"}"#)
        await harness.settled()
        await gated.hold(exports: true)
        #expect(try await harness.send(#"{"type":"nav.openExport"}"#).isAccepted)
        // Queued (the export screen's task hasn't started the run yet): already busy.
        #expect(try await harness.send(#"{"type":"albums.delete","album":"album-1"}"#).refusal == .busy)
        await gated.waitUntilHeld()
        #expect(harness.value("pending.export") == .value(.bool(true)))
        #expect(harness.value("idle") == .value(.bool(false)))
        #expect(try await harness.send(#"{"type":"albums.delete","album":"album-1"}"#).refusal == .busy)
        #expect(try await harness.send(#"{"type":"albums.reset","album":"album-1"}"#).refusal == .busy)
        #expect(try await harness.send(#"{"type":"export.retry"}"#).refusal == .busy)
        // Not the fake: the library levers aren't available.
        #expect(try await harness.fixtureOp(#"{"op":"library.failFetch","kind":"fetchFailed"}"#).refusal == .unavailable)
        await gated.release()
        await harness.settled()
        #expect(harness.value("active.export.phase") == .value(.string("done")))
        #expect(!harness.graph.session.reviewDayByID.isEmpty)   // the overview published the review context
        #expect(harness.value("idle") == .value(.bool(true)))
        #expect(try await harness.send(#"{"type":"export.retry"}"#).refusal == .notShown)   // only after a failure
    }

    @Test("a failing fetch, then recovery: failFetch → failed scan; null → re-open settles ready")
    func failFetchAndRecover() async throws {
        let harness = ControlHarness(.oneAlbum)
        await harness.runtime.bootstrap()
        #expect(try await harness.fixtureOp(#"{"op":"library.failFetch","kind":"fetchFailed"}"#).isAccepted)
        try await harness.send(#"{"type":"nav.openAlbum","album":"album-1"}"#)
        await harness.settled()
        #expect(harness.value("active.scan.phase") == .value(.string("failed")))
        #expect(harness.value("active.scan.reason") == .value(.string("loadError")))
        #expect(try await harness.fixtureOp(#"{"op":"library.failFetch","kind":null}"#).isAccepted)
        try await harness.send(#"{"type":"nav.back"}"#)
        try await harness.send(#"{"type":"nav.openAlbum","album":"album-1"}"#)   // re-open scans fresh
        await harness.settled()
        #expect(harness.value("active.scan.phase") == .value(.string("ready")))
    }

    @Test("revoked access mid-session: library.authorization + lifecycle.resume → recovery")
    func revokeMidSession() async throws {
        let harness = ControlHarness(.oneAlbum)
        await harness.runtime.bootstrap()
        try await harness.send(#"{"type":"nav.openAlbum","album":"album-1"}"#)
        await harness.settled()
        #expect(try await harness.fixtureOp(#"{"op":"library.authorization","status":"denied"}"#).isAccepted)
        #expect(harness.value("app.rootPhase") == .value(.string("albums")))   // not re-read yet
        #expect(try await harness.fixtureOp(#"{"op":"lifecycle.resume"}"#).isAccepted)
        #expect(harness.value("app.rootPhase") == .value(.string("recovery")))
        #expect(try await harness.send(#"{"type":"nav.openAlbum","album":"album-1"}"#).refusal == .notShown)
    }

    @Test("library actions need the album list (or the album's settings) on screen; iPad's sidebar always is")
    func libraryActionsRespectTheScreen() async throws {
        let phone = ControlHarness(.fourStatuses)
        await phone.runtime.bootstrap()
        try await phone.send(#"{"type":"nav.openAlbum","album":"album-3"}"#)
        #expect(try await phone.send(#"{"type":"albums.delete","album":"album-1"}"#).refusal == .notShown)
        #expect(try await phone.send(#"{"type":"albums.duplicate","album":"album-1"}"#).refusal == .notShown)
        #expect(try await phone.send(#"{"type":"nav.openAlbum","album":"album-1"}"#).refusal == .notShown)
        #expect(try await phone.send(#"{"type":"albums.update","album":"album-3","target":10}"#).refusal == .notShown)
        // From the album's own settings: delete / reset / update yes, another album's no.
        try await phone.send(#"{"type":"nav.openSettings","album":"album-3"}"#)
        #expect(try await phone.send(#"{"type":"albums.reset","album":"album-1"}"#).refusal == .notShown)
        #expect(try await phone.send(#"{"type":"albums.update","album":"album-3","target":10}"#).isAccepted)
        #expect(try await phone.send(#"{"type":"albums.reset","album":"album-3"}"#).isAccepted)
        #expect(try await phone.send(#"{"type":"albums.delete","album":"album-3"}"#).isAccepted)
        #expect(phone.value("nav.screen") == .value(.string("albums")))
        await phone.settled()

        let pad = ControlHarness(.fourStatuses, iPad: true)
        await pad.runtime.bootstrap()
        try await pad.send(#"{"type":"nav.openAlbum","album":"album-3"}"#)
        #expect(try await pad.send(#"{"type":"albums.duplicate","album":"album-1"}"#).isAccepted)
        #expect(try await pad.send(#"{"type":"albums.delete","album":"album-1"}"#).isAccepted)
        await pad.settled()
    }
}

/// Review blocker: the album list re-rendered a row for an album just deleted — after the stores' last
/// flush wrote to it — and SwiftData trapped on the deleted model's attributes. The row now draws nothing
/// for a deleted model; this asserts the guard holds on the exact model the list held.
@MainActor
@Suite("Album row: a deleted album (#298 review)")
struct AlbumRowDeletedTests {
    @Test("open → back → delete: the row's model reads as gone, and rendering it doesn't trap")
    func rowSkipsDeletedModel() async throws {
        let harness = ControlHarness(.oneAlbum)
        await harness.runtime.bootstrap()
        let project = try #require(harness.project("album-1"))
        #expect(!project.isGone)
        try await harness.send(#"{"type":"nav.openAlbum","album":"album-1"}"#)
        await harness.settled()
        try await harness.send(#"{"type":"nav.back"}"#)
        #expect(try await harness.send(#"{"type":"albums.delete","album":"album-1"}"#).isAccepted)
        #expect(project.isGone)
        // Rendering the row for it must not touch its attributes.
        _ = AlbumRow(project: project).body
    }
}
