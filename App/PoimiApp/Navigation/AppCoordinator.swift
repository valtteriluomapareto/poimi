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

    /// The asset last viewed in the grid / viewer. The grid restores its scroll to it on return
    /// from the viewer (D22); set on cell tap and updated as the viewer swipes. Shared so scroll
    /// position survives the round-trip.
    var lastViewedID: String?

    /// The photo viewer, presented as a `.sheet` (a Now-Playing-style modal card) rather than a path
    /// push — you pull it DOWN to dismiss (the sheet owns the interactive drag), never a sideways
    /// nav-pop (#36). `nil` when closed; the grid stays mounted underneath, exactly where you left it.
    var presentedPhotoID: String?

    init(library: any PhotoLibraryProviding) {
        self.library = library
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
        path.removeAll()
    }

    // MARK: - Lifecycle restore (D20, §11)

    /// Re-open the last-opened album on launch (the album-library "resume" entry). A `nil` id
    /// (no prior project) lands on the library root.
    func restore(lastOpenedProjectID id: UUID?) {
        presentedPhotoID = nil
        guard let id else {
            path.removeAll()
            return
        }
        path = [.albumOverview(id)]
    }
}
