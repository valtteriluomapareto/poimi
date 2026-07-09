//
//  CandidateStore.swift
//  PoimiApp — the review-fetch pipeline (issue #34; architecture §3, D2/D12/D17).
//
//  Given a `CurationProject`, this drives the two-call fetch tier behind the `PhotoLibrary`
//  actor and applies the two exact source filters, producing the candidate set the review grid
//  (#35) renders:
//
//      1. fetch the project's date-range assets               (oldest → newest)
//      2. resolve the excluded albums → their member asset ids (set-difference input)
//      3. `Filtering.included`: drop screenshots + excluded-album members
//
//  Step 2 is where #33's persisted `excludedAlbumIDs` finally *resolve* into a concrete
//  membership set. The whole thing is a `@MainActor @Observable` so the scanning surface can
//  bind to `phase` and react as the pass settles.
//
//  Scope note: the candidates are materialized flat here — the windowed-by-index snapshot (D17)
//  and its access-counting guard (D29) are #47, which depends on this. The flat array matches
//  the existing `fetchAssets` contract, so this introduces no regression for #47 to undo.
//
//  Grouping lives here, NOT in the review grid's `body` (smoothness review, Finding 1):
//  `DayGrouping.groups` is an O(n log n) sort + bucket over the whole candidate set, so it must
//  run exactly once — when the pass settles to `.ready` — never on a view re-render (a scroll
//  anchor write would otherwise recompute it on the interaction hot path). The `calendar` is
//  owned + injected here so the timezone policy is explicit and testable (rather than implicitly
//  `.current` inside a `body`), and the grouped `.ready` is the value the grid renders directly.
//

import Foundation
import Curation

@MainActor
@Observable
final class CandidateStore {
    /// Why a settled pass has no candidates — so the empty state can be actionable (#40, design 2JE):
    /// point at the range vs the exclusions rather than a generic dead-end.
    enum EmptyReason: Equatable {
        /// The date range itself yielded no photos (or the range is inverted). Fix: widen the range.
        case noPhotosInRange
        /// Photos existed in range, but every one was filtered out (screenshots / excluded albums).
        /// Fix: relax the exclusions.
        case allExcluded
    }

    /// Why a pass failed — a transient load error (retry) vs photo access lost mid-session (recover).
    enum FailureReason: Equatable {
        /// The fetch threw while access is still granted — likely iCloud/network. Retryable.
        case loadError
        /// The fetch threw AND photo access is no longer authorized (revoked mid-session, D6/§10).
        /// A retry can't succeed — the app should route to the recovery screen.
        case accessLost
    }

    /// The phases the scanning surface renders. `Equatable` so the view (and tests) can compare
    /// without unwrapping the associated clusters.
    enum Phase: Equatable {
        case idle
        case scanning
        /// The filtered candidates assembled into the review timeline (trip/visit clusters relabelled
        /// over the date day-groups, #130), oldest → newest. Non-empty by construction (empty →
        /// `.empty`). The review grid renders these directly — assembly is done here, once, off-main,
        /// not in the view (Finding 1). With location off (or no trips) every element is a `.day`.
        case ready([ReviewCluster])
        /// Nothing matched the range and filters — a real, expected outcome, not an error (#40).
        case empty(EmptyReason)
        case failed(FailureReason)
    }

    private(set) var phase: Phase = .idle
    /// Each candidate's calendar day, keyed by asset id — the per-photo day the viewer labels with
    /// (#36). `DayGroup` only records the days a group *spans* (a merged quiet run spans several),
    /// so the per-asset day is derived here from `captureDate` under the same `calendar`. Empty
    /// until a pass settles to `.ready`.
    private(set) var dayByID: [String: DayKey] = [:]
    /// Each candidate keyed by id — so the photo viewer can read `captureDate` (for the capture time on
    /// its date line) + `pixelSize` (for the resolution in its info panel) synchronously, without a
    /// re-fetch (#127). Empty until a pass settles to `.ready`; published to the coordinator by the review.
    private(set) var assetsByID: [String: AssetRef] = [:]
    /// Resolved place names per trip-cluster id (`TripCluster.clusterID`) — fills in asynchronously
    /// after `.ready` as reverse-geocoding settles (§7). A trip whose name hasn't resolved yet shows a
    /// date fallback; `nil` naming deps (tests / location off) leaves this empty. `@Observable` drives
    /// the label refresh with no live-recompute of the timeline.
    private(set) var tripNames: [String: String] = [:]

