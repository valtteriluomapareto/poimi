//
//  ControlHost.swift
//  PoimiApp — the ONE handler for every control host: the in-process tests, the app with its UI, and the
//  headless app (#298, docs/plans/control-plane.md §4 C). DEBUG-only (D30).
//
//  It owns no feature logic: each action is the call the control makes — into the album session, the
//  `AlbumActions` façade, a store or the coordinator. What the host adds is only what a user gets for free
//  from the screen:
//
//  - **Reachability.** Each action is a control a user can reach, and only from where it is on screen: a
//    row of the album list (always, in the iPad sidebar), the overview's buttons, the grid's chips, a
//    settings screen's fields. Elsewhere it's `refused(notShown)`. An alias that names nothing is
//    `unknownAlias`; a store that isn't hydrated `invalidState` — never a silent `accepted` that did
//    nothing. Where the UI's own guard would swallow a repeat, the reply is `noop`.
//  - **The screens' own `.task`s.** A screen starts work when it appears (`AlbumSession.appear`, the one
//    mapping the views call too). With no view mounted nobody would, so after every action the host runs
//    it for every album screen on the path — the SAME idempotent call, which joins the view's when there
//    is one — skipping a screen that left the path or whose album was deleted by then (as a view's task
//    is cancelled with its view).
//
//  `accepted` means admitted, not finished: it carries a `seq`, and `settledSeq` (in the snapshot)
//  reaches it once the async work the action started — scan, trip naming, export, an authorization read —
//  has finished.
//
#if DEBUG

import Foundation
import Observation
import Curation

/// Action bookkeeping, observable so the snapshot (and `wait`) see it: `lastSeq` is the newest accepted
/// action, `settledSeq` the highest seq with everything up to it finished.
@MainActor
@Observable
final class ControlProgress {
    private(set) var lastSeq = 0
    private(set) var settledSeq = 0
    @ObservationIgnored private var unsettled: [Int: Task<Void, Never>] = [:]

    /// Admit an action whose async `work` runs now; returns its seq. Settled when `work` returns.
    func begin(_ work: @escaping @MainActor () async -> Void) -> Int {
        lastSeq += 1
        let seq = lastSeq
        unsettled[seq] = Task { @MainActor [weak self] in
            await work()
            self?.settle(seq)
        }
        return seq
    }

    private func settle(_ seq: Int) {
        unsettled[seq] = nil
        let settled = (unsettled.keys.min().map { $0 - 1 }) ?? lastSeq
        if settled != settledSeq { settledSeq = settled }
    }

    /// Await every admitted action (the in-process tests; never a fixed sleep).
    func awaitSettled() async {
        while let task = unsettled.values.first { await task.value }
    }
}

@MainActor
final class ControlHost {
    let graph: AppGraph
    let progress: ControlProgress
    private let run: String
    private let fixture: ControlFixture
    /// The asset aliases: the fixture's library, grown by `library.addPhotos` (#300).
    private(set) var assets: ControlAssetAliases
    private let albums: ControlAlbumAliases
    /// The fake library's export gate (the export levers, #300).
    private let exportGate: FakeExportGate
    /// Whether the album list is always on screen (the iPad split view's sidebar) — otherwise only at the
    /// root of the path (the iPhone stack).
    private let listAlwaysShown: Bool
    /// The snapshot as `state.json` would carry it now (content + run + the writer's rev).
    private let state: () -> ControlJSON
    private let rev: () -> Int
    /// Bring `state.json` up to date before a reply is written (so the file's `rev` ≥ the reply's).
    private let syncState: () async -> Void
    /// Albums whose export screen task is admitted but hasn't started the export yet — `busy` like a
    /// running export, so a delete can't land between the reply and the run.
    private var queuedExports: Set<UUID> = []

    init(graph: AppGraph, run: String, fixture: ControlFixture, assets: ControlAssetAliases,
         albums: ControlAlbumAliases, progress: ControlProgress, listAlwaysShown: Bool = false,
         exportGate: FakeExportGate,
         state: @escaping () -> ControlJSON, rev: @escaping () -> Int,
         syncState: @escaping () async -> Void = {}) {
        self.graph = graph
        self.run = run
        self.fixture = fixture
        self.assets = assets
        self.albums = albums
        self.exportGate = exportGate
        self.progress = progress
        self.listAlwaysShown = listAlwaysShown
        self.state = state
        self.rev = rev
        self.syncState = syncState
    }

