//
//  AppCoordinatorTests.swift
//  PoimiAppTests — the navigation coordinator (#30, D20).
//

import Testing
import Foundation
import Curation
@testable import PoimiApp

@MainActor
@Suite("AppCoordinator (#30)")
struct AppCoordinatorTests {

    private func coordinator(_ status: LibraryAuthorization) -> AppCoordinator {
        AppCoordinator(library: FakePhotoLibrary(status: status))
    }

    @Test("rootPhase derives from authorization (each permission branch → correct phase)")
    func rootPhaseMapping() async {
        let cases: [(LibraryAuthorization, RootPhase)] = [
            (.authorized, .albums),
            (.notDetermined, .onboarding),
            (.limited, .recovery),
            (.denied, .recovery),
            (.restricted, .recovery)
        ]
        for (status, expected) in cases {
            let coord = coordinator(status)
            await coord.refreshAuthorization()
            #expect(coord.authorization == status)
            #expect(coord.rootPhase == expected, "\(status) should map to \(expected)")
        }
    }

    @Test("before any refresh the phase is onboarding (notDetermined)")
    func initialPhase() {
        #expect(coordinator(.authorized).rootPhase == .onboarding)   // not yet refreshed
    }

    @Test("requestAuthorization adopts the resolved status")
    func requestAuth() async {
        let coord = coordinator(.authorized)
        await coord.requestAuthorization()
        #expect(coord.authorization == .authorized)
        #expect(coord.rootPhase == .albums)
    }

    @Test("openProject roots the path at the album overview")
    func openProject() {
        let coord = coordinator(.authorized)
        let id = UUID()
        coord.openProject(id)
        #expect(coord.path == [.albumOverview(id)])
    }

    @Test("review / export push onto the path in order; the photo viewer is a cover, not a push")
    func pushDestinations() {
        let coord = coordinator(.authorized)
        let id = UUID()
        coord.openProject(id)
        coord.openReview(id, day: .undated)
        coord.openPhoto("asset/1")
        #expect(coord.path == [.albumOverview(id), .review(id, .undated)])   // photo NOT in the path
        #expect(coord.presentedPhotoID == "asset/1")                          // it's a cover
        coord.finishToExport()
        #expect(coord.path == [.albumOverview(id), .review(id, .undated), .export(id)])
    }

    @Test("the Overview's Save to Photos is the guarded entry: a double tap pushes export once (#298)")
    func overviewExportDoubleTapGuarded() {
        let coord = coordinator(.authorized)
        let id = UUID()
        coord.openProject(id)
        coord.finishToExport()   // the Overview's button
        coord.finishToExport()   // a second tap before the push animates
        #expect(coord.path == [.albumOverview(id), .export(id)])
    }

    @Test("opening a project resets a deeper path — switching albums starts fresh")
    func switchingResetsPath() {
        let coord = coordinator(.authorized)
        let a = UUID(), b = UUID()
        coord.openProject(a)
        coord.openReview(a)
        coord.openPhoto("x")
        coord.openProject(b)
        #expect(coord.path == [.albumOverview(b)])
        #expect(coord.presentedPhotoID == nil)   // switching albums dismisses an open viewer
    }

    @Test("pop removes the last route; popToRoot clears; both safe when empty")
    func popping() {
        let coord = coordinator(.authorized)
        let id = UUID()
        coord.openProject(id)
        coord.openReview(id)
        coord.pop()
        #expect(coord.path == [.albumOverview(id)])
        coord.popToRoot()
        #expect(coord.path.isEmpty)
        coord.pop()                       // safe on empty
        #expect(coord.path.isEmpty)
    }

    @Test("restore reopens the last-opened album, replacing any deeper path; nil → library root")
    func restore() {
        let coord = coordinator(.authorized)
        let id = UUID(), other = UUID()
        // A deep path on a *different* album — restore must replace it wholesale, not append.
        coord.openProject(other)
        coord.openReview(other)
        coord.openPhoto("z")
        coord.restore(lastOpenedProjectID: id)
        #expect(coord.path == [.albumOverview(id)])
        #expect(coord.presentedPhotoID == nil)   // restore dismisses an open viewer
        coord.restore(lastOpenedProjectID: nil)
        #expect(coord.path.isEmpty)
    }