    private let library: any PhotoLibraryProviding
    /// The calendar the timeline buckets by. Injected (default `.current`) so the timezone policy is
    /// explicit and a test can pin it — and so a locale/timezone change is a property of this store.
    private let calendar: Calendar
    /// Whether to overlay trip/visit clusters (v1.1). `false` → the timeline is byte-identical to the
    /// date-only day-grouping (the v1 path). Default on now that the location layer is validated.
    private let locationEnabled: Bool
    /// The reverse-geocoding seam + persistent name cache (#130 Phase 2). `nil` on the debug/test
    /// construction sites (no naming — trips still form, just unlabelled). The production sites inject
    /// the environment's `PlaceNaming` + a `NameCacheStore` over the app container.
    private let naming: (any PlaceNaming)?
    private let nameCache: NameCacheStore?
    /// The per-album timeline cache (#130). `nil` on the debug/test sites (always recompute). When set,
    /// a repeat open with an unchanged photo set skips the seconds of clustering and re-reads the result.
    private let timelineCache: TimelineCache?
    /// The in-flight trip-name resolution — cancelled when a new load starts, so a stale pass never
    /// publishes names for a superseded album/setting. Detached from `.ready` so naming never blocks it.
    private var nameTask: Task<Void, Never>?
    /// Monotonic load token: the name pass only publishes if it's still the current load — guards the
    /// retry paths (`onRetry`/`onRecovered`) that re-enter `load()` without cancelling the prior `.task`.
    private var loadGeneration = 0

    /// Where an album-open's time goes — fetch vs cluster vs naming — so we can target caching at the
    /// real bottleneck. Populated each `load`; `namingMillis`/`namesResolved` fill in when the detached
    /// name pass completes. Just measured data (no behaviour); a copyable summary is surfaced from
    /// Album Settings in DEBUG (`ScanReport.text`).
    private(set) var scanReport: ScanReport?

    struct ScanReport: Sendable {
        let albumTitle: String
        let candidateCount: Int
        let clusterCount: Int
        let tripCount: Int
        let fetchMillis: Double
        let clusterMillis: Double
        var namingMillis: Double?
        var namesResolved: Int?
        var cacheHits: Int?       // names served from the persistent cache
        var geocoded: Int?        // names freshly reverse-geocoded (cache miss)
        var cacheRows: Int?       // total rows in the name cache after the pass (0 ⇒ saves not persisting)
        let locationEnabled: Bool
        let cached: Bool          // clusters served from the timeline cache (⇒ clustering was skipped)

        /// A one-screen, copyable summary (shared per-album to see where the open time goes).
        var text: String {
            let naming: String
            if let namingMillis {
                naming = "\(Int(namingMillis)) ms — \(cacheHits ?? 0) cache hits, \(geocoded ?? 0) geocoded"
                    + " (\(namesResolved ?? 0) named; cache rows: \(cacheRows.map(String.init) ?? "—"))"
            } else {
                naming = "pending…"
            }
            return """
            Poimi scan diagnostics — \(albumTitle)
            location grouping: \(locationEnabled ? "on" : "off")
            candidates: \(candidateCount)
            clusters: \(clusterCount) (\(tripCount) trips)
            fetch:   \(Int(fetchMillis)) ms
            cluster: \(Int(clusterMillis)) ms\(cached ? " (cached — fingerprint + reload, no clustering)" : "")
            naming:  \(naming)
            """
        }
    }

    init(library: any PhotoLibraryProviding,
         calendar: Calendar = .current,
         locationEnabled: Bool = true,
         naming: (any PlaceNaming)? = nil,
         nameCache: NameCacheStore? = nil,
         timelineCache: TimelineCache? = nil) {
        self.library = library
        self.calendar = calendar
        self.locationEnabled = locationEnabled
        self.naming = naming
        self.nameCache = nameCache
        self.timelineCache = timelineCache
    }

