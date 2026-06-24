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

    @Test("a stale debounce never writes one project's picks onto another")
    func staleDebounceIsInert() throws {
        // Short debounce so the scheduled write actually fires; the switch must have cancelled it.
        let (projects, selection) = try makeStores(debounce: .milliseconds(20))
        let a = project(projects, "A")
        let b = project(projects, "B")

        selection.activate(a)
        selection.toggle("a/1")    // schedules a write targeting A
        selection.activate(b)      // flushes + cancels A's timer, hydrates B
        selection.toggle("b/1")

        // A keeps exactly its own pick; B's pick never bled into A even if a timer fired.
        #expect(SelectionSnapshot.decode(a.selectionSnapshot).assetIDs == ["a/1"])
        selection.flushNow()
        #expect(SelectionSnapshot.decode(b.selectionSnapshot).assetIDs == ["b/1"])

        selection.deactivate()
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
