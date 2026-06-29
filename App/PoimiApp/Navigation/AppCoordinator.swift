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
    /// from the viewer (D22) and the viewer keys its `.zoom` source off it; set on cell tap and
    /// updated as the viewer swipes. Shared so scroll position survives the round-trip.
    var lastViewedID: String?

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
        path = [.albumOverview(id)]
    }

    /// Push the review grid for an album, optionally scrolled to a day-group.
    func openReview(_ projectID: UUID, day: DayKey? = nil) {
        path.append(.review(projectID, day))
    }

    /// Push the full-screen photo viewer (the `.zoom` destination). Records the asset as last-viewed
    /// so the `.zoom` source + the grid's scroll restore are anchored to it from the outset.
    func openPhoto(_ assetID: String) {
        lastViewedID = assetID
        path.append(.photo(assetID))
    }

    /// Push the export / completion step.
    func openExport(_ projectID: UUID) {
        path.append(.export(projectID))
    }

    func pop() {
        guard !path.isEmpty else { return }
        path.removeLast()
    }

    /// Back to the albums library root.
    func popToRoot() {
        path.removeAll()
    }

    // MARK: - Lifecycle restore (D20, §11)

    /// Re-open the last-opened album on launch (the album-library "resume" entry). A `nil` id
    /// (no prior project) lands on the library root.
    func restore(lastOpenedProjectID id: UUID?) {
        guard let id else {
            path.removeAll()
            return
        }
        path = [.albumOverview(id)]
    }
}