    /// Run the fetch → resolve → filter pass for `project`, publishing each phase as it settles.
    /// Idempotent: callable again (e.g. a "Try again" after `.failed`) — it restarts from
    /// `.scanning`.
    func load(_ project: CurationProject) async {
        phase = .scanning
        dayByID = [:]   // clear any prior pass's map (e.g. a retry after .failed)
        assetsByID = [:]
        tripNames = [:]
        nameTask?.cancel()        // supersede any in-flight name pass from a prior load
        loadGeneration += 1
        let generation = loadGeneration

        // An empty / inverted range has no candidates — and `DateInterval(start:end:)` traps when
        // end < start, so guard before constructing it. Setup disables Create on an inverted range
        // (#33), but a malformed persisted project must degrade to "empty", never crash.
        guard project.rangeEnd > project.rangeStart else {
            phase = .empty(.noPhotosInRange)
            return
        }
        let interval = DateInterval(start: project.rangeStart, end: project.rangeEnd)

        do {
            let fetchStart = Date()
            let fetched = try await library.fetchAssets(in: interval)
            let excludedAssetIDs = try await library.assetIDs(inAlbums: project.excludedAlbumIDs)
            let candidates = Filtering.included(
                fetched,
                excludeScreenshots: project.excludeScreenshots,
                includeVideos: project.includeVideos,
                excludedAssetIDs: excludedAssetIDs)
            let fetchMillis = Date().timeIntervalSince(fetchStart) * 1000
            // Assemble the timeline once, here — the grid renders it directly and never recomputes it
            // (Finding 1). Reuses the cached result for an unchanged photo set, else clusters off-main.
            let clusterStart = Date()
            let (clusters, fromCache) = await assembleTimeline(for: candidates, project: project)
            let clusterMillis = Date().timeIntervalSince(clusterStart) * 1000
            // Per-photo day map for the viewer's label (#36), built from the same candidates +
            // calendar so it agrees with the grouping (a busy day and the viewer read the same day).
            // In practice every value is a real day: a range fetch never returns a nil-capture-date
            // asset, so `.undated` doesn't arise here — the viewer's `.undated` label is defensive
            // (and `DayKey(date: nil,…)`'s mapping is pinned in CurationTests regardless).
            dayByID = Dictionary(
                candidates.map { ($0.id, DayKey(date: $0.captureDate, calendar: calendar)) },
                uniquingKeysWith: { first, _ in first })
            // Keep each candidate reachable by id for the viewer's info panel (#127) — same source array.
            assetsByID = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            if clusters.isEmpty {
                // Distinguish WHY it's empty so the state is actionable (#40): the range yielded
                // nothing (widen it) vs photos existed but were all filtered out (relax exclusions).
                phase = .empty(fetched.isEmpty ? .noPhotosInRange : .allExcluded)
            } else {
                phase = .ready(clusters)
                scanReport = ScanReport(
                    albumTitle: project.title, candidateCount: candidates.count,
                    clusterCount: clusters.count,
                    tripCount: clusters.filter { $0.tripCluster != nil }.count,
                    fetchMillis: fetchMillis, clusterMillis: clusterMillis,
                    namingMillis: nil, namesResolved: nil, locationEnabled: locationEnabled,
                    cached: fromCache)
                // Resolve trip place names in a DETACHED, cancellable task — geocoding is network-bound
                // and slow (§7), so it must never block `.ready` (the grid/viewer publish + done reconcile
                // happen as soon as we return). Names fill into `tripNames` when the pass completes
                // (cache-fast on repeat opens); trips show a date fallback until then.
                nameTask = Task { [weak self] in
                    await self?.resolveTripNames(in: clusters, generation: generation)
                }
            }
        } catch {
            Log.photoLibrary.error("CandidateStore.load failed: \(String(describing: error), privacy: .public)")
            // A transient load error is retryable; but if access was revoked mid-session the fetch
            // fails for good — re-check authorization so the view can route to recovery instead of a
            // retry that can't succeed (#40, D6/§10).
            let stillAuthorized = await library.authorizationStatus() == .authorized
            phase = .failed(stillAuthorized ? .loadError : .accessLost)
        }
    }

