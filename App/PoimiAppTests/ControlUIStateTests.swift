//
//  ControlUIStateTests.swift
//  PoimiAppTests — the slice-D actions through `ControlHost` (#299, docs/plans/control-plane.md §4 D): the
//  Overview's filter, the grid's current cluster, the viewer (page / Pick / end-of-set card / the auto-done
//  toast) and the modals. These pin what the HOST adds — reachability, refusals, one snapshot path per
//  piece; the stores' own behaviour is `ReviewScreenStateTests`. Every action is decoded from the JSON an
//  agent sends; every wait awaits the real work — never a fixed sleep.
//

import Testing
import Foundation
import Curation
@testable import PoimiApp

extension ControlHarness {
    /// The open review's clusters (the session's published ones).
    var clusters: [ReviewCluster] { graph.session.reviewClusters }

    /// A photo's alias.
    func alias(_ id: String) throws -> String { try #require(runtime.assetAliases.alias(for: id)) }

    /// Open `album`'s grid (no drill day) and wait for its scan.
    func openGrid(_ album: String = "album-1") async throws {
        #expect(try await send(#"{"type":"nav.openAlbum","album":"\#(album)"}"#).isAccepted)
        #expect(try await send(#"{"type":"nav.openReview","album":"\#(album)"}"#).isAccepted)
        await settled()
    }
}

@MainActor
@Suite("Control plane: screen state beyond routes (#299)")
struct ControlUIStateTests {

    // MARK: - review.setFilter

