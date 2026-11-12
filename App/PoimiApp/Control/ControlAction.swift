//
//  ControlAction.swift
//  PoimiApp — the control plane's actions (what a user does) and fixture ops (test levers), each
//  declared ONCE with its arguments: the decoder and the `schema` reply both read the declaration, so
//  they can't drift (#298, docs/plans/control-plane.md §4 C). DEBUG-only (D30).
//
//  An action is something the UI offers: each maps to one control a user can reach (a row, a button, a
//  chip). Things no control does — picking an arbitrary photo list, clearing every pick — are fixture
//  ops, so an agent can't mistake a lever for a user path.
//
#if DEBUG

import Foundation
import Curation

/// An argument's declared JSON shape — read by the decoder and printed by `schema`.
enum ControlArgType: String {
    case albumAlias = "album alias (album-N)"
    case assetAlias = "photo alias (a-NNNN)"
    case assetAliases = "[photo alias]"
    case day = "day (yyyy-mm-dd)"
    case int
    case bool
    case string
    case media = "photosOnly | photosAndVideos | videosOnly"
    case fetchFailure = "fetchFailed | null"
    case exportFailure = "albumMissing | writeFailed | noAssetsResolved | null"
    case authorization = "notDetermined | authorized | limited | denied | restricted"
    case fixture = "fixture name"
    case filter = "toReview | done | all"
    case direction = "next | previous"
    case modal = "newAlbum | whatsNew | confirmDelete | confirmReset | confirmUnreview"
}

/// The Overview filter's lenses by name (`review.setFilter`, `-PoimiFilter`, `active.overview.filter`).
extension ReviewFilter {
    static let controlNames: [(name: String, filter: ReviewFilter)] = [
        ("toReview", .toReview), ("done", .done), ("all", .all)
    ]

    init?(controlName: String) {
        guard let match = Self.controlNames.first(where: { $0.name == controlName }) else { return nil }
        self = match.filter
    }

    var controlName: String {
        Self.controlNames.first { $0.filter == self }?.name ?? "all"
    }
}

/// `ui.present`'s modals by name — each the button that presents it (`nav.sheet` reports them so).
enum ControlModal: String, CaseIterable {
    case newAlbum
    case whatsNew
    case confirmDelete
    case confirmReset
    case confirmUnreview

    /// The confirmation kind, for the three that need an album.
    var confirmation: AlbumConfirmation.Kind? {
        switch self {
        case .newAlbum, .whatsNew: nil
        case .confirmDelete: .delete
        case .confirmReset: .reset
        case .confirmUnreview: .markAllUnreviewed
        }
    }

    /// The control name of a coordinator modal.
    init(_ modal: AppModal) {
        switch modal {
        case .newAlbum: self = .newAlbum
        case .whatsNew: self = .whatsNew
        case .confirm(let confirmation):
            switch confirmation.kind {
            case .delete: self = .confirmDelete
            case .reset: self = .confirmReset
            case .markAllUnreviewed: self = .confirmUnreview
            }
        }
    }
}

/// `viewer.page`'s target: a chevron / swipe step, or a filmstrip tap on a photo.
enum ControlPageTarget: Equatable {
    case next
    case previous
    case photo(String)
}

struct ControlArgSpec {
    let name: String
    let type: ControlArgType
    let required: Bool

    static func req(_ name: String, _ type: ControlArgType) -> ControlArgSpec {
        ControlArgSpec(name: name, type: type, required: true)
    }

    static func opt(_ name: String, _ type: ControlArgType) -> ControlArgSpec {
        ControlArgSpec(name: name, type: type, required: false)
    }
}

