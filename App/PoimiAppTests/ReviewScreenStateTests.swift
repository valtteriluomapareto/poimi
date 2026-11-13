//
//  ReviewScreenStateTests.swift
//  PoimiAppTests — the screen state lifted out of the views (#299, control plane slice D), tested on the
//  stores with NO view and no control plane: the Overview's filter and the grid's current cluster on the
//  album session, the viewer's page / end-of-set card / auto-mark-done on `ViewerStore`, and the
//  coordinator's modal with `AlbumActions.confirm`. Through the real `AppGraph` wiring (`SessionHarness`);
//  every async step awaits the real work — never a fixed sleep.
//

import Testing
import Foundation
import Curation
@testable import PoimiApp

/// Four busy days (12 photos each — over the busy-day threshold, well apart) → four single-day clusters, oldest first.
private let fourDays: [DayKey] = [
    .day(year: 2025, month: 2, day: 1), .day(year: 2025, month: 4, day: 10),
    .day(year: 2025, month: 6, day: 20), .day(year: 2025, month: 9, day: 5)
]

private func fourDaySeed() -> [AssetRef] {
    let calendar = utcCalendar()
    return fourDays.enumerated().flatMap { index, day -> [AssetRef] in
        guard case .day(let year, let month, let dayOfMonth) = day else { return [] }
        return (0..<12).map { photo in
            AssetRef(id: "d\(index)/\(photo)",
                     captureDate: calendar.date(from: DateComponents(year: year, month: month,
                                                                     day: dayOfMonth, hour: 8 + photo)))
        }
    }
}

@MainActor
private struct GridHarness {
    let base: SessionHarness
    let project: CurationProject

    init() throws {
        base = try SessionHarness(assets: fourDaySeed())
        project = base.album()
    }

    var session: AlbumSession { base.session }
    var done: DoneStore { base.done }
    var coordinator: AppCoordinator { base.coordinator }
    var viewer: ViewerStore { base.graph.viewer }
    var clusters: [ReviewCluster] { session.reviewClusters }

    /// The cluster id holding `day`.
    func id(_ day: DayKey) -> String? { clusters.first { $0.days.contains(day) }?.id }

    /// Open the album as the album list does, then the grid on `day` — the coordinator's path and the
    /// grid screen's own task (`AlbumSession.appear(.review(day))`), as `ScanningView` runs it.
    func openGrid(day: DayKey? = nil) async {
        base.actions.open(project)
        await session.appear(.overview, project)
        coordinator.openReview(project.id, day: day)
        await session.appear(.review(day), project)
    }
}

@MainActor
@Suite("Review screen state on the stores (#299)")
struct ReviewScreenStateTests {

    // MARK: - The grid's current cluster

    @Test("the grid enters on the drill day's cluster, once per visit; leaving resets it")
    func gridEntryOncePerVisit() async throws {
        let harness = try GridHarness()
        await harness.openGrid(day: fourDays[2])
        #expect(harness.clusters.count == 4)
        #expect(harness.session.reviewClusterID == harness.id(fourDays[2]))

        // The screen re-appearing (or the control host re-running its task) doesn't move the page.
        harness.session.goTo(day: fourDays[1])
        await harness.session.appear(.review(fourDays[2]), harness.project)
        #expect(harness.session.reviewClusterID == harness.id(fourDays[1]))

        // Back to the Overview: the grid left the path, so its next visit enters afresh.
        harness.coordinator.pop()
        #expect(harness.session.reviewClusterID == nil)
        harness.coordinator.openReview(harness.project.id)
        await harness.session.appear(.review(nil), harness.project)
        #expect(harness.session.reviewClusterID == harness.id(fourDays[0]))   // the first unreviewed
    }

    @Test("with no drill day the grid resumes on the first unreviewed cluster")
    func gridEntryResumes() async throws {
        let harness = try GridHarness()
        harness.base.actions.open(harness.project)
        await harness.session.appear(.overview, harness.project)
        harness.done.toggle(harness.clusters[0])
        harness.done.toggle(harness.clusters[1])
        harness.coordinator.openReview(harness.project.id)
        await harness.session.appear(.review(nil), harness.project)
        #expect(harness.session.reviewClusterID == harness.clusters[2].id)
    }