    @Test("review.setFilter: the overview's menu — active.overview.filter; noop on repeat; not on the grid")
    func overviewFilter() async throws {
        let harness = await ControlHarness.booted(.midReview)
        #expect(try await harness.send(#"{"type":"review.setFilter","filter":"toReview"}"#).refusal == .notShown)
        try await harness.send(#"{"type":"nav.openAlbum","album":"album-1"}"#)
        await harness.settled()
        #expect(harness.value("active.overview.filter") == .value(.string("all")))
        #expect(try await harness.send(#"{"type":"review.setFilter","filter":"toReview"}"#).isAccepted)
        #expect(harness.value("active.overview.filter") == .value(.string("toReview")))
        #expect(try await harness.send(#"{"type":"review.setFilter","filter":"toReview"}"#).isNoop)
        try await harness.send(#"{"type":"nav.openReview","album":"album-1"}"#)
        await harness.settled()
        #expect(try await harness.send(#"{"type":"review.setFilter","filter":"done"}"#).refusal == .notShown)
        #expect(throws: (any Error).self) {   // a bad lens is a bad request, not a refusal
            try JSONDecoder().decode(ControlAction.self, from: Data(#"{"type":"review.setFilter","filter":"x"}"#.utf8))
        }
    }

    @Test("the filter isn't shown with a single cluster")
    func filterHiddenOnOneCluster() async throws {
        let harness = await ControlHarness.booted(.oneAlbum)
        let created = try await harness.send(
            #"{"type":"albums.create","title":"One day","start":"2025-07-05","end":"2025-07-05","target":5}"#)
        #expect(created.isAccepted, "\(created)")
        await harness.settled()
        try #require(harness.clusters.count == 1)
        #expect(try await harness.send(#"{"type":"review.setFilter","filter":"done"}"#).refusal == .notShown)
    }

    /// Regression (found building #299): `albums.create` / `albums.update` built the period on
    /// `DayKey.anchorDate` (noon), so a one-day album ran noon to noon and held the next morning's photos.
    @Test("albums.create / albums.update periods run midnight to midnight, as the date pickers give them")
    func periodsStartAtMidnight() async throws {
        let harness = await ControlHarness.booted(.oneAlbum)
        try await harness.send(
            #"{"type":"albums.create","title":"One day","start":"2025-07-05","end":"2025-07-05","target":5}"#)
        await harness.settled()
        let project = try #require(harness.project("album-2"))
        let calendar = harness.graph.calendar
        let july5 = try #require(calendar.date(from: DateComponents(year: 2025, month: 7, day: 5)))
        #expect(project.rangeStart == july5)
        #expect(project.rangeEnd == calendar.date(byAdding: .day, value: 1, to: july5))
        #expect(harness.clusters.map(\.days) == [[.day(year: 2025, month: 7, day: 5)]])

        try await harness.send(#"{"type":"nav.openSettings","album":"album-2"}"#)
        try await harness.send(#"{"type":"albums.update","album":"album-2","start":"2025-07-04","end":"2025-07-06"}"#)
        #expect(project.rangeStart == calendar.date(byAdding: .day, value: -1, to: july5))
        #expect(project.rangeEnd == calendar.date(byAdding: .day, value: 2, to: july5))
    }

    // MARK: - review.goTo / review.markDoneAndAdvance

    @Test("the grid page: active.grid.cluster; goTo / markDoneAndAdvance only on the grid")
    func gridCluster() async throws {
        let harness = await ControlHarness.booted(.midReview)
        try await harness.openGrid()
        let entry = try #require(harness.graph.session.currentReviewCluster)
        #expect(harness.value("active.grid.cluster") == .value(.string(entry.firstDay?.description)))

        let target = try #require(harness.clusters.last)
        let day = try #require(target.days.last).description   // any of the cluster's days reaches it
        #expect(try await harness.send(#"{"type":"review.goTo","day":"\#(day)"}"#).isAccepted)
        #expect(harness.value("active.grid.cluster") == .value(.string(target.firstDay?.description)))
        #expect(try await harness.send(#"{"type":"review.goTo","day":"\#(day)"}"#).isNoop)
        #expect(try await harness.send(#"{"type":"review.goTo","day":"2024-01-01"}"#).refusal == .notShown)
        #expect(try await harness.send(#"{"type":"review.markDoneAndAdvance"}"#).isAccepted)
        #expect(harness.graph.doneStore.isDone(target))

        try await harness.send(#"{"type":"nav.back"}"#)
        #expect(harness.value("active.grid.cluster") == .value(.null))
        #expect(try await harness.send(#"{"type":"review.markDoneAndAdvance"}"#).refusal == .notShown)
        #expect(try await harness.send(#"{"type":"review.goTo","day":"\#(day)"}"#).refusal == .notShown)
    }

    // MARK: - viewer.page / viewer.undoAutoDone / the end-of-set card

    @Test("viewer.page + the auto-done toast: nav.viewerPhoto / nav.viewerToast; Undo; the filmstrip's reach")
    func viewerPagingAndToast() async throws {
        let harness = await ControlHarness.booted(.midReview)
        try await harness.openGrid()
        let done = harness.graph.doneStore
        let index = try #require(harness.clusters.firstIndex { !done.isDone($0) })
        let cluster = harness.clusters[index]
        let last = try harness.alias(try #require(cluster.assetIDs.last))
        let nextFirst = try harness.alias(try #require(harness.clusters[index + 1].assetIDs.first))

        #expect(try await harness.send(#"{"type":"viewer.page","direction":"next"}"#).refusal == .notShown)
        try await harness.send(#"{"type":"viewer.open","photo":"\#(last)"}"#)
        #expect(harness.value("nav.viewerToast") == .value(.null))
        #expect(try await harness.send(#"{"type":"viewer.undoAutoDone"}"#).refusal == .notShown)
        #expect(try await harness.send(#"{"type":"viewer.page","direction":"next"}"#).isAccepted)
        #expect(harness.value("nav.viewerPhoto") == .value(.string(nextFirst)))
        #expect(harness.value("nav.viewerToast.day") == .value(.string(cluster.firstDay?.description)))
        #expect(done.isDone(cluster))
        #expect(try await harness.send(#"{"type":"viewer.undoAutoDone"}"#).isAccepted)   // the toast's Undo
        #expect(!done.isDone(cluster))
        #expect(harness.value("nav.viewerToast") == .value(.null))

        // A filmstrip tap reaches exactly what the strip shows.
        let strip = harness.graph.viewer.filmstripPages
        let inStrip = try harness.alias(try #require(strip.last))
        let pastStrip = try #require(harness.graph.session.reviewOrderedIDs.first { !strip.contains($0) })
        #expect(try await harness.send(#"{"type":"viewer.page","photo":"\#(harness.alias(pastStrip))"}"#)
                    .refusal == .notShown)
        #expect(try await harness.send(#"{"type":"viewer.page","photo":"\#(inStrip)"}"#).isAccepted)
        #expect(harness.value("nav.viewerPhoto") == .value(.string(inStrip)))
    }

    @Test("past the last photo: the end-of-set card covers the transport; its Save to Photos is nav.openExport")
    func endOfSetCard() async throws {
        let harness = await ControlHarness.booted(.midReview)
        try await harness.openGrid()
        let lastID = try #require(harness.graph.session.reviewOrderedIDs.last)
        try await harness.send(#"{"type":"viewer.open","photo":"\#(harness.alias(lastID))"}"#)
        // Not on the grid's (unfinished) review, nor the open viewer, until the card shows.
        #expect(try await harness.send(#"{"type":"nav.openExport"}"#).refusal == .notShown)
        #expect(try await harness.send(#"{"type":"viewer.keepReviewing"}"#).refusal == .notShown)

        #expect(try await harness.send(#"{"type":"viewer.page","direction":"next"}"#).isAccepted)
        #expect(harness.value("nav.viewerEndOfSet") == .value(.bool(true)))
        #expect(try await harness.send(#"{"type":"viewer.page","direction":"previous"}"#).refusal == .notShown)
        #expect(try await harness.send(#"{"type":"viewer.pick"}"#).refusal == .notShown)
        #expect(try await harness.send(#"{"type":"viewer.keepReviewing"}"#).isAccepted)
        #expect(harness.value("nav.viewerEndOfSet") == .value(.bool(false)))

        try await harness.send(#"{"type":"viewer.page","direction":"next"}"#)
        #expect(try await harness.send(#"{"type":"nav.openExport"}"#).isAccepted)
        #expect(harness.value("nav.sheet") == .value(.null))
        #expect(harness.value("nav.screen") == .value(.string("export")))
        let exported = await harness.wait([("active.export.phase", .eq, .string("done")), ("idle", .eq, .bool(true))])
        #expect((try? exported.get()) != nil, "\(exported)")
    }
}

@MainActor
@Suite("Control plane: modals (#299)")
struct ControlModalTests {

    @Test("New album sheet: present, it covers the screen, Create from it, or dismiss")
    func newAlbumSheet() async throws {
        let harness = await ControlHarness.booted(.oneAlbum)
        #expect(try await harness.send(#"{"type":"ui.present","modal":"newAlbum"}"#).isAccepted)
        #expect(harness.value("nav.sheet") == .value(.string("newAlbum")))
        #expect(try await harness.send(#"{"type":"ui.present","modal":"newAlbum"}"#).isNoop)
        // Nothing behind a sheet is reachable.
        #expect(try await harness.send(#"{"type":"nav.openAlbum","album":"album-1"}"#).refusal == .notShown)
        #expect(try await harness.send(#"{"type":"ui.confirm"}"#).refusal == .notShown)
        #expect(try await harness.send(#"{"type":"ui.dismiss"}"#).isAccepted)
        #expect(harness.value("nav.sheet") == .value(.null))
        #expect(try await harness.send(#"{"type":"ui.dismiss"}"#).isNoop)

        try await harness.send(#"{"type":"ui.present","modal":"newAlbum"}"#)
        let create = #"{"type":"albums.create","title":"Summer","start":"2025-06-01","end":"2025-08-31","target":40}"#
        #expect(try await harness.send(create).isAccepted)
        #expect(harness.value("nav.sheet") == .value(.null))
        #expect(harness.value("nav.screen") == .value(.string("overview")))
        await harness.settled()
    }

    @Test("confirmations from the album list: nav.sheet + sheetAlbum; ui.confirm / ui.dismiss; settings-only ones")
    func listConfirmations() async throws {
        let harness = await ControlHarness.booted(.fourStatuses)
        // A confirmation needs its album, and only the confirmations take one.
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(ControlAction.self,
                                     from: Data(#"{"type":"ui.present","modal":"confirmDelete"}"#.utf8))
        }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(ControlAction.self,
                                     from: Data(#"{"type":"ui.present","modal":"newAlbum","album":"album-1"}"#.utf8))
        }
        #expect(try await harness.send(#"{"type":"ui.present","modal":"confirmDelete","album":"album-4"}"#).isAccepted)
        #expect(harness.value("nav.sheet") == .value(.string("confirmDelete")))
        #expect(harness.value("nav.sheetAlbum") == .value(.string("album-4")))
        #expect(try await harness.send(#"{"type":"ui.dismiss"}"#).isAccepted)   // Cancel: nothing deleted
        #expect(harness.value("albums.album-4") != .missing)
        try await harness.send(#"{"type":"ui.present","modal":"confirmDelete","album":"album-4"}"#)
        #expect(try await harness.send(#"{"type":"ui.confirm"}"#).isAccepted)
        #expect(harness.value("albums.album-4") == .missing)
        #expect(harness.value("nav.sheet") == .value(.null))
        // Mark all unreviewed is on the album's settings only.
        #expect(try await harness.send(#"{"type":"ui.present","modal":"confirmUnreview","album":"album-1"}"#)
                    .refusal == .notShown)
    }

    @Test("a refused ui.confirm leaves the dialog up and the album untouched (its export is running)")
    func refusedConfirm() async throws {
        let gated = GatedLibrary(ControlFixture.midReview.makeLibrary())
        let harness = await ControlHarness.booted(.midReview, library: gated, iPad: true)
        try await harness.send(#"{"type":"nav.openAlbum","album":"album-1"}"#)
        await harness.settled()
        await gated.hold(exports: true)
        #expect(try await harness.send(#"{"type":"nav.openExport"}"#).isAccepted)
        await gated.waitUntilHeld()
        // The sidebar's Delete is disabled while it exports…
        #expect(try await harness.send(#"{"type":"ui.present","modal":"confirmDelete","album":"album-1"}"#)
                    .refusal == .busy)
        // …and a dialog already up when the export started can't run it either: the reply is `busy`, and
        // nothing changed.
        let project = try #require(harness.project("album-1"))
        let confirmation = AlbumConfirmation(kind: .delete, album: project.id, origin: .albumList)
        harness.coordinator.present(.confirm(confirmation))
        #expect(try await harness.send(#"{"type":"ui.confirm"}"#).refusal == .busy)
        #expect(harness.value("nav.sheet") == .value(.string("confirmDelete")))
        #expect(harness.value("albums.album-1") != .missing)
        harness.coordinator.dismiss(.confirm(confirmation))
        await gated.release()
        await harness.settled()
    }

    @Test("iPad: on album settings the settings' dialog is the one (not the sidebar's); What's New on app settings")
    func settingsConfirmations() async throws {
        let harness = await ControlHarness.booted(.midReview, iPad: true)
        try await harness.send(#"{"type":"nav.openAlbum","album":"album-1"}"#)
        await harness.settled()
        try await harness.send(#"{"type":"nav.openSettings","album":"album-1"}"#)

        #expect(try await harness.send(#"{"type":"ui.present","modal":"confirmUnreview","album":"album-1"}"#)
                    .isAccepted)
        guard case .confirm(let confirmation)? = harness.coordinator.modal else {
            Issue.record("no confirmation up")
            return
        }
        #expect(confirmation.origin == .albumSettings)
        // The sidebar is behind the dialog too.
        #expect(try await harness.send(#"{"type":"albums.duplicate","album":"album-1"}"#).refusal == .notShown)
        #expect(try await harness.send(#"{"type":"ui.confirm"}"#).isAccepted)
        // The button is disabled with nothing marked done.
        #expect(try await harness.send(#"{"type":"ui.present","modal":"confirmUnreview","album":"album-1"}"#)
                    .refusal == .invalidState)

        #expect(try await harness.send(#"{"type":"ui.present","modal":"whatsNew"}"#).refusal == .notShown)
        try await harness.send(#"{"type":"nav.openAppSettings"}"#)
        #expect(try await harness.send(#"{"type":"ui.present","modal":"whatsNew"}"#).isAccepted)
        #expect(harness.value("nav.sheet") == .value(.string("whatsNew")))
        #expect(try await harness.send(#"{"type":"nav.back"}"#).refusal == .notShown)
        #expect(try await harness.send(#"{"type":"ui.dismiss"}"#).isAccepted)
        #expect(try await harness.send(#"{"type":"nav.back"}"#).isAccepted)
    }
}