    /// Assemble the review timeline for `candidates`, reusing the cached result when this exact photo
    /// set + options were already clustered (keyed by a fingerprint, so a range/exclusion edit or a
    /// re-geotag misses). A miss clusters OFF the main actor — clustering (DBSCAN over the located set)
    /// is heavier than the old day-grouping, so a detached task keeps it off the UI thread — and persists
    /// the result for next time. `timelineCache == nil` (debug/test) always recomputes. With location off
    /// (or no trips) the result is the date-only day-grouping wrapped as `.day` clusters. Returns whether
    /// the clusters came from the cache (for the scan report).
    ///
    /// - Note: on a cache HIT the small residual cost (fingerprint sort+hash + file reload) is still
    ///   counted in the caller's `clusterMillis`; the clustering itself is what's skipped. The fetch that
    ///   produced `candidates` (~1 s) is the remaining per-open floor — the cache doesn't touch it.
    private func assembleTimeline(
        for candidates: [AssetRef], project: CurationProject
    ) async -> (clusters: [ReviewCluster], fromCache: Bool) {
        let locationOn = locationEnabled
        let cal = calendar
        let fingerprint = TimelineCache.fingerprint(
            candidates: candidates, locationEnabled: locationOn, calendar: cal)
        if let cached = await timelineCache?.lookup(projectID: project.id, fingerprint: fingerprint) {
            return (cached, true)
        }
        let clusters = await Task.detached(priority: .userInitiated) {
            ReviewTimeline.clusters(for: candidates, calendar: cal, locationEnabled: locationOn)
        }.value
        await timelineCache?.store(projectID: project.id, fingerprint: fingerprint, clusters: clusters)
        return (clusters, false)
    }

    /// Reverse-geocode the trip places (§7) and publish `tripNames`. No-ops without naming deps
    /// (debug/test) or when there are no trips. Serial + cache-backed inside `LocationPreprocessor`;
    /// a superseding `load()` cancels this task before it can publish stale names.
    private func resolveTripNames(in clusters: [ReviewCluster], generation: Int) async {
        guard locationEnabled, let naming, let nameCache else { return }
        // Name the ALREADY-computed trip places (clusterID + medoid coordinate from the timeline) — no
        // re-clustering here (that was the real cost behind "slow naming", not the cache).
        let places: [(clusterID: String, medoid: Coordinate)] = clusters.compactMap { cluster in
            guard let trip = cluster.tripCluster, let medoid = trip.medoid else { return nil }
            return (trip.clusterID, medoid)
        }
        guard !places.isEmpty else { return }
        let preprocessor = LocationPreprocessor(naming: naming, cache: nameCache)
        let namingStart = Date()
        let names = await preprocessor.resolveNames(forPlaces: places)
        // Only publish if this is still the current load (a newer load bumps the token / cancels us).
        guard generation == loadGeneration, !Task.isCancelled else { return }
        tripNames = names
        // Record the naming cost + cache stats (hits vs geocodes, and whether the cache persisted).
        scanReport?.namingMillis = Date().timeIntervalSince(namingStart) * 1000
        scanReport?.namesResolved = names.count
        scanReport?.cacheHits = await preprocessor.lastCacheHits
        scanReport?.geocoded = await preprocessor.lastGeocoded
        scanReport?.cacheRows = await nameCache.count()
    }

    /// The display label for a trip cluster: the resolved place sentence ("Week in Salo"), or `nil`
    /// until the name arrives — the caller then falls back to the date range. Date clusters keep their
    /// existing date title (`DayGroupHeader`), unchanged.
    func tripLabel(for trip: TripCluster) -> String? {
        tripNames[trip.clusterID].map { TripLabel.sentence(for: trip.shape, place: $0) }
    }

    /// Await the in-flight trip-name resolution — the pass is detached from `.ready`, so a test (or a
    /// caller that needs settled names) awaits it here rather than after `load()`. No-op if idle.
    func awaitPendingNames() async { await nameTask?.value }
}