/// The action names, each with its declared arguments. `CaseIterable`, so `schema` and the
/// every-action-is-exercised test enumerate the same list the decoder accepts.
enum ControlActionKind: String, CaseIterable {
    case navOpenAlbum = "nav.openAlbum"
    case navOpenReview = "nav.openReview"
    case navOpenExport = "nav.openExport"
    case navOpenSettings = "nav.openSettings"
    case navOpenAppSettings = "nav.openAppSettings"
    case navBack = "nav.back"
    case navRoot = "nav.root"
    case viewerOpen = "viewer.open"
    case viewerDismiss = "viewer.dismiss"
    case albumsCreate = "albums.create"
    case albumsDelete = "albums.delete"
    case albumsReset = "albums.reset"
    case albumsDuplicate = "albums.duplicate"
    case albumsUpdate = "albums.update"
    case albumsMarkAllUnreviewed = "albums.markAllUnreviewed"
    case selectionToggle = "selection.toggle"
    case selectionToggleCluster = "selection.toggleCluster"
    case doneToggle = "done.toggle"
    case exportRetry = "export.retry"
    case authRequest = "auth.request"
    case reviewSetFilter = "review.setFilter"
    case reviewGoTo = "review.goTo"
    case reviewMarkDoneAndAdvance = "review.markDoneAndAdvance"
    case viewerPage = "viewer.page"
    case viewerPick = "viewer.pick"
    case viewerKeepReviewing = "viewer.keepReviewing"
    case viewerUndoAutoDone = "viewer.undoAutoDone"
    case uiPresent = "ui.present"
    case uiConfirm = "ui.confirm"
    case uiDismiss = "ui.dismiss"

    var args: [ControlArgSpec] {
        switch self {
        case .navOpenAlbum, .navOpenSettings, .albumsDelete, .albumsReset, .albumsDuplicate,
             .albumsMarkAllUnreviewed:
            [.req("album", .albumAlias)]
        case .navOpenReview: [.req("album", .albumAlias), .opt("day", .day)]
        case .navOpenExport, .navOpenAppSettings, .navBack, .navRoot, .viewerDismiss, .authRequest,
             .reviewMarkDoneAndAdvance, .viewerPick, .viewerKeepReviewing, .viewerUndoAutoDone, .uiConfirm,
             .uiDismiss: []
        case .viewerOpen, .selectionToggle: [.req("photo", .assetAlias)]
        case .reviewSetFilter: [.req("filter", .filter)]
        case .reviewGoTo: [.req("day", .day)]
        case .viewerPage: [.opt("direction", .direction), .opt("photo", .assetAlias)]
        case .uiPresent: [.req("modal", .modal), .opt("album", .albumAlias)]
        case .albumsCreate:
            [.opt("title", .string), .req("start", .day), .req("end", .day), .req("target", .int),
             .opt("media", .media), .opt("excludeScreenshots", .bool)]
        case .albumsUpdate:
            [.req("album", .albumAlias), .opt("title", .string), .opt("start", .day), .opt("end", .day),
             .opt("target", .int), .opt("media", .media), .opt("excludeScreenshots", .bool),
             .opt("locationEnabled", .bool)]
        case .selectionToggleCluster, .doneToggle: [.req("day", .day)]
        case .exportRetry: [.opt("newAlbum", .bool)]
        }
    }

    /// The control it is, and where it's reachable — for `schema`.
    var summary: String {
        switch self {
        case .navOpenAlbum: "tap the album's row in the album list (bump + its overview, which scans)"
        case .navOpenReview: "tap a day/cluster on the album's overview: the review grid (on that day), which scans"
        case .navOpenExport:
            "Save to Photos: the overview's button, or the fully-reviewed grid's (needs picks); "
                + "the export screen runs the export"
        case .navOpenSettings: "the overview's settings button: album settings"
        case .navOpenAppSettings: "the album list's cog: app settings (noop when already on top, #258)"
        case .navBack: "the back button (not under the viewer)"
        case .navRoot: "back to the album list"
        case .viewerOpen: "tap a photo in the review grid: the viewer"
        case .viewerDismiss: "pull the viewer down (or the end-of-set card's Back to grid); the grid follows the photo"
        case .albumsCreate:
            "the New album sheet's Create (inclusive start/end days), from the sheet or the album list; opens it"
        case .albumsDelete: "Delete, from the album list or that album's settings; refused busy while it exports"
        case .albumsReset: "Reset all progress, from the album list or that album's settings; busy while it exports"
        case .albumsDuplicate: "Duplicate, from the album list"
        case .albumsUpdate: "edit fields on that album's settings screen (inclusive end day); committed at once"
        case .albumsMarkAllUnreviewed: "Mark all days unreviewed, on that album's settings (#285)"
        case .selectionToggle: "tap a grid cell: toggle one photo"
        case .selectionToggleCluster: "the grid's select-all chip on the cluster holding that day"
        case .doneToggle: "the grid's done seal on the cluster holding that day (a trip toggles all its days)"
        case .exportRetry: "a failed export screen's Try again (newAlbum: Create a new album instead)"
        case .authRequest: "onboarding's continue: request photo access (answers with the fake's status)"
        case .reviewSetFilter: "the overview's filter menu (shown with more than one cluster)"
        case .reviewGoTo: "swipe the review grid to the cluster holding that day"
        case .reviewMarkDoneAndAdvance:
            "the current cluster's end-cap: Mark day done → the next unreviewed cluster (reopens a done one)"
        case .viewerPage:
            "the viewer: direction = the ‹ › chevrons / a swipe (forward past a cluster's end marks it done; "
                + "next on the last photo opens the end-of-set card); photo = a filmstrip tap (never marks)"
        case .viewerPick: "the viewer's Pick: toggle; a pick advances (the end-of-set card after the last photo)"
        case .viewerKeepReviewing: "the end-of-set card's Keep reviewing"
        case .viewerUndoAutoDone: "the auto-done toast's Undo (#128): reopens the cluster the viewer just marked"
        case .uiPresent:
            "the button that opens it: New album (album list), What's New (app settings), Delete / Reset all "
                + "progress (album list or that album's settings; album), Mark all days unreviewed (settings; album)"
        case .uiConfirm: "the open confirmation's confirm button (Delete / Discard picks / Mark all unreviewed)"
        case .uiDismiss: "Cancel / swipe down / Continue on the open sheet or dialog"
        }
    }
}