    @Test("Mark day done advances to the next UNREVIEWED cluster; un-marking stays put")
    func markDoneAndAdvance() async throws {
        let harness = try GridHarness()
        await harness.openGrid()
        let clusters = harness.clusters
        harness.done.toggle(clusters[2])   // already reviewed: the advance skips it

        #expect(harness.session.markDoneAndAdvance(clusters[0]) == false)
        #expect(harness.done.isDone(clusters[0]))
        #expect(harness.session.reviewClusterID == clusters[1].id)

        harness.session.markDoneAndAdvance(clusters[1])
        #expect(harness.session.reviewClusterID == clusters[3].id)   // skipped the done cluster 2

        // On the last page with everything done: stay.
        harness.session.markDoneAndAdvance(clusters[3])
        #expect(harness.session.reviewClusterID == clusters[3].id)

        // The end-cap on a done cluster reopens it and stays.
        #expect(harness.session.markDoneAndAdvance(clusters[3]) == true)
        #expect(!harness.done.isDone(clusters[3]))
        #expect(harness.session.reviewClusterID == clusters[3].id)
    }

    @Test("a swipe / goTo moves the page; an unknown id or day is ignored")
    func showAndGoTo() async throws {
        let harness = try GridHarness()
        await harness.openGrid()
        harness.session.showCluster(harness.clusters[3].id)
        #expect(harness.session.reviewClusterID == harness.clusters[3].id)
        harness.session.showCluster("no-such-cluster")
        #expect(harness.session.reviewClusterID == harness.clusters[3].id)
        #expect(!harness.session.goTo(day: .day(year: 2025, month: 12, day: 24)))
        #expect(harness.session.goTo(day: fourDays[1]))
        #expect(harness.session.currentReviewCluster == harness.clusters[1])
    }

    @Test("dismissing the viewer moves the grid to the cluster of the photo it ended on (#126)")
    func viewerReturnFollows() async throws {
        let harness = try GridHarness()
        await harness.openGrid()
        harness.coordinator.openPhoto("d0/7")
        harness.viewer.show("d2/3")   // paged / jumped elsewhere in the viewer
        #expect(harness.session.reviewClusterID == harness.clusters[0].id)   // only on dismiss
        harness.coordinator.dismissPhoto()
        #expect(harness.session.reviewClusterID == harness.clusters[2].id)
    }

    @Test("a new scan under an open grid re-enters it; with the viewer up, its dismissal restores the page")
    func reentryUnderOpenGrid() async throws {
        let harness = try GridHarness()
        await harness.openGrid()
        harness.session.goTo(day: fourDays[3])
        await harness.session.rescanReview(harness.project)   // the grid's "Try again" / access recovered
        #expect(harness.session.reviewClusterID == harness.clusters[0].id)   // the entry cluster again

        // The viewer is up while the scan lands: the page moves under the sheet, then follows the photo.
        harness.coordinator.openPhoto("d2/3")
        harness.session.goTo(day: fourDays[2])
        await harness.session.rescanReview(harness.project)
        #expect(harness.session.reviewClusterID == harness.clusters[0].id)
        #expect(harness.viewer.currentID == "d2/3")
        harness.coordinator.dismissPhoto()
        #expect(harness.session.reviewClusterID == harness.clusters[2].id)
    }

    // MARK: - The Overview's filter

    @Test("the Overview filter lasts while the album is open and starts at .all on the next open")
    func overviewFilterLifetime() async throws {
        let harness = try GridHarness()
        harness.base.actions.open(harness.project)
        await harness.session.appear(.overview, harness.project)
        #expect(harness.session.overviewFilter == .all)
        harness.session.setOverviewFilter(.toReview)
        harness.coordinator.openReview(harness.project.id)
        harness.coordinator.pop()
        #expect(harness.session.overviewFilter == .toReview)   // the Overview stayed mounted under the grid
        harness.coordinator.popToRoot()
        #expect(harness.session.overviewFilter == .all)
        harness.base.actions.open(harness.project)
        #expect(harness.session.overviewFilter == .all)
    }

    // MARK: - The viewer