    @Test("refreshAuthorization adopts a status change on a live coordinator (notDetermined → authorized)")
    func authorizationTransition() async {
        // The launch/resume lifecycle (D6): onboarding until the user grants at the prompt.
        let library = FakePhotoLibrary(status: .notDetermined)
        let coord = AppCoordinator(library: library)
        await coord.refreshAuthorization()
        #expect(coord.rootPhase == .onboarding)

        await library.setAuthorization(.authorized)   // user grants full access
        await coord.refreshAuthorization()
        #expect(coord.rootPhase == .albums)
    }

    @Test("Route equality distinguishes the cases NavigationStack dedups on")
    func routeEquality() {
        let id = UUID(), other = UUID()
        // Scrolled-to-a-day vs unscrolled must be distinct, or pushing one over the other no-ops.
        #expect(Route.review(id, .undated) != Route.review(id, nil))
        #expect(Route.albumOverview(id) != Route.albumOverview(other))   // different albums
        #expect(Route.review(id, nil) != Route.export(id))               // cross-case
        #expect(Route.albumOverview(id) == Route.albumOverview(id))      // same → equal
        #expect(Route.albumOverview(id).hashValue == Route.albumOverview(id).hashValue)
    }

    @Test("openReview carries a real day-group key as the scroll target")
    func openReviewWithDay() {
        let coord = coordinator(.authorized)
        let id = UUID()
        let day = DayKey.day(year: 2025, month: 7, day: 5)
        coord.openProject(id)
        coord.openReview(id, day: day)
        #expect(coord.path.last == .review(id, day))
    }

    @Test("openPhoto records lastViewedID + presents the viewer as a sheet, not a path push (#36)")
    func openPhotoRecordsLastViewed() {
        let coord = coordinator(.authorized)
        let id = UUID()
        coord.openProject(id)
        coord.openReview(id)
        coord.openPhoto("asset/42")
        #expect(coord.lastViewedID == "asset/42")        // the grid's scroll-restore anchor (D22)
        #expect(coord.presentedPhotoID == "asset/42")    // the viewer is a sheet …
        #expect(coord.path.last == .review(id, nil))     // … not pushed onto the path
    }

    @Test("dismissPhoto closes the viewer sheet but leaves the grid's path untouched (#36)")
    func dismissPhotoKeepsPath() {
        let coord = coordinator(.authorized)
        let id = UUID()
        coord.openProject(id)
        coord.openReview(id)
        coord.openPhoto("asset/7")
        coord.dismissPhoto()
        #expect(coord.presentedPhotoID == nil)                          // viewer closed …
        #expect(coord.path == [.albumOverview(id), .review(id, nil)])   // … grid stays exactly where it was
    }

    @Test("finishToExport dismisses the viewer sheet AND pushes export in one transition (#187)")
    func finishToExportFromViewer() {
        let coord = coordinator(.authorized)
        let id = UUID()
        coord.openProject(id)
        coord.openReview(id)
        coord.openPhoto("asset/7")     // the end-of-set card fires from the viewer sheet, over the grid
        coord.finishToExport()
        #expect(coord.presentedPhotoID == nil)     // sheet dropped BEFORE the push (no viewer left over export)
        #expect(coord.path.last == .export(id))    // export pushed for the active album, in one call
        #expect(coord.path == [.albumOverview(id), .review(id, nil), .export(id)])
    }

    @Test("finishToExport from the fully-reviewed grid (no viewer open) still pushes export (#187)")
    func finishToExportFromGrid() {
        let coord = coordinator(.authorized)
        let id = UUID()
        coord.openProject(id)
        coord.openReview(id)
        coord.finishToExport()
        #expect(coord.presentedPhotoID == nil)
        #expect(coord.path.last == .export(id))
    }

    @Test("finishToExport is re-entrancy-guarded — a double-tap can't push export twice (#187)")
    func finishToExportDoubleTapGuarded() {
        // The guard `path.last != .export(id)` exists for exactly this: a fumbled double-tap of the
        // finish action must push export ONCE, not stack two export routes.
        let coord = coordinator(.authorized)
        let id = UUID()
        coord.openProject(id)
        coord.openReview(id)
        coord.finishToExport()
        coord.finishToExport()   // double-tap
        #expect(coord.path.filter { $0 == .export(id) }.count == 1)
        #expect(coord.path == [.albumOverview(id), .review(id, nil), .export(id)])
    }

