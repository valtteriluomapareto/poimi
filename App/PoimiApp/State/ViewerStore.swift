//
//  ViewerStore.swift
//  PoimiApp — the photo viewer's state, lifted out of `PhotoViewerView` (#299, control plane slice D;
//  docs/plans/control-plane.md §4 D).
//
//  The photo on screen, the end-of-set card (#180) and the paged-past auto-mark-done (#128) used to be the
//  viewer's `@State`, so nothing without a mounted viewer could page it, and a run with no UI couldn't
//  reach the card's Save to Photos. This `@MainActor @Observable` store holds them; the viewer binds its
//  pager, filmstrip, chevrons, Pick and the card to it, and the control plane calls the same methods.
//
//  What stays in the view: the haptics, the VoiceOver announcement, the toast's auto-hide timer, the
//  Pick bounce guard, the filmstrip window, the ambient wash and the info labels — presentation only.
//
//  The coordinator starts it over whenever `presentedPhotoID` changes (`present`), so each opening starts
//  on the tapped photo with no card and no toast, exactly as a freshly presented viewer did.
//

import Foundation
import Observation
import Curation

@MainActor
@Observable
final class ViewerStore {
    @ObservationIgnored private let coordinator: AppCoordinator
    @ObservationIgnored private let session: AlbumSession
    @ObservationIgnored private let selection: SelectionStore
    @ObservationIgnored private let done: DoneStore

    /// The photo on screen, or `nil` with no viewer up.
    private(set) var currentID: String?
    /// The end-of-set card is up (#180): Pick / Next went past the last photo.
    private(set) var endReached = false
    /// The cluster the last paged-past auto-mark marked done (#128) — the undoable toast; `nil` hides it.
    private(set) var autoDoneCluster: ReviewCluster?
    /// Bumped on every auto-mark, so the view fires its haptic + VoiceOver announcement once per mark.
    private(set) var autoDoneCount = 0

    /// The filmstrip's window around the current photo — how far a filmstrip tap can jump (#80).
    static let filmstripBack = 25
    static let filmstripForward = 25

    init(coordinator: AppCoordinator, session: AlbumSession, selection: SelectionStore, done: DoneStore) {
        self.coordinator = coordinator
        self.session = session
        self.selection = selection
        self.done = done
    }

    /// Every photo the viewer pages through: the open review's, in order — or just the current photo when
    /// it isn't in the review (the screenshot harness's hand-picked list falls back the same way).
    var orderedIDs: [String] {
        guard let currentID else { return [] }
        return session.reviewOrderedIDs.contains(currentID) ? session.reviewOrderedIDs : [currentID]
    }

    // MARK: - Lifecycle

    /// The viewer opened on `id` (or closed, `nil`): start over — no card, no toast.
    func present(_ id: String?) {
        if currentID != id { currentID = id }
        if endReached { endReached = false }
        if autoDoneCluster != nil { autoDoneCluster = nil }
    }

    // MARK: - Paging

    /// Show `id` without marking anything: a filmstrip tap, a backward step, or the pager publishing the
    /// page a swipe settled on (whose auto-mark is `swiped`). The grid restores to it on return (D22).
    func show(_ id: String) {
        guard currentID != id else { return }
        currentID = id
        coordinator.lastViewedID = id
    }

    /// A real swipe settled from `previous` to `current` (already shown): forward past a cluster's last
    /// photo marks it done (#128).
    func swiped(from previous: String, to current: String) {
        autoMarkDone(from: previous, to: current)
    }

    /// A chevron / swipe step (`offset` −1 or +1). Forward past the last photo opens the end-of-set card; a
    /// forward step across a cluster's end marks it done (as a swipe does, #128). Never changes a pick.
    func step(_ offset: Int) {
        guard let from = currentID else { return }
        guard let target = viewerStep(from: from, in: orderedIDs, offset: offset) else {
            if offset > 0 { endReached = true }
            return
        }
        if offset > 0 { advance(to: target, from: from) } else { show(target) }
    }

    /// Whether ‹ is enabled: there's a photo before this one.
    var hasPrevious: Bool {
        guard let currentID else { return false }
        return viewerStep(from: currentID, in: orderedIDs, offset: -1) != nil
    }

    /// The photos a filmstrip tap can reach from here: the window it shows around the current photo.
    func filmstripReaches(_ id: String) -> Bool {
        let ids = orderedIDs
        guard let current = currentID, let index = ids.firstIndex(of: current),
              let target = ids.firstIndex(of: id) else { return false }
        let window = viewerWindow(count: ids.count, around: index, back: Self.filmstripBack,
                                  forward: Self.filmstripForward)
        return window.contains(target)
    }

    // MARK: - Pick (#180)

    /// The Pick button (or a tap on the photo): toggle the current photo's pick, then apply `pickPlan` —
    /// adding advances (or opens the end-of-set card on the last photo); removing stays put. Returns
    /// whether it advanced, so the view arms its double-tap bounce guard.
    @discardableResult
    func pick() -> Bool {
        guard let current = currentID else { return false }
        let plan = pickPlan(currentID: current, in: orderedIDs, currentlyPicked: selection.contains(current))
        selection.toggle(plan.toggleID)
        if let next = plan.advanceTo {
            advance(to: next, from: plan.toggleID)
            return true
        }
        if plan.reachedEnd { endReached = true }
        return false
    }

    // MARK: - End-of-set card + toast

    /// The card's "Keep reviewing".
    func keepReviewing() {
        if endReached { endReached = false }
    }

    /// The toast's Undo: reverse the auto-mark and hide the toast.
    func undoAutoDone() {
        guard let cluster = autoDoneCluster else { return }
        if done.isDone(cluster) { done.toggle(cluster) }
        autoDoneCluster = nil
    }

    /// The toast timed out.
    func hideAutoDoneToast() {
        if autoDoneCluster != nil { autoDoneCluster = nil }
    }

    // MARK: - Auto-mark-done on paging past a cluster's end (#128)

    /// A FORWARD programmatic advance: seal the cluster if this crossed its boundary (the pager's swipe
    /// delegate doesn't fire for a programmatic turn), then turn the page.
    private func advance(to target: String, from: String) {
        autoMarkDone(from: from, to: target)
        show(target)
    }

    /// Forward-paging past a cluster's last photo marks it done — once, forward-only (paging back never
    /// marks or un-marks), through the same `DoneStore` toggle as the grid's seal, so the grid shows it on
    /// return (#126).
    private func autoMarkDone(from previous: String, to current: String) {
        guard let finished = clusterToAutoMarkDone(from: previous, to: current,
                                                   clusters: session.reviewClusters,
                                                   isDone: { done.isDone($0) }) else { return }
        done.toggle(finished)
        autoDoneCluster = finished
        autoDoneCount &+= 1
    }
}
