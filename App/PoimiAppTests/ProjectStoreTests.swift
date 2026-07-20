//
//  ProjectStoreTests.swift
//  PoimiAppTests — the album-library CRUD + status derivation (#29, D31).
//

import Testing
import Foundation
import SwiftData
import Curation
@testable import PoimiApp

@MainActor
@Suite("ProjectStore CRUD (#29)")
struct ProjectStoreTests {

    // A fresh in-memory store with a deterministic, strictly-increasing clock so created /
    // opened ordering is assertable.
    private func makeStore() throws -> ProjectStore {
        let container = try AppModelContainer.make(inMemory: true)
        return ProjectStore(container: container, now: monotonicClock())   // store retains the container
    }

    @discardableResult
    private func makeProject(_ store: ProjectStore, title: String, target: Int = 50) -> CurationProject {
        store.create(title: title, rangeStart: TestDates.year2025Start, rangeEnd: TestDates.year2025End, targetCount: target)
    }

    @Test("create inserts a fresh, empty, unexported project")
    func create() throws {
        let store = try makeStore()
        #expect(store.projects.isEmpty)

        let project = makeProject(store, title: "Best of 2025")
        #expect(store.projects.count == 1)
        #expect(store.projects.first?.id == project.id)
        #expect(project.targetAlbumID == nil)        // unexported until first export (D19)
        #expect(project.status == .empty)
        #expect(project.persistedPickedCount == 0)
    }

    @Test("library is ordered most-recently-opened first; open bumps to the top")
    func openOrder() throws {
        let store = try makeStore()
        let a = makeProject(store, title: "A")
        makeProject(store, title: "B")
        // B was created after A → newer lastOpenedAt → on top.
        #expect(store.projects.map(\.title) == ["B", "A"])

        store.open(a)
        #expect(store.projects.map(\.title) == ["A", "B"])
    }

    @Test("open bumps a middle project to the top, preserving the relative order of the rest")
    func openReordersMiddle() throws {
        let store = try makeStore()
        makeProject(store, title: "A")
        let b = makeProject(store, title: "B")
        makeProject(store, title: "C")
        // Created A, B, C with increasing lastOpenedAt → newest first.
        #expect(store.projects.map(\.title) == ["C", "B", "A"])

        store.open(b)   // middle → top; C and A keep their relative order
        #expect(store.projects.map(\.title) == ["B", "C", "A"])
    }

    @Test("duplicate copies configuration but none of the progress or export link")
    func duplicate() throws {
        let store = try makeStore()
        let original = makeProject(store, title: "A", target: 40)
        original.targetAlbumID = "album/123"
        original.doneDays = ["2025-07-05"]
        original.markedDoneAt = Date(timeIntervalSince1970: 1_750_000_000)
        original.selectionSnapshot = try SelectionSnapshot(assetIDs: ["x", "y"]).encoded()

        let copy = store.duplicate(original)
        #expect(copy.title == "A copy")
        #expect(copy.targetCount == 40)
        #expect(copy.rangeStart == original.rangeStart && copy.rangeEnd == original.rangeEnd)
        // Progress + export are NOT carried over.
        #expect(copy.targetAlbumID == nil)
        #expect(copy.doneDays.isEmpty)
        #expect(copy.markedDoneAt == nil)
        #expect(copy.persistedPickedCount == 0)
        #expect(copy.id != original.id)
    }

    @Test("reset clears progress but keeps configuration (and the export link, D31)")
    func reset() throws {
        let store = try makeStore()
        let project = makeProject(store, title: "A")
        project.targetAlbumID = "album/123"
        project.doneDays = ["2025-07-05", "2025-07-06"]
        project.resumeDayKey = "2025-07-06"
        project.lastViewedAssetID = "asset/9"
        project.markedDoneAt = Date(timeIntervalSince1970: 1_750_000_000)
        project.selectionSnapshot = try SelectionSnapshot(assetIDs: ["x"]).encoded()

        store.reset(project)
        #expect(project.persistedPickedCount == 0)
        #expect(project.doneDays.isEmpty)
        #expect(project.resumeDayKey == nil)
        #expect(project.lastViewedAssetID == nil)
        #expect(project.markedDoneAt == nil)
        // Config + the exported album stay — resetting progress is not un-exporting.
        #expect(project.targetAlbumID == "album/123")
        #expect(project.status == .empty)
    }

    @Test("delete removes only that project — siblings (and their export links) untouched")
    func delete() throws {
        let store = try makeStore()
        let a = makeProject(store, title: "A")
        a.targetAlbumID = "album/A"            // A is exported
        let b = makeProject(store, title: "B")
        b.targetAlbumID = "album/B"
        #expect(store.projects.count == 2)

        store.delete(a)
        // Only A's record is gone. B and its exported-album link are untouched — and the Photos
        // albums themselves are untouched by construction (ProjectStore has no PhotoKit dependency
        // and never deletes a `targetAlbumID`'s collection, D31).
        #expect(store.projects.map(\.title) == ["B"])
        #expect(store.projects.first?.targetAlbumID == "album/B")
    }

