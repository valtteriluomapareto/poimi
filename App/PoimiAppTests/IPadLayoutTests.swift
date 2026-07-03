//
//  IPadLayoutTests.swift
//  PoimiAppTests — the logic behind the iPad split-view (#42): the sidebar's active-album derivation
//  and the review grid's width→columns density. The layout/reflow itself is human-verified (per #42);
//  these pin the coordinator + grid math that drive it.
//

import Testing
import Foundation
import Curation
@testable import PoimiApp

@MainActor
@Suite("iPad split-view — active album (#42)")
struct ActiveAlbumTests {

    private func coordinator() -> AppCoordinator {
        AppCoordinator(library: FakePhotoLibrary(status: .authorized))
    }

    @Test("activeAlbumID tracks the album at the path root across route depths, nil at the albums root")
    func activeAlbum() {
        let coord = coordinator()
        #expect(coord.activeAlbumID == nil)          // albums root — nothing selected

        let a = UUID(), b = UUID()
        coord.openProject(a)
        #expect(coord.activeAlbumID == a)            // .albumOverview(a)
        coord.openReview(a)
        #expect(coord.activeAlbumID == a)            // deeper (.review) — still album a
        coord.openSettings(a)
        #expect(coord.activeAlbumID == a)            // deeper still (.settings) — still a

        coord.openProject(b)                         // switch albums resets the path to b's overview
        #expect(coord.activeAlbumID == b)

        coord.popToRoot()
        #expect(coord.activeAlbumID == nil)          // back at the library — selection clears
    }
}

@Suite("Review grid columns (#42)")
struct ReviewGridColumnsTests {

    @Test("column count fills the width at ~132pt cells, clamped to the size-class range")
    func ideal() {
        // iPhone-ish detail width → ~3; iPad detail column → ~6.
        #expect(ReviewGridColumns.ideal(forWidth: 390, minColumns: 2, maxColumns: 5) == 3)
        #expect(ReviewGridColumns.ideal(forWidth: 854, minColumns: 2, maxColumns: 8) == 6)
        // Clamps: a narrow Slide-Over pane floors at minColumns; an ultra-wide pane caps at maxColumns.
        #expect(ReviewGridColumns.ideal(forWidth: 100, minColumns: 2, maxColumns: 8) == 2)
        #expect(ReviewGridColumns.ideal(forWidth: 5000, minColumns: 2, maxColumns: 8) == 8)
        // A zero/uninitialised width degrades to minColumns, never 0.
        #expect(ReviewGridColumns.ideal(forWidth: 0, minColumns: 2, maxColumns: 8) == 2)
    }
}
