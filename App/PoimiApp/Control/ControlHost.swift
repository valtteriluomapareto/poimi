//
//  ControlHost.swift
//  PoimiApp — the ONE handler for every control host: the in-process tests, the app with its UI, and the
//  headless app (#298, docs/plans/control-plane.md §4 C). DEBUG-only (D30).
//
//  `handle(_:)` decodes nothing and owns no feature logic: each action is a call into the store, the album
//  session, the `AlbumActions` façade or the coordinator — the same call the button makes. What the host
//  adds is only what a user gets for free from the screen:
//
//  - **Reachability.** An action the user couldn't take from where the app is gets `refused(notShown)`
//    (a back button under the viewer, a photo outside the open review); one whose alias names nothing,
//    `unknownAlias`; a store that isn't hydrated, `invalidState` — never a silent `accepted` that did
//    nothing. Where the UI's own idempotence guard would swallow a repeat, the reply is `noop`.
//  - **The screen's own `.task`.** A screen starts its work when it appears: the Overview and the grid
//    open the album session (scan + publish, the grid reconciling, #289), the export screen runs the
//    export. With no view mounted (headless) nobody would, so after every navigation the host runs the
//    session call for the screen now on top (`screenTask`) — the SAME, idempotent call the view makes,
//    which joins the view's when there is one.
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
    private let assets: ControlAssetAliases
    private let albums: ControlAlbumAliases
    /// The snapshot as `state.json` would carry it now (content + run + the writer's rev).
    private let state: () -> ControlJSON
    private let rev: () -> Int

    init(graph: AppGraph, run: String, fixture: ControlFixture, assets: ControlAssetAliases,
         albums: ControlAlbumAliases, progress: ControlProgress,
         state: @escaping () -> ControlJSON, rev: @escaping () -> Int) {
        self.graph = graph
        self.run = run
        self.fixture = fixture
        self.assets = assets
        self.albums = albums
        self.progress = progress
        self.state = state
        self.rev = rev
    }

    fileprivate var coordinator: AppCoordinator { graph.coordinator }
    fileprivate var session: AlbumSession { graph.session }
    fileprivate var actions: AlbumActions { graph.actions }
    fileprivate var selection: SelectionStore { graph.selectionStore }
    fileprivate var done: DoneStore { graph.doneStore }

    // MARK: - Requests

    /// Handle one request file's bytes (`fileID` = the `n` of `req-<n>.json`, the reply's id when the
    /// bytes don't decode). Never throws: every failure is an error reply.
    func handle(data: Data, fileID: Int) async -> ControlResponse {
        let request: ControlRequest
        do throws(ControlRequestError) {
            request = try ControlRequest.decode(data)
        } catch {
            return ControlResponse(id: fileID, result: .failure(error))
        }
        guard request.id == fileID else {
            return ControlResponse(id: fileID, result: .failure(.bad("id \(request.id) doesn't match the file's \(fileID)")))
        }
        return await handle(request)
    }

    func handle(_ request: ControlRequest) async -> ControlResponse {
        guard request.run == run else {
            return ControlResponse(id: request.id, result: .failure(ControlRequestError(
                .staleRun, "request is for run \(request.run); this launch is \(run) — relaunched since?")))
        }
        switch request.command {
        case .send(let action):
            return ControlResponse(id: request.id, result: .success(await perform(action).json))
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

    func wait(_ predicates: [ControlPredicate], timeoutMs: Int) async -> Result<ControlJSON, ControlRequestError> {
        if let bad = ControlWait.undeclared(predicates) {
            return .failure(ControlRequestError(.undeclaredPath,
                                                "'\(bad.path)' is not a declared state path (see schema)"))
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

    /// The reply's `rev`: the revision `state.json` is at (the writer's).
    var currentRev: Int { rev() }
    var currentRun: String { run }

    // MARK: - Actions

    func perform(_ action: ControlAction) async -> ControlOutcome {
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

    private func refuse(_ reason: ControlRefusal, _ message: String) -> Refused {
        Refused(reason: reason, message: message)
    }

    // One case per action, each a guard or two and the one call — a switch is the clearest shape.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private func dispatch(_ action: ControlAction) throws(Refused) -> ControlOutcome {
        switch action {
        case .navOpenAlbum(let alias):
            let project = try albumsPhase(album: alias)
            actions.open(project)
            return accept()

        case .navOpenReview(let alias, let day):
            let project = try albumsPhase(album: alias)
            guard coordinator.path.last == .albumOverview(project.id), coordinator.presentedPhotoID == nil else {
                throw refuse(.notShown, "the review opens from \(alias)'s overview, which isn't on top")
            }
            coordinator.openReview(project.id, day: day)
            return accept()

        case .navOpenExport:
            let project = try openAlbumOnScreen()
            let onTop = coordinator.path.last
            if onTop == .export(project.id) { return .noop("export is already on top") }
            // The Overview's "Save to Photos", the finished grid's and the viewer's end-of-set forward path.
            guard onTop == .albumOverview(project.id) || onTop.map(isReview) == true else {
                throw refuse(.notShown, "export opens from the album's overview, grid or viewer")
            }
            coordinator.finishToExport()
            return accept()

        case .navOpenSettings(let alias):
            let project = try albumsPhase(album: alias)
            if coordinator.path.last == .settings(project.id) { return .noop("album settings already on top") }
            guard coordinator.path.last == .albumOverview(project.id), coordinator.presentedPhotoID == nil else {
                throw refuse(.notShown, "album settings open from \(alias)'s overview, which isn't on top")
            }
            coordinator.openSettings(project.id)
            return accept()

        case .navOpenAppSettings:
            try requireAlbumsPhase()
            // The coordinator's own guard (#258): a repeat would be swallowed — say so.
            if coordinator.path.last == .appSettings { return .noop("app settings already on top") }
            try requireNoViewer()
            coordinator.openAppSettings()
            return accept()

        case .navBack:
            try requireAlbumsPhase()
            try requireNoViewer()
            guard !coordinator.path.isEmpty else { return .noop("already at the album library") }
            coordinator.pop()
            return accept()

        case .navRoot:
            try requireAlbumsPhase()
            guard !coordinator.path.isEmpty || coordinator.presentedPhotoID != nil else {
                return .noop("already at the album library")
            }
            coordinator.popToRoot()
            return accept()

        case .viewerOpen(let alias):
            let id = try assetID(alias)
            if coordinator.presentedPhotoID == id { return .noop("the viewer already shows \(alias)") }
            guard coordinator.path.last.map(isReview) == true, coordinator.presentedPhotoID == nil,
                  session.reviewOrderedIDs.contains(id) else {
                throw refuse(.notShown, "\(alias) isn't in the open review grid")
            }
            coordinator.openPhoto(id)
            return accept(screen: false)

        case .viewerDismiss:
            guard coordinator.presentedPhotoID != nil else { return .noop("no viewer is open") }
            coordinator.dismissPhoto()
            return accept(screen: false)

        case .albumsCreate(let new):
            try requireAlbumsPhase()
            guard let project = actions.create(validated: draft(new)) else {
                throw refuse(.invalidState, "not a valid album (a name and a non-empty period are required)")
            }
            return accept(extra: [.init(key: "album", value: .string(albums.assign(project.id)))])

        case .albumsDelete(let alias):
            let project = try albumsPhase(album: alias)
            guard actions.delete(project) else { throw refuse(.busy, "\(alias) is exporting") }
            return accept()

        case .albumsReset(let alias):
            let project = try albumsPhase(album: alias)
            guard actions.reset(project) else { throw refuse(.busy, "\(alias) is exporting") }
            return accept(screen: false)

        case .albumsDuplicate(let alias):
            let project = try albumsPhase(album: alias)
            let copy = actions.duplicate(project)
            return accept(extra: [.init(key: "album", value: .string(albums.assign(copy.id)))], screen: false)

        case .albumsUpdate(let alias, let edit):
            let project = try albumsPhase(album: alias)
            guard actions.update(project, with: edits(edit), calendar: graph.calendar) else {
                throw refuse(.invalidState, "the period would be empty or inverted")
            }
            return accept()

        case .albumsMarkAllUnreviewed(let alias):
            let project = try albumsPhase(album: alias)
            actions.markAllUnreviewed(project)
            return accept(screen: false)

        case .selectionToggle(let alias):
            let id = try assetID(alias)
            try requireSelectionActive()
            try requireInReview([id], alias)
            selection.toggle(id)
            return accept(screen: false)

        case .selectionSelect(let set), .selectionDeselect(let set):
            try requireSelectionActive()
            let ids = try reviewIDs(set)
            let selecting = if case .selectionSelect = action { true } else { false }
            let changes = selecting ? !ids.allSatisfy(selection.contains) : ids.contains(where: selection.contains)
            guard changes else { return .noop(selecting ? "already picked" : "none of them are picked") }
            if selecting { selection.select(ids) } else { selection.deselect(ids) }
            return accept(screen: false)

        case .selectionClear:
            try requireSelectionActive()
            guard !selection.selected.isEmpty else { return .noop("nothing is picked") }
            selection.clear()
            return accept(screen: false)

        case .doneToggle(let day):
            guard done.isActive else { throw refuse(.invalidState, "no album is open (the done store is inactive)") }
            guard let cluster = session.reviewClusters.first(where: { $0.days.contains(day) }) else {
                throw refuse(.notShown, "\(day) isn't a day of the open review")
            }
            done.toggle(cluster)
            return accept(screen: false)

        case .exportRun(let alias):
            return try exportRun(alias)

        case .authRequest:
            guard coordinator.rootPhase == .onboarding else {
                throw refuse(.notShown, "the access request is on onboarding; the app is at \(coordinator.rootPhase)")
            }
            return accept(screen: false) { [coordinator] in await coordinator.requestAuthorization() }
        }
    }

    /// `export.run`: from anywhere in the library, the whole path a user takes — open the album (as the
    /// album list does, if it isn't the open one), let its Overview scan publish the review context (so
    /// the completion stats are real, not just picks), go to export and run it. On a FAILED export screen
    /// it's the "Try again" button; on a finished one, a noop.
    private func exportRun(_ alias: String) throws(Refused) -> ControlOutcome {
        let project = try albumsPhase(album: alias)
        if session.isExporting(project) { throw refuse(.busy, "\(alias) is already exporting") }
        if coordinator.path.last == .export(project.id) {
            switch session.export.phase {
            case .done: return .noop("the export already finished")
            case .failed:
                let id = project.id
                return accept(screen: false) { [weak self, session] in
                    guard let self, isShown(.export(id), id) else { return }
                    await session.retryExport(project)
                }
            case .idle, .exporting: return accept()
            }
        }
        if coordinator.activeAlbumID != project.id { actions.open(project) }
        coordinator.finishToExport()
        // The Overview's open (publishes the review context the completion stats read), then the export
        // screen's own task — both the very calls those screens make.
        let id = project.id
        return accept(screen: false) { [weak self, session] in
            // As those screens' own tasks: only while the export screen is still there (an action in
            // between may have left it, or deleted the album).
            guard self?.isShown(.export(id), id) == true else { return }
            await session.openOverview(project).awaitPendingNames()
            guard self?.isShown(.export(id), id) == true else { return }
            await session.startExport(project)
        }
    }

    // MARK: - Fixture ops

    func perform(_ op: ControlFixtureOp) async -> ControlOutcome {
        switch op {
        case .flush:
            selection.flushNow()
            done.flushNow()
            return accept(screen: false)
        case .lifecycleResume:
            // Awaited before replying: a lever is finished when it returns.
            await graph.coordinator.refreshAuthorization()
            return accept(screen: false)
        case .libraryFailFetch(let failing):
            guard let fake = graph.photoLibrary as? FakePhotoLibrary else {
                return .refused(.unavailable, "not the fake library")
            }
            await fake.setFetchError(failing ? FakePhotoLibrary.FakeError.fetchFailed : nil)
            return accept(screen: false)
        case .libraryAuthorization(let status):
            guard let fake = graph.photoLibrary as? FakePhotoLibrary else {
                return .refused(.unavailable, "not the fake library")
            }
            await fake.setAuthorization(status)
            return accept(screen: false)
        case .reset(let name):
            return .refused(.unavailable, "a reset is a relaunch: Scripts/poimi.sh reset \(name)")
        }
    }

    // MARK: - The screen's own task

    /// The session call the screen on top makes when it appears — what its `.task` does under the UI,
    /// and what nothing would do headless — or `nil` when that screen starts no work. Decided NOW, for the
    /// screen the action left on top (one the next action merely covers still runs it), and skipped if,
    /// by the time it runs, that screen has left the path or its album was deleted — as a view's task is
    /// cancelled with its view. Idempotent: each call joins the view's, or no-ops when it already ran.
    func screenTask() -> (@MainActor () async -> Void)? {
        guard coordinator.rootPhase == .albums, let id = coordinator.activeAlbumID,
              let project = graph.projectStore.projects.first(where: { $0.id == id }),
              let route = coordinator.path.last else { return nil }
        let session = session
        let work: @MainActor () async -> Void
        switch route {
        case .albumOverview: work = { await session.openOverview(project).awaitPendingNames() }
        case .review: work = { await session.openReview(project).awaitPendingNames() }
        case .export: work = { await session.startExport(project) }
        case .settings, .appSettings: return nil
        }
        return { [weak self] in
            guard let self, isShown(route, id) else { return }
            await work()
        }
    }

    /// Whether `route` is still on the path and its album still exists.
    private func isShown(_ route: Route, _ albumID: UUID) -> Bool {
        coordinator.path.contains(route) && graph.projectStore.projects.contains { $0.id == albumID }
    }

    /// Admit the action: its own async `work` (if any), then — unless `screen` is false — the task of the
    /// screen it left on top. Settles when both finished.
    private func accept(extra: [ControlJSON.Member] = [], screen: Bool = true,
                        _ work: (@MainActor () async -> Void)? = nil) -> ControlOutcome {
        let screenWork = screen ? screenTask() : nil
        let seq = progress.begin {
            await work?()
            await screenWork?()
        }
        return .accepted(seq: seq, extra: extra)
    }
}

// MARK: - Lookups + reachability

extension ControlHost {

    private func requireAlbumsPhase() throws(Refused) {
        guard coordinator.rootPhase == .albums else {
            throw refuse(.notShown, "the album library isn't shown (the app is at \(coordinator.rootPhase))")
        }
    }

    private func requireNoViewer() throws(Refused) {
        guard coordinator.presentedPhotoID == nil else {
            throw refuse(.notShown, "the photo viewer covers the screen (viewer.dismiss first)")
        }
    }

    /// The album behind `alias`, in the albums phase.
    private func albumsPhase(album alias: String) throws(Refused) -> CurationProject {
        try requireAlbumsPhase()
        guard let id = albums.projectID(for: alias),
              let project = graph.projectStore.projects.first(where: { $0.id == id }) else {
            throw refuse(.unknownAlias, "no album \(alias) in this run")
        }
        return project
    }

    /// The album open on screen (its overview or deeper), or `notShown`.
    private func openAlbumOnScreen() throws(Refused) -> CurationProject {
        try requireAlbumsPhase()
        guard let id = coordinator.activeAlbumID,
              let project = graph.projectStore.projects.first(where: { $0.id == id }) else {
            throw refuse(.notShown, "no album is open")
        }
        return project
    }

    private func assetID(_ alias: String) throws(Refused) -> String {
        guard let id = assets.assetID(for: alias) else {
            throw refuse(.unknownAlias, "no photo \(alias) in fixture '\(fixture.rawValue)'")
        }
        return id
    }

    private func requireSelectionActive() throws(Refused) {
        guard selection.isActive else {
            throw refuse(.invalidState, "no album is open (the selection store is inactive)")
        }
    }

    private func requireInReview(_ ids: [String], _ what: String) throws(Refused) {
        let shown = Set(session.reviewOrderedIDs)
        guard ids.allSatisfy(shown.contains) else {
            throw refuse(.notShown, "\(what) isn't in the open album's review")
        }
    }

    /// The ids a bulk selection acts on — each in the open review.
    private func reviewIDs(_ set: ControlPhotoSet) throws(Refused) -> [String] {
        switch set {
        case .photos(let aliases):
            var ids: [String] = []
            for alias in aliases { ids.append(try assetID(alias)) }
            try requireInReview(ids, aliases.count == 1 ? aliases[0] : "a photo of \(aliases.joined(separator: ","))")
            return ids
        case .day(let day):
            let ids = session.reviewOrderedIDs.filter { session.reviewDayByID[$0] == day }
            guard !ids.isEmpty else { throw refuse(.notShown, "\(day) has no photos in the open review") }
            return ids
        }
    }

    private func isReview(_ route: Route) -> Bool {
        if case .review = route { return true }
        return false
    }

    /// `albums.create`'s draft: the setup form's defaults, with the given fields (inclusive end day →
    /// the model's end-exclusive bound, as the "To" picker does).
    private func draft(_ new: ControlNewAlbum) -> NewAlbumDraft {
        let calendar = graph.calendar
        var draft = NewAlbumDraft.priorCalendarYear(now: ControlFixture.rangeEnd, calendar: calendar)
        if let title = new.title { draft.title = title }
        draft.rangeStart = new.start.anchorDate(in: calendar) ?? draft.rangeStart
        if let end = new.end.anchorDate(in: calendar) {
            draft.rangeEnd = NewAlbumDraft.exclusiveEnd(forInclusiveDay: end, calendar: calendar)
        }
        draft.targetCount = new.target
        if let media = new.media { draft.media = media }
        if let excludeScreenshots = new.excludeScreenshots { draft.excludeScreenshots = excludeScreenshots }
        return draft
    }

    private func edits(_ edit: ControlAlbumEdit) -> AlbumEdits {
        let calendar = graph.calendar
        return AlbumEdits(
            title: edit.title,
            rangeStart: edit.start?.anchorDate(in: calendar),
            rangeEnd: edit.end?.anchorDate(in: calendar).map {
                NewAlbumDraft.exclusiveEnd(forInclusiveDay: $0, calendar: calendar)
            },
            targetCount: edit.target, media: edit.media,
            excludeScreenshots: edit.excludeScreenshots, locationEnabled: edit.locationEnabled)
    }
}

/// One reply: `{v, id, run, rev, ok, data | error}`.
struct ControlResponse {
    let id: Int
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