    fileprivate var coordinator: AppCoordinator { graph.coordinator }
    fileprivate var session: AlbumSession { graph.session }
    fileprivate var actions: AlbumActions { graph.actions }
    fileprivate var selection: SelectionStore { graph.selectionStore }
    fileprivate var done: DoneStore { graph.doneStore }
    fileprivate var viewer: ViewerStore { graph.viewer }

    // MARK: - Requests

    /// Decode one request file's bytes (`fileID` = the `n` of `req-<n>.json`, the reply's id when the
    /// bytes don't decode): the request, or the error reply.
    enum Decoded {
        case request(ControlRequest)
        case reply(ControlResponse)
    }

    func request(from data: Data, fileID: Int?) -> Decoded {
        guard let fileID else {
            return .reply(ControlResponse(id: nil, result: .failure(.bad("request file name must be req-<n>.json"))))
        }
        let request: ControlRequest
        do throws(ControlRequestError) {
            request = try ControlRequest.decode(data)
        } catch {
            return .reply(ControlResponse(id: fileID, result: .failure(error)))
        }
        guard request.id == fileID else {
            let message = "id \(request.id) doesn't match the file's \(fileID)"
            return .reply(ControlResponse(id: fileID, result: .failure(.bad(message))))
        }
        return .request(request)
    }

    /// Decode and handle one request file's bytes. Never throws: every failure is an error reply.
    func handle(data: Data, fileID: Int?) async -> ControlResponse {
        switch request(from: data, fileID: fileID) {
        case .request(let request): await handle(request)
        case .reply(let response): response
        }
    }

    func handle(_ request: ControlRequest) async -> ControlResponse {
        guard request.run == run else {
            return ControlResponse(id: request.id, result: .failure(ControlRequestError(
                .staleRun, "request is for run \(request.run); this launch is \(run) — relaunched since?")))
        }
        switch request.command {
        case .send(let action):
            return ControlResponse(id: request.id, result: .success(perform(action).json))
        case .fixture(let op):
            return ControlResponse(id: request.id, result: .success(await perform(op).json))
        case .snapshot:
            return ControlResponse(id: request.id, result: .success(state()))
        case .schema:
            return ControlResponse(id: request.id, result: .success(ControlSchema.json()))
        case .wait(let predicates, let timeoutMs):
            return ControlResponse(id: request.id, result: await wait(predicates, timeoutMs: timeoutMs))
        }
    }

    /// The reply envelope for `response`, after bringing `state.json` up to date — so a `state` read
    /// right after a reply sees at least the reply's `rev`.
    func reply(_ response: ControlResponse) async -> ControlJSON {
        await syncState()
        return response.json(run: run, rev: rev())
    }

    func wait(_ predicates: [ControlPredicate], timeoutMs: Int) async -> Result<ControlJSON, ControlRequestError> {
        if let bad = ControlWait.undeclared(predicates) {
            return .failure(ControlRequestError(.undeclaredPath,
                                                "'\(bad.path)' is not a declared state path (see schema)"))
        }
        if let mismatch = ControlWait.typeMismatch(predicates) {
            return .failure(.bad(mismatch))
        }
        let started = ContinuousClock.now
        let unmet = await ControlWait.wait(for: predicates, timeout: .milliseconds(timeoutMs), state: state)
        let waited = ContinuousClock.now - started
        let waitedMs = Int(waited.components.seconds * 1000 + waited.components.attoseconds / 1_000_000_000_000_000)
        guard unmet.isEmpty else {
            return .failure(ControlRequestError(.unmet,
                                                "\(unmet.count) of \(predicates.count) unmet after \(timeoutMs) ms",
                                                detail: .array(unmet.map(\.json))))
        }
        return .success(.object(("met", .bool(true)), ("waitedMs", .int(waitedMs))))
    }

    var currentRun: String { run }

    // MARK: - Actions

    func perform(_ action: ControlAction) -> ControlOutcome {
        do throws(Refused) {
            return try dispatch(action)
        } catch {
            return .refused(error.reason, error.message)
        }
    }

    /// A refusal on its way out of `dispatch`.
    struct Refused: Error {
        let reason: ControlRefusal
        let message: String
    }

    fileprivate func refuse(_ reason: ControlRefusal, _ message: String) -> Refused {
        Refused(reason: reason, message: message)
    }

