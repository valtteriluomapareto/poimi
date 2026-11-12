//
//  AlbumSession.swift
//  PoimiApp — the open album's review session, lifted out of the views (#297, control plane slice B;
//  docs/plans/control-plane.md §3/§4 B).
//
//  One `@MainActor @Observable` owner for what used to run inside view `.task`s, in two diverging copies
//  (`AlbumOverviewView` and `ScanningView`, the latter without the timeline cache):
//
//      openOverview / openReview = activate selection + done
//                                → get-or-create the album's `CandidateStore` (always with the shared
//                                  `TimelineCache`, the graph's calendar, naming + name cache)
//                                → load it ONCE (a second caller awaits the in-flight load)
//                                → reconcile done-state (`openReview` only — the Overview doesn't, #289)
//                                → publish the review context the viewer / grid / export read.
//
//  It also owns the album's `ExportStore` (initial `.idle`), so an export runs exactly once per visit to
//  the export screen — never twice from a view re-appearing (an iPad size-class flip rebuilds the whole
//  tree), a second caller or a double-tap. Navigation stays the `AppCoordinator`'s: it tells the session
//  when the album closes (`onCloseAlbum`) and when the export screen leaves the path (`onLeaveExport`),
//  from one choke point on its `path` — so a NavigationStack back-swipe counts too.
//
//  Built by `AppGraph` with every dependency, so it runs with no view mounted (the control plane's
//  headless host and the integration tests drive it directly).
//

import Foundation
import Observation
import Curation

@MainActor
@Observable
final class AlbumSession {
    /// Identity of a scanned store — a change in any field means a genuinely different candidate set, so
    /// the store is rebuilt (and every `.task(id:)` keyed on it re-fires). Covers the fetch inputs
    /// (`start`/`end`), the clustering setting (`locationEnabled`), AND the source filters
    /// (`excludeScreenshots` / `excludedAlbumIDs` / `includeVideos` / `includePhotos`) — a Settings edit to
    /// any filter must re-scan too, else the grid keeps showing the old candidate set. `excludedAlbumIDs`
    /// is sorted so the picker's unordered `Set` edits don't churn the key spuriously.
    struct CandidateStoreKey: Equatable {
        let id: UUID
        let start: Date
        let end: Date
        let locationEnabled: Bool
        let excludeScreenshots: Bool
        let excludedAlbumIDs: [String]
        let includeVideos: Bool
        let includePhotos: Bool
        init(_ project: CurationProject) {
            id = project.id
            start = project.rangeStart
            end = project.rangeEnd
            locationEnabled = project.locationEnabled
            excludeScreenshots = project.excludeScreenshots
            excludedAlbumIDs = project.excludedAlbumIDs.sorted()
            includeVideos = project.includeVideos
            includePhotos = project.includePhotos
        }
    }

    // MARK: - Dependencies

    @ObservationIgnored private let library: any PhotoLibraryProviding
    @ObservationIgnored private let naming: (any PlaceNaming)?
    @ObservationIgnored private let nameCache: NameCacheStore?
    @ObservationIgnored private let timelineCache: TimelineCache?
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private let selection: SelectionStore
    @ObservationIgnored private let done: DoneStore

    // MARK: - The open album

    /// The album this session holds a scan / review context / export for, or `nil` when closed.
    private(set) var projectID: UUID?

    /// The album's scanned candidate store — created ONCE by whichever screen opens first (the Overview,
    /// in the real navigation path) and REUSED by the grid, so drilling in doesn't re-fetch + re-cluster.
    /// Keyed by `CandidateStoreKey`; a Settings edit that changes the key yields a fresh store.
    private(set) var candidateStore: CandidateStore?
    @ObservationIgnored private var candidateStoreKey: CandidateStoreKey?
    /// The in-flight load and the store it is loading, so a second `open` awaits it instead of starting a
    /// second load (or returning before the scan settled).
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var scanTaskStore: ObjectIdentifier?
    @ObservationIgnored private var scanGeneration = 0
    /// A caller waiting on the in-flight load asked to reconcile — the load's own settle honours it, so the
    /// reconcile lands in the same turn as `.ready` even when the load was started by the Overview.
    @ObservationIgnored private var pendingReconcile = false
    /// The store whose current load has been reconciled / published — so a re-entry (each grid entry, a
    /// size-class flip) neither re-runs a no-op reconcile nor republishes the same large collections,
    /// which would invalidate every grid cell and the viewer. Cleared when a load starts.
    @ObservationIgnored private var reconciledStore: ObjectIdentifier?
    @ObservationIgnored private var publishedStore: ObjectIdentifier?
    /// How many times the review context was (re)published — observability for the once-per-load rule
    /// (Observation itself skips equal writes, so a republish is invisible to it but not free: each one
    /// compares the large collections).
    @ObservationIgnored private(set) var publishCount = 0

