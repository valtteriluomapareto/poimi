//
//  ControlSnapshot.swift
//  PoimiApp — the redacted state snapshot (`state.json`, #296; docs/plans/control-plane.md §5).
//
//  A projection of main-actor `@Observable` store state into a small, versioned, REDACTED JSON tree:
//  aliases instead of ids, counts and lengths instead of text. No `localIdentifier`, no title (length
//  only), no place name, no coordinate ever reaches it (asserted per fixture by ControlPlaneTests).
//
//  Built by the control runtime's observer — never from a View `body`.
//
//  Since slice B (#297) the album session, the stores' pending debounces and the trip-name pass are
//  observable, so `pending.selectionFlush` / `doneFlush` / `naming` / `export` and `active.export` are
//  real values. Slice C (#298) adds the action bookkeeping (`settledSeq` / `lastSeq`) and the fake's
//  thumbnail loads in flight (`pending.thumbnails`). `idle` covers what is observable — see
//  `ControlSnapshot.isIdle`.
//
#if DEBUG

import Foundation
import Curation

/// Everything a snapshot is projected from. All main-actor state; reading it inside
/// `withObservationTracking` registers exactly the dependencies the snapshot has.
@MainActor
struct ControlSnapshotInputs {
    let fixture: ControlFixture
    let coordinator: AppCoordinator
    let session: AlbumSession
    let viewer: ViewerStore
    let projects: ProjectStore
    let selection: SelectionStore
    let done: DoneStore
    let assetAliases: ControlAssetAliases
    let albumAliases: ControlAlbumAliases
    /// The action bookkeeping (`settledSeq` / `lastSeq`), or `nil` before a host exists.
    var progress: ControlProgress?
    /// The fake thumbnail provider's loads in flight, or `nil` when nothing counts them.
    var thumbnails: ThumbnailLoadCounter?
    /// The fake library's export gate (`library.*`, #300).
    let exportGate: FakeExportGate
    /// No UI: `ControlHeadlessView` instead of `AppRootView` (`app.host`).
    var headless = false
    /// A launch/route problem to surface (`app.launchError`), or `nil`.
    var launchError: String?
    /// The launch has finished: authorization read, route applied, viewer opened (or failed).
    var bootstrapped: Bool
    var idiom: String
    var timeZone: String
}

enum ControlSnapshot {
    static let version = 1

    // MARK: - state.json

    /// The snapshot content, WITHOUT the `run`/`rev` stamp (so equality means "nothing changed").
    /// A pure projection: no side effects, no I/O (it runs inside observation tracking). Album aliases
    /// are assigned beforehand by the writer.
    @MainActor
    static func content(_ inputs: ControlSnapshotInputs) -> ControlJSON {
        let coordinator = inputs.coordinator
        let activeProject = coordinator.activeAlbumID.flatMap { id in
            inputs.projects.projects.first { $0.id == id }
        }
        let session = sessionFor(activeProject, inputs)
        let store = session?.candidateStore
        let export = session?.export.phase ?? .idle
        return .object(
            ("settledSeq", .int(inputs.progress?.settledSeq ?? 0)),
            ("lastSeq", .int(inputs.progress?.lastSeq ?? 0)),
            ("app", app(inputs)),
            ("nav", nav(inputs)),
            ("albums", albums(inputs)),
            ("active", active(inputs, project: activeProject, store: store, export: export)),
            ("library", library(inputs.exportGate)),
            ("pending", .object(
                ("selectionFlush", .bool(inputs.selection.hasPendingFlush)),
                ("doneFlush", .bool(inputs.done.hasPendingFlush)),
                ("scan", .bool(store?.phase == .scanning)),
                ("naming", .bool(store?.isNaming ?? false)),
                // Any album's export in flight — also one whose screen left (iPad, #300): still live work.
                ("export", .bool(export.isRunning || !inputs.session.exportingAlbums.isEmpty)),
                ("thumbnails", .int(inputs.thumbnails?.inFlight ?? 0)))),
            ("idle", isIdle(inputs, store: store, export: export).map(ControlJSON.bool) ?? .null))
    }