    // One case per action, each a guard or two and the one call — a switch is the clearest shape.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private func dispatch(_ action: ControlAction) throws(Refused) -> ControlOutcome {
        try requireNoModal(over: action)
        switch action {
        case .navOpenAlbum(let alias):
            let project = try album(alias)
            try requireList("an album opens from its row in the album list")
            actions.open(project)
            return accept()

        case .navOpenReview(let alias, let day):
            let project = try album(alias)
            try requireOnTop(.albumOverview(project.id), "the review opens from \(alias)'s overview")
            coordinator.openReview(project.id, day: day)
            return accept()

        case .navOpenExport:
            let project = try openAlbum()
            if coordinator.path.last == .export(project.id) { return .noop("export is already on top") }
            // The overview's Save to Photos, the fully-reviewed grid's, or the viewer's end-of-set card's.
            let onTop = coordinator.path.last
            let gridDone = onTop.map(isReview) == true
                && isReviewComplete(clusters: session.reviewClusters, isDone: { done.isDone($0) })
            let viewerUp = coordinator.presentedPhotoID != nil
            guard viewerUp ? viewer.endReached : onTop == .albumOverview(project.id) || gridDone else {
                throw refuse(.notShown, "Save to Photos is on the album's overview, the grid once every day is "
                    + "done, or the viewer's end-of-set card")
            }
            guard selection.progress.picked > 0 else {
                throw refuse(.invalidState, "nothing is picked (Save to Photos is disabled)")
            }
            coordinator.finishToExport()
            return accept()

        case .navOpenSettings(let alias):
            let project = try album(alias)
            if coordinator.path.last == .settings(project.id) { return .noop("album settings already on top") }
            try requireOnTop(.albumOverview(project.id), "album settings open from \(alias)'s overview")
            coordinator.openSettings(project.id)
            return accept()

        case .navOpenAppSettings:
            try requireAlbumsPhase()
            // The coordinator's own guard (#258): a repeat would be swallowed — say so.
            if coordinator.path.last == .appSettings { return .noop("app settings already on top") }
            try requireList("app settings open from the album list's cog")
            coordinator.openAppSettings()
            return accept()

        case .navBack:
            try requireAlbumsPhase()
            try requireNoViewer()
            guard !coordinator.path.isEmpty else { return .noop("already at the album list") }
            // The export screen hides the navigation bar and its back button (no swipe back mid-write).
            if case .export? = coordinator.path.last {
                throw refuse(.notShown, "the export screen has no back button: Back to albums (nav.root) "
                    + "once the export settles")
            }
            coordinator.pop()
            return accept()

        case .navRoot:
            try requireAlbumsPhase()
            guard !coordinator.path.isEmpty || coordinator.presentedPhotoID != nil else {
                return .noop("already at the album list")
            }
            // On the export screen, the way out is its Back to albums — shown only once the export settled.
            if case .export? = coordinator.path.last {
                switch session.export.phase {
                case .done, .failed: break
                case .idle, .exporting:
                    throw refuse(.notShown, "Back to albums shows once the export settles (on iPad the "
                        + "sidebar's rows stay live: nav.openAlbum)")
                }
            }
            coordinator.popToRoot()
            return accept()

        case .viewerOpen(let alias):
            let id = try assetID(alias)
            if coordinator.presentedPhotoID == id { return .noop("the viewer already shows \(alias)") }
            guard coordinator.path.last.map(isReview) == true, coordinator.presentedPhotoID == nil,
                  session.reviewOrderedIDs.contains(id) else {
                throw refuse(.notShown, "\(alias) isn't in the review grid on screen")
            }
            coordinator.openPhoto(id)
            return accept()

        case .viewerDismiss:
            guard coordinator.presentedPhotoID != nil else { return .noop("no viewer is open") }
            coordinator.dismissPhoto()
            return accept()

        case .albumsCreate(let new):
            try requireAlbumsPhase()
            // The sheet's Create — from the open sheet, or the album list (its New album button, then Create).
            if coordinator.modal != .newAlbum { try requireList("New album is on the album list") }
            guard let project = actions.create(validated: draft(new)) else {
                throw refuse(.invalidState, "not a valid album (a name and a non-empty period are required)")
            }
            return accept(extra: [.init(key: "album", value: .string(albums.assign(project.id)))])

        case .albumsDelete(let alias):
            let project = try album(alias)
            try requireListOrSettings(of: project, "Delete")
            try requireNotExporting(project, alias)
            guard actions.delete(project) else { throw refuse(.busy, "\(alias) is exporting") }
            return accept()

        case .albumsReset(let alias):
            let project = try album(alias)
            try requireListOrSettings(of: project, "Reset all progress")
            try requireNotExporting(project, alias)
            guard actions.reset(project) else { throw refuse(.busy, "\(alias) is exporting") }
            return accept()

        case .albumsDuplicate(let alias):
            let project = try album(alias)
            try requireList("Duplicate is on the album list")
            let copy = actions.duplicate(project)
            return accept(extra: [.init(key: "album", value: .string(albums.assign(copy.id)))])

        case .albumsUpdate(let alias, let edit):
            let project = try album(alias)
            try requireOnTop(.settings(project.id), "\(alias)'s fields are edited on its settings screen")
            guard actions.update(project, with: edits(edit), calendar: graph.calendar) else {
                throw refuse(.invalidState, "the period would be empty or inverted")
            }
            return accept()

        case .albumsMarkAllUnreviewed(let alias):
            let project = try album(alias)
            try requireOnTop(.settings(project.id), "Mark all days unreviewed is on \(alias)'s settings")
            actions.markAllUnreviewed(project)
            return accept()

        case .selectionToggle(let alias):
            let id = try assetID(alias)
            try requireSelectionActive()
            try requireGrid()
            guard session.reviewOrderedIDs.contains(id) else {
                throw refuse(.notShown, "\(alias) isn't in the review grid on screen")
            }
            selection.toggle(id)
            return accept()

        case .selectionToggleCluster(let day):
            try requireSelectionActive()
            try requireGrid()
            selection.toggleAll(try cluster(day).assetIDs)
            return accept()

        case .doneToggle(let day):
            guard done.isActive else { throw refuse(.invalidState, "no album is open (the done store is inactive)") }
            try requireGrid()
            done.toggle(try cluster(day))
            return accept()

        case .exportRetry(let newAlbum):
            let project = try openAlbum()
            guard coordinator.path.last == .export(project.id) else {
                throw refuse(.notShown, "Try again is on a failed export screen")
            }
            switch session.export.phase {
            case .failed:
                return accept { [session] in await session.retryExport(project, forceNewAlbum: newAlbum) }
            case .exporting:
                throw refuse(.busy, "the export is running")
            case .idle, .done:
                throw refuse(.notShown, "Try again shows only when the export failed")
            }

        case .authRequest:
            guard coordinator.rootPhase == .onboarding else {
                throw refuse(.notShown, "the access request is on onboarding; the app is at \(coordinator.rootPhase)")
            }
            return accept { [coordinator] in await coordinator.requestAuthorization() }

        case .reviewSetFilter, .reviewGoTo, .reviewMarkDoneAndAdvance, .viewerPage, .viewerPick,
             .viewerKeepReviewing, .viewerUndoAutoDone, .uiPresent, .uiConfirm, .uiDismiss:
            return try dispatchScreenState(action)
        }
    }

}

