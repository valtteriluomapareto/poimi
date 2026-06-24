//
//  SelectionStoreTests.swift
//  PoimiAppTests — in-memory selection, debounced durability, per-project isolation (#29, D15).
//

import Testing
import Foundation
import SwiftData
import Curation
@testable import PoimiApp

@MainActor
@Suite("SelectionStore (#29)")
struct SelectionStoreTests {

    private static let rangeStart = Date(timeIntervalSince1970: 1_735_689_600)
    private static let rangeEnd = Date(timeIntervalSince1970: 1_767_225_600)

    // A shared in-memory context backing both stores, plus a ProjectStore to mint projects.
    private func makeStores(debounce: Duration = .seconds(60)) throws -> (ProjectStore, SelectionStore) {
        // Both stores share ONE container (so they see the same context) and each retains it.
        let container = try AppModelContainer.make(inMemory: true)
        var tick = Date(timeIntervalSince1970: 1_000_000_000)
        let clock: () -> Date = { defer { tick += 1 }; return tick }
        return (
            ProjectStore(container: container, now: clock),
            SelectionStore(container: container, debounce: debounce))
    }

    private func project(_ store: ProjectStore, _ title: String, target: Int = 50) -> CurationProject {
        store.create(title: title, rangeStart: Self.rangeStart, rangeEnd: Self.rangeEnd, targetCount: target)
    }

    @Test("a tap mutates the in-memory set but does NOT write per-tap — durability is debounced (D15)")
    func noPerTapWrite() throws {
        let (projects, selection) = try makeStores()   // 60s debounce — the timer won't fire in-test
        let a = project(projects, "A")

        selection.activate(a)
        selection.toggle("asset/x")
        #expect(selection.selected == ["asset/x"])               // in-memory truth updated
        #expect(SelectionSnapshot.decode(a.selectionSnapshot).assetIDs.isEmpty)  // NOT persisted yet

        selection.flushNow()
        #expect(SelectionSnapshot.decode(a.selectionSnapshot).assetIDs == ["asset/x"])  // now durable

        selection.deactivate()   // cancel the pending debounce
    }

    @Test("switching projects flushes the outgoing project to its own snapshot first")
    func flushOnSwitch() throws {
        let (projects, selection) = try makeStores()
        let a = project(projects, "A")
        let b = project(projects, "B")

        selection.activate(a)
        selection.toggle("asset/x")        // no manual flush
        selection.activate(b)              // the switch must flush A

        #expect(SelectionSnapshot.decode(a.selectionSnapshot).assetIDs == ["asset/x"])
        #expect(selection.selected.isEmpty)   // B starts from its own (empty) snapshot

        selection.deactivate()
    }

    @Test("selection is isolated per project across switches")
    func perProjectIsolation() throws {
        let (projects, selection) = try makeStores()
        let a = project(projects, "A")
        let b = project(projects, "B")

        selection.activate(a)
        selection.toggle("a/1"); selection.toggle("a/2")
        selection.activate(b)
        selection.toggle("b/1")
        selection.activate(a)
        #expect(selection.selected == ["a/1", "a/2"])
        selection.activate(b)
        #expect(selection.selected == ["b/1"])

        selection.deactivate()
    }

    @Test("the debounced flush actually fires after the window and persists — no manual flush")
    func debouncedFlushFires() async throws {
        let (projects, selection) = try makeStores(debounce: .milliseconds(50))
        let a = project(projects, "A")

        selection.activate(a)
        selection.toggle("x")
        // Not flushing manually — await past the window so the scheduled MainActor task runs.
        try await Task.sleep(for: .milliseconds(500))
        await Task.yield()
        #expect(SelectionSnapshot.decode(a.selectionSnapshot).assetIDs == ["x"])

        selection.deactivate()
    }

    @Test("switching cancels the outgoing project's pending debounce; the incoming one fires on its own")
    func switchCancelsStaleDebounceAndIncomingFires() async throws {
        let (projects, selection) = try makeStores(debounce: .milliseconds(50))
        let a = project(projects, "A")
        let b = project(projects, "B")

        selection.activate(a)
        selection.toggle("a/1")        // schedules A's debounce
        selection.activate(b)          // flushes A synchronously + cancels A's timer
        selection.toggle("b/1")        // schedules B's debounce

        // Wait past the window: A's cancelled timer must NOT re-fire (and could never write B's
        // pick onto A); B's own timer fires and persists its set.
        try await Task.sleep(for: .milliseconds(500))
        await Task.yield()
        #expect(SelectionSnapshot.decode(a.selectionSnapshot).assetIDs == ["a/1"])
        #expect(SelectionSnapshot.decode(b.selectionSnapshot).assetIDs == ["b/1"])

        selection.deactivate()
    }

    @Test("re-activating the already-active project keeps the unflushed live selection")
    func reactivateSameProjectPreservesLiveSelection() throws {
        let (projects, selection) = try makeStores()    // 60s debounce — nothing flushed yet
        let a = project(projects, "A")

        selection.activate(a)
        selection.toggle("x")
        selection.activate(a)   // same project: must early-return, NOT reload the (empty) snapshot
        #expect(selection.selected == ["x"])

        selection.deactivate()
    }

    @Test("deactivate flushes the live selection and clears active state")
    func deactivateFlushesAndClears() throws {
        let (projects, selection) = try makeStores()
        let a = project(projects, "A", target: 10)

        selection.activate(a)
        selection.toggle("x")
        selection.deactivate()
        #expect(SelectionSnapshot.decode(a.selectionSnapshot).assetIDs == ["x"])   // flushed
        #expect(selection.selected.isEmpty)
        #expect(selection.isActive == false)
        #expect(selection.activeProjectID == nil)
        #expect(selection.progress.target == 0)
    }

    @Test("running total tracks picks against the project's target")
    func runningTotal() throws {
        let (projects, selection) = try makeStores()
        let a = project(projects, "A", target: 10)

        selection.activate(a)
        #expect(selection.progress.target == 10)
        #expect(selection.progress.picked == 0)

        selection.toggle("x"); selection.toggle("y"); selection.toggle("x")  // x added then removed
        #expect(selection.selected == ["y"])
        #expect(selection.progress.picked == 1)

        selection.deactivate()
    }

    @Test("toggles are ignored when no project is active")
    func inertWhenInactive() throws {
        let (_, selection) = try makeStores()
        #expect(selection.toggle("x") == false)
        #expect(selection.selected.isEmpty)
    }
}
