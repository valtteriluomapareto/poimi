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
//  real values. What still can't be observed honestly stays an explicit `null`, not a guess:
//  `pending.thumbnails` (slice C adds a counter, and `settledSeq`). `idle` covers what IS observable —
//  see `ControlSnapshot.isIdle`.
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
    let projects: ProjectStore
    let selection: SelectionStore
    let done: DoneStore
    let assetAliases: ControlAssetAliases
    let albumAliases: ControlAlbumAliases
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
            ("app", app(inputs)),
            ("nav", nav(inputs)),
            ("albums", albums(inputs)),
            ("active", active(inputs, project: activeProject, store: store, export: export)),
            ("pending", .object(
                ("selectionFlush", .bool(inputs.selection.hasPendingFlush)),
                ("doneFlush", .bool(inputs.done.hasPendingFlush)),
                ("scan", .bool(store?.phase == .scanning)),
                ("naming", .bool(store?.isNaming ?? false)),
                ("export", .bool(export.isRunning)),
                ("thumbnails", .null))),
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
    /// - `false` until the launch bootstrap finished, while a review scan or its trip-name pass runs, and
    ///   while an export runs — including "the screen on top needs a scan / an export that hasn't started
    ///   yet" (the screen's `.task` runs after the route lands, so a missing or `.idle` store there is
    ///   pending, not idle).
    /// - `true` otherwise.
    /// - NOT covered: debounced flushes (reported under `pending`; under control the debounce is a day
    ///   long and there's no `flush` action until slice C, so an `idle` that waited on them would never
    ///   settle after a tap) and thumbnail loads (slice C's counter).
    @MainActor
    static func isIdle(_ inputs: ControlSnapshotInputs, store: CandidateStore?,
                       export: ExportStore.Phase) -> Bool? {
        guard inputs.bootstrapped else { return false }
        if store?.phase == .scanning || store?.isNaming == true || export.isRunning { return false }
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
        let viewer = coordinator.presentedPhotoID
        return .object(
            ("screen", .string(screen)),
            ("path", .array(coordinator.path.map { route(for: $0, albums: inputs.albumAliases) })),
            ("sheet", viewer == nil ? .null : .string("viewer")),
            ("viewerPhoto", .string(viewer.flatMap(inputs.assetAliases.alias(for:)))))
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
                ("exported", .bool(project.markedDoneAt != nil))))
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
                           ("export", .null))
        }
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
                ("wasReExport", wasReExport(export).map(ControlJSON.bool) ?? .null))))
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