    // MARK: - Review context (published when a scan settles `.ready`)

    /// The open album's candidate ids in chronological order — the list the photo viewer pages through
    /// (#36). Empty when no review is open.
    private(set) var reviewOrderedIDs: [String] = []
    /// Each candidate's calendar day, keyed by asset id — the per-photo day the viewer labels with (#36)
    /// and the completion stats count from (#39). Empty when no review is open.
    private(set) var reviewDayByID: [String: DayKey] = [:]
    /// Each candidate keyed by id — the viewer reads `captureDate` + `pixelSize` from this synchronously
    /// (#127); the grid reads `isVideo`. Empty when no review is open.
    private(set) var reviewAssetsByID: [String: AssetRef] = [:]
    /// The open album's review clusters. The viewer reads them to detect paging FORWARD past a cluster's
    /// last photo (auto-mark-done, #128); the grid restores its page to the cluster of `lastViewedID` on
    /// return from the viewer (#126). Empty when no review is open.
    private(set) var reviewClusters: [ReviewCluster] = []
    /// Whether the open album already has a Photos album (`targetAlbumID != nil`) — so the finish-action
    /// affordances (#187) pick #185's re-export-aware label without holding a `CurationProject`.
    private(set) var reviewIsReExport = false

    // MARK: - Export

    /// The open album's export for the current visit to the export screen. Starts `.idle`; `startExport`
    /// runs it once, the error screen's buttons re-run it. Retired (a fresh `.idle` store) when the export
    /// screen leaves the path or the album closes — a run still in flight finishes on the retired store.
    private(set) var export: ExportStore
    /// Albums with an export run in flight (on the current store or a retired one). `AlbumActions` refuses
    /// to delete or reset these, so a run never writes into a deleted or just-zeroed album.
    private(set) var exportingAlbums: Set<UUID> = []

    init(library: any PhotoLibraryProviding,
         naming: (any PlaceNaming)?,
         nameCache: NameCacheStore?,
         timelineCache: TimelineCache?,
         calendar: Calendar,
         selection: SelectionStore,
         done: DoneStore) {
        self.library = library
        self.naming = naming
        self.nameCache = nameCache
        self.timelineCache = timelineCache
        self.calendar = calendar
        self.selection = selection
        self.done = done
        export = ExportStore(library: library)
    }

    // MARK: - Scan

    /// The scanned store for `project` — the existing one when the key is unchanged (so the Overview and
    /// the grid share ONE scan), or a fresh, not-yet-loaded one otherwise. Synchronous, so a screen can
    /// hold the store (and render its scanning phase) before awaiting `openOverview` / `openReview`.
    func candidateStore(for project: CurationProject) -> CandidateStore {
        adopt(project)
        let key = CandidateStoreKey(project)
        if candidateStoreKey == key, let candidateStore { return candidateStore }
        let store = CandidateStore(library: library, calendar: calendar,
                                   locationEnabled: project.locationEnabled,
                                   naming: naming, nameCache: nameCache,
                                   timelineCache: timelineCache)
        candidateStore = store
        candidateStoreKey = key
        scanTask = nil
        scanTaskStore = nil
        pendingReconcile = false
        return store
    }

