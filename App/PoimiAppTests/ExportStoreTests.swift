//
//  ExportStoreTests.swift
//  PoimiAppTests — the album export flow (#39, D19) against the in-memory FakePhotoLibrary.
//
//  Pins the create-or-find + dupe guard + idempotent re-export, the persisted finalize
//  (`targetAlbumID` + `markedDoneAt`), and the D19 error channel (revoked access, unresolved picks,
//  a since-deleted album → the "create a new album instead" recovery).
//

import Testing
import Foundation
import Curation
@testable import PoimiApp

@MainActor
@Suite("ExportStore — album export + completion (#39)")
struct ExportStoreTests {
    /// Retained for the whole test (one fresh in-memory store per `@Test` instance): the store holds
    /// the `ModelContainer`, so a project it creates stays valid while `ExportStore` mutates it. A
    /// locally-scoped store would deallocate, reset its context, and SIGTRAP on the mutation.
    private let projects: ProjectStore

    init() throws {
        projects = try ProjectStore(container: AppModelContainer.make(inMemory: true))
    }

    private func makeProject() -> CurationProject {
        projects.create(
            title: "Best of 2025",
            rangeStart: TestDates.year2025Start, rangeEnd: TestDates.year2025End,
            targetCount: 100)
    }

    /// Three ids that resolve against `yearMixedSeed` (the fake's default seed).
    private let picks: Set<String> = ["fake/busy/2", "fake/busy/5", "fake/quiet/16"]

    @Test("first export creates the album, sets targetAlbumID + markedDoneAt, adds every pick")
    func firstExportCreates() async throws {
        let project = makeProject()
        let store = ExportStore(library: FakePhotoLibrary())
        await store.run(project: project, picks: picks)

        guard case .done(let result, let wasReExport) = store.phase else {
            Issue.record("expected .done, got \(store.phase)"); return
        }
        #expect(wasReExport == false)
        #expect(result.added == 3)
        #expect(result.total == 3)
        #expect(project.targetAlbumID == result.albumID)   // the created album id is persisted
        #expect(project.markedDoneAt != nil)               // finalized → status .done
    }

    @Test("re-export dupe-guards: identical picks add nothing; a new pick adds only the delta")
    func reExportDupeGuards() async throws {
        let project = makeProject()
        let store = ExportStore(library: FakePhotoLibrary())
        await store.run(project: project, picks: picks)
        let albumID = project.targetAlbumID

        // Same picks again → nothing new, and it's flagged as a re-export.
        await store.run(project: project, picks: picks)
        guard case .done(let again, let wasReExport) = store.phase else {
            Issue.record("expected .done, got \(store.phase)"); return
        }
        #expect(wasReExport == true)
        #expect(again.added == 0)
        #expect(again.total == 3)
        #expect(project.targetAlbumID == albumID)          // same album, not a new one

        // One more pick → adds exactly the delta.
        await store.run(project: project, picks: picks.union(["fake/quiet/17"]))
        guard case .done(let grown, _) = store.phase else {
            Issue.record("expected .done, got \(store.phase)"); return
        }
        #expect(grown.added == 1)
        #expect(grown.total == 4)
    }

    @Test("a since-deleted target album fails with .albumMissing + offers create-new; recovery succeeds")
    func albumMissingOffersRecreate() async throws {
        let project = makeProject()
        project.targetAlbumID = "album/exported/does-not-exist"   // never created in the fake
        let store = ExportStore(library: FakePhotoLibrary())
        await store.run(project: project, picks: picks)

        guard case .failed(let error, let canCreateNew) = store.phase else {
            Issue.record("expected .failed, got \(store.phase)"); return
        }
        #expect(error == .albumMissing)
        #expect(canCreateNew == true)

        // "Create a new album instead" → a fresh album, ignoring the stale id.
        await store.run(project: project, picks: picks, forceNewAlbum: true)
        guard case .done(let result, let wasReExport) = store.phase else {
            Issue.record("expected .done, got \(store.phase)"); return
        }
        #expect(wasReExport == false)          // forceNewAlbum treats it as a first export
        #expect(result.added == 3)
        #expect(project.targetAlbumID == result.albumID)
    }

    @Test("no full-library access → .notAuthorized (no create-new offer on a first export)")
    func deniedAccess() async throws {
        let project = makeProject()
        let store = ExportStore(library: FakePhotoLibrary(status: .denied))
        await store.run(project: project, picks: picks)

        guard case .failed(let error, let canCreateNew) = store.phase else {
            Issue.record("expected .failed, got \(store.phase)"); return
        }
        #expect(error == .notAuthorized)
        #expect(canCreateNew == false)         // wasn't updating an existing album
        #expect(project.markedDoneAt == nil)   // a failed export never finalizes
    }

    @Test("picks that resolve to no live asset → .noAssetsResolved")
    func unresolvedPicks() async throws {
        let project = makeProject()
        let store = ExportStore(library: FakePhotoLibrary())
        await store.run(project: project, picks: ["not/a/real/id"])

        guard case .failed(let error, _) = store.phase else {
            Issue.record("expected .failed, got \(store.phase)"); return
        }
        #expect(error == .noAssetsResolved)
        #expect(project.targetAlbumID == nil)
    }
}
