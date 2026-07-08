//
//  AppCoordinator.swift
//  PoimiApp — the adaptive navigation spine (issue #30, D20; architecture §6/§11).
//
//  A `@MainActor @Observable` coordinator owning the typed `Route` path and the authorization
//  state that gates the root phase (onboarding/recovery vs the albums library). The UI binds to
//  it; auth status drives `rootPhase`. One logical path expressed in two containers (compact
//  `NavigationStack`, regular `NavigationSplitView` detail stack) — see `AppRootView`.
//
//  It reads only the `PhotoLibraryProviding` seam (Phase 1), never PhotoKit directly, so it is
//  fully testable against `FakePhotoLibrary` with any seeded authorization.
//

import Foundation
import Observation
import Curation

@MainActor
@Observable
final class AppCoordinator {
    private let library: any PhotoLibraryProviding

    /// Current authorization (D6). Drives `rootPhase`; refreshed on launch/resume and after a
    /// prompt. Starts `.notDetermined` until the first `refreshAuthorization()`.
    private(set) var authorization: LibraryAuthorization = .notDetermined

    /// The typed navigation path below the albums root (bound to the `NavigationStack`).
    var path: [Route] = []

    /// The open album's candidate ids in chronological order — the list the photo viewer pages
    /// through (#36). Set by the review screen when its fetch settles; empty when no review is open.
    var reviewOrderedIDs: [String] = []

    /// Each candidate's calendar day, keyed by asset id — the per-photo day the viewer labels with
    /// (#36). Published by the review screen alongside `reviewOrderedIDs`; empty when no review is
    /// open (the viewer then just shows the position, no day label).
    var reviewDayByID: [String: DayKey] = [:]

    /// The open album's review clusters, published alongside `reviewOrderedIDs`. The viewer reads them
    /// to detect paging FORWARD past a cluster's last photo (auto-mark-done, #128); the grid reads them
    /// to restore its page to the cluster of `lastViewedID` on return from the viewer (#126). Empty when
    /// no review is open.
    var reviewClusters: [ReviewCluster] = []

    /// The asset last viewed in the grid / viewer. The grid restores its scroll to it on return
    /// from the viewer (D22); set on cell tap and updated as the viewer swipes. Shared so scroll
    /// position survives the round-trip.
    var lastViewedID: String?

    /// The photo viewer, presented as a `.sheet` (a Now-Playing-style modal card) rather than a path
    /// push — you pull it DOWN to dismiss (the sheet owns the interactive drag), never a sideways
    /// nav-pop (#36). `nil` when closed; the grid stays mounted underneath, exactly where you left it.
    var presentedPhotoID: String?

    /// The active album's scanned candidate store, created ONCE by whichever review screen loads first
    /// (the Overview, in the real navigation path) and REUSED by the grid — so drilling in doesn't
    /// re-fetch + re-cluster the whole album (the double-scan the review flagged). Keyed by album +
    /// range + location setting; a Settings edit that changes any of those yields a fresh store on the
    /// next scan. Cleared on an album switch to free it.
    private(set) var candidateStore: CandidateStore?
    private var candidateStoreKey: CandidateStoreKey?

    /// The shared, cross-album review-timeline cache (#130) — one instance keyed internally by album id,
    /// so clustering is skipped on any repeat open of an unchanged album (even after a relaunch or an
    /// album switch that freed the in-memory store). Injected into each `CandidateStore` the review
    /// screens build; the SAME instance is handed to `ProjectStore` so a delete drops the cache file.
    let timelineCache: TimelineCache

    /// Identity of a scanned store — a change in any field means a genuinely different candidate set.
    struct CandidateStoreKey: Equatable {
        let id: UUID
        let start: Date
        let end: Date
        let locationEnabled: Bool
        init(_ project: CurationProject) {
            id = project.id
            start = project.rangeStart
            end = project.rangeEnd
            locationEnabled = project.locationEnabled
        }
    }

    init(library: any PhotoLibraryProviding, timelineCache: TimelineCache = TimelineCache()) {
        self.library = library
        self.timelineCache = timelineCache
    }