    /// The Overview's entry: hydrate, scan (or reuse the scan), publish — WITHOUT reconciling done-state.
    /// The Overview's done-state is display-only and the per-lens baseline is recorded only where the user
    /// actually reviews (#289) — don't make this reconcile without revisiting #289's reasoning.
    @discardableResult
    func openOverview(_ project: CurationProject) async -> CandidateStore {
        await open(project, reconcile: false)
    }

    /// The review grid's entry: hydrate, scan (or reuse the scan), reconcile done-state — a done day that
    /// gained a photo since the last load re-opens (D32(d)) — and publish.
    @discardableResult
    func openReview(_ project: CurationProject) async -> CandidateStore {
        await open(project, reconcile: true)
    }

    /// Re-run the scan (the Overview's "Try again" / access-recovered paths), then settle like `openOverview`.
    func rescanOverview(_ project: CurationProject) async {
        await rescan(project, reconcile: false)
    }

    /// Re-run the scan (the grid's "Try again" / access-recovered paths), then settle like `openReview`.
    func rescanReview(_ project: CurationProject) async {
        await rescan(project, reconcile: true)
    }

    /// Hydrate selection + done (idempotent — re-entry never clobbers unflushed picks or done-days),
    /// get-or-create the store, then: await a load already in flight for it, or load it if it never was,
    /// and settle with this caller's `reconcile` choice.
    private func open(_ project: CurationProject, reconcile: Bool) async -> CandidateStore {
        selection.activate(project)
        done.activate(project)
        let store = candidateStore(for: project)
        if scanTaskStore == ObjectIdentifier(store), let scanTask {
            // Checked BEFORE `.idle`: the load runs in a task, so its store reads `.idle` until that task
            // first runs — a second caller in that window must join it, not start a second fetch.
            if reconcile { pendingReconcile = true }
            await scanTask.value
            settle(store, project, reconcile: reconcile)
        } else if store.phase == .idle {
            await load(store, project, reconcile: reconcile)
        } else {
            settle(store, project, reconcile: reconcile)   // already settled → synchronous, no await
        }
        return store
    }

    private func rescan(_ project: CurationProject, reconcile: Bool) async {
        selection.activate(project)
        done.activate(project)
        await load(candidateStore(for: project), project, reconcile: reconcile)
    }

    /// Load `store` in a task other callers can await, and settle it in the same main-actor turn the load
    /// lands `.ready` — reconciling if this caller or any caller waiting on the load asked to — so the grid
    /// never draws a `.ready` frame with a stale done-state or an unpublished review context.
    private func load(_ store: CandidateStore, _ project: CurationProject, reconcile: Bool) async {
        scanGeneration += 1
        let generation = scanGeneration
        reconciledStore = nil
        publishedStore = nil
        pendingReconcile = reconcile
        let task = Task { [weak self] in
            await store.load(project)
            guard let self, scanGeneration == generation else { return }   // superseded by a newer load
            scanTask = nil
            scanTaskStore = nil
            let reconcileNow = pendingReconcile
            pendingReconcile = false
            settle(store, project, reconcile: reconcileNow)
        }
        scanTask = task
        scanTaskStore = ObjectIdentifier(store)
        await task.value
    }

    /// Reconcile + publish a settled scan — only if the store is still the session's (a newer key or a
    /// closed album must not publish a stale scan) and it's `.ready`. Each load is reconciled and
    /// published at most once; a re-entry only refreshes the cheap re-export flag.
    private func settle(_ store: CandidateStore, _ project: CurationProject, reconcile: Bool) {
        guard store === candidateStore, case .ready(let clusters) = store.phase else { return }
        let identity = ObjectIdentifier(store)
        if reconcile, reconciledStore != identity {
            // A done day that gained a photo since the last load re-opens, so the collapse never hides a
            // new unreviewed photo (D32(d)). Only on a real `.ready` — an empty/failed load would record a
            // bogus (empty) baseline. Once per load: against the same candidate set it's a no-op.
            done.reconcile(currentIDsByDay: Self.idsByDay(store.dayByID))
            reconciledStore = identity
        }
        if publishedStore != identity {
            reviewOrderedIDs = clusters.flatMap(\.assetIDs)
            reviewDayByID = store.dayByID
            reviewAssetsByID = store.assetsByID
            reviewClusters = clusters
            publishedStore = identity
            publishCount += 1
        }
        let isReExport = project.targetAlbumID != nil
        if reviewIsReExport != isReExport { reviewIsReExport = isReExport }
    }

