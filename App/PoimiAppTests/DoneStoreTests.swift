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

    @Test("the debounced flush actually fires after the window and persists — no manual flush")
    func debouncedFlushFires() async throws {
        let (projects, done) = try makeStores(debounce: .milliseconds(10))
        let a = project(projects, "A")
        let g = group("g", [.day(year: 2025, month: 7, day: 5)])

        done.activate(a)
        done.toggle(g)
        await done.awaitPendingFlush()              // await the real task, not a fixed sleep
        #expect(a.doneDays == ["2025-07-05"])
        done.deactivate()
    }

    @Test("switching cancels the outgoing project's pending debounce; the incoming fires on its own")
    func switchCancelsStaleDebounceAndIncomingFires() async throws {
        let (projects, done) = try makeStores(debounce: .milliseconds(10))
        let a = project(projects, "A")
        let b = project(projects, "B")

        done.activate(a)
        done.toggle(group("g", [.day(year: 2025, month: 7, day: 5)]))   // schedules A's flush
        done.activate(b)                                                // flushes A synchronously, cancels its timer
        done.toggle(group("h", [.day(year: 2025, month: 8, day: 1)]))   // schedules B's flush
        await done.awaitPendingFlush()
        #expect(a.doneDays == ["2025-07-05"])   // A's switch-flush value; its cancelled timer never wrote onto A
        #expect(b.doneDays == ["2025-08-01"])
        done.deactivate()
    }

    @Test("deactivate flushes the live done-days, then clears the active state")
    func deactivateFlushesAndClears() throws {
        let (projects, done) = try makeStores()   // 60s debounce — deactivate must flush, not the timer
        let a = project(projects, "A")
        let g = group("g", [.day(year: 2025, month: 7, day: 5)])

        done.activate(a)
        done.toggle(g)
        done.deactivate()
        #expect(a.doneDays == ["2025-07-05"])     // flushed on deactivate
        #expect(done.doneDays.isEmpty)
        #expect(done.isActive == false)
        #expect(done.activeProjectID == nil)
    }

    @Test("activate decodes externally-persisted done-days (the launch / debug-host path)")
    func activateDecodesPersisted() throws {
        let (projects, done) = try makeStores()
        let a = project(projects, "A")
        a.doneDays = ["2025-03-16", "2025-03-17"]   // set outside the store (a prior session)
        done.activate(a)
        #expect(done.doneDays == [.day(year: 2025, month: 3, day: 16), .day(year: 2025, month: 3, day: 17)])
        done.deactivate()
    }

    // MARK: - Done-but-changed reconcile (D32(d) — the collapse must not hide a new photo)

    @Test("reconcile: the FIRST load (no baseline) records a snapshot and re-opens nothing")
    func reconcileFirstLoadNoReopen() throws {
        let (projects, done) = try makeStores()
        let a = project(projects, "A")
        let day = DayKey.day(year: 2025, month: 3, day: 16)
        done.activate(a)
        done.toggle(group("g", [day]))
        #expect(a.reviewedIDsByDay == nil)               // no baseline before the first reconcile
        done.reconcile(currentIDsByDay: [day: ["x"]])
        #expect(done.isDone(group("g", [day])))          // still done — empty baseline must NOT reopen
        #expect(a.reviewedIDsByDay != nil)               // baseline now recorded
        done.deactivate()
    }

    @Test("reconcile: a done day that GAINED a photo since the last load re-opens (and persists)")
    func reconcileGainReopens() throws {
        let (projects, done) = try makeStores()
        let a = project(projects, "A")
        let day = DayKey.day(year: 2025, month: 3, day: 16)
        let g = group("g", [day])
        done.activate(a)
        done.toggle(g)
        done.reconcile(currentIDsByDay: [day: ["x"]])    // first load → baseline {x}
        done.flushNow()
        #expect(a.doneDays == ["2025-03-16"])            // done, persisted
        done.reconcile(currentIDsByDay: [day: ["x", "y"]])   // "y" is new on a done day
        #expect(!done.isDone(g))                         // re-opened
        #expect(a.doneDays.isEmpty)                      // the reopen is persisted immediately
        done.deactivate()
    }

    @Test("reconcile: a done day that only LOST a photo stays done")
    func reconcileLossKeepsDone() throws {
        let (projects, done) = try makeStores()
        let a = project(projects, "A")
        let day = DayKey.day(year: 2025, month: 3, day: 16)
        let g = group("g", [day])
        done.activate(a)
        done.toggle(g)
        done.reconcile(currentIDsByDay: [day: ["x", "y"]])   // baseline {x, y}
        done.reconcile(currentIDsByDay: [day: ["x"]])        // "y" deleted, nothing new
        #expect(done.isDone(g))
        done.deactivate()
    }
}
