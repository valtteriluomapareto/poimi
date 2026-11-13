//
//  AlbumActionsTests.swift
//  PoimiAppTests — the album-actions façade (#297): one ordering for open / create / delete / reset /
//  edit. Delete and reset let go of exactly the stores that hold the album (#59) — never the open album's
//  when another album is mutated — and delete leaves no route or session pointing at a deleted album.
//

import Testing
import Foundation
import Curation
@testable import PoimiApp

@MainActor
@Suite("AlbumActions — one ordering for open / create / delete / reset / edit (#297)")
struct AlbumActionsTests {

    @Test("open bumps the album and shows its overview; create validates, then opens")
    func openAndCreate() throws {
        let harness = try SessionHarness()
        let older = harness.album("Older")
        _ = harness.album("Newer")
        harness.actions.open(older)
        #expect(harness.graph.projectStore.projects.first?.id == older.id)
        #expect(harness.coordinator.path == [.albumOverview(older.id)])

        var draft = NewAlbumDraft.priorCalendarYear(now: TestDates.year2025End, calendar: utcCalendar())
        draft.title = "   "
        #expect(harness.actions.create(validated: draft) == nil)   // invalid → nothing created
        #expect(harness.graph.projectStore.projects.count == 2)
        draft.title = "Trip"
        let created = try #require(harness.actions.create(validated: draft))
        #expect(harness.coordinator.path == [.albumOverview(created.id)])
    }

    /// #59: a store left holding a deleted album could flush a debounce into it. Delete lets go first.
    @Test("deleting the open album: stores let go (no pending debounce), back to the library, session closed")
    func deleteOpenAlbum() async throws {
        let harness = try SessionHarness()
        let project = harness.album()
        harness.actions.open(project)
        await harness.session.openReview(project)
        harness.selection.toggle("fake/busy/2")
        harness.done.toggle(try #require(harness.session.reviewClusters.first))
        #expect(harness.selection.hasPendingFlush)
        #expect(harness.done.hasPendingFlush)

        #expect(harness.actions.delete(project))

        #expect(!harness.selection.isActive)
        #expect(!harness.done.isActive)
        #expect(!harness.selection.hasPendingFlush)   // the stale debounce is gone — it can't write later
        #expect(!harness.done.hasPendingFlush)
        await harness.selection.awaitPendingFlush()
        await harness.done.awaitPendingFlush()
        #expect(harness.coordinator.path.isEmpty)
        #expect(harness.session.projectID == nil)
        #expect(harness.graph.projectStore.projects.isEmpty)
    }

    @Test("deleting from the album's settings screen returns to the library")
    func deleteFromSettings() async throws {
        let harness = try SessionHarness()
        let project = harness.album()
        harness.actions.open(project)
        await harness.session.openOverview(project)
        harness.coordinator.openSettings(project.id)

        #expect(harness.actions.delete(project))

        #expect(harness.coordinator.path.isEmpty)
        #expect(harness.session.projectID == nil)
    }

    /// The session can hold an album the path doesn't show (a headless open, a control action). Deleting
    /// it must not leave the session pointing at the deleted model.
    @Test("deleting an album the session holds but the path doesn't show closes the session")
    func deleteClosesSessionOffPath() async throws {
        let harness = try SessionHarness()
        let project = harness.album()
        await harness.session.openOverview(project)   // no navigation at all
        #expect(harness.session.projectID == project.id)

        #expect(harness.actions.delete(project))

        #expect(harness.session.projectID == nil)
        #expect(harness.session.candidateStore == nil)
        #expect(harness.session.reviewOrderedIDs.isEmpty)
    }

    /// The two old orderings differed here: `AlbumSettingsView` deactivated the stores unconditionally.
    /// Deleting (or resetting) an album that isn't the open one must leave the open one hydrated.
    @Test("deleting / resetting ANOTHER album leaves the open album hydrated, picks and all")
    func otherAlbumLeavesOpenOneAlone() async throws {
        let harness = try SessionHarness()
        let open = harness.album("Open")
        let other = harness.album("Other")
        let spare = harness.album("Spare")
        harness.actions.open(open)
        await harness.session.openReview(open)
        harness.selection.toggle("fake/busy/2")

        #expect(harness.actions.reset(other))
        #expect(harness.actions.delete(spare))

        #expect(harness.selection.activeProjectID == open.persistentModelID)
        #expect(harness.done.activeProjectID == open.persistentModelID)
        #expect(harness.selection.selected == ["fake/busy/2"])
        #expect(harness.selection.hasPendingFlush)   // its own debounce is untouched
        #expect(harness.coordinator.path == [.albumOverview(open.id)])
        #expect(harness.session.projectID == open.id)
    }

    @Test("resetting the open album zeroes it durably, re-hydrates it, and no later flush resurrects picks")
    func resetOpenAlbum() async throws {
        let harness = try SessionHarness()
        let project = harness.album()
        harness.actions.open(project)
        await harness.session.openReview(project)
        harness.selection.toggle("fake/busy/2")
        harness.done.toggle(try #require(harness.session.reviewClusters.first))

        #expect(harness.actions.reset(project))

        #expect(harness.selection.activeProjectID == project.persistentModelID)   // re-hydrated …
        #expect(harness.done.activeProjectID == project.persistentModelID)
        #expect(harness.selection.selected.isEmpty)                               // … with the reset state
        #expect(harness.done.doneDays.isEmpty)
        await harness.selection.awaitPendingFlush()
        await harness.done.awaitPendingFlush()
        let persisted = try #require(try harness.persisted(project))
        #expect(persisted.persistedPickedCount == 0)
        #expect(persisted.doneDays.isEmpty)
    }

    @Test("applyEdits: a blank name falls back to the name on open; the edit is saved; the tally retargets")
    func applyEdits() async throws {
        let harness = try SessionHarness()
        let project = harness.album("Summer")
        await harness.session.openOverview(project)
        project.title = "  "
        project.targetCount = 42

        harness.actions.applyEdits(to: project, titleOnOpen: "Summer")

        #expect(project.title == "Summer")
        #expect(harness.selection.target == 42)
        #expect(try harness.persisted(project)?.targetCount == 42)
    }
}
