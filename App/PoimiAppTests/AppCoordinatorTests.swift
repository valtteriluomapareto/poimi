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

    @Test("restore reopens the last-opened album; nil lands on the library root")
    func restore() {
        let coord = coordinator(.authorized)
        let id = UUID()
        coord.openReview(id)              // some prior deeper state
        coord.restore(lastOpenedProjectID: id)
        #expect(coord.path == [.albumOverview(id)])
        coord.restore(lastOpenedProjectID: nil)
        #expect(coord.path.isEmpty)
    }
}
