//
//  ControlUIStateTests.swift
//  PoimiAppTests — the slice-D actions through `ControlHost` (#299, docs/plans/control-plane.md §4 D): the
//  Overview's filter, the grid's current cluster (`review.goTo`, `review.markDoneAndAdvance`), the viewer's
//  page / Pick / end-of-set card, and the modals (`ui.present` / `ui.confirm` / `ui.dismiss`), each read
//  back from its snapshot path, plus the `-PoimiFilter` / `-PoimiModal` launch flags. Every action is
//  decoded from the JSON an agent sends; every wait awaits the real work — never a fixed sleep.
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

    /// Open album-1's grid (no drill day) and wait for its scan.
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

    @Test("review.setFilter is the overview's filter menu: set, noop on repeat, kept under the grid, reset on reopen")
    func overviewFilter() async throws {
        let harness = ControlHarness(.midReview)
        await harness.runtime.bootstrap()
        // Not on screen before the album is open.
        #expect(try await harness.send(#"{"type":"review.setFilter","filter":"toReview"}"#).refusal == .notShown)
        try await harness.send(#"{"type":"nav.openAlbum","album":"album-1"}"#)
        await harness.settled()
        #expect(harness.value("active.overview.filter") == .value(.string("all")))

        #expect(try await harness.send(#"{"type":"review.setFilter","filter":"toReview"}"#).isAccepted)
        #expect(harness.value("active.overview.filter") == .value(.string("toReview")))
        #expect(try await harness.send(#"{"type":"review.setFilter","filter":"toReview"}"#).isNoop)

        // On the grid the menu isn't on screen; back on the Overview it still holds.
        try await harness.send(#"{"type":"nav.openReview","album":"album-1"}"#)
        await harness.settled()
        #expect(try await harness.send(#"{"type":"review.setFilter","filter":"done"}"#).refusal == .notShown)
        try await harness.send(#"{"type":"nav.back"}"#)
        #expect(harness.value("active.overview.filter") == .value(.string("toReview")))

        // Closing the album drops it, like the view's `@State` it was.
        try await harness.send(#"{"type":"nav.root"}"#)
        try await harness.send(#"{"type":"nav.openAlbum","album":"album-1"}"#)
        await harness.settled()
        #expect(harness.value("active.overview.filter") == .value(.string("all")))

        // A bad lens is a bad request, not a refusal.
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(ControlAction.self, from: Data(#"{"type":"review.setFilter","filter":"x"}"#.utf8))
        }
    }

    @Test("the filter isn't shown with a single cluster")
    func filterHiddenOnOneCluster() async throws {
        let harness = ControlHarness(.oneAlbum)
        await harness.runtime.bootstrap()
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
        let harness = ControlHarness(.oneAlbum)
        await harness.runtime.bootstrap()
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

    @Test("the grid's current cluster: entry, goTo, markDoneAndAdvance — read back from active.grid.cluster")
    func gridCluster() async throws {
        let harness = ControlHarness(.midReview)
        await harness.runtime.bootstrap()
        try await harness.openGrid()
        let clusters = harness.clusters
        let done = harness.graph.doneStore
        // Entered on the first unreviewed cluster (mid-review has its first days done).
        let firstOpen = try #require(clusters.firstIndex { !done.isDone($0) })
        #expect(firstOpen > 0)
        #expect(harness.value("active.grid.cluster")
                == .value(.string(clusters[firstOpen].firstDay?.description)))

        let target = clusters[firstOpen + 2]
        let day = try #require(target.days.last).description   // any of the cluster's days reaches it
        #expect(try await harness.send(#"{"type":"review.goTo","day":"\#(day)"}"#).isAccepted)
        #expect(harness.value("active.grid.cluster") == .value(.string(target.firstDay?.description)))
        #expect(try await harness.send(#"{"type":"review.goTo","day":"\#(day)"}"#).isNoop)
        #expect(try await harness.send(#"{"type":"review.goTo","day":"2024-01-01"}"#).refusal == .notShown)

        // Mark day done → done, and on to the next unreviewed cluster.
        let doneBefore = harness.value("active.done.clusters")
        #expect(try await harness.send(#"{"type":"review.markDoneAndAdvance"}"#).isAccepted)
        #expect(done.isDone(target))
        #expect(doneBefore != harness.value("active.done.clusters"))
        let next = try #require(clusters[(firstOpen + 3)...].first { !done.isDone($0) })
        #expect(harness.value("active.grid.cluster") == .value(.string(next.firstDay?.description)))

        // Left the grid → no current cluster; the next visit enters afresh (on the drill day).
        try await harness.send(#"{"type":"nav.back"}"#)
        #expect(harness.value("active.grid.cluster") == .value(.null))
        #expect(try await harness.send(#"{"type":"review.markDoneAndAdvance"}"#).refusal == .notShown)
        try await harness.send(#"{"type":"nav.openReview","album":"album-1","day":"\#(day)"}"#)
        await harness.settled()
        #expect(harness.value("active.grid.cluster") == .value(.string(target.firstDay?.description)))
    }

    // MARK: - viewer.page / viewer.pick / viewer.keepReviewing

    @Test("viewer.page: a forward step across a cluster's end auto-marks it (#128); the grid follows on dismiss")
    func viewerPaging() async throws {
        let harness = ControlHarness(.midReview)
        await harness.runtime.bootstrap()
        try await harness.openGrid()
        let done = harness.graph.doneStore
        let clusters = harness.clusters
        let index = try #require(clusters.firstIndex { !done.isDone($0) })
        let cluster = clusters[index]
        let last = try harness.alias(try #require(cluster.assetIDs.last))
        let nextFirst = try harness.alias(try #require(clusters[index + 1].assetIDs.first))

        #expect(try await harness.send(#"{"type":"viewer.page","direction":"next"}"#).refusal == .notShown)
        try await harness.send(#"{"type":"viewer.open","photo":"\#(last)"}"#)
        #expect(harness.value("nav.viewerEndOfSet") == .value(.bool(false)))
        #expect(try await harness.send(#"{"type":"viewer.page","direction":"next"}"#).isAccepted)
        #expect(harness.value("nav.viewerPhoto") == .value(.string(nextFirst)))
        #expect(done.isDone(cluster))
        #expect(try await harness.send(#"{"type":"viewer.page","direction":"previous"}"#).isAccepted)
        #expect(harness.value("nav.viewerPhoto") == .value(.string(last)))
        #expect(done.isDone(cluster))   // back never un-marks

        // A filmstrip jump: within the window, never marks; far away isn't on the strip.
        let ahead = try harness.alias(clusters[index + 1].assetIDs[min(1, clusters[index + 1].count - 1)])
        #expect(try await harness.send(#"{"type":"viewer.page","photo":"\#(ahead)"}"#).isAccepted)
        #expect(harness.value("nav.viewerPhoto") == .value(.string(ahead)))
        let far = try harness.alias(try #require(harness.graph.session.reviewOrderedIDs.last))
        #expect(try await harness.send(#"{"type":"viewer.page","photo":"\#(far)"}"#).refusal == .notShown)

        // Dismissed: the grid's page follows the photo the viewer ended on.
        try await harness.send(#"{"type":"viewer.dismiss"}"#)
        #expect(harness.value("nav.viewerEndOfSet") == .value(.null))
        #expect(harness.value("active.grid.cluster")
                == .value(.string(clusters[index + 1].firstDay?.description)))
    }

    @Test("past the last photo: the end-of-set card; its Save to Photos is nav.openExport; Keep reviewing closes it")
    func endOfSetCard() async throws {
        let harness = ControlHarness(.midReview)
        await harness.runtime.bootstrap()
        try await harness.openGrid()
        let lastID = try #require(harness.graph.session.reviewOrderedIDs.last)
        let last = try harness.alias(lastID)
        if harness.selection.contains(lastID) { harness.selection.toggle(lastID) }   // Pick must ADD
        try await harness.send(#"{"type":"viewer.open","photo":"\#(last)"}"#)
        // Not on the grid's (unfinished) review, nor the open viewer, until the card shows.
        #expect(try await harness.send(#"{"type":"nav.openExport"}"#).refusal == .notShown)

        let picked = harness.selection.selected.count
        #expect(try await harness.send(#"{"type":"viewer.pick"}"#).isAccepted)   // pick the last → the card
        #expect(harness.selection.selected.count == picked + 1)
        #expect(harness.value("nav.viewerEndOfSet") == .value(.bool(true)))
        // The card's scrim covers the transport.
        #expect(try await harness.send(#"{"type":"viewer.page","direction":"previous"}"#).refusal == .notShown)
        #expect(try await harness.send(#"{"type":"viewer.pick"}"#).refusal == .notShown)
        #expect(try await harness.send(#"{"type":"viewer.keepReviewing"}"#).isAccepted)
        #expect(harness.value("nav.viewerEndOfSet") == .value(.bool(false)))
        #expect(try await harness.send(#"{"type":"viewer.keepReviewing"}"#).refusal == .notShown)

        // Next on the last photo opens it again; Save to Photos from the card exports.
        #expect(try await harness.send(#"{"type":"viewer.page","direction":"next"}"#).isAccepted)
        #expect(harness.value("nav.viewerEndOfSet") == .value(.bool(true)))
        #expect(try await harness.send(#"{"type":"nav.openExport"}"#).isAccepted)
        #expect(harness.value("nav.sheet") == .value(.null))
        #expect(harness.value("nav.screen") == .value(.string("export")))
        let exported = await harness.wait([("active.export.phase", .eq, .string("done")), ("idle", .eq, .bool(true))])
        #expect((try? exported.get()) != nil, "\(exported)")
    }

}

@MainActor
@Suite("Control plane: modals + screen-state launch flags (#299)")
struct ControlModalTests {

    // MARK: - ui.present / ui.confirm / ui.dismiss

    @Test("New album sheet: present, it covers the screen, Create from it, or dismiss")
    func newAlbumSheet() async throws {
        let harness = ControlHarness(.oneAlbum)
        await harness.runtime.bootstrap()
        #expect(try await harness.send(#"{"type":"ui.present","modal":"newAlbum"}"#).isAccepted)
        #expect(harness.value("nav.sheet") == .value(.string("newAlbum")))
        #expect(try await harness.send(#"{"type":"ui.present","modal":"newAlbum"}"#).isNoop)
        // Nothing behind a sheet is reachable.
        #expect(try await harness.send(#"{"type":"nav.openAlbum","album":"album-1"}"#).refusal == .notShown)
        #expect(try await harness.send(#"{"type":"nav.openAppSettings"}"#).refusal == .notShown)
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

    @Test("Delete / Reset confirmations from the album list; ui.confirm runs the same AlbumActions path")
    func listConfirmations() async throws {
        let harness = ControlHarness(.fourStatuses)
        await harness.runtime.bootstrap()
        // A confirmation needs its album, and only the confirmations take one.
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(ControlAction.self,
                                     from: Data(#"{"type":"ui.present","modal":"confirmDelete"}"#.utf8))
        }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(ControlAction.self,
                                     from: Data(#"{"type":"ui.present","modal":"newAlbum","album":"album-1"}"#.utf8))
        }

        #expect(try await harness.send(#"{"type":"ui.present","modal":"confirmReset","album":"album-3"}"#).isAccepted)
        #expect(harness.value("nav.sheet") == .value(.string("confirmReset")))
        #expect(harness.value("nav.sheetAlbum") == .value(.string("album-3")))
        let origin = { () -> AlbumConfirmation.Origin? in
            if case .confirm(let confirmation)? = harness.coordinator.modal { return confirmation.origin }
            return nil
        }
        #expect(origin() == .albumList)
        #expect(try await harness.send(#"{"type":"ui.confirm"}"#).isAccepted)
        #expect(harness.value("nav.sheet") == .value(.null))
        #expect(harness.value("albums.album-3.picked") == .value(.int(0)))

        try await harness.send(#"{"type":"ui.present","modal":"confirmDelete","album":"album-4"}"#)
        #expect(try await harness.send(#"{"type":"ui.dismiss"}"#).isAccepted)   // Cancel: nothing deleted
        #expect(harness.value("albums.album-4") != .missing)
        try await harness.send(#"{"type":"ui.present","modal":"confirmDelete","album":"album-4"}"#)
        #expect(try await harness.send(#"{"type":"ui.confirm"}"#).isAccepted)
        #expect(harness.value("albums.album-4") == .missing)

        // Mark all unreviewed is on the album's settings only.
        #expect(try await harness.send(#"{"type":"ui.present","modal":"confirmUnreview","album":"album-1"}"#)
                    .refusal == .notShown)
    }

    @Test("confirmations from album settings (iPad: the settings' dialog, not the sidebar's) + What's New")
    func settingsConfirmations() async throws {
        let harness = ControlHarness(.midReview, iPad: true)
        await harness.runtime.bootstrap()
        try await harness.send(#"{"type":"nav.openAlbum","album":"album-1"}"#)
        await harness.settled()
        try await harness.send(#"{"type":"nav.openSettings","album":"album-1"}"#)
        #expect(harness.value("active.done.days") != .value(.int(0)))

        #expect(try await harness.send(#"{"type":"ui.present","modal":"confirmUnreview","album":"album-1"}"#)
                    .isAccepted)
        guard case .confirm(let confirmation)? = harness.coordinator.modal else {
            Issue.record("no confirmation up")
            return
        }
        #expect(confirmation.origin == .albumSettings)
        #expect(confirmation.kind == .markAllUnreviewed)
        // The sidebar is behind the dialog too.
        #expect(try await harness.send(#"{"type":"albums.duplicate","album":"album-1"}"#).refusal == .notShown)
        #expect(try await harness.send(#"{"type":"ui.confirm"}"#).isAccepted)
        #expect(harness.value("active.done.days") == .value(.int(0)))
        #expect(harness.value("active.selection.count") != .value(.int(0)))   // picks kept
        // The button is disabled with nothing marked done.
        #expect(try await harness.send(#"{"type":"ui.present","modal":"confirmUnreview","album":"album-1"}"#)
                    .refusal == .invalidState)

        try await harness.send(#"{"type":"ui.present","modal":"confirmDelete","album":"album-1"}"#)
        #expect(try await harness.send(#"{"type":"ui.confirm"}"#).isAccepted)
        #expect(harness.value("nav.screen") == .value(.string("albums")))
        #expect(harness.value("albums.album-1") == .missing)

        // What's New is on app settings.
        #expect(try await harness.send(#"{"type":"ui.present","modal":"whatsNew"}"#).refusal == .notShown)
        try await harness.send(#"{"type":"nav.openAppSettings"}"#)
        #expect(try await harness.send(#"{"type":"ui.present","modal":"whatsNew"}"#).isAccepted)
        #expect(harness.value("nav.sheet") == .value(.string("whatsNew")))
        #expect(harness.value("nav.sheetAlbum") == .value(.null))
        #expect(try await harness.send(#"{"type":"nav.back"}"#).refusal == .notShown)
        #expect(try await harness.send(#"{"type":"ui.dismiss"}"#).isAccepted)
        #expect(try await harness.send(#"{"type":"nav.back"}"#).isAccepted)
    }

    // MARK: - Launch flags

    @Test("-PoimiFilter / -PoimiModal: parsed strictly, applied after the route as the actions")
    func launchFlags() async throws {
        let base = ["-PoimiControl", "-PoimiFixture", "mid-review"]
        let filter = ControlLaunch.parse(base + ["-PoimiRoute", "overview:album-1", "-PoimiFilter", "toReview"])
        #expect(filter.launch?.filter == .toReview)
        for bad in [["-PoimiFilter", "toReview"],                                   // no overview route
                    ["-PoimiRoute", "overview:album-1", "-PoimiFilter", "later"],   // unknown lens
                    ["-PoimiModal", "confirmDelete"],                               // needs an album
                    ["-PoimiModal", "newAlbum:album-1"],                            // takes none
                    ["-PoimiModal", "sheet"]] {
            guard case .invalid = ControlLaunch.parse(base + bad) else {
                Issue.record("\(bad) must be refused")
                continue
            }
        }
        guard case .invalid = ControlLaunch.parse(["-PoimiModal", "newAlbum"]) else {
            Issue.record("-PoimiModal alone must be refused")
            return
        }

        let filtered = ControlHarness(.midReview, parsed: filter)
        await filtered.runtime.bootstrap()
        #expect(filtered.value("app.launchError") == .value(.null))
        #expect(filtered.value("active.overview.filter") == .value(.string("toReview")))

        let modal = ControlHarness(.midReview, parsed: ControlLaunch.parse(
            base + ["-PoimiRoute", "settings:album-1", "-PoimiModal", "confirmReset:album-1"]))
        await modal.runtime.bootstrap()
        #expect(modal.value("nav.sheet") == .value(.string("confirmReset")))
        #expect(modal.value("nav.sheetAlbum") == .value(.string("album-1")))

        // A modal the launch's screen doesn't offer is the launch's error, with the action's refusal.
        let refused = ControlHarness(.midReview, parsed: ControlLaunch.parse(
            base + ["-PoimiRoute", "overview:album-1", "-PoimiModal", "whatsNew"]))
        await refused.runtime.bootstrap()
        guard case .value(.string(let error)) = refused.value("app.launchError") else {
            Issue.record("expected a launch error")
            return
        }
        #expect(error.contains("-PoimiModal") && error.contains("notShown"))
    }
}