// MARK: - Fixture ops + the screens' own tasks

extension ControlHost {
    func perform(_ op: ControlFixtureOp) async -> ControlOutcome {
        switch op {
        case .flush:
            selection.flushNow()
            done.flushNow()
            return accept()
        case .lifecycleResume:
            // Awaited before replying: a lever is finished when it returns.
            await graph.coordinator.refreshAuthorization()
            return accept()
        case .libraryFailFetch(let failing):
            guard let fake = graph.photoLibrary as? FakePhotoLibrary else {
                return .refused(.unavailable, "not the fake library")
            }
            await fake.setFetchError(failing ? FakePhotoLibrary.FakeError.fetchFailed : nil)
            return accept()
        case .libraryAuthorization(let status):
            guard let fake = graph.photoLibrary as? FakePhotoLibrary else {
                return .refused(.unavailable, "not the fake library")
            }
            await fake.setAuthorization(status)
            return accept()
        case .selectionSelect(let aliases):
            do throws(Refused) {
                try requireSelectionActive()
                var ids: [String] = []
                for alias in aliases { ids.append(try assetID(alias)) }
                let shown = Set(session.reviewOrderedIDs)
                guard ids.allSatisfy(shown.contains) else {
                    throw refuse(.notShown, "not all of them are in the open album's review")
                }
                selection.select(ids)
                return accept()
            } catch {
                return .refused(error.reason, error.message)
            }
        case .selectionClear:
            guard selection.isActive else {
                return .refused(.invalidState, "no album is open (the selection store is inactive)")
            }
            selection.clear()
            return accept()
        case .library(let lever):
            return await perform(lever)
        case .reset(let name):
            return .refused(.unavailable, "a reset is a relaunch: Scripts/poimi.sh reset \(name)")
        }
    }

