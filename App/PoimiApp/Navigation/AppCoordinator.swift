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

    /// The typed navigation path below the albums root (bound to the `NavigationStack`). The ONE choke
    /// point for the album session's lifetime (#297): every change — a method below, or SwiftUI writing
    /// the binding on a back-swipe / back button — runs `pathDidChange`.
    var path: [Route] = [] {
        didSet { pathDidChange(from: oldValue) }
    }

    /// The viewer's last `currentID`, outliving it: the grid restores its scroll to it on return from the
    /// viewer (D22). Set on cell tap and as the viewer pages.
    var lastViewedID: String?

    /// The photo viewer, presented as a `.sheet` (a Now-Playing-style modal card) rather than a path
    /// push — you pull it DOWN to dismiss (the sheet owns the interactive drag), never a sideways
    /// nav-pop (#36). `nil` when closed; the grid stays mounted underneath, exactly where you left it.
    /// The photo it OPENED on: the photo on screen as you page is the `ViewerStore`'s (#299).
    var presentedPhotoID: String?

    /// The modal over the albums phase (#299): the New album sheet, What's New (from App settings), or a
    /// destructive confirmation — or `nil`. Navigation state like the path, so it can be read and set as
    /// data (the control plane); the views bind their `.sheet` / `.confirmationDialog` to it. The photo
    /// viewer is NOT one of these: it's `presentedPhotoID` (its own sheet, over the grid).
    private(set) var modal: AppModal?

    /// Bumped each time the viewer is dismissed back to the grid (`dismissPhoto`). The grid observes THIS
    /// (a monotonic tick), not `presentedPhotoID`'s nil-transition, to restore its position (#126): while
    /// the full-screen sheet covers it, the grid may not re-evaluate on the open, so an `.onChange(of:
    /// presentedPhotoID)` baseline can miss nil→id and then never fire on id→nil. A monotonic tick always
    /// differs, so the restore fires reliably.
    private(set) var viewerReturnTick = 0

    /// Called when the open album closes — the path's album changes (a switch, back to the library root,
    /// a back-swipe out of the album, a launch restore) or an album is re-opened — so the album session
    /// (#297) drops its scan, review context and export. The session owns those; the coordinator only
    /// owns navigation and says when the album changes. Wired by `AppGraph`.
    @ObservationIgnored var onCloseAlbum: (@MainActor () -> Void)?
    /// Called when an export screen leaves the path, so the next visit runs a fresh export instead of
    /// showing the last result. Wired by `AppGraph`.
    @ObservationIgnored var onLeaveExport: (@MainActor () -> Void)?
    /// Called when the review grid leaves the path, so the next visit opens on its entry cluster again
    /// (the drill target or the first unreviewed one), as a freshly pushed grid always has. Wired by
    /// `AppGraph`.
    @ObservationIgnored var onLeaveReview: (@MainActor () -> Void)?
    /// Called when the viewer opens (its state starts over on that photo) and when it's dismissed back to
    /// the grid (the grid's current cluster follows the photo it ended on, #126) — #299. Wired by `AppGraph`.
    @ObservationIgnored var onPhotoViewer: (@MainActor (PhotoViewerEvent) -> Void)?

    enum PhotoViewerEvent {
        case opened(String)
        case dismissed(lastViewed: String?)
    }

    init(library: any PhotoLibraryProviding) {
        self.library = library
    }

    private func closeAlbum() {
        lastViewedID = nil
        onCloseAlbum?()
    }

    private func pathDidChange(from old: [Route]) {
        if old.contains(where: \.isExport), !path.contains(where: \.isExport) { onLeaveExport?() }
        if old.contains(where: \.isReview), !path.contains(where: \.isReview) { onLeaveReview?() }
        if let oldAlbum = Self.albumID(of: old), oldAlbum != activeAlbumID { closeAlbum() }
    }

    /// The album at the root of `path`, or `nil` at the albums root / app settings.
    private static func albumID(of path: [Route]) -> UUID? {
        switch path.first {
        case .albumOverview(let id), .review(let id, _), .export(let id), .settings(let id): id
        case .appSettings, nil: nil
        }
    }

    /// The album at the root of the current path — the one shown in the iPad detail column — or `nil`
    /// at the albums root / app-settings. Drives the split-view sidebar's selection highlight (#42).
    var activeAlbumID: UUID? { Self.albumID(of: path) }

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
        modal = nil                     // …and the sheet it came from (New album → Create opens it)
        closeAlbum()                    // re-opening (even the same album) scans fresh; frees the old one
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
        onPhotoViewer?(.opened(assetID))   // before the sheet reads it: the viewer starts on this photo
        presentedPhotoID = assetID
    }

    /// Dismiss the photo-viewer sheet — the single dismiss path (the sheet's `isPresented` binding
    /// routes its pull-down here), so the open→dismiss Perf span stays closed. The grid stays mounted
    /// underneath, revealed exactly where you left it.
    func dismissPhoto() {
        Perf.event("dismissPhoto (→ grid revealed)")
        presentedPhotoID = nil
        onPhotoViewer?(.dismissed(lastViewed: lastViewedID))   // the grid's page follows that photo
        viewerReturnTick &+= 1   // signal the grid to restore its position to `lastViewedID` (#126)
    }

    /// THE way to the export / completion step (#187, #298): the Overview's "Save to Photos", the
    /// fully-reviewed grid and the viewer's end-of-set card all call it (and so does the control plane).
    /// Dismisses the viewer sheet FIRST so export isn't pushed under a mounted sheet, then pushes
    /// export for the active album. One transition, so the two affordances share it (and it's testable
    /// as a single call). No-op if there's no active album.
    func finishToExport() {
        // Re-entrancy guard: a fast double-tap must not push `.export` twice.
        guard let id = activeAlbumID, path.last != .export(id) else { return }
        // Nil the sheet, then push. SwiftUI coalesces these two @Observable writes into one update, so the
        // order is intent, not a teardown guarantee (device-verified not to flicker). We clear the sheet
        // directly rather than via `dismissPhoto()` because this goes FORWARD to export — the grid-restore
        // return-tick / Perf span (for the dismiss→grid round-trip) deliberately don't apply here.
        presentedPhotoID = nil
        path.append(.export(id))
    }

    /// Push the album's settings screen (#41). Idempotent — a repeat tap can't stack a second copy
    /// (same guard as `finishToExport`, for symmetry with `openAppSettings` below).
    func openSettings(_ projectID: UUID) {
        guard path.last != .settings(projectID) else { return }
        path.append(.settings(projectID))
    }

    /// Push the app-level settings screen (Photos access + About) — not album-scoped. Idempotent:
    /// on iPad the cog lives in the always-visible split-view *sidebar* (`AppRootView.splitView`), so it
    /// stays tappable while App settings shows in the detail column — without this guard every extra tap
    /// pushed another `.appSettings` and the user had to Back out N times (#258). Guarding the append
    /// (rather than resetting the path) keeps Back returning to the album the detail was showing.
    func openAppSettings() {
        guard path.last != .appSettings else { return }
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
        modal = nil
        closeAlbum()
        path.removeAll()
    }

    // MARK: - Modals (#299)

    /// Present `modal`: what the New album button, App settings' What's New row and the Delete / Reset /
    /// Mark all unreviewed buttons do — the views bind their sheet / dialog to `modal`.
    func present(_ modal: AppModal) {
        if self.modal != modal { self.modal = modal }
    }

    /// Dismiss `modal` if it's the one up (Cancel, a swipe-down, Continue, or the binding SwiftUI writes
    /// once a dialog's button ran) — never a different modal presented since.
    func dismiss(_ modal: AppModal) {
        if self.modal == modal { self.modal = nil }
    }

    // MARK: - Lifecycle restore (D20, §11)

    /// Re-open the last-opened album on launch (the album-library "resume" entry). A `nil` id
    /// (no prior project) lands on the library root.
    func restore(lastOpenedProjectID id: UUID?) {
        presentedPhotoID = nil
        modal = nil
        closeAlbum()
        guard let id else {
            path.removeAll()
            return
        }
        path = [.albumOverview(id)]
    }
}
