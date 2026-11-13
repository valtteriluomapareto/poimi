//
//  AlbumSessionTests.swift
//  PoimiAppTests — the album session lifted out of the views (#297, control plane slice B): the scan /
//  reconcile / publish lifecycle runs in-process with NO view mounted, one load per store however the
//  opens race, the grid-first path uses the shared timeline cache, and the Overview's
//  activate-without-reconcile (#289) is its own entry point. Through the real `AppGraph` wiring + a fake
//  library; every async step awaits the real work or a library gate — never a fixed sleep.
//  Export: AlbumSessionExportTests. The façade: AlbumActionsTests.
//

import Testing
import Foundation
import SwiftData
import Curation
@testable import PoimiApp

/// The fake library behind a counter and optional gates, so a test can count fetches / exports and hold
/// one in flight (then release it) deterministically.
actor GatedLibrary: PhotoLibraryProviding {
    let base: FakePhotoLibrary
    private(set) var fetchCount = 0
    private(set) var exportCount = 0
    private var gateFetches = false
    private var gateExports = false
    private var held: [CheckedContinuation<Void, Never>] = []

    init(_ base: FakePhotoLibrary) { self.base = base }

    func hold(fetches: Bool = false, exports: Bool = false) {
        gateFetches = fetches
        gateExports = exports
    }

    func release() {
        gateFetches = false
        gateExports = false
        held.forEach { $0.resume() }
        held = []
    }

    /// Poll (yielding, no sleep) until `count` calls are held at a gate.
    func waitUntilHeld(_ count: Int = 1) async {
        while held.count < count { await Task.yield() }
    }

    func authorizationStatus() async -> LibraryAuthorization { await base.authorizationStatus() }
    func requestAuthorization() async -> LibraryAuthorization { await base.requestAuthorization() }
    func albums() async throws -> [AlbumRef] { try await base.albums() }
    func assetIDs(inAlbums ids: [String]) async throws -> Set<String> { try await base.assetIDs(inAlbums: ids) }

    func fetchAssets(in interval: DateInterval) async throws -> [AssetRef] {
        fetchCount += 1
        if gateFetches { await withCheckedContinuation { held.append($0) } }
        return try await base.fetchAssets(in: interval)
    }

    func export(assetIDs: Set<String>, toAlbumNamed name: String,
                existingAlbumID: String?) async throws -> ExportResult {
        exportCount += 1
        if gateExports { await withCheckedContinuation { held.append($0) } }
        return try await base.export(assetIDs: assetIDs, toAlbumNamed: name, existingAlbumID: existingAlbumID)
    }
}

/// One app graph, wired exactly as the app wires it, over an in-memory store and a (gated) fake library.
@MainActor
struct SessionHarness {
    let graph: AppGraph
    let library: FakePhotoLibrary
    let gate: GatedLibrary

