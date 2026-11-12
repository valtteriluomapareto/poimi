//
//  AlbumSessionTests.swift
//  PoimiAppTests — the album session + album-actions façade lifted out of the views (#297, control
//  plane slice B): the scan / reconcile / publish lifecycle runs in-process with NO view mounted, the
//  grid-first path uses the shared timeline cache, export can't run twice, the Overview's
//  activate-without-reconcile (#289) is an explicit parameter, and delete / reset share one ordering.
//  Through the real `AppGraph` wiring + `FakePhotoLibrary`; every async step awaits the real work.
//

import Testing
import Foundation
import SwiftData
import Curation
@testable import PoimiApp

/// One app graph, wired exactly as the app wires it, over an in-memory store and a fake library.
@MainActor
private struct SessionHarness {
    let graph: AppGraph
    let library: FakePhotoLibrary

    init(assets: [AssetRef] = FakePhotoLibrary.yearMixedSeed(),
         timelineCache: TimelineCache = TimelineCache(directory: SessionHarness.temporaryDirectory())) throws {
        library = FakePhotoLibrary(assets: assets)
        graph = AppGraph.make(
            container: try AppModelContainer.make(inMemory: true),
            library: library, thumbnails: FakeThumbnailProvider(), naming: FakePlaceNaming(),
            timelineCache: timelineCache, debounce: .seconds(60), now: monotonicClock(),
            calendar: utcCalendar())
    }

    static func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("album-session-tests-\(UUID().uuidString)", isDirectory: true)
    }

    var session: AlbumSession { graph.session }
    var actions: AlbumActions { graph.actions }
    var coordinator: AppCoordinator { graph.coordinator }
    var selection: SelectionStore { graph.selectionStore }
    var done: DoneStore { graph.doneStore }

    func album(_ title: String = "Best of 2025") -> CurationProject {
        graph.projectStore.create(title: title, rangeStart: TestDates.year2025Start,
                                  rangeEnd: TestDates.year2025End, targetCount: 100)
    }

    /// A model context independent of the stores', to prove what was actually SAVED.
    func persisted(_ project: CurationProject) throws -> CurationProject? {
        let id = project.id
        return try ModelContext(graph.modelContainer).fetch(FetchDescriptor<CurationProject>())
            .first { $0.id == id }
    }
}

private let july5 = DayKey.day(year: 2025, month: 7, day: 5)
private let july5Noon = Date(timeIntervalSince1970: 1_751_716_800)   // 2025-07-05T12:00:00Z

@MainActor
@Suite("AlbumSession — the album session out of the views (#297)")
struct AlbumSessionTests {

    // MARK: - Open / publish

    @Test("open scans, hydrates the stores and publishes the review context — no view mounted")
    func openPublishesHeadless() async throws {
        let harness = try SessionHarness()
        let project = harness.album()
        harness.actions.open(project)

        let store = await harness.session.open(project, reconcile: true)

        guard case .ready(let clusters) = store.phase else {
            Issue.record("scan did not settle .ready: \(store.phase)")
            return
        }
        #expect(harness.selection.isActive)
        #expect(harness.done.isActive)
        #expect(harness.session.projectID == project.id)
        #expect(harness.session.reviewOrderedIDs == clusters.flatMap(\.assetIDs))
        #expect(!harness.session.reviewOrderedIDs.isEmpty)
        #expect(harness.session.reviewDayByID == store.dayByID)
        #expect(harness.session.reviewAssetsByID.count == store.assetsByID.count)
        #expect(harness.session.reviewClusters == clusters)
        #expect(!harness.session.reviewIsReExport)
        // With the stores active, a pick is real (an inactive store would silently refuse it).
        #expect(harness.selection.toggle(harness.session.reviewOrderedIDs[0]))
    }