    /// The fake library's levers (#300): the export gate, and new photos taken mid-session.
    private func perform(_ lever: ControlLibraryLever) async -> ControlOutcome {
        switch lever {
        case .holdExports:
            if exportGate.holding { return .noop("exports are already held") }
            exportGate.hold()
            return accept()
        case .releaseExports:
            guard exportGate.holding else { return .noop("the export gate is open") }
            exportGate.release()
            return accept()
        case .failExport(let error):
            if exportGate.failure == error { return .noop("already so") }
            exportGate.fail(error)
            return accept()
        case .addPhotos(let day, let count):
            guard let fake = graph.photoLibrary as? FakePhotoLibrary else {
                return .refused(.unavailable, "not the fake library")
            }
            guard let start = day.anchorDate(in: ControlFixture.utc).map(ControlFixture.utc.startOfDay(for:)) else {
                return .refused(.invalidState, "not a calendar day")
            }
            let added = await fake.addPhotos(onDayStarting: start, count: count)
            assets = assets.appending(added)
            let aliases = added.compactMap { assets.alias(for: $0.id) }
            return accept(extra: [.init(key: "photos", value: .array(aliases.map(ControlJSON.string)))])
        }
    }

    // MARK: - The screens' own tasks

    /// What the album screens on the path run when they appear (`AlbumSession.appear` — the views' own
    /// call), in path order, or `nil` when none starts work. Decided NOW (a screen the next action covers
    /// still ran its task), each skipped if by then it left the path or its album was deleted — as a
    /// view's task is cancelled with its view. Idempotent: each call joins the view's, or no-ops.
    func screenTask() -> (@MainActor () async -> Void)? {
        guard coordinator.rootPhase == .albums, let id = coordinator.activeAlbumID,
              let project = graph.projectStore.projects.first(where: { $0.id == id }) else { return nil }
        let screens = coordinator.path.compactMap { route in AlbumSession.Screen(route).map { (route, $0) } }
        guard !screens.isEmpty else { return nil }
        let exports = screens.contains { $0.1 == .export }
        if exports { queuedExports.insert(id) }
        let session = session
        return { [weak self] in
            for (route, screen) in screens {
                guard let self, isShown(route, id) else { continue }
                if screen == .export { queuedExports.remove(id) }   // from here, `isExporting` covers it
                await session.appear(screen, project)
                await session.candidateStore?.awaitPendingNames()
            }
            if exports { self?.queuedExports.remove(id) }
        }
    }

    /// Whether `route` is still on the path and its album still exists.
    private func isShown(_ route: Route, _ albumID: UUID) -> Bool {
        coordinator.path.contains(route) && graph.projectStore.projects.contains { $0.id == albumID }
    }

    /// Admit the action: its own async `work` (if any), then the tasks of the album screens it left on
    /// the path. Settles when all finished.
    private func accept(extra: [ControlJSON.Member] = [],
                        _ work: (@MainActor () async -> Void)? = nil) -> ControlOutcome {
        let screenWork = screenTask()
        let seq = progress.begin {
            await work?()
            await screenWork?()
        }
        return .accepted(seq: seq, extra: extra)
    }
}

// MARK: - Screen state beyond routes (#299)

