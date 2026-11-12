//
//  AlbumSession.swift
//  PoimiApp — the open album's review session, lifted out of the views (#297, control plane slice B;
//  docs/plans/control-plane.md §3/§4 B).
//
//  One `@MainActor @Observable` owner for what used to run inside view `.task`s, in two diverging copies
//  (`AlbumOverviewView` and `ScanningView`, the latter without the timeline cache):
//
//      open(project, reconcile:) = activate selection + done
//                                → get-or-create the album's `CandidateStore` (always with the shared
//                                  `TimelineCache`, the graph's calendar, naming + name cache)
//                                → load it (once; a second caller awaits the in-flight load)
//                                → optionally reconcile done-state (the grid does; the Overview doesn't, #289)
//                                → publish the review context the viewer / grid / export read.
//
//  It also owns the album's `ExportStore` (initial `.idle`), so an export runs exactly once per entry —
//  never twice from a view re-appearing (an iPad size-class flip rebuilds the whole tree) or from a second
//  caller. Navigation stays the `AppCoordinator`'s; it tells the session when the album closes
//  (`AppCoordinator.onCloseAlbum`), and the session drops the scan, the review context and the export.
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
    /// The in-flight load and the store it is loading, so a second `open` awaits it instead of
    /// returning before the scan settled (or starting a second load).
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var scanTaskStore: ObjectIdentifier?
    @ObservationIgnored private var scanGeneration = 0

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

    /// The open album's export. Starts `.idle`; `startExport` runs it once, the error screen's buttons
    /// re-run it. Replaced (back to `.idle`) when the album closes or another album opens.
    private(set) var export: ExportStore

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
    /// hold the store (and render its `.scanning` phase) before awaiting `open`.
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
        return store
    }

    /// Open `project` for review: hydrate selection + done (idempotent — re-entry never clobbers unflushed
    /// picks or done-days), get-or-create its store, load it unless it already loaded (awaiting a load
    /// another caller started), then — on `.ready` — reconcile done-state if asked and publish the review
    /// context.
    ///
    /// `reconcile` is the one intended difference between the two review entry points: the grid
    /// (`ScanningView`) reconciles — a done day that gained a photo since the last load re-opens (D32(d)) —
    /// while the Overview does NOT (#289): its done-state is display-only, and the per-lens baseline is
    /// recorded only where the user actually reviews. Don't make the Overview reconcile without revisiting
    /// #289's reasoning.
    @discardableResult
    func open(_ project: CurationProject, reconcile: Bool) async -> CandidateStore {
        selection.activate(project)
        done.activate(project)
        let store = candidateStore(for: project)
        if store.phase == .idle {
            await load(store, project, reconcile: reconcile)
        } else {
            // Another screen's load may still be running (a fast drill-in): wait for it, then settle with
            // THIS caller's reconcile choice. Already settled → reconcile + publish synchronously.
            if scanTaskStore == ObjectIdentifier(store), let scanTask { await scanTask.value }
            settle(store, project, reconcile: reconcile)
        }
        return store
    }

    /// Re-run the scan for `project` on its current store (the "Try again" / access-recovered paths), then
    /// settle it like `open`.
    func rescan(_ project: CurationProject, reconcile: Bool) async {
        selection.activate(project)
        done.activate(project)
        await load(candidateStore(for: project), project, reconcile: reconcile)
    }

    /// Load `store` in a task other callers can await, and settle it in the SAME main-actor turn the load
    /// lands `.ready` — so no frame ever shows the grid before its done-state is reconciled and its
    /// review context published (the inline order the view `.task`s had).
    private func load(_ store: CandidateStore, _ project: CurationProject, reconcile: Bool) async {
        scanGeneration += 1
        let generation = scanGeneration
        let task = Task { [weak self] in
            await store.load(project)
            guard let self else { return }
            // Done loading: a later `open` of the settled store then settles synchronously (no await).
            if scanGeneration == generation {
                scanTask = nil
                scanTaskStore = nil
            }
            settle(store, project, reconcile: reconcile)
        }
        scanTask = task
        scanTaskStore = ObjectIdentifier(store)
        await task.value
    }

    /// Reconcile + publish a settled scan — but only if the store is still the session's (a newer key or a
    /// closed album must not publish a stale scan) and it's `.ready`.
    private func settle(_ store: CandidateStore, _ project: CurationProject, reconcile: Bool) {
        guard store === candidateStore, case .ready(let clusters) = store.phase else { return }
        if reconcile {
            // A done day that gained a photo since the last load re-opens, so the collapse never hides a
            // new unreviewed photo (D32(d)). Only on a real `.ready` — an empty/failed load would record a
            // bogus (empty) baseline.
            done.reconcile(currentIDsByDay: Self.idsByDay(store.dayByID))
        }
        reviewOrderedIDs = clusters.flatMap(\.assetIDs)
        reviewDayByID = store.dayByID
        reviewAssetsByID = store.assetsByID
        reviewClusters = clusters
        reviewIsReExport = project.targetAlbumID != nil
    }

    /// Invert the store's per-photo `id → DayKey` map into the `DayKey → ids` shape the done-state
    /// reconcile diffs against the persisted baseline.
    static func idsByDay(_ dayByID: [String: DayKey]) -> [DayKey: Set<String>] {
        var out: [DayKey: Set<String>] = [:]
        for (id, day) in dayByID { out[day, default: []].insert(id) }
        return out
    }

    // MARK: - Export

    /// Run the export for `project` with the live picks — once: a no-op unless the export is `.idle`, so a
    /// re-appearing export screen (or a second caller) can never export twice. Re-runs after a failure go
    /// through `retryExport`.
    func startExport(_ project: CurationProject) async {
        adopt(project)
        selection.activate(project)
        done.activate(project)
        guard export.phase == .idle else { return }
        await export.run(project: project, picks: selection.selected)
    }

    /// Re-run the export (the error screen's "Try again" / "Create a new album instead").
    func retryExport(_ project: CurationProject, forceNewAlbum: Bool = false) async {
        adopt(project)
        await export.run(project: project, picks: selection.selected, forceNewAlbum: forceNewAlbum)
    }

    /// Return the export to `.idle` (e.g. after a reset), unless one is running.
    func resetExport() {
        if case .exporting = export.phase { return }
        export = ExportStore(library: library)
    }

    // MARK: - Lifecycle

    /// Drop the scan, the review context and the export (an album switch, back to the library root, a
    /// launch restore). Selection / done activation is left alone — the next `activate` flushes it.
    func close() {
        projectID = nil
        candidateStore = nil
        candidateStoreKey = nil
        scanTask = nil
        scanTaskStore = nil
        reviewOrderedIDs = []
        reviewDayByID = [:]
        reviewAssetsByID = [:]
        reviewClusters = []
        reviewIsReExport = false
        if export.phase != .idle { export = ExportStore(library: library) }
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
