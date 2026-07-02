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

    @Test("saveEdits persists name / target / exclusions durably, with excluded ids sorted")
    func saveEditsPersistsSorted() throws {
        let container = try AppModelContainer.make(inMemory: true)
        let projects = ProjectStore(container: container, now: monotonicClock())
        let proj = project(projects, "Old name", target: 100)
        let id = proj.id

        proj.title = "New name"
        proj.targetCount = 300
        proj.excludedAlbumIDs = ["z/album", "a/album", "m/album"]   // deliberately unsorted
        projects.saveEdits(to: proj)

        #expect(proj.excludedAlbumIDs == ["a/album", "m/album", "z/album"])   // sorted in place

        // Read back through an INDEPENDENT context → proves the edit committed to the store, not just
        // the origin context's memory.
        let other = ModelContext(container)
        let fetched = try #require(try other.fetch(FetchDescriptor<CurationProject>()).first { $0.id == id })
        #expect(fetched.title == "New name")
        #expect(fetched.targetCount == 300)
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
        #expect(proj.persistedPickedCount == 0)      // persisted snapshot empty — no stale flush-back
        #expect(done.doneDays.isEmpty)               // live done state cleared
        #expect(proj.doneDays.isEmpty)               // …and persisted
        #expect(proj.markedDoneAt == nil)            // un-finalized
        #expect(proj.status == .empty)

        selection.deactivate()
        done.deactivate()
    }
}