    /// The album session, if it holds the album on screen (it may still hold nothing, or — briefly —
    /// another album's leftovers before the new one's screen opens it).
    @MainActor
    private static func sessionFor(_ project: CurationProject?, _ inputs: ControlSnapshotInputs) -> AlbumSession? {
        guard let project, inputs.session.projectID == project.id else { return nil }
        return inputs.session
    }

    /// `content` stamped with the format version, the per-launch `run` id and the revision.
    static func stamped(_ content: ControlJSON, run: String, rev: Int) -> ControlJSON {
        content.prepending(("snapshotVersion", .int(version)), ("run", .string(run)), ("rev", .int(rev)))
    }

    /// Whether the app has settled — `true`, `false`, or `nil` for "unknown" (never a silent `true`):
    /// - `false` until the launch bootstrap finished; while an accepted action hasn't settled
    ///   (`settledSeq < lastSeq`); while a review scan or its trip-name pass runs, any export runs, or a
    ///   fake thumbnail load is in flight — including "the screen on top needs a scan / an export that
    ///   hasn't started yet" (the screen's `.task` runs after the route lands, so a missing or `.idle`
    ///   store there is pending, not idle).
    /// - `true` otherwise.
    /// - Deliberately NOT covered: debounced flushes. Under control the debounce is a day long, so an
    ///   `idle` that waited on them would stay `false` after every tap until an explicit flush — and the
    ///   in-memory picks are already the truth the UI shows (D15). `pending.selectionFlush` / `doneFlush`
    ///   report them; call `fixture flush` before checking what was PERSISTED.
    @MainActor
    static func isIdle(_ inputs: ControlSnapshotInputs, store: CandidateStore?,
                       export: ExportStore.Phase) -> Bool? {
        guard inputs.bootstrapped else { return false }
        if let progress = inputs.progress, progress.settledSeq < progress.lastSeq { return false }
        if (inputs.thumbnails?.inFlight ?? 0) > 0 { return false }
        if store?.phase == .scanning || store?.isNaming == true || export.isRunning { return false }
        if !inputs.session.exportingAlbums.isEmpty { return false }   // an export whose screen left (#300)
        let coordinator = inputs.coordinator
        guard coordinator.rootPhase == .albums else { return true }
        switch coordinator.path.last {
        case .albumOverview, .review:
            switch store?.phase {
            case .ready, .empty, .failed: return true
            case .idle, .scanning, nil: return false
            }
        case .export:
            switch export {
            case .done, .failed: return true
            case .idle, .exporting: return false
            }
        case .settings, .appSettings, nil:
            return true
        }
    }

    @MainActor
    private static func app(_ inputs: ControlSnapshotInputs) -> ControlJSON {
        .object(
            ("rootPhase", .string(rootPhase(inputs.coordinator.rootPhase))),
            ("authorization", .string(authorization(inputs.coordinator.authorization))),
            ("library", .string("fake")),
            ("fixture", .string(inputs.fixture.rawValue)),
            ("host", .string(inputs.headless ? "headless" : "ui")),
            ("idiom", .string(inputs.idiom)),
            ("timeZone", .string(inputs.timeZone)),
            ("launchError", .string(inputs.launchError)))
    }

