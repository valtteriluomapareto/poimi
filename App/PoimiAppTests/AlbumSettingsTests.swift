//
//  AlbumSettingsTests.swift
//  PoimiAppTests — the store-level contracts behind the album settings screen (#41):
//  live-target re-sync, durable in-place edits, and the reset-while-active ordering that must not
//  resurrect picks. The view is thin; these are the behaviours worth locking down.
//

import Testing
import Foundation
import SwiftData
import Curation
@testable import PoimiApp

@MainActor
@Suite("Album settings (#41)")
struct AlbumSettingsTests {

    private func project(_ store: ProjectStore, _ title: String, target: Int = 50) -> CurationProject {
        store.create(title: title, rangeStart: TestDates.year2025Start,
                     rangeEnd: TestDates.year2025End, targetCount: target)
    }

    @Test("retarget re-syncs the live tally for the active project, and is a no-op for any other")
    func retargetActiveOnly() throws {
        let container = try AppModelContainer.make(inMemory: true)
        let projects = ProjectStore(container: container, now: monotonicClock())
        let selection = SelectionStore(container: container, debounce: .seconds(60))
        let a = project(projects, "A", target: 100)
        let b = project(projects, "B", target: 50)

        selection.activate(a)
        #expect(selection.progress.target == 100)

        a.targetCount = 250
        selection.retarget(a)
        #expect(selection.progress.target == 250)     // active project → live tally follows

        b.targetCount = 999
        selection.retarget(b)
        #expect(selection.progress.target == 250)     // editing a non-active project doesn't move the tally

        selection.deactivate()
    }

    @Test("saveEdits persists name / period / target / exclusions / destination durably, excluded ids sorted")
    func saveEditsPersistsSorted() throws {
        let container = try AppModelContainer.make(inMemory: true)
        let projects = ProjectStore(container: container, now: monotonicClock())
        let proj = project(projects, "Old name", target: 100)
        let id = proj.id
        let newStart = Date(timeIntervalSince1970: 1_704_067_200)   // 2024-01-01Z
        let newEnd = Date(timeIntervalSince1970: 1_735_689_600)     // 2025-01-01Z

        proj.title = "New name"
        proj.targetCount = 300
        proj.rangeStart = newStart
        proj.rangeEnd = newEnd
        proj.targetAlbumID = "album/dest"
        proj.excludeScreenshots = false                            // default is true — prove the toggle persists
        proj.excludedAlbumIDs = ["z/album", "a/album", "m/album"]   // deliberately unsorted
        projects.saveEdits(to: proj)

        #expect(proj.excludedAlbumIDs == ["a/album", "m/album", "z/album"])   // sorted in place

        // Read back through an INDEPENDENT context → proves the edit committed to the store, not just
        // the origin context's memory.
        let other = ModelContext(container)
        let fetched = try #require(try other.fetch(FetchDescriptor<CurationProject>()).first { $0.id == id })
        #expect(fetched.title == "New name")
        #expect(fetched.targetCount == 300)
        #expect(fetched.rangeStart == newStart)
        #expect(fetched.rangeEnd == newEnd)
        #expect(fetched.targetAlbumID == "album/dest")
        #expect(fetched.excludeScreenshots == false)
        #expect(fetched.excludedAlbumIDs == ["a/album", "m/album", "z/album"])
    }

    @Test("Reset from settings clears picks, done days, and finalize — the ordering never resurrects picks")
    func resetClearsEverythingNoFlushBack() throws {
        let container = try AppModelContainer.make(inMemory: true)
        let projects = ProjectStore(container: container, now: monotonicClock())
        let selection = SelectionStore(container: container, debounce: .seconds(60))
        let done = DoneStore(container: container, debounce: .seconds(60))
        let proj = project(projects, "A", target: 120)

        // Seed done state on the model BEFORE activating (DoneStore hydrates from the model), plus a
        // live selection and a finalize stamp — the full "in progress, finalized" shape.
        proj.doneDays = ["2025-02-01"]
        proj.markedDoneAt = Date(timeIntervalSince1970: 1_750_000_000)
        selection.activate(proj)
        selection.select(["a", "b", "c"])
        done.activate(proj)
        #expect(done.doneDays.count == 1)

        // The exact sequence AlbumSettingsView.resetPicks runs: deactivate the live stores (flushing
        // their in-memory state), zero the model, then re-activate to reload the emptied state. If the
        // order were wrong, the deactivate flush would write picks back over the reset.
        selection.deactivate()
        done.deactivate()
        projects.reset(proj)
        selection.activate(proj)
        done.activate(proj)

        #expect(selection.selected.isEmpty)          // live picks gone
        #expect(selection.progress.target == 120)    // configuration (target) kept

        // Prove the zeroing COMMITTED durably — read back through an independent context (the same-object
        // reads above would pass even if `reset` never saved).
        let other = ModelContext(container)
        let fetched = try #require(try other.fetch(FetchDescriptor<CurationProject>()).first { $0.id == proj.id })
        #expect(fetched.persistedPickedCount == 0)   // persisted snapshot empty — no stale flush-back
        #expect(done.doneDays.isEmpty)               // live done state cleared
        #expect(fetched.doneDays.isEmpty)            // …and persisted
        #expect(fetched.markedDoneAt == nil)         // un-finalized
        #expect(fetched.status == .empty)

        selection.deactivate()
        done.deactivate()
    }