    /// Regression (#299 review): the dismissal cleared the viewer's state while the sheet was still sliding
    /// down, so it snapped to its start photo as a black "1 of 1" card and the card / toast blanked mid-slide.
    @Test("a dismissal leaves the viewer as it was (the sheet slides down showing it); the next opening starts over")
    func viewerSurvivesDismissal() async throws {
        let harness = try GridHarness()
        await harness.openGrid()
        harness.coordinator.openPhoto("d2/11")
        harness.viewer.step(1)                    // across d2's end → d3/0, toast up
        harness.viewer.show("d3/11")
        harness.viewer.step(1)                    // past the last photo → the card
        let pages = harness.viewer.filmstripPages
        #expect(harness.viewer.endReached)
        harness.coordinator.dismissPhoto()
        #expect(harness.viewer.currentID == "d3/11")
        #expect(harness.viewer.orderedIDs.count == 48)
        #expect(harness.viewer.filmstripPages == pages)
        #expect(harness.viewer.endReached)
        #expect(harness.viewer.autoDoneCluster == harness.clusters[2])

        harness.coordinator.openPhoto("d1/2")
        #expect(harness.viewer.currentID == "d1/2")
        #expect(!harness.viewer.endReached)
        #expect(harness.viewer.autoDoneCluster == nil)
        #expect(harness.coordinator.lastViewedID == "d1/2")
    }

    @Test("stepping forward past a cluster's last photo marks it done once; back and a jump never do (#128)")
    func viewerAutoMarkDone() async throws {
        let harness = try GridHarness()
        await harness.openGrid()
        let clusters = harness.clusters
        harness.coordinator.openPhoto("d0/10")
        harness.viewer.step(1)
        #expect(!harness.done.isDone(clusters[0]))      // still inside the cluster
        harness.viewer.step(1)                          // d0/11 → d1/0: crossed the end
        #expect(harness.viewer.currentID == "d1/0")
        #expect(harness.done.isDone(clusters[0]))
        #expect(harness.viewer.autoDoneCluster == clusters[0])
        #expect(harness.viewer.autoDoneCount == 1)
        #expect(harness.coordinator.lastViewedID == "d1/0")

        harness.viewer.step(-1)                         // back never un-marks
        #expect(harness.done.isDone(clusters[0]))
        harness.viewer.step(1)                          // across again: already done → no re-toggle
        #expect(harness.done.isDone(clusters[0]))
        #expect(harness.viewer.autoDoneCount == 1)

        harness.viewer.show("d1/11")
        harness.viewer.show("d2/0")                     // a filmstrip jump across an end: never marks
        #expect(!harness.done.isDone(clusters[1]))

        harness.viewer.undoAutoDone()                   // the toast's Undo
        #expect(!harness.done.isDone(clusters[0]))
        #expect(harness.viewer.autoDoneCluster == nil)
    }

    @Test("a real swipe across an end marks it done, as the chevron does")
    func viewerSwipe() async throws {
        let harness = try GridHarness()
        await harness.openGrid()
        harness.coordinator.openPhoto("d1/11")
        harness.viewer.show("d2/0")                     // the pager publishes the settled page…
        harness.viewer.swiped(from: "d1/11", to: "d2/0") // …then reports the swipe
        #expect(harness.done.isDone(harness.clusters[1]))
    }

    @Test("Pick toggles + advances; on the last photo it opens the end-of-set card; Keep reviewing closes it")
    func viewerPick() async throws {
        let harness = try GridHarness()
        await harness.openGrid()
        harness.coordinator.openPhoto("d3/10")
        #expect(harness.viewer.pick())                  // picked → advanced
        #expect(harness.base.selection.contains("d3/10"))
        #expect(harness.viewer.currentID == "d3/11")
        #expect(!harness.viewer.pick())                 // the last photo: picked, no advance → the card
        #expect(harness.viewer.endReached)
        harness.viewer.keepReviewing()
        #expect(!harness.viewer.endReached)
        #expect(!harness.viewer.pick())                 // un-pick stays
        #expect(!harness.base.selection.contains("d3/11"))
        #expect(harness.viewer.currentID == "d3/11")
        #expect(!harness.viewer.endReached)
    }

    @Test("the filmstrip's window: ±25 around the opened photo, sliding once the photo nears its edge")
    func filmstripWindow() async throws {
        let harness = try GridHarness()
        await harness.openGrid()
        harness.coordinator.openPhoto("d0/0")
        #expect(harness.viewer.filmstripPages.first == "d0/0")
        #expect(harness.viewer.filmstripPages.last == "d2/1")    // index 25
        #expect(!harness.viewer.hasPrevious)
        harness.viewer.show("d1/8")                               // index 20: 5 from the edge — stays
        #expect(harness.viewer.filmstripPages.last == "d2/1")
        harness.viewer.show("d1/9")                               // index 21: inside the margin — slides
        #expect(harness.viewer.filmstripPages.first == "d0/0")
        #expect(harness.viewer.filmstripPages.last == "d3/10")   // index 46 = 21 + 25
    }

}