/// A decoded action. Aliases are checked for SHAPE here; whether they name something is the host's
/// call (`refused(unknownAlias)`).
enum ControlAction: Equatable {
    case navOpenAlbum(album: String)
    case navOpenReview(album: String, day: DayKey?)
    case navOpenExport
    case navOpenSettings(album: String)
    case navOpenAppSettings
    case navBack
    case navRoot
    case viewerOpen(photo: String)
    case viewerDismiss
    case albumsCreate(ControlNewAlbum)
    case albumsDelete(album: String)
    case albumsReset(album: String)
    case albumsDuplicate(album: String)
    case albumsUpdate(album: String, ControlAlbumEdit)
    case albumsMarkAllUnreviewed(album: String)
    case selectionToggle(photo: String)
    case selectionToggleCluster(day: DayKey)
    case doneToggle(day: DayKey)
    case exportRetry(newAlbum: Bool)
    case authRequest
    case reviewSetFilter(ReviewFilter)
    case reviewGoTo(day: DayKey)
    case reviewMarkDoneAndAdvance
    case viewerPage(ControlPageTarget)
    case viewerPick
    case viewerKeepReviewing
    case viewerUndoAutoDone
    case uiPresent(ControlModal, album: String?)
    case uiConfirm
    case uiDismiss

    var kind: ControlActionKind {
        switch self {
        case .navOpenAlbum: .navOpenAlbum
        case .navOpenReview: .navOpenReview
        case .navOpenExport: .navOpenExport
        case .navOpenSettings: .navOpenSettings
        case .navOpenAppSettings: .navOpenAppSettings
        case .navBack: .navBack
        case .navRoot: .navRoot
        case .viewerOpen: .viewerOpen
        case .viewerDismiss: .viewerDismiss
        case .albumsCreate: .albumsCreate
        case .albumsDelete: .albumsDelete
        case .albumsReset: .albumsReset
        case .albumsDuplicate: .albumsDuplicate
        case .albumsUpdate: .albumsUpdate
        case .albumsMarkAllUnreviewed: .albumsMarkAllUnreviewed
        case .selectionToggle: .selectionToggle
        case .selectionToggleCluster: .selectionToggleCluster
        case .doneToggle: .doneToggle
        case .exportRetry: .exportRetry
        case .authRequest: .authRequest
        case .reviewSetFilter: .reviewSetFilter
        case .reviewGoTo: .reviewGoTo
        case .reviewMarkDoneAndAdvance: .reviewMarkDoneAndAdvance
        case .viewerPage: .viewerPage
        case .viewerPick: .viewerPick
        case .viewerKeepReviewing: .viewerKeepReviewing
        case .viewerUndoAutoDone: .viewerUndoAutoDone
        case .uiPresent: .uiPresent
        case .uiConfirm: .uiConfirm
        case .uiDismiss: .uiDismiss
        }
    }
}

/// `albums.create`'s fields. `end` is the INCLUSIVE last day, as the setup form's "To" picker shows it.
struct ControlNewAlbum: Equatable {
    var title: String?
    var start: DayKey
    var end: DayKey
    var target: Int
    var media: MediaSelection?
    var excludeScreenshots: Bool?
}

