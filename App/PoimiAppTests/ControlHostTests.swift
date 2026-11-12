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
        return await host.perform(action)
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
              timeoutMs: Int = 10_000) async -> Result<ControlJSON, ControlRequestError> {
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

    /// The whole loop with NO view mounted, entirely through actions: open → scan ready → grid → pick a
    /// day → mark it done → flush → export → exported.
    @Test("headless happy path: open → scan → select a day → done → flush → export → exported")
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

        let day = ControlFixture.yearDays[0].description   // 8 photos
        #expect(try await harness.send(#"{"type":"selection.select","day":"\#(day)"}"#).isAccepted)
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
        let harness = ControlHarness(.fourStatuses)
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

        // The open album: its stores flush + let go, the screen returns to the library.
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

    /// #258: on iPad the cog stays tappable while App settings shows; a repeat must not stack a copy.
    @Test("#258: openAppSettings twice → the second is a noop, one copy on the path")
    func appSettingsIdempotent() async throws {
        let harness = ControlHarness(.oneAlbum)
        await harness.runtime.bootstrap()
        try await harness.send(#"{"type":"nav.openAlbum","album":"album-1"}"#)
        #expect(try await harness.send(#"{"type":"nav.openAppSettings"}"#).isAccepted)
        #expect(try await harness.send(#"{"type":"nav.openAppSettings"}"#).isNoop)
        let id = try #require(harness.project("album-1")?.id)
        #expect(harness.coordinator.path == [.albumOverview(id), .appSettings])
        // Back returns to the album the detail was showing.
        #expect(try await harness.send(#"{"type":"nav.back"}"#).isAccepted)
        #expect(harness.coordinator.path == [.albumOverview(id)])
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

        #expect(try await harness.send(#"{"type":"albums.markAllUnreviewed","album":"album-1"}"#).isAccepted)
        #expect(try await harness.fixtureOp(#"{"op":"flush"}"#).isAccepted)
        #expect(harness.value("active.done.days") == .value(.int(0)))
        #expect(harness.value("albums.album-1.picked") == .value(.int(34)))
        let project = try #require(harness.project("album-1"))
        #expect(project.doneDays.isEmpty)
        #expect(project.persistedPickedCount == 34)
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
        #expect(try await harness.send(#"{"type":"nav.back"}"#).isAccepted)   // the Overview re-scans (new key)
        #expect(try await harness.send(#"{"type":"nav.openReview","album":"album-1"}"#).isAccepted)
        await harness.settled()
        #expect(harness.value("active.scan.phase") == .value(.string("ready")))
        #expect(harness.value("active.scan.candidates") != photosOnly)   // the video is in now

        #expect(harness.value("active.done.days") == .value(.int(4)))
        #expect(try await harness.fixtureOp(#"{"op":"flush"}"#).isAccepted)
        let project = try #require(harness.project("album-1"))
        #expect(project.doneDays == ControlFixture.yearDays.prefix(4).map(\.description))
    }

    @Test("a running export makes delete / reset / export.run refuse busy; it finishes and settles")
    func busyWhileExporting() async throws {
        let gated = GatedLibrary(ControlFixture.midReview.makeLibrary())
        let harness = ControlHarness(.midReview, library: gated)
        await harness.runtime.bootstrap()
        await gated.hold(exports: true)
        let run = try await harness.send(#"{"type":"export.run","album":"album-1"}"#)
        #expect(run.isAccepted)
        #expect(harness.value("nav.screen") == .value(.string("export")))
        await gated.waitUntilHeld()
        #expect(harness.value("pending.export") == .value(.bool(true)))
        #expect(harness.value("idle") == .value(.bool(false)))
        #expect(try await harness.send(#"{"type":"albums.delete","album":"album-1"}"#).refusal == .busy)
        #expect(try await harness.send(#"{"type":"albums.reset","album":"album-1"}"#).refusal == .busy)
        #expect(try await harness.send(#"{"type":"export.run","album":"album-1"}"#).refusal == .busy)
        // Not the fake: the library levers aren't available.
        #expect(try await harness.fixtureOp(#"{"op":"library.failFetch","kind":"fetchFailed"}"#).refusal == .unavailable)
        await gated.release()
        await harness.settled()
        #expect(harness.value("active.export.phase") == .value(.string("done")))
        // The completion stats are real: export.run opened the album first (the review context is published).
        #expect(!harness.graph.session.reviewDayByID.isEmpty)
        #expect(harness.value("idle") == .value(.bool(true)))
        #expect(try await harness.send(#"{"type":"export.run","album":"album-1"}"#).isNoop)
    }

    @Test("a failing fetch, then recovery: failFetch → failed scan; null → the rescan settles ready")
    func failFetchAndRecover() async throws {
        let harness = ControlHarness(.oneAlbum)
        await harness.runtime.bootstrap()
        #expect(try await harness.fixtureOp(#"{"op":"library.failFetch","kind":"fetchFailed"}"#).isAccepted)
        try await harness.send(#"{"type":"nav.openAlbum","album":"album-1"}"#)
        await harness.settled()
        #expect(harness.value("active.scan.phase") == .value(.string("failed")))
        #expect(harness.value("active.scan.reason") == .value(.string("loadError")))
        #expect(try await harness.fixtureOp(#"{"op":"library.failFetch","kind":null}"#).isAccepted)
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
}
