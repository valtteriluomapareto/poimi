//
//  ExportStoreTests.swift
//  PoimiAppTests — the album export flow (#39, D19) against the in-memory FakePhotoLibrary.
//
//  Pins create-or-find + dupe guard + idempotent re-export (added counts AND actual album membership),
//  the persisted finalize (`targetAlbumID` + `markedDoneAt`, durable across a fresh context), export to
//  a pre-existing album chosen at setup, and the D19 error channel (limited/denied access, unresolved
//  picks, a since-deleted album → the "create a new album instead" recovery).
//

import Testing
import Foundation
import SwiftData
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

    @Test("first export creates the album, adds every pick (verified membership), sets targetAlbumID + markedDoneAt")
    func firstExportCreates() async throws {
        let project = makeProject()
        let fake = FakePhotoLibrary()
        let store = ExportStore(library: fake)
        await store.run(project: project, picks: picks)

        guard case .done(let result, let wasReExport) = store.phase else {
            Issue.record("expected .done, got \(store.phase)"); return
        }
        #expect(wasReExport == false)
        #expect(result.added == 3)
        #expect(result.total == 3)
        #expect(await fake.exportedAssetIDs(inAlbum: result.albumID) == picks)   // ACTUAL membership, not just counts
        #expect(project.targetAlbumID == result.albumID)   // the created album id is persisted
        #expect(project.markedDoneAt != nil)               // finalized → status .done
    }

    @Test("a video pick exports into the album like a photo (mixed selection, #125)")
    func exportsVideosLikePhotos() async throws {
        // Export is media-type-agnostic (it resolves ids → assets → album membership), so a picked video
        // must land in the album alongside the stills — nothing special-cases it out.
        let project = makeProject()
        let fake = FakePhotoLibrary(assets: FakePhotoLibrary.videoMixedSeed())
        let store = ExportStore(library: fake)
        let mixed: Set<String> = ["fake/busy/2", "fake/video/1"]   // one still + one video
        await store.run(project: project, picks: mixed)

        guard case .done(let result, _) = store.phase else {
            Issue.record("expected .done, got \(store.phase)"); return
        }
        #expect(result.added == 2)
        #expect(await fake.exportedAssetIDs(inAlbum: result.albumID) == mixed)   // the video is in the album
    }

    @Test("the finalize is durably saved — a fresh context re-fetches targetAlbumID + markedDoneAt")
    func finalizePersistsAcrossContext() async throws {
        let project = makeProject()
        let id = project.id
        await ExportStore(library: FakePhotoLibrary()).run(project: project, picks: picks)

        // A fresh context on the SAME container must see the saved finalize — proving the explicit
        // `context.save()` at the seam, not just the in-memory @Model mutation.
        let container = try #require(project.modelContext).container
        let refetched = try ModelContext(container)
            .fetch(FetchDescriptor<CurationProject>(predicate: #Predicate { $0.id == id })).first
        #expect(refetched?.targetAlbumID != nil)
        #expect(refetched?.markedDoneAt != nil)
    }

    @Test("re-export dupe-guards (counts + membership); a new pick adds only the delta; finalize isn't re-stamped")
    func reExportDupeGuards() async throws {
        let project = makeProject()
        let fake = FakePhotoLibrary()
        let store = ExportStore(library: fake)
        await store.run(project: project, picks: picks)
        let albumID = try #require(project.targetAlbumID)
        let finalizedAt = project.markedDoneAt

        // Same picks again → nothing new, flagged as a re-export, and the finalize stamp is unchanged.
        await store.run(project: project, picks: picks)
        guard case .done(let again, let wasReExport) = store.phase else {
            Issue.record("expected .done, got \(store.phase)"); return
        }
        #expect(wasReExport == true)
        #expect(again.added == 0)
        #expect(again.total == 3)
        #expect(project.targetAlbumID == albumID)          // same album, not a new one
        #expect(project.markedDoneAt == finalizedAt)       // finalize records the FIRST export only

        // One more pick → adds exactly the delta; the album holds all four.
        let grownPicks = picks.union(["fake/quiet/17"])
        await store.run(project: project, picks: grownPicks)
        guard case .done(let grown, _) = store.phase else {
            Issue.record("expected .done, got \(store.phase)"); return
        }
        #expect(grown.added == 1)
        #expect(grown.total == 4)
        #expect(await fake.exportedAssetIDs(inAlbum: albumID) == grownPicks)
    }

    @Test("export to a PRE-EXISTING album (chosen at setup) adds to it, dupe-guarding its current members")
    func exportToPreExistingAlbum() async throws {
        // Setup can persist an existing album's id as `targetAlbumID`; export must add to it, not fail.
        let project = makeProject()
        project.targetAlbumID = "album/whatsapp"   // seeded album; members = {fake/busy/0, fake/busy/1}
        let fake = FakePhotoLibrary()
        let store = ExportStore(library: fake)
        await store.run(project: project, picks: picks)   // none of these are already in WhatsApp

        guard case .done(let result, let wasReExport) = store.phase else {
            Issue.record("expected .done, got \(store.phase)"); return
        }
        #expect(wasReExport == true)                       // adding to a pre-existing album is an update
        #expect(result.albumID == "album/whatsapp")
        #expect(result.added == 3)
        #expect(result.total == 5)                         // 2 existing + 3 added
        #expect(await fake.exportedAssetIDs(inAlbum: "album/whatsapp")
            == picks.union(["fake/busy/0", "fake/busy/1"]))
    }

    @Test("partial resolve: deleted picks drop out, only the live ones are added (not a total failure)")
    func partialResolve() async throws {
        let project = makeProject()
        let fake = FakePhotoLibrary()
        let store = ExportStore(library: fake)
        await store.run(project: project, picks: ["fake/busy/2", "not/a/real/id"])

        guard case .done(let result, _) = store.phase else {
            Issue.record("expected .done, got \(store.phase)"); return
        }
        #expect(result.added == 1)
        #expect(await fake.exportedAssetIDs(inAlbum: result.albumID) == ["fake/busy/2"])
    }

    @Test("a since-deleted target album fails with .albumMissing + offers create-new; recovery succeeds")
    func albumMissingOffersRecreate() async throws {
        let project = makeProject()
        project.targetAlbumID = "album/exported/does-not-exist"   // neither created nor seeded
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

    @Test("limited access is rejected like denied (album creation needs full access) — matches System")
    func limitedAccessDenied() async throws {
        let project = makeProject()
        let store = ExportStore(library: FakePhotoLibrary(status: .limited))
        await store.run(project: project, picks: picks)

        guard case .failed(let error, let canCreateNew) = store.phase else {
            Issue.record("expected .failed, got \(store.phase)"); return
        }
        #expect(error == .notAuthorized)   // limited can't create albums — must match System
        #expect(canCreateNew == false)
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