/// `albums.update`'s fields (`nil` = unchanged). `end` is the INCLUSIVE last day.
struct ControlAlbumEdit: Equatable {
    var title: String?
    var start: DayKey?
    var end: DayKey?
    var target: Int?
    var media: MediaSelection?
    var excludeScreenshots: Bool?
    var locationEnabled: Bool?
}

/// The UI's target bound (`TargetCountField`), so an action can't set what the UI can't.
let controlTargetRange = 1...10_000

extension ControlAction: Decodable {
    init(from decoder: any Decoder) throws {
        let keys = try decoder.container(keyedBy: ControlKey.self)
        let name = try keys.required(String.self, "type")
        guard let kind = ControlActionKind(rawValue: name) else {
            throw ControlRequestError.bad("unknown action '\(name)'; see `schema` for the list")
        }
        try keys.declared(kind.args, extra: ["type"], in: name)
        self = try Self.make(kind, keys)
    }

    // One case per action, each reading its declared arguments — a switch is the clearest shape.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private static func make(_ kind: ControlActionKind,
                             _ keys: KeyedDecodingContainer<ControlKey>) throws -> ControlAction {
        switch kind {
        case .navOpenAlbum: return .navOpenAlbum(album: try keys.album())
        case .navOpenReview: return .navOpenReview(album: try keys.album(), day: try keys.day("day"))
        case .navOpenExport: return .navOpenExport
        case .navOpenSettings: return .navOpenSettings(album: try keys.album())
        case .navOpenAppSettings: return .navOpenAppSettings
        case .navBack: return .navBack
        case .navRoot: return .navRoot
        case .viewerOpen: return .viewerOpen(photo: try keys.photo())
        case .viewerDismiss: return .viewerDismiss
        case .albumsCreate:
            let album = ControlNewAlbum(
                title: try keys.optional(String.self, "title"),
                start: try keys.day("start")!, end: try keys.day("end")!,
                target: try keys.target()!,
                media: try keys.media(), excludeScreenshots: try keys.optional(Bool.self, "excludeScreenshots"))
            return .albumsCreate(album)
        case .albumsDelete: return .albumsDelete(album: try keys.album())
        case .albumsReset: return .albumsReset(album: try keys.album())
        case .albumsDuplicate: return .albumsDuplicate(album: try keys.album())
        case .albumsUpdate:
            let edit = ControlAlbumEdit(
                title: try keys.optional(String.self, "title"),
                start: try keys.day("start"), end: try keys.day("end"), target: try keys.target(),
                media: try keys.media(), excludeScreenshots: try keys.optional(Bool.self, "excludeScreenshots"),
                locationEnabled: try keys.optional(Bool.self, "locationEnabled"))
            guard edit != ControlAlbumEdit() else {
                throw ControlRequestError.bad("albums.update: give at least one field to change")
            }
            return .albumsUpdate(album: try keys.album(), edit)
        case .albumsMarkAllUnreviewed: return .albumsMarkAllUnreviewed(album: try keys.album())
        case .selectionToggle: return .selectionToggle(photo: try keys.photo())
        case .selectionToggleCluster: return .selectionToggleCluster(day: try keys.day("day")!)
        case .doneToggle: return .doneToggle(day: try keys.day("day")!)
        case .exportRetry: return .exportRetry(newAlbum: try keys.optional(Bool.self, "newAlbum") ?? false)
        case .authRequest: return .authRequest
        case .reviewSetFilter:
            let raw = try keys.required(String.self, "filter")
            guard let filter = ReviewFilter(controlName: raw) else {
                throw ControlRequestError.bad("'filter' must be \(ControlArgType.filter.rawValue), got '\(raw)'")
            }
            return .reviewSetFilter(filter)
        case .reviewGoTo: return .reviewGoTo(day: try keys.day("day")!)
        case .reviewMarkDoneAndAdvance: return .reviewMarkDoneAndAdvance
        case .viewerPage: return .viewerPage(try keys.pageTarget())
        case .viewerPick: return .viewerPick
        case .viewerKeepReviewing: return .viewerKeepReviewing
        case .viewerUndoAutoDone: return .viewerUndoAutoDone
        case .uiPresent:
            let raw = try keys.required(String.self, "modal")
            guard let modal = ControlModal(rawValue: raw) else {
                throw ControlRequestError.bad("'modal' must be \(ControlArgType.modal.rawValue), got '\(raw)'")
            }
            let album = keys.contains(ControlKey("album")) ? try keys.album() : nil
            guard (modal.confirmation != nil) == (album != nil) else {
                throw ControlRequestError.bad(modal.confirmation != nil
                    ? "ui.present \(raw): give the 'album' it's for" : "ui.present \(raw) takes no 'album'")
            }
            return .uiPresent(modal, album: album)
        case .uiConfirm: return .uiConfirm
        case .uiDismiss: return .uiDismiss
        }
    }
}

