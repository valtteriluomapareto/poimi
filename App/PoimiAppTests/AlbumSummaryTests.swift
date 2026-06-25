//
//  AlbumSummaryTests.swift
//  PoimiAppTests — the album-row display mapping (#32, D31).
//
//  The store behaviors the issue lists (status derivation, reorder-on-open, delete leaves the
//  Photos album untouched) are covered in ProjectStoreTests; this pins the row's pure display copy.
//

import Testing
import Curation
@testable import PoimiApp

@Suite("AlbumSummary (#32)")
struct AlbumSummaryTests {

    @Test("status text maps from ProjectStatus")
    func statusText() {
        #expect(AlbumSummary(status: .empty, picked: 0, target: 100).statusText == "Not started")
        #expect(AlbumSummary(status: .inProgress, picked: 47, target: 100).statusText == "In progress")
        #expect(AlbumSummary(status: .done, picked: 187, target: 200).statusText == "Done")
    }

    @Test("progress text is picked / target")
    func progressText() {
        #expect(AlbumSummary(status: .inProgress, picked: 47, target: 100).progressText == "47 / 100")
        #expect(AlbumSummary(status: .empty, picked: 0, target: 0).progressText == "0 / 0")
        #expect(AlbumSummary(status: .done, picked: 200, target: 200).progressText == "200 / 200")
    }
}
