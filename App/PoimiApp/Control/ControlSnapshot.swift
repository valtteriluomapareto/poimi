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
//  Fields that slice A can't observe honestly are explicit `null`, not a guess:
//  `pending.selectionFlush` / `doneFlush` (the debounce task isn't observable yet), `pending.naming`
//  (the name task is private), `active.export.phase` + `pending.export` (`ExportStore` is view state),
//  `pending.thumbnails`. Slice B lifts the album session into a store and fills these in; slice C adds
//  `settledSeq`. `idle` covers what IS observable — see `ControlSnapshot.isIdle`.
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
    @MainActor
    static func content(_ inputs: ControlSnapshotInputs) -> ControlJSON {
        let coordinator = inputs.coordinator
        inputs.albumAliases.registerNew(inputs.projects.projects)
        let activeProject = coordinator.activeAlbumID.flatMap { id in
            inputs.projects.projects.first { $0.id == id }
        }
        let store = activeProject == nil ? nil : coordinator.candidateStore
        let scanning = store?.phase == .scanning
        return .object(
            ("app", app(inputs)),
            ("nav", nav(inputs)),
            ("albums", albums(inputs)),
            ("active", active(inputs, project: activeProject, store: store)),
            ("pending", .object(
                ("selectionFlush", .null),
                ("doneFlush", .null),
                ("scan", .bool(scanning)),
                ("naming", .null),
                ("export", .null),
                ("thumbnails", .null))),
            ("idle", .bool(isIdle(inputs, store: store))))
    }

    /// `content` stamped with the format version, the per-launch `run` id and the revision.
    static func stamped(_ content: ControlJSON, run: String, rev: Int) -> ControlJSON {
        content.prepending(("snapshotVersion", .int(version)), ("run", .string(run)), ("rev", .int(rev)))
    }

    /// Whether the app has settled, as far as slice A can observe: the launch bootstrap finished, and
    /// no scan is running — including "the screen on top needs a scan that hasn't started yet" (the
    /// review/overview `.task` runs after the route lands, so a missing or `.idle` store there is
    /// pending, not idle). NOT covered yet (slice B/C): debounced flushes, trip naming, an export
    /// started by `ExportView`, thumbnail loads.
    @MainActor
    static func isIdle(_ inputs: ControlSnapshotInputs, store: CandidateStore?) -> Bool {
        guard inputs.bootstrapped else { return false }
        if store?.phase == .scanning { return false }
        let coordinator = inputs.coordinator
        guard coordinator.rootPhase == .albums else { return true }
        switch coordinator.path.last {
        case .albumOverview, .review:
            switch store?.phase {
            case .ready, .empty, .failed: return true
            case .idle, .scanning, nil: return false
            }
        default:
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
        let rows = inputs.projects.projects.map { project -> (alias: String, value: ControlJSON) in
            // The active album's picks are the live in-memory set (D15); the rest are persisted.
            let picks = project.persistentModelID == activeID ? inputs.selection.selected : project.persistedPicks
            let status = project.status(currentPicks: picks)
            return (inputs.albumAliases.alias(for: project.id), .object(
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
                               store: CandidateStore?) -> ControlJSON {
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
            ("export", .object(("phase", .null))))
    }

    // MARK: - state-detail.json

    /// Per-day detail for the active album only (`state.json` stays small at `scale`): each day's
    /// photos as aliases, which of them are picked, and whether the day is done. `days` is empty until
    /// the scan is ready.
    @MainActor
    static func detail(_ inputs: ControlSnapshotInputs) -> ControlJSON {
        let coordinator = inputs.coordinator
        guard let activeID = coordinator.activeAlbumID,
              let project = inputs.projects.projects.first(where: { $0.id == activeID }),
              let store = coordinator.candidateStore, case .ready = store.phase else {
            return .object(("album", .null), ("days", .object(pairs: [])))
        }
        var idsByDay: [DayKey: [String]] = [:]
        for (id, day) in store.dayByID { idsByDay[day, default: []].append(id) }
        let selected = inputs.selection.activeProjectID == project.persistentModelID
            ? inputs.selection.selected : project.persistedPicks
        let doneDays = inputs.done.activeProjectID == project.persistentModelID
            ? inputs.done.doneDays : Set(project.doneDays.compactMap(DayKey.init))
        let days = idsByDay.keys.sorted().map { day -> (String, ControlJSON) in
            let ids = idsByDay[day] ?? []
            return (day.description, .object(
                ("photos", .array(inputs.assetAliases.aliases(for: ids).map(ControlJSON.string))),
                ("picked", .array(inputs.assetAliases.aliases(for: ids.filter(selected.contains))
                    .map(ControlJSON.string))),
                ("done", .bool(doneDays.contains(day)))))
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