extension KeyedDecodingContainer where Key == ControlKey {
    /// `viewer.page`: exactly one of `direction` (next | previous) or `photo` (an alias).
    func pageTarget() throws -> ControlPageTarget {
        let direction = try optional(String.self, "direction")
        let photo = try optional(String.self, "photo")
        switch (direction, photo) {
        case ("next"?, nil): return .next
        case ("previous"?, nil): return .previous
        case (nil, let alias?):
            guard ControlAssetAliases.isAlias(alias) else {
                throw ControlRequestError.bad("'photo' must be a photo alias like a-0001, got '\(alias)'")
            }
            return .photo(alias)
        case (let other?, nil):
            throw ControlRequestError.bad("'direction' must be \(ControlArgType.direction.rawValue), got '\(other)'")
        default:
            throw ControlRequestError.bad("viewer.page: give exactly one of 'direction' or 'photo'")
        }
    }
}

// MARK: - Fixture ops

/// The fixture op names, each with its declared arguments (one declaration for decoder + `schema`).
enum ControlFixtureOpKind: String, CaseIterable {
    case flush
    case lifecycleResume = "lifecycle.resume"
    case libraryFailFetch = "library.failFetch"
    case libraryAuthorization = "library.authorization"
    case selectionSelect = "selection.select"
    case selectionClear = "selection.clear"
    case libraryHoldExports = "library.holdExports"
    case libraryReleaseExports = "library.releaseExports"
    case libraryFailExport = "library.failExport"
    case libraryAddPhotos = "library.addPhotos"
    case reset

    var args: [ControlArgSpec] {
        switch self {
        case .flush, .lifecycleResume, .selectionClear, .libraryHoldExports, .libraryReleaseExports: []
        case .libraryFailFetch: [.opt("kind", .fetchFailure)]
        case .libraryAuthorization: [.req("status", .authorization)]
        case .selectionSelect: [.req("photos", .assetAliases)]
        case .libraryFailExport: [.opt("error", .exportFailure)]
        case .libraryAddPhotos: [.req("day", .day), .req("count", .int)]
        case .reset: [.req("fixture", .fixture)]
        }
    }

    var summary: String {
        switch self {
        case .flush: "persist the debounced picks + day marks now (both stores' flushNow), as backgrounding does"
        case .lifecycleResume: "the app becoming active: re-read photo authorization"
        case .libraryFailFetch: "make the fake's fetches fail (or recover with null / no kind)"
        case .libraryAuthorization:
            "what the fake reports from now on (then lifecycle.resume / auth.request); persisted"
        case .selectionSelect: "pick these photos of the open review directly (no single control does this)"
        case .selectionClear: "unpick everything in the open album (no control does this)"
        case .libraryHoldExports:
            "close the fake's export gate: exports park mid-flight (library.heldExports) until releaseExports"
        case .libraryReleaseExports: "open the export gate: parked exports go on"
        case .libraryFailExport:
            "make the fake's exports fail with this error from now on (a parked one once released); null clears"
        case .libraryAddPhotos:
            "add count (1–100) new photos on day (from 21:00 UTC) to the fake library — new photos taken mid-session; "
                + "persisted; an open album sees them on its next scan (re-open it)"
        case .reset: "refused here — a reset is a relaunch: Scripts/poimi.sh reset <fixture>"
        }
    }
}

/// Test levers, not user actions (`fixture` command). `reset` is a RELAUNCH (`poimi.sh reset`), so the
/// app refuses it in place — the container and library are built once per launch.
enum ControlFixtureOp: Equatable {
    /// Persist both stores' debounced state now (`flushNow()`), as a scene-phase change would.
    case flush
    /// The app becoming active again: re-read authorization (the Settings round-trip, D6).
    case lifecycleResume
    /// Make the fake library's fetches fail (`fetchFailed`), or succeed again (`null`).
    case libraryFailFetch(failing: Bool)
    /// What the fake library reports from now on (follow with `lifecycle.resume` or `auth.request`).
    case libraryAuthorization(LibraryAuthorization)
    /// Pick photos of the open review directly.
    case selectionSelect(photos: [String])
    /// Unpick everything in the open album.
    case selectionClear
    /// Close the fake library's export gate: exports park until released (#300).
    case libraryHoldExports
    /// Open the export gate.
    case libraryReleaseExports
    /// Make every export fail with this error from now on (`nil` clears).
    case libraryFailExport(ExportError?)
    /// Add `count` photos taken on `day` to the fake library (#191 drift).
    case libraryAddPhotos(day: DayKey, count: Int)
    /// Refused in place: a reset is a relaunch.
    case reset(fixture: String)
}

