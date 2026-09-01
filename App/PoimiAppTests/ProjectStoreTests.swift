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

    // MARK: The 3-way media lens (#273)

    @Test("includePhotos defaults TRUE — an upgraded album must not silently become videos-only")
    func includePhotosDefaultsTrue() throws {
        let store = try makeStore()
        let plain = makeProject(store, title: "Plain")
        // The silent-flip guard: if this default were false, every album existing before #273 would
        // come back from migration reviewing nothing but videos.
        #expect(plain.includePhotos == true)
        #expect(plain.media == .photosOnly)

        // Copy carries the lens forward with the rest of the config.
        plain.media = .videosOnly
        let copy = store.duplicate(plain)
        #expect(copy.includePhotos == false)
        #expect(copy.includeVideos == true)
        #expect(copy.media == .videosOnly)
    }

    @Test("MediaSelection is the single writer: every case round-trips, and neither maps to photosOnly")
    func mediaSelectionRoundTrip() {
        for lens in MediaSelection.allCases {
            let decoded = MediaSelection(includePhotos: lens.includePhotos, includeVideos: lens.includeVideos)
            #expect(decoded == lens)
        }
        // Exhaustive decode of the storage shape, including the combination the UI can't produce.
        #expect(MediaSelection(includePhotos: true, includeVideos: false) == .photosOnly)
        #expect(MediaSelection(includePhotos: true, includeVideos: true) == .photosAndVideos)
        #expect(MediaSelection(includePhotos: false, includeVideos: true) == .videosOnly)
        // Degenerate (nothing to review) decodes to a defined case rather than trapping.
        #expect(MediaSelection(includePhotos: false, includeVideos: false) == .photosOnly)
        // …and no case ever ENCODES that combination.
        #expect(MediaSelection.allCases.allSatisfy { $0.includePhotos || $0.includeVideos })
    }

    @Test("reset clears the reconcile baselines, so a reset album starts with no stale history")
    func resetClearsReviewedBaseline() throws {
        let store = try makeStore()
        let project = makeProject(store, title: "A")
        project.doneDays = ["2025-07-05"]
        project.reviewedIDsByDay = Data("{}".utf8)
        store.reset(project)
        #expect(project.doneDays.isEmpty)
        #expect(project.reviewedIDsByDay == nil)
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

// MARK: - Reset day marks without discarding picks (#285)
//
// In an extension (not the main struct body) so these don't push the suite over SwiftLint's
// type_body_length — the same reason CandidateStoreTests splits its #125 videos tests out.
extension ProjectStoreTests {

    /// The whole point of the action: progress goes, picks stay. If this ever regresses, the only way
    /// to re-review an album costs the user every pick they made.
    @Test("resetDoneMarks clears progress and KEEPS the picks (#285)")
    func resetDoneMarksKeepsPicks() throws {
        let store = try makeStore()
        let project = makeProject(store, title: "A")
        let picks = try SelectionSnapshot(assetIDs: ["p1", "p2", "p3"]).encoded()
        project.selectionSnapshot = picks
        project.doneDays = ["2025-07-05", "2025-07-06"]
        project.resumeDayKey = "2025-07-06"
        project.markedDoneAt = Date(timeIntervalSince1970: 1_000)

        store.resetDoneMarks(project)

        #expect(project.doneDays.isEmpty)
        #expect(project.resumeDayKey == nil)
        // `markedDoneAt` SURVIVES: despite the name it is the first-export stamp, not review state,
        // and clearing it demotes an exported album out of `.exported` (see the status tests below).
        #expect(project.markedDoneAt == Date(timeIntervalSince1970: 1_000))
        // Byte-identical: the picks are not merely non-empty, they are untouched.
        #expect(project.selectionSnapshot == picks)
        #expect(SelectionSnapshot.decode(project.selectionSnapshot).assetIDs == ["p1", "p2", "p3"])
    }

    /// The doc comment promises the per-lens reconcile baseline is left alone (#273 §6b) — assert it,
    /// so a later "tidy-up" that nils it can't silently cost a cycle of D32(d)/D34 re-open protection.
    @Test("resetDoneMarks leaves the reconcile baseline intact (#285/#273)")
    func resetDoneMarksKeepsReconcileBaseline() throws {
        let store = try makeStore()
        let project = makeProject(store, title: "A")
        let baseline = Data(#"{"photosOnly":{"2025-07-05":["a"]}}"#.utf8)
        project.reviewedIDsByDay = baseline
        project.doneDays = ["2025-07-05"]

        store.resetDoneMarks(project)

        #expect(project.doneDays.isEmpty)
        #expect(project.reviewedIDsByDay == baseline)
    }

    /// An already-exported album must keep its post-export status — clearing day marks is not an
    /// export event, so the drift baseline (#191) must survive or the row silently reverts to `.empty`.
    @Test("resetDoneMarks keeps an exported album EXPORTED — status, not just the raw fields (#285/#191)")
    func resetDoneMarksKeepsExportStatus() throws {
        let store = try makeStore()
        let project = makeProject(store, title: "A")
        let exported = try SelectionSnapshot(assetIDs: ["p1"]).encoded()
        project.selectionSnapshot = exported
        project.exportedSelectionSnapshot = exported
        project.exportedPhotoCount = 1
        project.lastExportedAt = Date(timeIntervalSince1970: 2_000)
        // The field that actually gates the status — and the one the first version of this wrongly
        // cleared. Without seeding it, this fixture is not an exported album at all and the test
        // cannot fail, which is exactly how the regression shipped past it.
        project.markedDoneAt = Date(timeIntervalSince1970: 1_500)
        project.doneDays = ["2025-07-05"]
        #expect(project.status == .exported)

        store.resetDoneMarks(project)

        #expect(project.doneDays.isEmpty)
        #expect(project.status == .exported)          // the user-visible outcome
        #expect(project.markedDoneAt == Date(timeIntervalSince1970: 1_500))
        #expect(project.exportedSelectionSnapshot == exported)
        #expect(project.exportedPhotoCount == 1)
        #expect(project.lastExportedAt == Date(timeIntervalSince1970: 2_000))
    }

    @Test("resetDoneMarks preserves post-export DRIFT — #191's heads-up survives (#285)")
    func resetDoneMarksKeepsDrift() throws {
        let store = try makeStore()
        let project = makeProject(store, title: "A")
        project.exportedSelectionSnapshot = try SelectionSnapshot(assetIDs: ["p1"]).encoded()
        project.exportedPhotoCount = 1
        project.markedDoneAt = Date(timeIntervalSince1970: 1_500)
        // One pick made since the export → the amber "N to add" state.
        project.selectionSnapshot = try SelectionSnapshot(assetIDs: ["p1", "p2"]).encoded()
        project.doneDays = ["2025-07-05"]
        #expect(project.status == .editedSinceExport(toAdd: 1))

        store.resetDoneMarks(project)

        #expect(project.status == .editedSinceExport(toAdd: 1))
    }
}