    @Test("create(from:) persists the full setup draft — exclusions (sorted) + videos + export target")
    func createFromDraft() throws {
        let store = try makeStore()
        let draft = NewAlbumDraft(
            title: "Trip",
            rangeStart: TestDates.year2025Start,
            rangeEnd: TestDates.year2025End,
            targetCount: 80,
            excludeScreenshots: false,
            excludedAlbumIDs: ["album/whatsapp", "album/downloads"],
            includeVideos: true,
            targetAlbumID: "album/existing")

        let project = store.create(from: draft)
        #expect(project.title == "Trip")
        #expect(project.rangeStart == TestDates.year2025Start)   // the source period must round-trip
        #expect(project.rangeEnd == TestDates.year2025End)
        #expect(project.targetCount == 80)
        #expect(project.excludeScreenshots == false)
        #expect(project.excludedAlbumIDs == ["album/downloads", "album/whatsapp"])   // stored sorted
        #expect(project.includeVideos == true)                   // the video opt-in threads through (#125)
        #expect(project.targetAlbumID == "album/existing")
        #expect(store.projects.contains { $0.id == project.id })
    }

    @Test("includeVideos defaults off, and duplicate carries it (+ locationEnabled) forward")
    func includeVideosDefaultAndDuplicate() throws {
        let store = try makeStore()
        // A plain create() leaves videos off (the images-only default, #125).
        let plain = makeProject(store, title: "Plain")
        #expect(plain.includeVideos == false)

        // Duplicate must copy the CONFIG — including includeVideos and locationEnabled (the latter a
        // latent omission fixed alongside #125).
        plain.includeVideos = true
        plain.locationEnabled = false
        let copy = store.duplicate(plain)
        #expect(copy.includeVideos == true)
        #expect(copy.locationEnabled == false)
    }

    @Test("status derives from persisted state: empty → inProgress → exported")
    func statusDerivation() throws {
        let store = try makeStore()
        let project = makeProject(store, title: "A")
        #expect(project.status == .empty)

        // Any marked day → in progress.
        project.doneDays = ["2025-07-05"]
        #expect(project.status == .inProgress)

        // Picks (with no done days) also count as in progress — reviewed-but-not-exported ≠ exported (#191).
        project.doneDays = []
        project.selectionSnapshot = try SelectionSnapshot(assetIDs: ["x"]).encoded()
        #expect(project.status == .inProgress)

        // Exported (finalized, baseline stamped) → exported, in sync.
        project.markedDoneAt = Date(timeIntervalSince1970: 1_750_000_000)
        project.exportedSelectionSnapshot = try SelectionSnapshot(assetIDs: ["x"]).encoded()
        #expect(project.status == .exported)
    }

    @Test("post-export drift (#191): add → editedSinceExport; remove alone stays exported; re-export clears")
    func postExportDrift() throws {
        let store = try makeStore()
        let project = makeProject(store, title: "A")
        // Export baseline: picks {a,b}, finalized.
        project.selectionSnapshot = try SelectionSnapshot(assetIDs: ["a", "b"]).encoded()
        project.markedDoneAt = Date(timeIntervalSince1970: 1_750_000_000)
        project.exportedSelectionSnapshot = try SelectionSnapshot(assetIDs: ["a", "b"]).encoded()
        #expect(project.status == .exported)

        // Add a pick → edited since export, 1 to add.
        project.selectionSnapshot = try SelectionSnapshot(assetIDs: ["a", "b", "c"]).encoded()
        #expect(project.status == .editedSinceExport(toAdd: 1))

        // Remove a pick only (add-only framing) → nothing new to add → still exported.
        project.selectionSnapshot = try SelectionSnapshot(assetIDs: ["a"]).encoded()
        #expect(project.status == .exported)

        // De-select EVERYTHING after export → still exported (the photos are honestly still in Photos —
        // add-only), never regressing to .empty (markedDoneAt wins over the empty check).
        project.selectionSnapshot = try SelectionSnapshot(assetIDs: []).encoded()
        #expect(project.status == .exported)

        // Re-export catches the baseline up → back in sync.
        project.selectionSnapshot = try SelectionSnapshot(assetIDs: ["a", "b", "c"]).encoded()
        project.exportedSelectionSnapshot = try SelectionSnapshot(assetIDs: ["a", "b", "c"]).encoded()
        #expect(project.status == .exported)
    }

    @Test("a pre-#191 exported album (no baseline snapshot) reads as exported, never drifted")
    func exportedWithoutBaseline() throws {
        let store = try makeStore()
        let project = makeProject(store, title: "A")
        project.selectionSnapshot = try SelectionSnapshot(assetIDs: ["a", "b"]).encoded()
        project.markedDoneAt = Date(timeIntervalSince1970: 1_750_000_000)
        // exportedSelectionSnapshot stays nil (exported before the feature) → no baseline ⇒ no drift.
        #expect(project.status == .exported)
    }

    @Test("reset clears the export drift baseline + finalize stamps → back to empty (#191)")
    func resetClearsDriftBaseline() throws {
        let store = try makeStore()
        let project = makeProject(store, title: "A")
        project.selectionSnapshot = try SelectionSnapshot(assetIDs: ["a", "b"]).encoded()
        project.markedDoneAt = Date(timeIntervalSince1970: 1_750_000_000)
        project.exportedSelectionSnapshot = try SelectionSnapshot(assetIDs: ["a", "b"]).encoded()
        project.lastExportedAt = Date(timeIntervalSince1970: 1_750_000_000)
        #expect(project.status == .exported)

        store.reset(project)
        #expect(project.status == .empty)
        #expect(project.markedDoneAt == nil)
        #expect(project.exportedSelectionSnapshot == nil)
        #expect(project.lastExportedAt == nil)
    }
}