    /// The scanned candidate store for `project` — the existing one when the album/range/location are
    /// unchanged (so the Overview + grid share ONE scan), or a fresh one via `make` otherwise. `make`
    /// runs only on a miss, so the caller's environment deps are used just when a new scan is needed.
    func candidateStore(for project: CurationProject, make: () -> CandidateStore) -> CandidateStore {
        let key = CandidateStoreKey(project)
        if candidateStoreKey == key, let candidateStore { return candidateStore }
        let store = make()
        candidateStore = store
        candidateStoreKey = key
        return store
    }

    private func clearCandidateStore() {
        candidateStore = nil
        candidateStoreKey = nil
        // Drop the published review context too, so a switched-away album's ids/clusters can't linger
        // until the next scan republishes (tidiness; the viewer/grid also guard by cluster membership).
        reviewOrderedIDs = []
        reviewDayByID = [:]
        reviewClusters = []
        lastViewedID = nil
    }

    /// The album at the root of the current path — the one shown in the iPad detail column — or `nil`
    /// at the albums root / app-settings. Drives the split-view sidebar's selection highlight (#42).
    var activeAlbumID: UUID? {
        switch path.first {
        case .albumOverview(let id), .review(let id, _), .export(let id), .settings(let id): id
        case .appSettings, nil: nil
        }
    }

    /// Where the app should be, derived from authorization — never stored (single source of truth).
    var rootPhase: RootPhase {
        switch authorization {
        case .authorized: .albums
        case .notDetermined: .onboarding
        case .limited, .denied, .restricted: .recovery
        }
    }

    // MARK: - Authorization (D6)

    /// Read the current status without prompting (launch / resume).
    func refreshAuthorization() async {
        authorization = await library.authorizationStatus()
    }

    /// Drive the system prompt and adopt the resolved status.
    func requestAuthorization() async {
        authorization = await library.requestAuthorization()
    }

    // MARK: - Navigation (typed path)

    /// Open an album to its overview (the level above the selection grid). Resets the path so
    /// switching albums from the library starts a fresh stack.
    func openProject(_ id: UUID) {
        presentedPhotoID = nil          // dismiss any open viewer when switching albums
        clearCandidateStore()           // a different album scans fresh (and frees the old one)
        path = [.albumOverview(id)]
    }

    /// Push the review grid for an album, optionally scrolled to a day-group.
    func openReview(_ projectID: UUID, day: DayKey? = nil) {
        path.append(.review(projectID, day))
    }

    /// Present the photo viewer as a `.sheet` (not a path push — see `presentedPhotoID`).
    /// Records the asset as last-viewed so the grid's scroll anchor is set from the outset.
    func openPhoto(_ assetID: String) {
        Perf.event("openPhoto \(assetID.suffix(8))")   // start of the open span (→ viewer.onAppear)
        lastViewedID = assetID
        presentedPhotoID = assetID
    }

    /// Dismiss the photo-viewer sheet — the single dismiss path (the sheet's `isPresented` binding
    /// routes its pull-down here), so the open→dismiss Perf span stays closed. The grid stays mounted
    /// underneath, revealed exactly where you left it.
    func dismissPhoto() {
        Perf.event("dismissPhoto (→ grid revealed)")
        presentedPhotoID = nil
    }

    /// Push the export / completion step.
    func openExport(_ projectID: UUID) {
        path.append(.export(projectID))
    }

    /// Push the album's settings screen (#41).
    func openSettings(_ projectID: UUID) {
        path.append(.settings(projectID))
    }

    /// Push the app-level settings screen (Photos access + About) — not album-scoped.
    func openAppSettings() {
        path.append(.appSettings)
    }

    /// Pop one route off the path (a within-albums back, e.g. review → overview). Does NOT touch the
    /// viewer sheet — that's `dismissPhoto()`'s job (the viewer is no longer a path route).
    func pop() {
        guard !path.isEmpty else { return }
        Perf.event("pop from \(path.count)")
        path.removeLast()
    }

    /// Back to the albums library root.
    func popToRoot() {
        presentedPhotoID = nil
        clearCandidateStore()
        path.removeAll()
    }

    // MARK: - Lifecycle restore (D20, §11)

    /// Re-open the last-opened album on launch (the album-library "resume" entry). A `nil` id
    /// (no prior project) lands on the library root.
    func restore(lastOpenedProjectID id: UUID?) {
        presentedPhotoID = nil
        clearCandidateStore()
        guard let id else {
            path.removeAll()
            return
        }
        path = [.albumOverview(id)]
    }
}