extension ControlFixtureOp: Decodable {
    init(from decoder: any Decoder) throws {
        let keys = try decoder.container(keyedBy: ControlKey.self)
        let name = try keys.required(String.self, "op")
        guard let kind = ControlFixtureOpKind(rawValue: name) else {
            let known = ControlFixtureOpKind.allCases.map(\.rawValue).joined(separator: ", ")
            throw ControlRequestError.bad("unknown fixture op '\(name)'; known: \(known)")
        }
        try keys.declared(kind.args, extra: ["op"], in: name)
        switch kind {
        case .flush: self = .flush
        case .lifecycleResume: self = .lifecycleResume
        case .libraryFailFetch:
            switch try keys.optional(String.self, "kind") {
            case nil: self = .libraryFailFetch(failing: false)
            case "fetchFailed": self = .libraryFailFetch(failing: true)
            case let other?:
                throw ControlRequestError.bad("library.failFetch: kind must be fetchFailed or null, got '\(other)'")
            }
        case .libraryAuthorization:
            let status = try keys.required(String.self, "status")
            guard let value = LibraryAuthorization.allControlCases.first(where: {
                ControlSnapshot.authorization($0) == status
            }) else {
                throw ControlRequestError.bad("library.authorization: unknown status '\(status)'")
            }
            self = .libraryAuthorization(value)
        case .selectionSelect: self = .selectionSelect(photos: try keys.photos(name))
        case .selectionClear: self = .selectionClear
        case .libraryHoldExports: self = .libraryHoldExports
        case .libraryReleaseExports: self = .libraryReleaseExports
        case .libraryFailExport: self = .libraryFailExport(try keys.exportFailure())
        case .libraryAddPhotos:
            let (day, count) = try keys.addedPhotos()
            self = .libraryAddPhotos(day: day, count: count)
        case .reset: self = .reset(fixture: try keys.required(String.self, "fixture"))
        }
    }
}

extension KeyedDecodingContainer where Key == ControlKey {
    /// `library.failExport`'s `error` (absent / null clears it).
    func exportFailure() throws -> ExportError? {
        let failures: [String: ExportError] = [
            "albumMissing": .albumMissing, "writeFailed": .writeFailed, "noAssetsResolved": .noAssetsResolved
        ]
        guard let raw = try optional(String.self, "error") else { return nil }
        guard let error = failures[raw] else {
            throw ControlRequestError.bad("library.failExport: error must be "
                + "\(ControlArgType.exportFailure.rawValue), got '\(raw)'")
        }
        return error
    }

    /// `library.addPhotos`'s calendar `day` and `count` (1…100).
    func addedPhotos() throws -> (day: DayKey, count: Int) {
        guard let day = try day("day"), day.anchorDate(in: ControlFixture.utc) != nil else {
            throw ControlRequestError.bad("library.addPhotos: 'day' must be a calendar day (yyyy-mm-dd)")
        }
        let count = try required(Int.self, "count")
        guard (1...100).contains(count) else {
            throw ControlRequestError.bad("library.addPhotos: 'count' must be 1…100, got \(count)")
        }
        return (day, count)
    }
}

extension LibraryAuthorization {
    /// Every status, for decoding `library.authorization` by its snapshot name.
    static let allControlCases: [LibraryAuthorization] = [.notDetermined, .authorized, .limited, .denied, .restricted]
}

extension KeyedDecodingContainer where Key == ControlKey {
    /// Refuse keys outside `args` + `extra`, and a missing required argument.
    func declared(_ args: [ControlArgSpec], extra: [String], in context: String) throws {
        try allow(extra + args.map(\.name), in: context)
        for arg in args where arg.required && !contains(ControlKey(arg.name)) {
            throw ControlRequestError.bad("\(context): missing '\(arg.name)' (\(arg.type.rawValue))")
        }
    }
}

#endif