    init(assets: [AssetRef] = FakePhotoLibrary.yearMixedSeed(),
         timelineCache: TimelineCache = TimelineCache(directory: SessionHarness.temporaryDirectory())) throws {
        library = FakePhotoLibrary(assets: assets)
        gate = GatedLibrary(library)
        graph = AppGraph.make(
            container: try AppModelContainer.make(inMemory: true),
            library: gate, thumbnails: FakeThumbnailProvider(), naming: FakePlaceNaming(),
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

let july5 = DayKey.day(year: 2025, month: 7, day: 5)
let july5Noon = Date(timeIntervalSince1970: 1_751_716_800)   // 2025-07-05T12:00:00Z

@MainActor
@Suite("AlbumSession — the album session out of the views (#297)")
struct AlbumSessionTests {

    // MARK: - Open / publish

    @Test("openReview scans, hydrates the stores and publishes the review context — no view mounted")
    func openPublishesHeadless() async throws {
        let harness = try SessionHarness()
        let project = harness.album()
        harness.actions.open(project)

        let store = await harness.session.openReview(project)

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

    /// The completion stats count from `reviewDayByID`; before #297 only the grid published it, so saving
    /// straight from the Overview showed nothing reviewed.
    @Test("openOverview publishes the review context too (the Overview → Save stats path)")
    func overviewPublishes() async throws {
        let harness = try SessionHarness()
        let project = harness.album()
        let store = await harness.session.openOverview(project)
        #expect(!harness.session.reviewDayByID.isEmpty)
        #expect(harness.session.reviewDayByID == store.dayByID)
        #expect(!harness.session.reviewOrderedIDs.isEmpty)
    }

    @Test("Overview + grid share ONE scan; a filter edit makes a fresh store (#125)")
    func storeReuseAcrossFilterEdit() async throws {
        let harness = try SessionHarness()
        let project = harness.album()
        let overview = await harness.session.openOverview(project)
        let grid = await harness.session.openReview(project)
        #expect(overview === grid)   // drilling in doesn't re-fetch + re-cluster
        #expect(await harness.gate.fetchCount == 1)

        project.includeVideos.toggle()
        let rebuilt = harness.session.candidateStore(for: project)
        #expect(rebuilt !== overview)
        #expect(rebuilt.phase == .idle)
    }

    /// The load runs in a task, so its store still reads `.idle` until that task first runs: a second
    /// open in that window must JOIN the load, not start a second fetch.
    @Test("racing opens share one load: one fetch, both get the same settled store")
    func concurrentOpensShareOneLoad() async throws {
        let harness = try SessionHarness()
        let project = harness.album()
        // Two main-actor tasks, as two screens' `.task`s would be: the second runs while the first loads.
        let overview = Task { await harness.session.openOverview(project) }
        let grid = Task { await harness.session.openReview(project) }
        let (first, second) = (await overview.value, await grid.value)
        #expect(first === second)
        #expect(await harness.gate.fetchCount == 1)
        #expect(!harness.session.reviewOrderedIDs.isEmpty)
    }

    /// The grid joining an Overview-started load must get its reconcile in the SAME turn the load lands
    /// `.ready` — not a turn later, after a frame drawn with the stale done-state.
    @Test("a reconcile asked by a caller waiting on the load lands with the load")
    func waitingReconcileLandsWithTheLoad() async throws {
        let harness = try SessionHarness(assets: [
            AssetRef(id: "p1", captureDate: july5Noon),
            AssetRef(id: "p2", captureDate: july5Noon.addingTimeInterval(60))
        ])
        let project = harness.album()
        project.doneDays = [july5.description]
        project.reviewedIDsByDay = ReviewBaseline.encode([MediaSelection.photosOnly.rawValue: [july5: ["p1"]]])
        await harness.gate.hold(fetches: true)

        let overview = Task { await harness.session.openOverview(project) }
        await harness.gate.waitUntilHeld()
        let grid = Task { await harness.session.openReview(project) }
        // Let the grid's open run up to its await on the held load (it registers its reconcile there).
        for _ in 0..<10 { await Task.yield() }
        let store = try #require(harness.session.candidateStore)
        var doneWhenReady: Bool?
        // Observe the turn `.ready` lands: by then the reconcile must already have run.
        let watcher = Task { @MainActor in
            while true {
                if case .ready = store.phase { doneWhenReady = harness.done.doneDays.contains(july5); return }
                await Task.yield()
            }
        }
        await harness.gate.release()
        _ = (await overview.value, await grid.value)
        await watcher.value
        #expect(doneWhenReady == false)   // the gained photo re-opened its day in the same turn
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

    @Test("a re-entry with the same scan doesn't republish the review context (no grid-wide invalidation)")
    func reentryDoesNotRepublish() async throws {
        let harness = try SessionHarness()
        let project = harness.album()
        await harness.session.openReview(project)
        #expect(harness.session.publishCount == 1)
        await harness.session.openReview(project)     // another grid entry / a size-class flip
        await harness.session.openOverview(project)
        #expect(harness.session.publishCount == 1)
        await harness.session.rescanReview(project)   // a new load of the same store does republish
        #expect(harness.session.publishCount == 2)
    }

    // MARK: - Closing follows the path

    @Test("an album switch clears the whole review context — no stale metadata bleeds across (#127/#187)")
    func albumSwitchClearsContext() async throws {
        let harness = try SessionHarness()
        let project = harness.album()
        project.targetAlbumID = "album/exported"   // a previously-exported album → "Update in Photos"
        harness.actions.open(project)
        await harness.session.openReview(project)
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

    /// A NavigationStack back-swipe writes `path` through the binding — no coordinator method runs.
    @Test("a back-swipe out of the album (a direct path write) closes the session")
    func backSwipeClosesSession() async throws {
        let harness = try SessionHarness()
        let project = harness.album()
        harness.actions.open(project)
        harness.coordinator.openReview(project.id)
        await harness.session.openReview(project)

        harness.coordinator.path = [.albumOverview(project.id)]   // back from the grid: same album
        #expect(harness.session.projectID == project.id)
        harness.coordinator.path = []                              // back out of the album
        #expect(harness.session.projectID == nil)
        #expect(harness.session.reviewOrderedIDs.isEmpty)
    }

    @Test("an album switch while its scan is in flight: nothing published, A's done-state not reconciled")
    func switchDuringScan() async throws {
        let harness = try SessionHarness(assets: [
            AssetRef(id: "p1", captureDate: july5Noon),
            AssetRef(id: "p2", captureDate: july5Noon.addingTimeInterval(60))
        ])
        let albumA = harness.album("A")
        albumA.doneDays = [july5.description]
        let baseline = ReviewBaseline.encode([MediaSelection.photosOnly.rawValue: [july5: ["p1"]]])
        albumA.reviewedIDsByDay = baseline
        harness.actions.open(albumA)
        await harness.gate.hold(fetches: true)
        let grid = Task { await harness.session.openReview(albumA) }
        await harness.gate.waitUntilHeld()

        harness.coordinator.openProject(UUID())   // switch away mid-scan
        await harness.gate.release()
        await grid.value

        #expect(harness.session.reviewOrderedIDs.isEmpty)
        #expect(harness.session.reviewDayByID.isEmpty)
        #expect(harness.done.doneDays.contains(july5))      // the gained photo did NOT re-open A's day …
        #expect(albumA.reviewedIDsByDay == baseline)        // … and no baseline was recorded
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
        let cold = await first.session.openReview(project)   // the grid, first
        #expect(cold.scanReport?.cached == false)

        // A fresh store for the same album + photo set (another launch, sharing the cache) is a hit.
        first.coordinator.openProject(project.id)   // re-opening closes → the next open builds a new store
        let warm = await first.session.openReview(project)
        #expect(warm !== cold)
        #expect(warm.scanReport?.cached == true)
    }

    // MARK: - #289: the Overview activates without reconciling

    @Test("openOverview does not reconcile; openReview does (#289)")
    func overviewDoesNotReconcile() async throws {
        // A done day whose recorded baseline is one photo; the library now holds a second one that day.
        let harness = try SessionHarness(assets: [
            AssetRef(id: "p1", captureDate: july5Noon),
            AssetRef(id: "p2", captureDate: july5Noon.addingTimeInterval(60))
        ])
        let project = harness.album()
        project.doneDays = [july5.description]
        project.reviewedIDsByDay = ReviewBaseline.encode([MediaSelection.photosOnly.rawValue: [july5: ["p1"]]])

        await harness.session.openOverview(project)
        #expect(harness.done.doneDays.contains(july5))          // display-only: nothing re-opened …
        #expect(ReviewBaseline.decodeKeyed(try #require(project.reviewedIDsByDay))?[
            MediaSelection.photosOnly.rawValue]?[july5] == ["p1"])   // … and no baseline recorded

        await harness.session.openReview(project)
        #expect(!harness.done.doneDays.contains(july5))         // the gained photo re-opens its day (D32(d))
    }

    /// The #289 hole: the Overview never reconciles, so the media picker is reachable before any
    /// reconcile ran on an upgraded album. The legacy blob must therefore be stamped with its true lens
    /// on the Overview's OPEN (activate) — or switching the lens then entering the grid adopts a
    /// photos-only baseline for the new lens and un-marks every done day holding a video.
    @Test("openOverview → lens switch → openReview keeps done days that hold a video (legacy baseline, #289)")
    func legacyBaselineSurvivesLensSwitchBeforeGrid() async throws {
        let harness = try SessionHarness(assets: [
            AssetRef(id: "p1", captureDate: july5Noon),
            AssetRef(id: "v1", captureDate: july5Noon.addingTimeInterval(60), isVideo: true, duration: 5)
        ])
        let project = harness.album()
        project.doneDays = [july5.description]
        project.reviewedIDsByDay = try JSONEncoder().encode([july5.description: ["p1"]])   // the pre-#273 shape

        await harness.session.openOverview(project)   // land on the Overview
        project.media = .photosAndVideos             // Settings: switch the lens
        await harness.session.openReview(project)     // drill into the grid

        #expect(harness.done.doneDays.contains(july5))
        let persisted = try #require(try harness.persisted(project))
        #expect(persisted.doneDays == [july5.description])
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
