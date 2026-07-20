//
//  AlbumSummaryTests.swift
//  PoimiAppTests — the album-row display mapping (#32, D31).
//
//  The store behaviors the issue lists (status derivation, reorder-on-open, delete leaves the
//  Photos album untouched) are covered in ProjectStoreTests; this pins the row's pure display copy.
//

import Testing
import Foundation
import Curation
@testable import PoimiApp

@Suite("AlbumSummary (#32)")
struct AlbumSummaryTests {

    @Test("status text maps from ProjectStatus, including the #191 exported / edited states")
    func statusText() {
        #expect(AlbumSummary(status: .empty, picked: 0, target: 100, exportedCount: 0).statusText == "Not started")
        #expect(AlbumSummary(status: .inProgress, picked: 47, target: 100, exportedCount: 0).statusText == "In progress")
        // Past-tense "Exported", never "Done" (#191).
        #expect(AlbumSummary(status: .exported, picked: 187, target: 200, exportedCount: 187).statusText == "Exported")
        #expect(AlbumSummary(status: .editedSinceExport(toAdd: 3), picked: 190, target: 200, exportedCount: 187)
            .statusText == "Edited since export")
    }

    @Test("progress text is state-dependent: picked/target, in-Photos count, or to-add count (#191)")
    func progressText() {
        #expect(AlbumSummary(status: .inProgress, picked: 47, target: 100, exportedCount: 0).progressText == "47 / 100")
        #expect(AlbumSummary(status: .empty, picked: 0, target: 0, exportedCount: 0).progressText == "0 / 0")
        // Large numbers are NOT locale-grouped (deliberate — plain Int interpolation).
        #expect(AlbumSummary(status: .inProgress, picked: 1000, target: 5000, exportedCount: 0)
            .progressText == "1000 / 5000")
        // Exported → "N in Photos" (the exported count); edited → "N to add" (the additions-only delta).
        #expect(AlbumSummary(status: .exported, picked: 200, target: 200, exportedCount: 200)
            .progressText == "200 in Photos")
        #expect(AlbumSummary(status: .editedSinceExport(toAdd: 3), picked: 190, target: 200, exportedCount: 187)
            .progressText == "3 to add")
    }

    @Test("the project convenience init reads status + counts off the project")
    func fromProject() throws {
        let project = CurationProject(
            title: "x", rangeStart: Date(timeIntervalSince1970: 0), rangeEnd: Date(timeIntervalSince1970: 1),
            targetCount: 150, selectionSnapshot: try SelectionSnapshot(assetIDs: ["a", "b", "c"]).encoded(),
            createdAt: Date(timeIntervalSince1970: 0), lastOpenedAt: Date(timeIntervalSince1970: 0))
        let summary = AlbumSummary(project: project)
        #expect(summary.statusText == "In progress")   // has picks, not finalized
        #expect(summary.progressText == "3 / 150")
    }
}