    @MainActor
    private static func nav(_ inputs: ControlSnapshotInputs) -> ControlJSON {
        let coordinator = inputs.coordinator
        let screen: String = switch coordinator.rootPhase {
        case .onboarding: "onboarding"
        case .recovery: "recovery"
        case .albums: coordinator.path.last.map(screenName) ?? "albums"
        }
        // The viewer is its own sheet over the grid; the coordinator's modal (#299) covers the rest.
        let viewerUp = coordinator.presentedPhotoID != nil
        let sheet: String? = viewerUp ? "viewer" : coordinator.modal.map { ControlModal($0).rawValue }
        var sheetAlbum: String?
        if !viewerUp, case .confirm(let confirmation)? = coordinator.modal {
            sheetAlbum = inputs.albumAliases.alias(for: confirmation.album)
        }
        let photo = viewerUp ? (inputs.viewer.currentID ?? coordinator.presentedPhotoID) : nil
        // The auto-done toast (#128): the day it marked + how many auto-marks so far (a new toast for the
        // same day still bumps it). In the UI it hides after a few seconds (a view timer); headless it
        // stays until Undo or the next opening.
        let toast: ControlJSON = if viewerUp, let cluster = inputs.viewer.autoDoneCluster {
            .object(("day", .string(cluster.firstDay?.description)), ("marks", .int(inputs.viewer.autoDoneCount)))
        } else {
            .null
        }
        return .object(
            ("screen", .string(screen)),
            ("path", .array(coordinator.path.map { route(for: $0, albums: inputs.albumAliases) })),
            ("sheet", .string(sheet)),
            ("sheetAlbum", .string(sheetAlbum)),
            ("viewerPhoto", .string(photo.flatMap(inputs.assetAliases.alias(for:)))),
            ("viewerEndOfSet", viewerUp ? .bool(inputs.viewer.endReached) : .null),
            ("viewerToast", toast))
    }

    @MainActor
    private static func albums(_ inputs: ControlSnapshotInputs) -> ControlJSON {
        let activeID = inputs.selection.isActive ? inputs.selection.activeProjectID : nil
        // Every project is aliased before a snapshot is built (`ControlStateWriter.flush`).
        let rows = inputs.projects.projects.compactMap { project -> (alias: String, value: ControlJSON)? in
            guard let alias = inputs.albumAliases.alias(for: project.id) else { return nil }
            // The active album's picks are the live in-memory set (D15); the rest are persisted.
            let picks = project.persistentModelID == activeID ? inputs.selection.selected : project.persistedPicks
            let status = project.status(currentPicks: picks)
            return (alias, .object(
                ("status", .string(statusName(status))),
                ("toAdd", .int(toAdd(status))),
                ("target", .int(project.targetCount)),
                ("picked", .int(picks.count)),
                ("titleLength", .int(project.title.count)),
                ("exported", .bool(project.markedDoneAt != nil)),
                // The row's "N in Photos": the Photos album's membership recorded at the last export (#191),
                // never the live pick count; `null` before any export.
                ("inPhotos", .int(project.exportedPhotoCount))))
        }
        return .object(pairs: rows
            .sorted { ControlAlbumAliases.number(of: $0.alias) < ControlAlbumAliases.number(of: $1.alias) }
            .map { ($0.alias, $0.value) })
    }

    @MainActor
    private static func active(_ inputs: ControlSnapshotInputs, project: CurationProject?,
                               store: CandidateStore?, export: ExportStore.Phase) -> ControlJSON {
        guard let project else {
            return .object(("album", .null), ("scan", .null), ("selection", .null), ("done", .null),
                           ("export", .null), ("overview", .null), ("grid", .null))
        }
        // The session's screen state (#299) belongs to this album only when the session holds it.
        let session = inputs.session.projectID == project.id ? inputs.session : nil
        let clusters: [ReviewCluster]
        if case .ready(let ready) = store?.phase { clusters = ready } else { clusters = [] }
        let selectionActive = inputs.selection.isActive
            && inputs.selection.activeProjectID == project.persistentModelID
        let doneActive = inputs.done.isActive && inputs.done.activeProjectID == project.persistentModelID
        return .object(
            ("album", .string(inputs.albumAliases.alias(for: project.id))),
            ("scan", .object(
                ("phase", .string(store.map { scanPhase($0.phase) } ?? "none")),
                ("reason", .string(store.flatMap { scanReason($0.phase) })),
                ("candidates", .int(store?.assetsByID.count ?? 0)),
                ("clusters", .int(clusters.count)),
                ("trips", .int(clusters.count { $0.tripCluster != nil })))),
            ("selection", .object(
                ("count", .int(selectionActive ? inputs.selection.selected.count : project.persistedPickedCount)),
                ("target", .int(project.targetCount)),
                ("active", .bool(selectionActive)))),
            ("done", .object(
                ("days", .int(doneActive ? inputs.done.doneDays.count : project.doneDays.count)),
                ("clusters", .int(doneActive ? clusters.count { inputs.done.isDone($0) } : 0)),
                ("of", .int(clusters.count)),
                ("active", .bool(doneActive)))),
            ("export", .object(
                ("phase", .string(exportPhase(export))),
                ("wasReExport", wasReExport(export).map(ControlJSON.bool) ?? .null),
                // The completion screen's "Added N · … now holds M" (`done` only).
                ("added", .int(exportResult(export)?.added)),
                ("total", .int(exportResult(export)?.total)))),
            ("overview", .object(
                ("filter", .string((session?.overviewFilter ?? .all).controlName)))),
            ("grid", .object(
                // The current cluster by its first day (clusters are keyed by day, §5) — `null` until the
                // grid is open and has entered.
                ("cluster", .string(session?.currentReviewCluster?.firstDay?.description)))))
    }