extension ControlHost {
    // The slice-D actions (#299): state a route can't express — the Overview's filter, the grid's current
    // cluster, the viewer's page and end-of-set card, and the modals. One case per action, like `dispatch`.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private func dispatchScreenState(_ action: ControlAction) throws(Refused) -> ControlOutcome {
        switch action {
        case .reviewSetFilter(let filter):
            let project = try openAlbum()
            try requireOnTop(.albumOverview(project.id), "the filter is on the album's overview")
            guard case .ready? = session.candidateStore?.phase, session.reviewClusters.count > 1 else {
                throw refuse(.notShown, "the filter shows once the overview lists more than one cluster")
            }
            if session.overviewFilter == filter { return .noop("the filter is already \(filter.controlName)") }
            session.setOverviewFilter(filter)
            return accept()

        case .reviewGoTo(let day):
            try requireGrid()
            let target = try cluster(day)
            guard session.reviewClusterID != nil else { throw refuse(.invalidState, "the grid hasn't entered yet") }
            if session.reviewClusterID == target.id { return .noop("the grid already shows \(day)'s cluster") }
            session.showCluster(target.id)
            return accept()

        case .reviewMarkDoneAndAdvance:
            guard done.isActive else { throw refuse(.invalidState, "no album is open (the done store is inactive)") }
            try requireGrid()
            guard let current = session.currentReviewCluster else {
                throw refuse(.invalidState, "the grid has no current cluster yet")
            }
            session.markDoneAndAdvance(current)
            return accept()

        case .viewerPage(let target):
            try requireViewerControls()
            switch target {
            case .next:
                viewer.step(1)
            case .previous:
                guard viewer.hasPrevious else { throw refuse(.invalidState, "‹ is disabled on the first photo") }
                viewer.step(-1)
            case .photo(let alias):
                let id = try assetID(alias)
                if viewer.currentID == id { return .noop("the viewer already shows \(alias)") }
                guard viewer.filmstripPages.contains(id) else {   // exactly what the strip shows
                    throw refuse(.notShown, "\(alias) isn't in the viewer's filmstrip")
                }
                viewer.show(id)
            }
            return accept()

        case .viewerPick:
            try requireSelectionActive()
            try requireViewerControls()
            viewer.pick()
            return accept()

        case .viewerKeepReviewing:
            guard coordinator.presentedPhotoID != nil, viewer.endReached else {
                throw refuse(.notShown, "Keep reviewing is on the viewer's end-of-set card")
            }
            viewer.keepReviewing()
            return accept()

        case .viewerUndoAutoDone:
            // The toast sits under the end-of-set card's scrim, so the card covers it too.
            guard coordinator.presentedPhotoID != nil, !viewer.endReached, viewer.autoDoneCluster != nil else {
                throw refuse(.notShown, "Undo is on the viewer's auto-done toast, which isn't showing")
            }
            viewer.undoAutoDone()
            return accept()

        case .uiPresent(let modal, let alias):
            return try present(modal, album: alias)

        case .uiConfirm:
            guard case .confirm(let confirmation)? = coordinator.modal else {
                throw refuse(.notShown, "no confirmation is open (the New album sheet's button is albums.create)")
            }
            guard actions.confirm(confirmation) else { throw refuse(.busy, "that album is exporting") }
            return accept()

        case .uiDismiss:
            guard let modal = coordinator.modal else {
                let hint = coordinator.presentedPhotoID == nil ? "" : " (viewer.dismiss closes the viewer)"
                return .noop("no sheet or dialog is open" + hint)
            }
            coordinator.dismiss(modal)
            return accept()

        default:
            preconditionFailure("dispatch handles \(action.kind.rawValue)")
        }
    }

    /// `ui.present`: the button that opens `modal`, where it is on screen.
    private func present(_ modal: ControlModal, album alias: String?) throws(Refused) -> ControlOutcome {
        try requireAlbumsPhase()
        let target = try appModal(modal, album: alias)
        if coordinator.modal == target { return .noop("\(modal.rawValue) is already open") }
        if coordinator.modal != nil { throw refuse(.notShown, "another sheet or dialog is open (ui.dismiss first)") }
        try requireButton(for: target, alias: alias ?? "")
        coordinator.present(target)
        return accept()
    }

    /// The coordinator modal `modal` names. A confirmation comes from the album's settings when they're on
    /// top (on iPad the album list is on screen too, and the settings' dialog is the one in front), else
    /// from the album list.
    private func appModal(_ modal: ControlModal, album alias: String?) throws(Refused) -> AppModal {
        guard let kind = modal.confirmation else { return modal == .newAlbum ? .newAlbum : .whatsNew }
        guard let alias else { throw refuse(.invalidState, "no album given") }
        let project = try album(alias)
        let onSettings = coordinator.path.last == .settings(project.id) && coordinator.presentedPhotoID == nil
        return .confirm(AlbumConfirmation(kind: kind, album: project.id,
                                          origin: onSettings ? .albumSettings : .albumList))
    }

    /// The button that presents `target` is on screen, and enabled.
    private func requireButton(for target: AppModal, alias: String) throws(Refused) {
        switch target {
        case .newAlbum:
            try requireList("New album is on the album list")
        case .whatsNew:
            try requireOnTop(.appSettings, "What's New is on app settings")
        case .confirm(let confirmation) where confirmation.kind == .markAllUnreviewed:
            guard confirmation.origin == .albumSettings else {
                throw refuse(.notShown, "Mark all days unreviewed is on \(alias)'s settings, which isn't on top")
            }
            guard !done.doneDays.isEmpty else {
                throw refuse(.invalidState, "no day is marked done (the button is disabled)")
            }
        case .confirm(let confirmation):
            if confirmation.origin == .albumList {
                try requireList("Delete / Reset all progress are on the album list or its settings")
            }
            // The list disables them while the album exports.
            if session.exportingAlbums.contains(confirmation.album) || queuedExports.contains(confirmation.album) {
                throw refuse(.busy, "\(alias) is exporting")
            }
        }
    }

}

