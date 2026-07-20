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

    @Test("an in-progress project derives In progress + picked/target")
    func fromProjectInProgress() throws {
        let project = CurationProject(
            title: "x", rangeStart: Date(timeIntervalSince1970: 0), rangeEnd: Date(timeIntervalSince1970: 1),
            targetCount: 150, selectionSnapshot: try SelectionSnapshot(assetIDs: ["a", "b", "c"]).encoded(),
            createdAt: Date(timeIntervalSince1970: 0), lastOpenedAt: Date(timeIntervalSince1970: 0))
        #expect(project.status == .inProgress)   // has picks, not finalized
        let summary = AlbumSummary(status: project.status, picked: project.persistedPickedCount,
                                   target: 150, exportedCount: project.exportedPhotoCountForDisplay)
        #expect(summary.statusText == "In progress")
        #expect(summary.progressText == "3 / 150")
    }

    @Test("the exported in-Photos count is the honest album membership, with a pre-#191 fallback (#191)")
    func exportedInPhotosCount() throws {
        // Exported: picks {a,b,c}, but only 198 landed (2 didn't resolve) → exportedPhotoCount reads 198,
        // NOT the pick count — the row can't overstate what's in Photos.
        let project = CurationProject(
            title: "x", rangeStart: Date(timeIntervalSince1970: 0), rangeEnd: Date(timeIntervalSince1970: 1),
            targetCount: 200, selectionSnapshot: try SelectionSnapshot(assetIDs: ["a", "b", "c"]).encoded(),
            markedDoneAt: Date(timeIntervalSince1970: 1),
            exportedSelectionSnapshot: try SelectionSnapshot(assetIDs: ["a", "b", "c"]).encoded(),
            exportedPhotoCount: 198,
            createdAt: Date(timeIntervalSince1970: 0), lastOpenedAt: Date(timeIntervalSince1970: 0))
        #expect(project.status == .exported)
        #expect(project.exportedPhotoCountForDisplay == 198)
        let summary = AlbumSummary(status: project.status, picked: project.persistedPickedCount,
                                   target: 200, exportedCount: project.exportedPhotoCountForDisplay)
        #expect(summary.statusText == "Exported")
        #expect(summary.progressText == "198 in Photos")

        // A pre-#191 export (no recorded count) falls back to the current pick count.
        project.exportedPhotoCount = nil
        #expect(project.exportedPhotoCountForDisplay == 3)
    }
}