    // MARK: - state-detail.json

    /// Per-day detail for the active album only (`state.json` stays small at `scale`): each day's
    /// photos as aliases, which of them are picked, and whether the day is done. `days` is empty until
    /// the scan is ready. The day → photos table comes from `cache` (built once per scanned store), so
    /// a burst of picks only recomputes `picked`/`done`.
    @MainActor
    static func detail(_ inputs: ControlSnapshotInputs, cache: ControlDetailCache) -> ControlJSON {
        let coordinator = inputs.coordinator
        guard let activeID = coordinator.activeAlbumID,
              let project = inputs.projects.projects.first(where: { $0.id == activeID }),
              let store = sessionFor(project, inputs)?.candidateStore, case .ready = store.phase else {
            cache.invalidate()
            return .object(("album", .null), ("days", .object(pairs: [])))
        }
        let selected = inputs.selection.activeProjectID == project.persistentModelID
            ? inputs.selection.selected : project.persistedPicks
        let doneDays = inputs.done.activeProjectID == project.persistentModelID
            ? inputs.done.doneDays : Set(project.doneDays.compactMap(DayKey.init))
        let days = cache.days(for: store, aliases: inputs.assetAliases).map { row -> (String, ControlJSON) in
            let picked = row.ids.indices
                .filter { selected.contains(row.ids[$0]) }
                .map { ControlJSON.string(row.aliases[$0]) }
            return (row.day.description, .object(
                ("photos", .array(row.aliases.map(ControlJSON.string))),
                ("picked", .array(picked)),
                ("done", .bool(doneDays.contains(row.day)))))
        }
        return .object(("album", .string(inputs.albumAliases.alias(for: project.id))),
                       ("days", .object(pairs: days)))
    }

    // MARK: - Names

    private static func screenName(_ route: Route) -> String {
        switch route {
        case .albumOverview: "overview"
        case .review: "review"
        case .export: "export"
        case .settings: "settings"
        case .appSettings: "appSettings"
        }
    }

    /// A path element, named by its `Route` case (`nav.screen` uses the shorter screen names).
    @MainActor
    private static func route(for route: Route, albums: ControlAlbumAliases) -> ControlJSON {
        switch route {
        case .albumOverview(let id):
            .object(("route", .string("albumOverview")), ("album", .string(albums.alias(for: id))))
        case .export(let id), .settings(let id):
            .object(("route", .string(screenName(route))), ("album", .string(albums.alias(for: id))))
        case .review(let id, let day):
            .object(("route", .string("review")), ("album", .string(albums.alias(for: id))),
                    ("day", .string(day?.description)))
        case .appSettings:
            .object(("route", .string("appSettings")))
        }
    }

    private static func rootPhase(_ phase: RootPhase) -> String {
        switch phase {
        case .onboarding: "onboarding"
        case .albums: "albums"
        case .recovery: "recovery"
        }
    }