    @Test("pop leaves an open viewer alone; popToRoot dismisses it (#36)")
    func popVsPopToRootWithOpenViewer() {
        let coord = coordinator(.authorized)
        let id = UUID()
        coord.openProject(id)
        coord.openReview(id)
        coord.openPhoto("asset/9")
        coord.pop()                                    // a within-albums back …
        #expect(coord.presentedPhotoID == "asset/9")   // … does NOT touch the viewer
        coord.popToRoot()
        #expect(coord.presentedPhotoID == nil)         // back to the library root dismisses it
    }

    @Test("finishToExport is a no-op with no active album (#187)")
    func finishToExportNoActiveAlbum() {
        let coord = coordinator(.authorized)
        coord.finishToExport()
        #expect(coord.path.isEmpty)
        #expect(coord.presentedPhotoID == nil)
    }

    @Test("openAppSettings is idempotent — repeat taps can't stack duplicates (iPad sidebar cog, #258)")
    func openAppSettingsIdempotent() {
        // On iPad the cog stays visible in the split-view sidebar while App settings shows in the
        // detail column, so it can be tapped repeatedly — each tap must NOT push another `.appSettings`.
        let coord = coordinator(.authorized)
        coord.openAppSettings()
        coord.openAppSettings()
        coord.openAppSettings()
        #expect(coord.path == [.appSettings])
        // …and Back (pop) leaves the stack empty, not holding leftover copies.
        coord.pop()
        #expect(coord.path.isEmpty)
    }

    @Test("openAppSettings guards only the top — it still returns to the album underneath on Back (#258)")
    func openAppSettingsKeepsAlbumContext() {
        // The guard is `path.last != .appSettings`, NOT a path reset: opening App settings while an album
        // is showing in the detail column pushes on top, so Back returns to the album (context preserved).
        let coord = coordinator(.authorized)
        let id = UUID()
        coord.openProject(id)
        coord.openReview(id)
        coord.openAppSettings()
        coord.openAppSettings()   // repeat tap from the still-visible sidebar cog
        #expect(coord.path == [.albumOverview(id), .review(id, nil), .appSettings])
        coord.pop()
        #expect(coord.path == [.albumOverview(id), .review(id, nil)])   // back to the album, not a dead end
    }

    @Test("openSettings is idempotent too — a double-tap can't stack per-album settings (#258)")
    func openSettingsIdempotent() {
        let coord = coordinator(.authorized)
        let id = UUID()
        coord.openProject(id)
        coord.openSettings(id)
        coord.openSettings(id)
        #expect(coord.path == [.albumOverview(id), .settings(id)])
    }
}

/// The path as the album session's lifetime (#297): every change — a coordinator method or SwiftUI writing
/// the binding on a back-swipe — reports the album closing and the export screen leaving.
@MainActor
@Suite("AppCoordinator — the path drives the album session (#297)")
struct AppCoordinatorPathTests {

    /// The path is the one choke point (#297): a NavigationStack back-swipe writes it through the binding,
    /// with no coordinator method involved, and must close the album all the same.
    @Test("any path change that leaves the album closes it; pushes within it don't (#297)")
    func pathChangesCloseTheAlbum() {
        let coord = AppCoordinator(library: FakePhotoLibrary())
        let id = UUID()
        var closes = 0
        coord.onCloseAlbum = { closes += 1 }
        coord.openProject(id)                      // re-opening always closes (a fresh scan)
        #expect(closes == 1)
        coord.openReview(id)
        coord.openSettings(id)
        coord.path = [.albumOverview(id)]          // back-swipes within the album
        #expect(closes == 1)
        coord.path = []                            // a back-swipe out of the album
        #expect(closes == 2)
        coord.openProject(id)
        coord.openAppSettings()
        coord.path = [.appSettings]                // the album is no longer at the root
        #expect(closes == 4)
    }

    @Test("the export screen leaving the path is reported once, however it leaves (#297)")
    func leavingExportIsReported() {
        let coord = AppCoordinator(library: FakePhotoLibrary())
        let id = UUID()
        var leaves = 0
        coord.onLeaveExport = { leaves += 1 }
        coord.openProject(id)
        coord.openReview(id)
        coord.finishToExport()
        #expect(leaves == 0)
        coord.pop()                                // back from export
        #expect(leaves == 1)
        coord.finishToExport()
        coord.popToRoot()                          // "Back to albums"
        #expect(leaves == 2)
    }
}