    @Test("Overview + grid share ONE scan; a filter edit makes a fresh store (#125)")
    func storeReuseAcrossFilterEdit() async throws {
        let harness = try SessionHarness()
        let project = harness.album()
        let overview = await harness.session.open(project, reconcile: false)
        let grid = await harness.session.open(project, reconcile: true)
        #expect(overview === grid)   // drilling in doesn't re-fetch + re-cluster

        project.includeVideos.toggle()
        let rebuilt = harness.session.candidateStore(for: project)
        #expect(rebuilt !== overview)
        #expect(rebuilt.phase == .idle)
    }

    @Test("a second open while the first is still loading waits for it, then settles (one load)")
    func concurrentOpensShareOneLoad() async throws {
        let harness = try SessionHarness()
        let project = harness.album()
        // Two main-actor tasks, as two screens' `.task`s would be: the second runs while the first loads.
        let overview = Task { await harness.session.open(project, reconcile: false) }
        let grid = Task { await harness.session.open(project, reconcile: true) }
        let (first, second) = (await overview.value, await grid.value)
        #expect(first === second)
        #expect(!harness.session.reviewOrderedIDs.isEmpty)   // published, whichever finished last
    }

    @Test("CandidateStoreKey tracks every source filter — a Settings filter edit forces a re-scan (#125)")
    func candidateStoreKeyTracksFilters() {
        let fixedID = UUID()   // same album id, so only the filter under test differs
        func project(includeVideos: Bool = false, includePhotos: Bool = true,
                     excludeScreenshots: Bool = true,
                     excludedAlbumIDs: [String] = []) -> CurationProject {
            CurationProject(
                id: fixedID, title: "A",
                rangeStart: Date(timeIntervalSince1970: 0), rangeEnd: Date(timeIntervalSince1970: 86_400),
                targetCount: 100, excludeScreenshots: excludeScreenshots,
                excludedAlbumIDs: excludedAlbumIDs, includeVideos: includeVideos,
                includePhotos: includePhotos,
                selectionSnapshot: Data(),
                createdAt: Date(timeIntervalSince1970: 0), lastOpenedAt: Date(timeIntervalSince1970: 0))
        }
        typealias Key = AlbumSession.CandidateStoreKey
        let base = Key(project())
        #expect(base == Key(project()))                                   // same config → reuse the scan
        #expect(base != Key(project(includeVideos: true)))               // videos toggled → re-scan (#125)
        #expect(base != Key(project(excludeScreenshots: false)))         // screenshots toggled → re-scan
        #expect(base != Key(project(excludedAlbumIDs: ["x"])))           // an excluded album added → re-scan
        #expect(base != Key(project(includePhotos: false)))              // videos-only lens → re-scan (#273)
        // Excluded-album ORDER must not matter — the picker's Set is unordered, so the key sorts it.
        #expect(Key(project(excludedAlbumIDs: ["a", "b"])) == Key(project(excludedAlbumIDs: ["b", "a"])))
    }

    @Test("an album switch clears the whole review context — no stale metadata bleeds across (#127/#187)")
    func albumSwitchClearsContext() async throws {
        let harness = try SessionHarness()
        let project = harness.album()
        project.targetAlbumID = "album/exported"   // a previously-exported album → "Update in Photos"
        harness.actions.open(project)
        await harness.session.open(project, reconcile: true)
        #expect(harness.session.reviewIsReExport)
        #expect(!harness.session.reviewAssetsByID.isEmpty)

        harness.coordinator.openProject(UUID())   // the coordinator closes the album → the session drops it

        #expect(harness.session.projectID == nil)
        #expect(harness.session.candidateStore == nil)
        #expect(harness.session.reviewOrderedIDs.isEmpty)
        #expect(harness.session.reviewDayByID.isEmpty)
        #expect(harness.session.reviewAssetsByID.isEmpty)
        #expect(harness.session.reviewClusters.isEmpty)
        #expect(!harness.session.reviewIsReExport)
    }

    // MARK: - The grid-first path uses the timeline cache