    @Test("Delete from settings deactivates the live stores (no dangling id) and removes the record")
    func deleteActiveDeactivatesStores() throws {
        let container = try AppModelContainer.make(inMemory: true)
        let projects = ProjectStore(container: container, now: monotonicClock())
        let selection = SelectionStore(container: container, debounce: .seconds(60))
        let done = DoneStore(container: container, debounce: .seconds(60))
        let proj = project(projects, "A")
        let id = proj.id

        selection.activate(proj)
        selection.select(["x", "y"])
        done.activate(proj)
        #expect(selection.isActive)
        #expect(done.isActive)

        // The exact sequence AlbumSettingsView.deleteAlbum runs (minus the nav pop): deactivate both
        // live stores so neither holds the dangling project, then delete the record.
        selection.deactivate()
        done.deactivate()
        projects.delete(proj)

        #expect(!selection.isActive)                 // no dangling PersistentIdentifier held
        #expect(!done.isActive)
        let other = ModelContext(container)
        let stillThere = try other.fetch(FetchDescriptor<CurationProject>()).contains { $0.id == id }
        #expect(!stillThere)                          // record gone from the store
    }

    @Test("TargetCountField.clamped keeps direct entry within the target bounds (#123)")
    func targetCountClamps() {
        let range = 1...10_000
        #expect(TargetCountField.clamped(0, in: range) == 1)           // 0 / empty-committed → floor
        #expect(TargetCountField.clamped(-50, in: range) == 1)         // negative → floor
        #expect(TargetCountField.clamped(99_999, in: range) == 10_000) // over max → ceiling
        #expect(TargetCountField.clamped(1_000, in: range) == 1_000)   // in range → unchanged
        #expect(TargetCountField.clamped(1, in: range) == 1)           // lower bound kept
        #expect(TargetCountField.clamped(10_000, in: range) == 10_000) // upper bound kept
    }

    // MARK: - #59 — delete/reset from the albums LIST must deactivate the active stores

    /// The three stores over one in-memory container (the shape both delete/reset paths use).
    private struct Stores {
        let container: ModelContainer
        let projects: ProjectStore
        let selection: SelectionStore
        let done: DoneStore
    }
    private func makeStores() throws -> Stores {
        let container = try AppModelContainer.make(inMemory: true)
        return Stores(container: container,
                      projects: ProjectStore(container: container, now: monotonicClock()),
                      selection: SelectionStore(container: container, debounce: .seconds(60)),
                      done: DoneStore(container: container, debounce: .seconds(60)))
    }

    @Test("deactivateIfActive deactivates only the currently-active project (#59)")
    func deactivateIfActiveGuards() throws {
        let env = try makeStores()
        let projects = env.projects, selection = env.selection, done = env.done
        let a = project(projects, "A"), b = project(projects, "B")
        selection.activate(a); done.activate(a)

        selection.deactivateIfActive(b); done.deactivateIfActive(b)   // not active → no-op
        #expect(selection.isActive)
        #expect(done.isActive)

        selection.deactivateIfActive(a); done.deactivateIfActive(a)   // the active one → deactivates
        #expect(!selection.isActive)
        #expect(!done.isActive)
    }

    @Test("Deleting the ACTIVE album from the library list deactivates the live stores (no dangling, #59)")
    func albumsListDeleteOfActiveDeactivates() throws {
        let env = try makeStores()
        let container = env.container, projects = env.projects, selection = env.selection, done = env.done
        let a = project(projects, "A")
        let id = a.id
        selection.activate(a); selection.select(["x", "y"]); done.activate(a)

        // The exact sequence AlbumsView.deleteAlbum runs (the previously-unguarded list path).
        selection.deactivateIfActive(a); done.deactivateIfActive(a)
        projects.delete(a)

        #expect(!selection.isActive)     // neither store holds the deleted model
        #expect(!done.isActive)
        let other = ModelContext(container)
        #expect(!(try other.fetch(FetchDescriptor<CurationProject>()).contains { $0.id == id }))
    }

    @Test("Deleting a NON-active album from the list leaves the active album's picks intact (#59)")
    func albumsListDeleteOfOtherKeepsActive() throws {
        let env = try makeStores()
        let projects = env.projects, selection = env.selection, done = env.done
        let a = project(projects, "A"), b = project(projects, "B")
        selection.activate(a); selection.select(["x", "y"]); done.activate(a)

        selection.deactivateIfActive(b); done.deactivateIfActive(b)   // deleting B must not disturb A
        projects.delete(b)

        #expect(selection.isActive)
        #expect(selection.selected == ["x", "y"])
        #expect(done.isActive)
    }

    @Test("Resetting the ACTIVE album from the list clears picks and reactivates emptied — no resurrect (#59)")
    func albumsListResetOfActiveClearsAndReactivates() throws {
        let env = try makeStores()
        let container = env.container, projects = env.projects, selection = env.selection, done = env.done
        let a = project(projects, "A")
        selection.activate(a); selection.select(["x", "y", "z"]); done.activate(a)

        // AlbumsView.resetAlbum sequence for the active album: deactivate → reset → reactivate.
        selection.deactivateIfActive(a); done.deactivateIfActive(a)
        projects.reset(a)
        selection.activate(a); done.activate(a)

        #expect(selection.isActive)
        #expect(selection.selected.isEmpty)   // emptied, not resurrected by a stale flush
        let other = ModelContext(container)
        let fetched = try #require(try other.fetch(FetchDescriptor<CurationProject>()).first { $0.id == a.id })
        #expect(fetched.persistedPickedCount == 0)
    }
}