@MainActor
@Suite("Modals + confirmations on the coordinator / AlbumActions (#299)")
struct ModalStateTests {

    @Test("a modal is dismissed only by its own dismissal; opening an album clears it")
    func modalLifecycle() throws {
        let harness = try GridHarness()
        let coordinator = harness.coordinator
        coordinator.present(.newAlbum)
        coordinator.dismiss(.whatsNew)   // a late dismissal of another modal is ignored
        #expect(coordinator.modal == .newAlbum)
        coordinator.dismiss(.newAlbum)
        #expect(coordinator.modal == nil)
        coordinator.present(.newAlbum)
        harness.base.actions.open(harness.project)   // New album → Create opens the new album
        #expect(coordinator.modal == nil)
    }

    @Test("a confirm runs through AlbumActions and dismisses its dialog: delete, reset, mark all unreviewed")
    func confirmations() async throws {
        let harness = try GridHarness()
        await harness.openGrid()
        let actions = harness.base.actions
        let project = harness.project
        harness.base.selection.toggle("d0/0")
        harness.done.toggle(harness.clusters[0])

        let unreview = AlbumConfirmation(kind: .markAllUnreviewed, album: project.id, origin: .albumSettings)
        harness.coordinator.present(.confirm(unreview))
        #expect(actions.confirm(unreview))
        #expect(harness.coordinator.modal == nil)
        #expect(harness.done.doneDays.isEmpty)
        #expect(harness.base.selection.contains("d0/0"))   // picks kept

        let reset = AlbumConfirmation(kind: .reset, album: project.id, origin: .albumList)
        harness.coordinator.present(.confirm(reset))
        #expect(actions.confirm(reset))
        #expect(harness.base.selection.selected.isEmpty)

        let delete = AlbumConfirmation(kind: .delete, album: project.id, origin: .albumSettings)
        harness.coordinator.present(.confirm(delete))
        #expect(actions.confirm(delete))
        #expect(harness.coordinator.modal == nil)
        #expect(harness.coordinator.path.isEmpty)
        #expect(!harness.base.graph.projectStore.projects.contains { $0.id == project.id })
        #expect(!actions.confirm(delete))   // the album is gone: nothing runs
    }

    @Test("a refused confirm changes nothing: the dialog stays up while the album exports")
    func refusedConfirmLeavesDialog() async throws {
        let harness = try GridHarness()
        await harness.openGrid()
        let project = harness.project
        harness.base.selection.toggle("d0/0")
        await harness.base.gate.hold(exports: true)
        let export = Task { await harness.session.startExport(project) }
        await harness.base.gate.waitUntilHeld()

        for kind in [AlbumConfirmation.Kind.delete, .reset] {
            let confirmation = AlbumConfirmation(kind: kind, album: project.id, origin: .albumList)
            harness.coordinator.present(.confirm(confirmation))
            #expect(!harness.base.actions.confirm(confirmation))
            #expect(harness.coordinator.modal == .confirm(confirmation))
            harness.coordinator.dismiss(.confirm(confirmation))
        }
        #expect(harness.base.graph.projectStore.projects.contains { $0.id == project.id })
        #expect(harness.base.selection.contains("d0/0"))
        await harness.base.gate.release()
        await export.value
    }

    @Test("deleting an album dismisses a confirmation still naming it")
    func deleteClearsStaleConfirmation() async throws {
        let harness = try GridHarness()
        let other = harness.base.album("Other")
        let listReset = AlbumConfirmation(kind: .reset, album: other.id, origin: .albumList)
        harness.coordinator.present(.confirm(listReset))
        #expect(harness.base.actions.delete(other))
        #expect(harness.coordinator.modal == nil)
        // One naming a different album stays.
        let mine = AlbumConfirmation(kind: .reset, album: harness.project.id, origin: .albumList)
        harness.coordinator.present(.confirm(mine))
        #expect(harness.base.actions.delete(harness.base.album("Third")))
        #expect(harness.coordinator.modal == .confirm(mine))
    }
}