    /// `ScanningView` used to build its store WITHOUT the timeline cache, so a grid-first open (iPad
    /// detail, a debug host, a control route) re-clustered every time. Every store now comes from the
    /// session, which always passes the shared cache.
    @Test("the grid-first open uses the shared timeline cache (a second open is a cache hit)")
    func gridFirstUsesTimelineCache() async throws {
        let cache = TimelineCache(directory: SessionHarness.temporaryDirectory())
        let first = try SessionHarness(timelineCache: cache)
        let project = first.album()
        let cold = await first.session.open(project, reconcile: true)   // the grid, first
        #expect(cold.scanReport?.cached == false)

        // A fresh store for the same album + photo set (another launch, sharing the cache) is a hit.
        first.coordinator.openProject(project.id)   // closes → the next open builds a new store
        let warm = await first.session.open(project, reconcile: true)
        #expect(warm !== cold)
        #expect(warm.scanReport?.cached == true)
    }

    // MARK: - #289: the Overview activates without reconciling

    @Test("the Overview's open does not reconcile; the grid's does (#289)")
    func overviewDoesNotReconcile() async throws {
        // A done day whose recorded baseline is one photo; the library now holds a second one that day.
        let harness = try SessionHarness(assets: [
            AssetRef(id: "p1", captureDate: july5Noon),
            AssetRef(id: "p2", captureDate: july5Noon.addingTimeInterval(60))
        ])
        let project = harness.album()
        project.doneDays = [july5.description]
        project.reviewedIDsByDay = ReviewBaseline.encode([MediaSelection.photosOnly.rawValue: [july5: ["p1"]]])

        await harness.session.open(project, reconcile: false)   // the Overview
        #expect(harness.done.doneDays.contains(july5))          // display-only: nothing re-opened …
        #expect(ReviewBaseline.decodeKeyed(try #require(project.reviewedIDsByDay))?[
            MediaSelection.photosOnly.rawValue]?[july5] == ["p1"])   // … and no baseline recorded

        await harness.session.open(project, reconcile: true)    // the grid
        #expect(!harness.done.doneDays.contains(july5))         // the gained photo re-opens its day (D32(d))
    }

    /// The #289 hole: the Overview never reconciles, so the media picker is reachable before any
    /// reconcile ran on an upgraded album. The legacy blob must therefore be stamped with its true lens
    /// on the Overview's OPEN (activate) — or switching the lens then entering the grid adopts a
    /// photos-only baseline for the new lens and un-marks every done day holding a video.
    @Test("open → lens switch → grid keeps done days that hold a video (legacy baseline, #289)")
    func legacyBaselineSurvivesLensSwitchBeforeGrid() async throws {
        let harness = try SessionHarness(assets: [
            AssetRef(id: "p1", captureDate: july5Noon),
            AssetRef(id: "v1", captureDate: july5Noon.addingTimeInterval(60), isVideo: true, duration: 5)
        ])
        let project = harness.album()
        project.doneDays = [july5.description]
        project.reviewedIDsByDay = try JSONEncoder().encode([july5.description: ["p1"]])   // the pre-#273 shape

        await harness.session.open(project, reconcile: false)   // land on the Overview
        project.media = .photosAndVideos                       // Settings: switch the lens
        await harness.session.open(project, reconcile: true)    // drill into the grid

        #expect(harness.done.doneDays.contains(july5))
        let persisted = try #require(try harness.persisted(project))
        #expect(persisted.doneDays == [july5.description])
    }

    // MARK: - Export runs once

    @Test("export cannot run twice: concurrent starts + a re-appearing screen run it once")
    func exportRunsOnce() async throws {
        let harness = try SessionHarness()
        let project = harness.album()
        harness.actions.open(project)
        let store = await harness.session.open(project, reconcile: true)
        let picks = Set(store.assetsByID.keys.sorted().prefix(3))
        harness.selection.select(picks)
        #expect(harness.session.export.phase == .idle)   // nothing reads "exporting" before a run

        // The screen's `.task` and a second caller (a re-mounted screen, a control action) race.
        let first = Task { await harness.session.startExport(project) }
        let second = Task { await harness.session.startExport(project) }
        _ = (await first.value, await second.value)
        guard case .done(let result, let wasReExport) = harness.session.export.phase else {
            Issue.record("export did not settle .done: \(harness.session.export.phase)")
            return
        }
        #expect(!wasReExport)
        #expect(result.added == picks.count)
        // Two first-export runs would each CREATE a Photos album — a duplicate album for the user.
        #expect(await harness.library.exportedAssetIDs(inAlbum: "album/exported/2").isEmpty)
        #expect(await harness.library.exportedAssetIDs(inAlbum: result.albumID) == picks)

        await harness.session.startExport(project)   // the screen appears again: still the one run
        #expect(harness.session.export.phase == .done(result, wasReExport: false))
    }

    @Test("an explicit retry re-runs the export; an album close returns it to idle")
    func exportRetryAndReset() async throws {
        let harness = try SessionHarness()
        let project = harness.album()
        harness.actions.open(project)
        await harness.session.open(project, reconcile: true)
        harness.selection.select(["fake/busy/2"])
        await harness.session.startExport(project)
        await harness.session.retryExport(project)
        guard case .done(_, let wasReExport) = harness.session.export.phase else {
            Issue.record("retry did not settle .done: \(harness.session.export.phase)")
            return
        }
        #expect(wasReExport)   // the retry ran (into the album the first run created)

        harness.coordinator.popToRoot()
        #expect(harness.session.export.phase == .idle)
    }

    // MARK: - CandidateStore.isNaming

    @Test("isNaming: true from .ready until the trip names publish")
    func isNamingTracksTheNamePass() async throws {
        let harness = try SessionHarness(assets: FakePhotoLibrary.locationSpikeSeed())
        let project = harness.album()
        let store = harness.session.candidateStore(for: project)
        #expect(!store.isNaming)
        await store.load(project)
        // `load` returns in the same main-actor turn it started the detached name pass.
        #expect(store.isNaming)
        await store.awaitPendingNames()
        #expect(!store.isNaming)
        #expect(!store.tripNames.isEmpty)
    }
}

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
        await harness.session.open(project, reconcile: true)
        harness.selection.toggle("fake/busy/2")
        harness.done.toggle(try #require(harness.session.reviewClusters.first))
        #expect(harness.selection.hasPendingFlush)
        #expect(harness.done.hasPendingFlush)

        harness.actions.delete(project)

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

    /// The two old orderings differed here: `AlbumSettingsView` deactivated the stores unconditionally.
    /// Deleting (or resetting) an album that isn't the open one must leave the open one hydrated.
    @Test("deleting / resetting ANOTHER album leaves the open album hydrated, picks and all")
    func otherAlbumLeavesOpenOneAlone() async throws {
        let harness = try SessionHarness()
        let open = harness.album("Open")
        let other = harness.album("Other")
        let spare = harness.album("Spare")
        harness.actions.open(open)
        await harness.session.open(open, reconcile: true)
        harness.selection.toggle("fake/busy/2")

        harness.actions.reset(other)
        harness.actions.delete(spare)

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
        await harness.session.open(project, reconcile: true)
        harness.selection.toggle("fake/busy/2")
        harness.done.toggle(try #require(harness.session.reviewClusters.first))

        harness.actions.reset(project)

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
        await harness.session.open(project, reconcile: false)
        project.title = "  "
        project.targetCount = 42

        harness.actions.applyEdits(to: project, titleOnOpen: "Summer")

        #expect(project.title == "Summer")
        #expect(harness.selection.target == 42)
        #expect(try harness.persisted(project)?.targetCount == 42)
    }
}