extension AlbumSession {
    /// The grid's current cluster (`reviewClusterID`'s), or `nil` before the grid's entry — for the host and
    /// the snapshot only (DEBUG).
    var currentReviewCluster: ReviewCluster? {
        guard let id = reviewClusterID else { return nil }
        return reviewClusters.first { $0.id == id }
    }
}

// MARK: - Lookups + reachability

extension ControlHost {

    fileprivate func requireAlbumsPhase() throws(Refused) {
        guard coordinator.rootPhase == .albums else {
            throw refuse(.notShown, "the album library isn't shown (the app is at \(coordinator.rootPhase))")
        }
    }

    /// A sheet or dialog covers the whole screen (on iPad the split view too): nothing behind it is
    /// reachable — only its own controls (`ui.confirm` / `ui.dismiss`, the New album sheet's Create).
    fileprivate func requireNoModal(over action: ControlAction) throws(Refused) {
        guard let modal = coordinator.modal else { return }
        switch action {
        case .uiPresent, .uiConfirm, .uiDismiss: return
        case .albumsCreate where modal == .newAlbum: return
        default:
            let kind = modal == .newAlbum || modal == .whatsNew ? "sheet" : "dialog"
            throw refuse(.notShown, "the \(ControlModal(modal).rawValue) \(kind) covers the screen (ui.dismiss first)")
        }
    }

    /// The viewer's transport (chevrons, Pick, filmstrip) is on screen: the viewer is up, without the
    /// end-of-set card's scrim over it.
    fileprivate func requireViewerControls() throws(Refused) {
        guard coordinator.presentedPhotoID != nil else { throw refuse(.notShown, "the viewer isn't open") }
        guard !viewer.endReached else {
            throw refuse(.notShown, "the end-of-set card covers the viewer (viewer.keepReviewing first)")
        }
    }

    fileprivate func requireNoViewer() throws(Refused) {
        guard coordinator.presentedPhotoID == nil else {
            throw refuse(.notShown, "the photo viewer covers the screen (viewer.dismiss first)")
        }
    }

    /// The album list is on screen: the iPhone stack's root, or always the iPad sidebar — not under the viewer.
    private var listShown: Bool {
        coordinator.rootPhase == .albums && coordinator.presentedPhotoID == nil && coordinator.modal == nil
            && (listAlwaysShown || coordinator.path.isEmpty)
    }

    fileprivate func requireList(_ what: String) throws(Refused) {
        guard listShown else { throw refuse(.notShown, "\(what), which isn't on screen") }
    }

    fileprivate func requireOnTop(_ route: Route, _ what: String) throws(Refused) {
        guard coordinator.path.last == route, coordinator.presentedPhotoID == nil, coordinator.modal == nil else {
            throw refuse(.notShown, "\(what), which isn't on top")
        }
    }

    fileprivate func requireListOrSettings(of project: CurationProject, _ what: String) throws(Refused) {
        guard listShown || (coordinator.path.last == .settings(project.id) && coordinator.presentedPhotoID == nil)
        else { throw refuse(.notShown, "\(what) is on the album list or the album's settings, neither on screen") }
    }

    fileprivate func requireNotExporting(_ project: CurationProject, _ alias: String) throws(Refused) {
        if session.isExporting(project) || queuedExports.contains(project.id) {
            throw refuse(.busy, "\(alias) is exporting")
        }
    }

    /// The review grid is on top (not covered by the viewer).
    fileprivate func requireGrid() throws(Refused) {
        guard coordinator.path.last.map(isReview) == true, coordinator.presentedPhotoID == nil else {
            throw refuse(.notShown, "the review grid isn't on screen")
        }
    }

    /// The review cluster holding `day` in the open review.
    fileprivate func cluster(_ day: DayKey) throws(Refused) -> ReviewCluster {
        guard let cluster = session.reviewClusters.first(where: { $0.days.contains(day) }) else {
            throw refuse(.notShown, "\(day) isn't a day of the open review")
        }
        return cluster
    }

