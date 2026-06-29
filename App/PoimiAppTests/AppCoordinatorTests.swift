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

    @Test("review / photo / export push onto the path in order")
    func pushDestinations() {
        let coord = coordinator(.authorized)
        let id = UUID()
        coord.openProject(id)
        coord.openReview(id, day: .undated)
        coord.openPhoto("asset/1")
        coord.openExport(id)
        #expect(coord.path == [.albumOverview(id), .review(id, .undated), .photo("asset/1"), .export(id)])
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
        #expect(Route.review(id, nil) != Route.photo("x"))               // cross-case
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

    @Test("openPhoto records lastViewedID and pushes the photo route (viewer + scroll anchor, #36)")
    func openPhotoRecordsLastViewed() {
        let coord = coordinator(.authorized)
        let id = UUID()
        coord.openProject(id)
        coord.openReview(id)
        coord.openPhoto("asset/42")
        // lastViewedID is the grid's scroll-restore anchor (D22) + the `.zoom` source; set on open.
        #expect(coord.lastViewedID == "asset/42")
        #expect(coord.path.last == .photo("asset/42"))
    }

    @Test("the review candidate list is shared so the viewer can page through it (#36)")
    func reviewCandidateListShared() {
        let coord = coordinator(.authorized)
        #expect(coord.reviewOrderedIDs.isEmpty)
        coord.reviewOrderedIDs = ["a", "b", "c"]   // published by the review screen on .ready
        #expect(coord.reviewOrderedIDs == ["a", "b", "c"])
    }
}