    /// Invert the store's per-photo `id → DayKey` map into the `DayKey → ids` shape the done-state
    /// reconcile diffs against the persisted baseline.
    static func idsByDay(_ dayByID: [String: DayKey]) -> [DayKey: Set<String>] {
        var out: [DayKey: Set<String>] = [:]
        for (id, day) in dayByID { out[day, default: []].insert(id) }
        return out
    }

    // MARK: - Export

    /// Run the export for `project` with the live picks — once per visit to the export screen: a no-op
    /// unless the export is `.idle`, so a re-appearing export screen or a second caller can never export
    /// twice. Re-runs after a failure go through `retryExport`.
    func startExport(_ project: CurationProject) async {
        adopt(project)
        selection.activate(project)
        done.activate(project)
        guard export.phase == .idle else { return }
        await run(export, project, forceNewAlbum: false)
    }

    /// Re-run the export (the error screen's "Try again" / "Create a new album instead") — a no-op while a
    /// run is in flight, so a double-tap can't create two albums.
    func retryExport(_ project: CurationProject, forceNewAlbum: Bool = false) async {
        adopt(project)
        guard !export.phase.isRunning else { return }
        await run(export, project, forceNewAlbum: forceNewAlbum)
    }

    /// Whether an export for `project` is in flight (on the current store or a retired one).
    func isExporting(_ project: CurationProject) -> Bool { exportingAlbums.contains(project.id) }

    private func run(_ store: ExportStore, _ project: CurationProject, forceNewAlbum: Bool) async {
        let id = project.id
        exportingAlbums.insert(id)
        defer { exportingAlbums.remove(id) }
        await store.run(project: project, picks: selection.selected, forceNewAlbum: forceNewAlbum)
    }

    /// The export screen left the path: the next visit starts a fresh run (a later "Save to Photos" after
    /// going back must export again, not show the last result).
    func exportScreenClosed() {
        retireExport()
    }

    /// Swap in a fresh `.idle` export. A run still in flight keeps going on the retired store — its writes
    /// go to its own album, which `AlbumActions` won't delete or reset until it finishes.
    private func retireExport() {
        if export.phase != .idle { export = ExportStore(library: library) }
    }

    // MARK: - Lifecycle

    /// Drop the scan, the review context and the export (the album closed: a switch, back to the library
    /// root, a back-swipe out of it, a launch restore, a delete). Selection / done activation is left alone —
    /// the next `activate` flushes it.
    func close() {
        // Idempotent without churn: a second close (the coordinator's explicit one + its path hook) must
        // not write the observed properties again.
        guard projectID != nil || candidateStore != nil || !reviewOrderedIDs.isEmpty || export.phase != .idle
        else { return }
        projectID = nil
        candidateStore = nil
        candidateStoreKey = nil
        scanTask = nil
        scanTaskStore = nil
        pendingReconcile = false
        reconciledStore = nil
        publishedStore = nil
        reviewOrderedIDs = []
        reviewDayByID = [:]
        reviewAssetsByID = [:]
        reviewClusters = []
        reviewIsReExport = false
        retireExport()
    }

    /// Make `project` the session's album — closing whatever another album left behind.
    private func adopt(_ project: CurationProject) {
        guard projectID != project.id else { return }
        close()
        projectID = project.id
    }

    #if DEBUG
    /// DEBUG screenshot harness only: publish a review context without a scan (the viewer host renders
    /// a hand-picked candidate list).
    func seedReviewContext(orderedIDs: [String], dayByID: [String: DayKey], assetsByID: [String: AssetRef]) {
        reviewOrderedIDs = orderedIDs
        reviewDayByID = dayByID
        reviewAssetsByID = assetsByID
    }
    #endif
}

extension ExportStore.Phase {
    /// An export is in flight.
    var isRunning: Bool {
        if case .exporting = self { return true }
        return false
    }
}