    static func authorization(_ status: LibraryAuthorization) -> String {
        switch status {
        case .notDetermined: "notDetermined"
        case .authorized: "authorized"
        case .limited: "limited"
        case .denied: "denied"
        case .restricted: "restricted"
        }
    }

    private static func statusName(_ status: ProjectStatus) -> String {
        switch status {
        case .empty: "empty"
        case .inProgress: "inProgress"
        case .exported: "exported"
        case .editedSinceExport: "editedSinceExport"
        }
    }

    private static func toAdd(_ status: ProjectStatus) -> Int? {
        if case .editedSinceExport(let toAdd) = status { return toAdd }
        return nil
    }

    @MainActor
    private static func exportPhase(_ phase: ExportStore.Phase) -> String {
        switch phase {
        case .idle: "idle"
        case .exporting: "exporting"
        case .done: "done"
        case .failed: "failed"
        }
    }

    /// Whether the settled export updated an existing Photos album (`done` only; `null` otherwise).
    @MainActor
    private static func wasReExport(_ phase: ExportStore.Phase) -> Bool? {
        if case .done(_, let wasReExport) = phase { return wasReExport }
        return nil
    }

    @MainActor
    private static func exportResult(_ phase: ExportStore.Phase) -> ExportResult? {
        if case .done(let result, _) = phase { return result }
        return nil
    }

    /// The fake library's side of exports (#300) — what the user would see in Photos, as counts: exports
    /// parked at the gate, export calls so far, and Photos albums export created (a re-export that finds
    /// its album doesn't create one).
    @MainActor
    private static func library(_ gate: FakeExportGate) -> ControlJSON {
        return .object(
            ("heldExports", .int(gate.held)),
            ("exportCalls", .int(gate.calls)),
            ("albumsCreated", .int(gate.albumsCreated)))
    }

    @MainActor
    private static func scanPhase(_ phase: CandidateStore.Phase) -> String {
        switch phase {
        case .idle: "idle"
        case .scanning: "scanning"
        case .ready: "ready"
        case .empty: "empty"
        case .failed: "failed"
        }
    }

    @MainActor
    private static func scanReason(_ phase: CandidateStore.Phase) -> String? {
        switch phase {
        case .empty(.noPhotosInRange): "noPhotosInRange"
        case .empty(.allExcluded): "allExcluded"
        case .empty(.noVideosInRange): "noVideosInRange"
        case .failed(.loadError): "loadError"
        case .failed(.accessLost): "accessLost"
        case .idle, .scanning, .ready: nil
        }
    }
}

/// The active album's day → photos table, built once per scanned `CandidateStore` (by identity) and
/// dropped whenever no store is ready — a re-scan passes through `.scanning`, and a Settings edit makes
/// a new store — so `scale` doesn't regroup ~10k photos on every burst of picks.
@MainActor
final class ControlDetailCache {
    struct Day {
        let day: DayKey
        /// The day's photo ids in alias order, index-aligned with `aliases`.
        let ids: [String]
        let aliases: [String]
    }

    private var storeID: ObjectIdentifier?
    private var table: [Day] = []

    func days(for store: CandidateStore, aliases: ControlAssetAliases) -> [Day] {
        if storeID == ObjectIdentifier(store) { return table }
        var idsByDay: [DayKey: [String]] = [:]
        for (id, day) in store.dayByID { idsByDay[day, default: []].append(id) }
        table = idsByDay.keys.sorted().map { day in
            let ids = aliases.ordered(idsByDay[day] ?? [])
            return Day(day: day, ids: ids, aliases: ids.compactMap(aliases.alias(for:)))
        }
        storeID = ObjectIdentifier(store)
        return table
    }

    func invalidate() {
        storeID = nil
        table = []
    }
}

/// `rev` bookkeeping: bumps only when the content actually changed.
struct ControlRevision {
    private(set) var rev = 0
    private var last: ControlJSON?

    /// Record `content`; returns `true` (and bumps `rev`) iff it differs from the last recorded content.
    mutating func record(_ content: ControlJSON) -> Bool {
        guard content != last else { return false }
        last = content
        rev += 1
        return true
    }
}

#endif
