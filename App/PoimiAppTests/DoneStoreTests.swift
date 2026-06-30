//
//  DoneStoreTests.swift
//  PoimiAppTests — mark-as-done state, debounced durability, per-project isolation (#38/#20).
//

import Testing
import Foundation
import SwiftData
import Curation
@testable import PoimiApp

@MainActor
@Suite("DoneStore (#38)")
struct DoneStoreTests {

    private func makeStores(debounce: Duration = .seconds(60)) throws -> (ProjectStore, DoneStore) {
        let container = try AppModelContainer.make(inMemory: true)   // both stores share one container
        return (ProjectStore(container: container, now: monotonicClock()),
                DoneStore(container: container, debounce: debounce))
    }

    private func project(_ store: ProjectStore, _ title: String) -> CurationProject {
        store.create(title: title, rangeStart: TestDates.year2025Start, rangeEnd: TestDates.year2025End, targetCount: 50)
    }

    private func group(_ id: String, _ days: [DayKey]) -> DayGroup {
        DayGroup(id: id, assetIDs: [id], days: days, isBusyDay: false)
    }

    @Test("toggling a section done flags its day; in-memory now, persisted only on flush (debounced)")
    func toggleMarksDay() throws {
        let (projects, done) = try makeStores()   // 60s debounce — won't fire in-test
        let a = project(projects, "A")
        let july = group("g", [.day(year: 2025, month: 7, day: 5)])

        done.activate(a)
        #expect(!done.isDone(july))
        done.toggle(july)
        #expect(done.isDone(july))                 // in-memory truth updated
        #expect(a.doneDays.isEmpty)                // NOT persisted yet (debounced)

        done.flushNow()
        #expect(a.doneDays == ["2025-07-05"])      // now durable
        done.deactivate()
    }

    @Test("toggling done twice returns to not-done")
    func toggleRoundTrip() throws {
        let (projects, done) = try makeStores()
        let a = project(projects, "A")
        let g = group("g", [.day(year: 2025, month: 7, day: 5)])

        done.activate(a)
        done.toggle(g)
        #expect(done.isDone(g))
        done.toggle(g)
        #expect(!done.isDone(g))
        done.flushNow()
        #expect(a.doneDays.isEmpty)
        done.deactivate()
    }

    @Test("a multi-day run is done only when EVERY day it spans is flagged")
    func multiDayRun() throws {
        let (projects, done) = try makeStores()
        let a = project(projects, "A")
        let run = group("run", [.day(year: 2025, month: 3, day: 16), .day(year: 2025, month: 3, day: 17)])

        done.activate(a)
        done.toggle(run)                           // marks BOTH days (Completion.markingDone)
        #expect(done.isDone(run))
        // A sub-run sharing only one of the days is not fully done.
        let partial = group("partial", [.day(year: 2025, month: 3, day: 16), .day(year: 2025, month: 3, day: 18)])
        #expect(!done.isDone(partial))
        done.deactivate()
    }

    @Test("switching projects flushes the outgoing one; the incoming starts from its own done-days")
    func perProjectIsolation() throws {
        let (projects, done) = try makeStores()
        let a = project(projects, "A")
        let b = project(projects, "B")
        let g = group("g", [.day(year: 2025, month: 7, day: 5)])

        done.activate(a)
        done.toggle(g)              // mark in A, no manual flush
        done.activate(b)            // the switch must flush A
        #expect(a.doneDays == ["2025-07-05"])
        #expect(done.doneDays.isEmpty)   // B starts from its own (empty) done-days

        done.activate(b)            // no-op (already active)
        done.activate(a)            // re-activate A → decodes its persisted done-days
        #expect(done.isDone(g))
        done.deactivate()
    }
}
