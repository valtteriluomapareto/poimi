//
//  ControlBreakTests.swift
//  PoimiAppTests — the control plane's slice E, "break on purpose" (#300, docs/plans/control-plane.md §4 E):
//  journeys through `ControlHost` that hold an export mid-flight (the fake library's export gate), relaunch
//  over the same store (a kill mid-debounce: the accepted D15 loss window), and change the library under an
//  exported album (#191 additions-only drift). Every step is the JSON an agent sends; every wait awaits the
//  real work or the host's own `wait` — never a fixed sleep.
//

import Testing
import Foundation
import Curation
@testable import PoimiApp

extension ControlHarness {
    /// `wait` through the host; records the unmet predicates as the failure.
    func expectWait(_ predicates: [(String, ControlPredicate.Op, ControlJSON)], timeoutMs: Int = 30_000,
                    sourceLocation: SourceLocation = #_sourceLocation) async {
        let result = await wait(predicates, timeoutMs: timeoutMs)
        #expect((try? result.get()) != nil, "\(result)", sourceLocation: sourceLocation)
    }

    func int(_ path: String) -> Int? {
        if case .value(.int(let value)) = value(path) { return value }
        return nil
    }

    /// Open `album-1`'s grid, pick the first shooting day's cluster (8 photos), back to its overview —
    /// where Save to Photos is.
    func pickFirstDayAndReturnToOverview() async throws {
        try await send(#"{"type":"nav.openAlbum","album":"album-1"}"#)
        await expectWait([("idle", .eq, .bool(true))])
        try await send(#"{"type":"nav.openReview","album":"album-1"}"#)
        await expectWait([("idle", .eq, .bool(true))])
        let day = ControlFixture.yearDays[0].description
        #expect(try await send(#"{"type":"selection.toggleCluster","day":"\#(day)"}"#).isAccepted)
        #expect(try await send(#"{"type":"nav.back"}"#).isAccepted)
        await expectWait([("idle", .eq, .bool(true))])
    }
}

@MainActor
@Suite("Control plane: break on purpose — export gate (#300)")
struct ControlExportGateTests {

    /// Live `busy`: an export held at the gate is visible in the snapshot (and blocks `idle`); a double-tap
    /// on Save is one push and one export; the export screen has no way out until it settles; and a
    /// re-export finds the album it created (create-or-find + dupe-guard, one-way — D31).
    @Test("held export: live busy, a double-tapped Save is one export, re-export finds its album")
    func heldExportIsLiveBusy() async throws {
        let harness = ControlHarness(.oneAlbum)
        await harness.runtime.bootstrap()
        try await harness.pickFirstDayAndReturnToOverview()

        #expect(try await harness.fixtureOp(#"{"op":"library.holdExports"}"#).isAccepted)
        let save = try #require(try await harness.send(#"{"type":"nav.openExport"}"#).seq)
        await harness.expectWait([("library.heldExports", .eq, .int(1))])
        // Busy, live: the export runs, nothing has settled, and the app isn't idle.
        await harness.expectWait([("active.export.phase", .eq, .string("exporting")),
                                  ("pending.export", .eq, .bool(true)), ("idle", .eq, .bool(false))], timeoutMs: 0)
        #expect(harness.int("settledSeq").map { $0 < save } == true)
        // The double-tap: the second Save is the coordinator's re-entrancy guard; one export screen on the path.
        #expect(try await harness.send(#"{"type":"nav.openExport"}"#).isNoop)
        #expect(harness.coordinator.path.filter { if case .export = $0 { true } else { false } }.count == 1)
        // The export screen hides its back button; Back to albums shows only once it settles.
        #expect(try await harness.send(#"{"type":"nav.back"}"#).refusal == .notShown)
        #expect(try await harness.send(#"{"type":"nav.root"}"#).refusal == .notShown)

        #expect(try await harness.fixtureOp(#"{"op":"library.releaseExports"}"#).isAccepted)
        await harness.expectWait([("active.export.phase", .eq, .string("done")), ("idle", .eq, .bool(true)),
                                  ("settledSeq", .gte, .int(save))])
        #expect(harness.int("library.exportCalls") == 1)
        #expect(harness.int("library.albumsCreated") == 1)
        #expect(harness.int("active.export.added") == 8)
        #expect(harness.value("albums.album-1.inPhotos") == .value(.int(8)))

        // Back to albums, then the same album again: Update in Photos finds the album and adds nothing.
        #expect(try await harness.send(#"{"type":"nav.root"}"#).isAccepted)
        try await harness.send(#"{"type":"nav.openAlbum","album":"album-1"}"#)
        await harness.expectWait([("idle", .eq, .bool(true))])
        try await harness.send(#"{"type":"nav.openExport"}"#)
        await harness.expectWait([("active.export.phase", .eq, .string("done")), ("idle", .eq, .bool(true))])
        #expect(harness.value("active.export.wasReExport") == .value(.bool(true)))
        #expect(harness.int("active.export.added") == 0)
        #expect(harness.int("active.export.total") == 8)
        #expect(harness.int("library.exportCalls") == 2)
        #expect(harness.int("library.albumsCreated") == 1)   // found, not created again
    }

    /// iPad: the sidebar stays tappable over a held export. Re-opening the album and saving again joins the
    /// run in flight — it used to start a second one, creating a second Photos album (fixed in AlbumSession).
    @Test("iPad: re-open the album mid-export + Save again → the one run in flight, one Photos album")
    func iPadReopenMidExportJoins() async throws {
        let harness = ControlHarness(.oneAlbum, iPad: true)
        await harness.runtime.bootstrap()
        try await harness.pickFirstDayAndReturnToOverview()
        try await harness.fixtureOp(#"{"op":"library.holdExports"}"#)
        try await harness.send(#"{"type":"nav.openExport"}"#)
        await harness.expectWait([("library.heldExports", .eq, .int(1))])

        // The sidebar: the album's row (Delete is disabled while it exports), then its overview's Save.
        #expect(try await harness.send(#"{"type":"albums.delete","album":"album-1"}"#).refusal == .busy)
        #expect(try await harness.send(#"{"type":"nav.openAlbum","album":"album-1"}"#).isAccepted)
        await harness.expectWait([("active.scan.phase", .eq, .string("ready")),
                                  ("nav.screen", .eq, .string("overview"))])
        // The export still runs (on the screen that left): pending, not idle.
        await harness.expectWait([("pending.export", .eq, .bool(true)), ("idle", .eq, .bool(false))], timeoutMs: 0)
        #expect(try await harness.send(#"{"type":"nav.openExport"}"#).isAccepted)
        await harness.expectWait([("active.export.phase", .eq, .string("exporting"))])
        #expect(harness.int("library.exportCalls") == 1)

        try await harness.fixtureOp(#"{"op":"library.releaseExports"}"#)
        await harness.expectWait([("active.export.phase", .eq, .string("done")), ("idle", .eq, .bool(true))])
        #expect(harness.int("library.exportCalls") == 1)
        #expect(harness.int("library.albumsCreated") == 1)
        #expect(harness.value("active.export.wasReExport") == .value(.bool(false)))
    }

    /// A failing export (held, then released into the failure): the error screen, its Try again, recovery.
    @Test("failExport: a held export released into a failure → failed → Try again recovers once cleared")
    func failedExportRetries() async throws {
        let harness = ControlHarness(.oneAlbum)
        await harness.runtime.bootstrap()
        try await harness.pickFirstDayAndReturnToOverview()
        try await harness.fixtureOp(#"{"op":"library.holdExports"}"#)
        #expect(try await harness.fixtureOp(#"{"op":"library.failExport","error":"writeFailed"}"#).isAccepted)
        try await harness.send(#"{"type":"nav.openExport"}"#)
        await harness.expectWait([("library.heldExports", .eq, .int(1))])
        #expect(try await harness.send(#"{"type":"export.retry"}"#).refusal == .busy)
        try await harness.fixtureOp(#"{"op":"library.releaseExports"}"#)
        await harness.expectWait([("active.export.phase", .eq, .string("failed")), ("idle", .eq, .bool(true))])
        #expect(harness.value("albums.album-1.exported") == .value(.bool(false)))

        #expect(try await harness.send(#"{"type":"export.retry"}"#).isAccepted)   // still failing
        await harness.expectWait([("active.export.phase", .eq, .string("failed")), ("idle", .eq, .bool(true))])
        #expect(try await harness.fixtureOp(#"{"op":"library.failExport"}"#).isAccepted)
        #expect(try await harness.send(#"{"type":"export.retry"}"#).isAccepted)
        await harness.expectWait([("active.export.phase", .eq, .string("done")), ("idle", .eq, .bool(true))])
        #expect(harness.int("library.exportCalls") == 3)
        #expect(harness.int("library.albumsCreated") == 1)
        #expect(harness.value("albums.album-1.status") == .value(.string("exported")))
    }

    @Test("the export levers decode strictly and say noop when already so")
    func leverEdges() async throws {
        let harness = ControlHarness(.oneAlbum)
        await harness.runtime.bootstrap()
        #expect(try await harness.fixtureOp(#"{"op":"library.releaseExports"}"#).isNoop)
        #expect(try await harness.fixtureOp(#"{"op":"library.holdExports"}"#).isAccepted)
        #expect(try await harness.fixtureOp(#"{"op":"library.holdExports"}"#).isNoop)
        #expect(try await harness.fixtureOp(#"{"op":"library.failExport"}"#).isNoop)
        #expect(throws: ControlRequestError.self) {
            try JSONDecoder().decode(ControlFixtureOp.self,
                                     from: Data(#"{"op":"library.failExport","error":"nope"}"#.utf8))
        }
        #expect(throws: ControlRequestError.self) {
            try JSONDecoder().decode(ControlFixtureOp.self,
                                     from: Data(#"{"op":"library.addPhotos","day":"2025-07-05","count":0}"#.utf8))
        }
        #expect(throws: ControlRequestError.self) {
            try JSONDecoder().decode(ControlFixtureOp.self,
                                     from: Data(#"{"op":"library.addPhotos","day":"undated","count":1}"#.utf8))
        }
        // A test's own library wrapper has no gate: the levers say so.
        let wrapped = ControlHarness(.oneAlbum, library: GatedLibrary(ControlFixture.oneAlbum.makeLibrary()))
        await wrapped.runtime.bootstrap()
        #expect(try await wrapped.fixtureOp(#"{"op":"library.holdExports"}"#).refusal == .unavailable)
        #expect(wrapped.value("library") == .value(.null))
    }
}

@MainActor
@Suite("Control plane: break on purpose — relaunch (#300)")
struct ControlRelaunchTests {

    /// D15's accepted loss window, made concrete: a pick that was flushed survives a kill; a pick still
    /// inside the debounce window does not. (`simctl terminate` delivers no scene-phase change, so nothing
    /// flushes on the way down; here the first run is simply abandoned without a flush.)
    @Test("kill mid-debounce: the flushed pick survives a relaunch, the unflushed one is lost")
    func killMidDebounce() async throws {
        let paths = ControlHarness.temporaryPaths()
        let flushed = try #require(ControlFixture.yearDatedIDs.first { !ControlFixture.midReviewPicks.contains($0) })
        let unflushed = try #require(ControlFixture.yearDatedIDs.last { !ControlFixture.midReviewPicks.contains($0) })
        do {
            let first = ControlHarness(.midReview, paths: paths)
            await first.runtime.bootstrap()
            try await first.send(#"{"type":"nav.openAlbum","album":"album-1"}"#)
            await first.expectWait([("idle", .eq, .bool(true))])
            try await first.send(#"{"type":"nav.openReview","album":"album-1"}"#)
            await first.expectWait([("idle", .eq, .bool(true))])
            let flushedAlias = try #require(first.runtime.assetAliases.alias(for: flushed))
            let unflushedAlias = try #require(first.runtime.assetAliases.alias(for: unflushed))
            #expect(try await first.send(#"{"type":"selection.toggle","photo":"\#(flushedAlias)"}"#).isAccepted)
            #expect(try await first.fixtureOp(#"{"op":"flush"}"#).isAccepted)
            #expect(try await first.send(#"{"type":"selection.toggle","photo":"\#(unflushedAlias)"}"#).isAccepted)
            #expect(first.value("active.selection.count") == .value(.int(36)))
            #expect(first.value("pending.selectionFlush") == .value(.bool(true)))
            // … and the process dies here: no scene phase, no flush.
        }

        let second = ControlHarness(.midReview, paths: paths, relaunch: true)
        await second.runtime.bootstrap()
        #expect(second.value("app.fixture") == .value(.string("mid-review")))
        #expect(second.value("nav.screen") == .value(.string("albums")))   // a cold launch lands on the list
        #expect(second.value("albums.album-1.picked") == .value(.int(35)))
        try await second.send(#"{"type":"nav.openAlbum","album":"album-1"}"#)
        await second.expectWait([("idle", .eq, .bool(true))])
        #expect(second.value("active.selection.count") == .value(.int(35)))
        let persisted = second.graph.projectStore.projects.first?.persistedPicks ?? []
        #expect(persisted.contains(flushed))
        #expect(!persisted.contains(unflushed))
        #expect(second.value("active.done.days") == .value(.int(4)))      // the fixture's done days, flushed at seed
    }

    /// The fake's exported albums persist with the store, so a relaunched re-export finds the album it made —
    /// and without them (today's in-memory fake) the same re-export fails `.albumMissing`.
    @Test("relaunch: a re-export finds the album the last run created (and fails without its state)")
    func relaunchedReExport() async throws {
        for keepsLibraryState in [true, false] {
            let paths = ControlHarness.temporaryPaths()
            do {
                let first = ControlHarness(.oneAlbum, paths: paths)
                await first.runtime.bootstrap()
                try await first.pickFirstDayAndReturnToOverview()
                try await first.send(#"{"type":"nav.openExport"}"#)
                await first.expectWait([("active.export.phase", .eq, .string("done")), ("idle", .eq, .bool(true))])
                #expect(first.int("library.albumsCreated") == 1)
            }
            if !keepsLibraryState { try FileManager.default.removeItem(at: paths.library) }

            let second = ControlHarness(.oneAlbum, paths: paths, relaunch: true)
            await second.runtime.bootstrap()
            #expect(second.value("albums.album-1.status") == .value(.string("exported")))
            #expect(second.value("albums.album-1.inPhotos") == .value(.int(8)))
            try await second.send(#"{"type":"nav.openAlbum","album":"album-1"}"#)
            await second.expectWait([("idle", .eq, .bool(true))])
            try await second.send(#"{"type":"nav.openExport"}"#)
            await second.expectWait([("idle", .eq, .bool(true))])
            if keepsLibraryState {
                #expect(second.value("active.export.phase") == .value(.string("done")))
                #expect(second.value("active.export.wasReExport") == .value(.bool(true)))
                #expect(second.int("active.export.added") == 0)
                #expect(second.int("library.albumsCreated") == 1)   // the restored count: nothing new created
            } else {
                #expect(second.value("active.export.phase") == .value(.string("failed")))
            }
        }
    }

    @Test("-PoimiRelaunch continues the run on record; refused without one, or with a fixture")
    func relaunchParsing() {
        let relaunch = ["-PoimiControl", "-PoimiRelaunch"]
        #expect(ControlLaunch.parse(relaunch, recorded: .midReview)
                == .on(ControlLaunch(fixture: .midReview, route: nil, viewer: nil, relaunch: true)))
        #expect(ControlLaunch.parse(relaunch + ["-PoimiHeadless"], recorded: .oneAlbum).launch?.headless == true)
        guard case .invalid(let none) = ControlLaunch.parse(relaunch, recorded: nil) else {
            Issue.record("a relaunch with nothing on record ran")
            return
        }
        #expect(none.contains("no control run on record"))
        guard case .invalid = ControlLaunch.parse(relaunch + ["-PoimiFixture", "one-album"], recorded: .oneAlbum)
        else {
            Issue.record("a relaunch with a fixture ran")
            return
        }
        guard case .invalid = ControlLaunch.parse(["-PoimiRelaunch"], recorded: .oneAlbum) else {
            Issue.record("-PoimiRelaunch without -PoimiControl ran")
            return
        }
    }

    @Test("album aliases survive a relaunch; a new album still never reuses a number")
    func aliasesSurviveRelaunch() async throws {
        let paths = ControlHarness.temporaryPaths()
        do {
            let first = ControlHarness(.fourStatuses, paths: paths, iPad: true)
            await first.runtime.bootstrap()
            #expect(try await first.send(#"{"type":"albums.delete","album":"album-2"}"#).isAccepted)
            let duplicate = try await first.send(#"{"type":"albums.duplicate","album":"album-3"}"#)
            guard case .accepted(_, let extra) = duplicate else { Issue.record("\(duplicate)"); return }
            #expect(extra.first { $0.key == "album" }?.value == .string("album-5"))
        }
        let second = ControlHarness(.fourStatuses, paths: paths, relaunch: true, iPad: true)
        await second.runtime.bootstrap()
        guard case .value(.object(let rows)) = second.value("albums") else { Issue.record("no albums"); return }
        #expect(rows.map(\.key) == ["album-1", "album-3", "album-4", "album-5"])
        #expect(second.value("albums.album-1.status") == .value(.string("exported")))
        let created = try await second.send(#"{"type":"albums.duplicate","album":"album-1"}"#)
        guard case .accepted(_, let extra) = created else { Issue.record("\(created)"); return }
        #expect(extra.first { $0.key == "album" }?.value == .string("album-6"))
    }
}

@MainActor
@Suite("Control plane: break on purpose — library drift (#300, #191)")
struct ControlLibraryDriftTests {

    /// #191: new photos land in the library under an exported album. The open album sees them on its next
    /// scan (the app doesn't observe the library); picking them makes the album "edited since export · N to
    /// add" — additions only, an un-pick doesn't count against it — and the re-export adds just those, removing
    /// nothing from Photos (one-way, D31). The added photos (and their aliases) survive a relaunch.
    @Test("#191 drift: added photos → N to add → re-export adds N, removes nothing; survives relaunch")
    func additionsOnlyDrift() async throws {
        let paths = ControlHarness.temporaryPaths()
        let day = "2025-07-05"
        let july5 = try #require(DayKey(day))
        let exportedOnDay = try #require(ControlFixture.yearAssets.first {
            ControlFixture.exportedPicks.contains($0.id)
                && $0.captureDate.map { DayKey(date: $0, calendar: ControlFixture.utc) } == july5
        })
        let inPhotos = ControlFixture.exportedPicks.count
        var added: [String] = []
        do {
            let harness = ControlHarness(.exported, paths: paths)
            await harness.runtime.bootstrap()
            #expect(harness.value("albums.album-1.status") == .value(.string("exported")))
            #expect(harness.value("albums.album-1.inPhotos") == .value(.int(inPhotos)))
            added = try await addThreePhotosAndReopen(harness, day: day)

            try await harness.send(#"{"type":"nav.openReview","album":"album-1","day":"\#(day)"}"#)
            await harness.expectWait([("idle", .eq, .bool(true))])
            for alias in added {
                #expect(try await harness.send(#"{"type":"selection.toggle","photo":"\#(alias)"}"#).isAccepted)
            }
            let removed = try #require(harness.runtime.assetAliases.alias(for: exportedOnDay.id))
            #expect(try await harness.send(#"{"type":"selection.toggle","photo":"\#(removed)"}"#).isAccepted)
            #expect(harness.value("albums.album-1.status") == .value(.string("editedSinceExport")))
            #expect(harness.value("albums.album-1.toAdd") == .value(.int(3)))   // the un-pick doesn't offset
            #expect(harness.value("albums.album-1.picked") == .value(.int(inPhotos + 2)))

            try await harness.send(#"{"type":"nav.back"}"#)
            await harness.expectWait([("idle", .eq, .bool(true))])
            try await harness.send(#"{"type":"nav.openExport"}"#)
            await harness.expectWait([("active.export.phase", .eq, .string("done")), ("idle", .eq, .bool(true))])
            #expect(harness.value("active.export.wasReExport") == .value(.bool(true)))
            #expect(harness.int("active.export.added") == 3)
            #expect(harness.int("active.export.total") == inPhotos + 3)   // the un-picked photo is still there
            #expect(harness.value("albums.album-1.status") == .value(.string("exported")))
            #expect(harness.value("albums.album-1.inPhotos") == .value(.int(inPhotos + 3)))
            #expect(harness.int("library.albumsCreated") == 0)            // found the album it was exported to
        }

        let relaunched = ControlHarness(.exported, paths: paths, relaunch: true)
        await relaunched.runtime.bootstrap()
        #expect(relaunched.value("albums.album-1.inPhotos") == .value(.int(inPhotos + 3)))
        #expect(added.map { relaunched.runtime.assetAliases.assetID(for: $0) != nil } == [true, true, true])
        try await relaunched.send(#"{"type":"nav.openAlbum","album":"album-1"}"#)
        await relaunched.expectWait([("idle", .eq, .bool(true))])
        #expect(relaunched.value("albums.album-1.status") == .value(.string("exported")))
    }

    /// Open `album-1`, add three photos on `day`, and show the open scan doesn't see them until the album is
    /// opened again. Returns the new photos' aliases.
    private func addThreePhotosAndReopen(_ harness: ControlHarness, day: String) async throws -> [String] {
        try await harness.send(#"{"type":"nav.openAlbum","album":"album-1"}"#)
        await harness.expectWait([("idle", .eq, .bool(true))])
        let before = try #require(harness.int("active.scan.candidates"))

        let add = try await harness.fixtureOp(#"{"op":"library.addPhotos","day":"\#(day)","count":3}"#)
        guard case .accepted(_, let extra) = add,
              case .array(let photos)? = extra.first(where: { $0.key == "photos" })?.value else {
            Issue.record("\(add)")
            return []
        }
        let added = photos.compactMap { if case .string(let alias) = $0 { alias } else { nil } }
        let seeded = ControlFixture.yearAssets.count                    // numbered after every seeded alias
        #expect(added == (1...3).map { String(format: "a-%04d", seeded + $0) })
        await harness.expectWait([("idle", .eq, .bool(true))])
        #expect(harness.int("active.scan.candidates") == before)       // the open scan doesn't see them …
        try await harness.send(#"{"type":"nav.root"}"#)
        try await harness.send(#"{"type":"nav.openAlbum","album":"album-1"}"#)
        await harness.expectWait([("idle", .eq, .bool(true))])
        #expect(harness.int("active.scan.candidates") == before + 3)   // … the next one does
        return added
    }
}