    /// The album behind `alias`, in the albums phase.
    fileprivate func album(_ alias: String) throws(Refused) -> CurationProject {
        try requireAlbumsPhase()
        guard let id = albums.projectID(for: alias),
              let project = graph.projectStore.projects.first(where: { $0.id == id }) else {
            throw refuse(.unknownAlias, "no album \(alias) in this run")
        }
        return project
    }

    /// The album open on screen (its overview or deeper), or `notShown`.
    fileprivate func openAlbum() throws(Refused) -> CurationProject {
        try requireAlbumsPhase()
        guard let id = coordinator.activeAlbumID,
              let project = graph.projectStore.projects.first(where: { $0.id == id }) else {
            throw refuse(.notShown, "no album is open")
        }
        return project
    }

    fileprivate func assetID(_ alias: String) throws(Refused) -> String {
        guard let id = assets.assetID(for: alias) else {
            throw refuse(.unknownAlias, "no photo \(alias) in fixture '\(fixture.rawValue)'")
        }
        return id
    }

    fileprivate func requireSelectionActive() throws(Refused) {
        guard selection.isActive else {
            throw refuse(.invalidState, "no album is open (the selection store is inactive)")
        }
    }

    fileprivate func isReview(_ route: Route) -> Bool {
        if case .review = route { return true }
        return false
    }

    /// `albums.create`'s draft: the setup form's defaults, with the given fields (inclusive end day →
    /// the model's end-exclusive bound, as the "To" picker does).
    fileprivate func draft(_ new: ControlNewAlbum) -> NewAlbumDraft {
        let calendar = graph.calendar
        var draft = NewAlbumDraft.priorCalendarYear(now: ControlFixture.rangeEnd, calendar: calendar)
        if let title = new.title { draft.title = title }
        draft.rangeStart = dayStart(new.start) ?? draft.rangeStart
        if let end = dayStart(new.end) {
            draft.rangeEnd = NewAlbumDraft.exclusiveEnd(forInclusiveDay: end, calendar: calendar)
        }
        draft.targetCount = new.target
        if let media = new.media { draft.media = media }
        if let excludeScreenshots = new.excludeScreenshots { draft.excludeScreenshots = excludeScreenshots }
        return draft
    }

    fileprivate func edits(_ edit: ControlAlbumEdit) -> AlbumEdits {
        let calendar = graph.calendar
        return AlbumEdits(
            title: edit.title,
            rangeStart: edit.start.flatMap(dayStart),
            rangeEnd: edit.end.flatMap(dayStart).map {
                NewAlbumDraft.exclusiveEnd(forInclusiveDay: $0, calendar: calendar)
            },
            targetCount: edit.target, media: edit.media,
            excludeScreenshots: edit.excludeScreenshots, locationEnabled: edit.locationEnabled)
    }

    /// The start of `day` (midnight) — the bound the date pickers give a range, which starts at the
    /// draft's midnight and keeps that time of day. (`anchorDate` is noon: a period built on it ran noon
    /// to noon, so a one-day album held the next morning's photos — #299.)
    fileprivate func dayStart(_ day: DayKey) -> Date? {
        day.anchorDate(in: graph.calendar).map(graph.calendar.startOfDay(for:))
    }
}

/// One reply: `{v, id, run, rev, ok, data | error}`. `id` is `null` only for a request file whose name
/// carries no number.
struct ControlResponse {
    let id: Int?
    let result: Result<ControlJSON, ControlRequestError>

    var ok: Bool {
        if case .success = result { return true }
        return false
    }

    var data: ControlJSON? { try? result.get() }

    var error: ControlRequestError? {
        if case .failure(let error) = result { return error }
        return nil
    }

    func json(run: String, rev: Int) -> ControlJSON {
        var members: [ControlJSON.Member] = [
            .init(key: "v", value: .int(ControlRequest.version)), .init(key: "id", value: .int(id)),
            .init(key: "run", value: .string(run)), .init(key: "rev", value: .int(rev)),
            .init(key: "ok", value: .bool(ok))
        ]
        switch result {
        case .success(let data):
            members.append(.init(key: "data", value: data))
        case .failure(let error):
            var detail: [ControlJSON.Member] = [.init(key: "code", value: .string(error.code.rawValue)),
                                                .init(key: "message", value: .string(error.message))]
            if let extra = error.detail { detail.append(.init(key: "unmet", value: extra)) }
            members.append(.init(key: "error", value: .object(detail)))
        }
        return .object(members)
    }
}

#endif
