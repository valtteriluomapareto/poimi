//
//  ControlRequest.swift
//  PoimiApp — the control plane's wire vocabulary: the request envelope, the actions, the fixture ops
//  and the wait predicates (#298, docs/plans/control-plane.md §4 C). DEBUG-only (D30).
//
//  Everything is STRICT: an unknown key, action, op, command or predicate operator, a value of the wrong
//  JSON type (`"10"` where an int is due), or a `v` other than 1 is refused with a message — never
//  ignored or coerced. Each action's arguments are declared once (`ControlActionKind.args`), and both the
//  decoder and the `schema` command read that declaration, so the two can't drift.
//
#if DEBUG

import Foundation
import Curation

// MARK: - Errors

/// Why a request couldn't be handled at all (as opposed to an action the app refused).
struct ControlRequestError: Error, Equatable {
    enum Code: String, CaseIterable {
        /// Malformed JSON, an unknown key / command / action / op, a wrong value type, a bad argument.
        case badRequest
        /// `v` isn't a protocol version this build speaks.
        case unsupportedVersion
        /// The request names a different launch's `run` (the app was relaunched since).
        case staleRun
        /// A `wait` predicate names a path the snapshot doesn't declare (see `schema`).
        case undeclaredPath
        /// A `wait` timed out with predicates unmet.
        case unmet
    }

    let code: Code
    let message: String
    /// Extra detail (the unmet predicates of a `wait`).
    var detail: ControlJSON?

    init(_ code: Code, _ message: String, detail: ControlJSON? = nil) {
        self.code = code
        self.message = message
        self.detail = detail
    }

    static func bad(_ message: String) -> ControlRequestError { ControlRequestError(.badRequest, message) }
}

// MARK: - Envelope

/// One request: `{v, id, run, cmd, …}`. `id` echoes back in the reply; `run` must be this launch's.
struct ControlRequest: Decodable, Equatable {
    static let version = 1
    /// `wait`'s bounds: 0 asserts now, 30 s at most (a longer wait is a stuck app, not patience).
    static let timeoutRange = 0...30_000
    static let defaultTimeoutMs = 10_000

    enum Command: Equatable {
        case send(ControlAction)
        case snapshot
        case wait([ControlPredicate], timeoutMs: Int)
        case schema
        case fixture(ControlFixtureOp)
    }

    static let commands = ["send", "snapshot", "wait", "schema", "fixture"]

    let id: Int
    let run: String
    let command: Command

    init(id: Int, run: String, command: Command) {
        self.id = id
        self.run = run
        self.command = command
    }

    init(from decoder: any Decoder) throws {
        let keys = try decoder.container(keyedBy: ControlKey.self)
        // The version first: a future envelope may not parse as this one, and that's the error to report.
        guard keys.contains(ControlKey("v")) else { throw ControlRequestError.bad("missing key 'v'") }
        let version = try keys.typed(Int.self, "v")
        guard version == Self.version else {
            throw ControlRequestError(.unsupportedVersion,
                                      "protocol version \(version) unsupported; this build speaks v\(Self.version)")
        }
        id = try keys.required(Int.self, "id")
        guard id >= 0 else { throw ControlRequestError.bad("'id' must be ≥ 0") }
        run = try keys.required(String.self, "run")
        let cmd = try keys.required(String.self, "cmd")
        let base = ["v", "id", "run", "cmd"]
        switch cmd {
        case "send":
            try keys.allow(base + ["action"], in: "send")
            command = .send(try keys.required(ControlAction.self, "action"))
        case "snapshot":
            try keys.allow(base, in: "snapshot")
            command = .snapshot
        case "schema":
            try keys.allow(base, in: "schema")
            command = .schema
        case "wait":
            try keys.allow(base + ["predicates", "timeoutMs"], in: "wait")
            let predicates = try keys.required([ControlPredicate].self, "predicates")
            guard !predicates.isEmpty else { throw ControlRequestError.bad("wait needs at least one predicate") }
            let timeout = try keys.optional(Int.self, "timeoutMs") ?? Self.defaultTimeoutMs
            guard Self.timeoutRange.contains(timeout) else {
                let range = Self.timeoutRange
                throw ControlRequestError.bad("timeoutMs must be \(range.lowerBound)…\(range.upperBound), got \(timeout)")
            }
            command = .wait(predicates, timeoutMs: timeout)
        case "fixture":
            try keys.allow(base + ["fixture"], in: "fixture")
            command = .fixture(try keys.required(ControlFixtureOp.self, "fixture"))
        default:
            throw ControlRequestError.bad("unknown cmd '\(cmd)'; known: \(Self.commands.joined(separator: ", "))")
        }
    }

    /// Decode one request file's bytes, mapping every decoding failure to a `ControlRequestError`.
    static func decode(_ data: Data) throws(ControlRequestError) -> ControlRequest {
        do {
            return try JSONDecoder().decode(ControlRequest.self, from: data)
        } catch let error as ControlRequestError {
            throw error
        } catch let error as DecodingError {
            throw ControlRequestError.bad(Self.describe(error))
        } catch {
            throw ControlRequestError.bad("unreadable request: \(error.localizedDescription)")
        }
    }

    /// A short, path-qualified message for a decoding failure (`action.album: expected String`).
    static func describe(_ error: DecodingError) -> String {
        func path(_ context: DecodingError.Context) -> String {
            let keys = context.codingPath.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }
            return keys.isEmpty ? "request" : keys.joined(separator: ".").replacingOccurrences(of: ".[", with: "[")
        }
        switch error {
        case .typeMismatch(let type, let context):
            return "\(path(context)): expected \(type)"
        case .valueNotFound(let type, let context):
            return "\(path(context)): expected \(type), got null"
        case .keyNotFound(let key, let context):
            return "\(path(context)): missing key '\(key.stringValue)'"
        case .dataCorrupted(let context):
            return context.codingPath.isEmpty ? "malformed JSON" : "\(path(context)): \(context.debugDescription)"
        @unknown default:
            return "malformed request"
        }
    }
}

// MARK: - Actions

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
}

struct ControlArgSpec {
    let name: String
    let type: ControlArgType
    let required: Bool
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
    case selectionSelect = "selection.select"
    case selectionDeselect = "selection.deselect"
    case selectionClear = "selection.clear"
    case doneToggle = "done.toggle"
    case exportRun = "export.run"
    case authRequest = "auth.request"

    var args: [ControlArgSpec] {
        func req(_ name: String, _ type: ControlArgType) -> ControlArgSpec {
            .init(name: name, type: type, required: true)
        }
        func opt(_ name: String, _ type: ControlArgType) -> ControlArgSpec {
            .init(name: name, type: type, required: false)
        }
        switch self {
        case .navOpenAlbum, .navOpenSettings, .albumsDelete, .albumsReset, .albumsDuplicate,
             .albumsMarkAllUnreviewed, .exportRun:
            return [req("album", .albumAlias)]
        case .navOpenReview: return [req("album", .albumAlias), opt("day", .day)]
        case .navOpenExport, .navOpenAppSettings, .navBack, .navRoot, .viewerDismiss, .selectionClear, .authRequest:
            return []
        case .viewerOpen, .selectionToggle: return [req("photo", .assetAlias)]
        case .albumsCreate:
            return [opt("title", .string), req("start", .day), req("end", .day), req("target", .int),
                    opt("media", .media), opt("excludeScreenshots", .bool)]
        case .albumsUpdate:
            return [req("album", .albumAlias), opt("title", .string), opt("start", .day), opt("end", .day),
                    opt("target", .int), opt("media", .media), opt("excludeScreenshots", .bool),
                    opt("locationEnabled", .bool)]
        case .selectionSelect, .selectionDeselect: return [opt("photos", .assetAliases), opt("day", .day)]
        case .doneToggle: return [req("day", .day)]
        }
    }

    /// One line on what it does, for `schema`.
    var summary: String {
        switch self {
        case .navOpenAlbum: "open the album from the library (bump + overview) and scan it as the Overview does"
        case .navOpenReview:
            "push the review grid from the album's overview (optionally on a day) and scan as the grid does"
        case .navOpenExport:
            "the forward path to export (finishToExport) from the open album's overview, grid or viewer; "
                + "runs the export as the export screen does"
        case .navOpenSettings: "push the album settings from the album's overview"
        case .navOpenAppSettings: "push app settings (noop when already on top, #258)"
        case .navBack: "pop one screen"
        case .navRoot: "back to the album library"
        case .viewerOpen: "open the photo viewer on a photo of the open review (grid on top)"
        case .viewerDismiss: "dismiss the photo viewer"
        case .albumsCreate: "create an album (inclusive start/end days) and open it, as the setup sheet's Create"
        case .albumsDelete: "delete an album (never its Photos album); refused busy while it exports"
        case .albumsReset: "reset an album's progress; refused busy while it exports"
        case .albumsDuplicate: "duplicate an album's configuration"
        case .albumsUpdate: "edit an album as its settings screen does (inclusive end day), committed at once"
        case .albumsMarkAllUnreviewed: "clear the album's day marks, keeping picks (#285)"
        case .selectionToggle: "toggle one photo of the open review (a grid-cell tap)"
        case .selectionSelect: "pick photos of the open review — a list, or a whole day"
        case .selectionDeselect: "unpick photos of the open review — a list, or a whole day"
        case .selectionClear: "unpick everything in the open album"
        case .doneToggle: "toggle done on the review cluster holding that day (a trip toggles all its days)"
        case .exportRun: "open the album if needed, go to export and run it (Try again on a failed export screen)"
        case .authRequest: "the onboarding button: request photo access (answers with the fake's status)"
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
    case selectionSelect(ControlPhotoSet)
    case selectionDeselect(ControlPhotoSet)
    case selectionClear
    case doneToggle(day: DayKey)
    case exportRun(album: String)
    case authRequest
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

/// Which photos a bulk selection acts on: a list, or every photo of a day in the open review.
enum ControlPhotoSet: Equatable {
    case photos([String])
    case day(DayKey)
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
        try keys.allow(["type"] + kind.args.map(\.name), in: name)
        for arg in kind.args where arg.required && !keys.contains(ControlKey(arg.name)) {
            throw ControlRequestError.bad("\(name): missing '\(arg.name)' (\(arg.type.rawValue))")
        }
        self = try Self.make(kind, keys)
    }

    // One case per action, each reading its declared arguments — a switch is the clearest shape.
    // swiftlint:disable:next cyclomatic_complexity
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
        case .selectionSelect: return .selectionSelect(try keys.photoSet(kind))
        case .selectionDeselect: return .selectionDeselect(try keys.photoSet(kind))
        case .selectionClear: return .selectionClear
        case .doneToggle: return .doneToggle(day: try keys.day("day")!)
        case .exportRun: return .exportRun(album: try keys.album())
        case .authRequest: return .authRequest
        }
    }
}

// MARK: - Fixture ops

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
    /// Refused in place: a reset is a relaunch.
    case reset(fixture: String)

    static let ops: [(name: String, args: String, summary: String)] = [
        ("flush", "", "persist the debounced picks + day marks now (both stores' flushNow)"),
        ("lifecycle.resume", "", "the app becoming active: re-read photo authorization"),
        ("library.failFetch", "kind: fetchFailed | null", "make the fake's fetches fail (or recover with null)"),
        ("library.authorization", "status: notDetermined | authorized | limited | denied | restricted",
         "what the fake reports from now on (then lifecycle.resume / auth.request)"),
        ("reset", "fixture: <name>", "refused here — a reset is a relaunch: Scripts/poimi.sh reset <fixture>")
    ]
}

extension ControlFixtureOp: Decodable {
    init(from decoder: any Decoder) throws {
        let keys = try decoder.container(keyedBy: ControlKey.self)
        let op = try keys.required(String.self, "op")
        switch op {
        case "flush":
            try keys.allow(["op"], in: op)
            self = .flush
        case "lifecycle.resume":
            try keys.allow(["op"], in: op)
            self = .lifecycleResume
        case "library.failFetch":
            try keys.allow(["op", "kind"], in: op)
            switch try keys.optional(String.self, "kind") {
            case nil: self = .libraryFailFetch(failing: false)
            case "fetchFailed": self = .libraryFailFetch(failing: true)
            case let other?:
                throw ControlRequestError.bad("library.failFetch: kind must be fetchFailed or null, got '\(other)'")
            }
        case "library.authorization":
            try keys.allow(["op", "status"], in: op)
            let name = try keys.required(String.self, "status")
            guard let status = LibraryAuthorization.allControlCases.first(where: {
                ControlSnapshot.authorization($0) == name
            }) else {
                throw ControlRequestError.bad("library.authorization: unknown status '\(name)'")
            }
            self = .libraryAuthorization(status)
        case "reset":
            try keys.allow(["op", "fixture"], in: op)
            self = .reset(fixture: try keys.required(String.self, "fixture"))
        default:
            let known = Self.ops.map(\.name).joined(separator: ", ")
            throw ControlRequestError.bad("unknown fixture op '\(op)'; known: \(known)")
        }
    }
}

extension LibraryAuthorization {
    /// Every status, for decoding `library.authorization` by its snapshot name.
    static let allControlCases: [LibraryAuthorization] = [.notDetermined, .authorized, .limited, .denied, .restricted]
}

// MARK: - Wait predicates

/// One `wait` predicate over a declared `state.json` path: `{path, op, value?}`.
struct ControlPredicate: Equatable, Decodable {
    enum Op: String, CaseIterable {
        /// Equal: same JSON type and value (`10` ≠ `"10"`; `null` matches only `null`).
        case eq
        /// Not `eq` (a missing path counts as not equal).
        case ne
        /// Both integers, observed ≥ value.
        case gte
        /// Both integers, observed ≤ value.
        case lte
        /// Present and not null (`value: false` inverts — e.g. a deleted album's row is gone).
        case exists
    }

    let path: String
    let op: Op
    let value: ControlJSON

    init(path: String, op: Op, value: ControlJSON) {
        self.path = path
        self.op = op
        self.value = value
    }

    init(from decoder: any Decoder) throws {
        let keys = try decoder.container(keyedBy: ControlKey.self)
        try keys.allow(["path", "op", "value"], in: "predicate")
        var path = try keys.required(String.self, "path")
        if path.hasPrefix(".") { path.removeFirst() }   // jq habit: `.idle` == `idle`
        let opName = try keys.required(String.self, "op")
        guard let op = Op(rawValue: opName) else {
            throw ControlRequestError.bad("predicate '\(path)': unknown op '\(opName)'; known: "
                + Op.allCases.map(\.rawValue).joined(separator: ", "))
        }
        let hasValue = keys.contains(ControlKey("value"))
        let valueKey = ControlKey("value")
        let isNull = try hasValue && keys.decodeNil(forKey: valueKey)
        let value: ControlJSON = hasValue && !isNull ? try keys.decode(ControlJSON.self, forKey: valueKey) : .null
        switch op {
        case .eq, .ne:
            guard hasValue else { throw ControlRequestError.bad("predicate '\(path)': \(opName) needs a value") }
        case .gte, .lte:
            guard case .int = value else {
                throw ControlRequestError.bad("predicate '\(path)': \(opName) needs an integer value")
            }
        case .exists:
            guard !hasValue || value.isBool else {
                throw ControlRequestError.bad("predicate '\(path)': exists takes an optional true/false")
            }
        }
        self.path = path
        self.op = op
        self.value = op == .exists && !hasValue ? .bool(true) : value
    }
}

// MARK: - Decoding helpers

/// Any key (the decoders list `allKeys` to refuse unknown ones).
struct ControlKey: CodingKey, Hashable {
    let stringValue: String
    var intValue: Int? { nil }
    init(_ string: String) { stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

extension KeyedDecodingContainer where Key == ControlKey {
    /// Refuse any key outside `allowed`.
    func allow(_ allowed: [String], in context: String) throws {
        let unknown = allKeys.map(\.stringValue).filter { !allowed.contains($0) }.sorted()
        guard unknown.isEmpty else {
            throw ControlRequestError.bad("\(context): unknown key\(unknown.count > 1 ? "s" : "") "
                + unknown.map { "'\($0)'" }.joined(separator: ", ")
                + (allowed.isEmpty ? "" : "; allowed: \(allowed.joined(separator: ", "))"))
        }
    }

    func typed<T: Decodable>(_ type: T.Type, _ key: String) throws -> T {
        do {
            return try decode(type, forKey: ControlKey(key))
        } catch DecodingError.typeMismatch, DecodingError.valueNotFound {
            throw ControlRequestError.bad("'\(key)' must be \(Self.name(of: type))")
        }
    }

    func required<T: Decodable>(_ type: T.Type, _ key: String) throws -> T {
        guard contains(ControlKey(key)) else { throw ControlRequestError.bad("missing key '\(key)'") }
        return try typed(type, key)
    }

    /// Absent or `null` → `nil`; anything else must have the type.
    func optional<T: Decodable>(_ type: T.Type, _ key: String) throws -> T? {
        guard contains(ControlKey(key)), try !decodeNil(forKey: ControlKey(key)) else { return nil }
        return try typed(type, key)
    }

    func album() throws -> String {
        let alias = try required(String.self, "album")
        guard ControlAlbumAliases.isAlias(alias) else {
            throw ControlRequestError.bad("'album' must be an album alias like album-1, got '\(alias)'")
        }
        return alias
    }

    func photo() throws -> String {
        let alias = try required(String.self, "photo")
        guard ControlAssetAliases.isAlias(alias) else {
            throw ControlRequestError.bad("'photo' must be a photo alias like a-0001, got '\(alias)'")
        }
        return alias
    }

    func day(_ key: String) throws -> DayKey? {
        guard let raw = try optional(String.self, key) else { return nil }
        // Canonical form only (round-trip), as the launch route parser does.
        guard let day = DayKey(raw), day.description == raw else {
            throw ControlRequestError.bad("'\(key)' must be yyyy-mm-dd or 'undated', got '\(raw)'")
        }
        return day
    }

    func target() throws -> Int? {
        guard let target = try optional(Int.self, "target") else { return nil }
        guard controlTargetRange.contains(target) else {
            let range = controlTargetRange
            throw ControlRequestError.bad("'target' must be \(range.lowerBound)…\(range.upperBound), got \(target)")
        }
        return target
    }

    func media() throws -> MediaSelection? {
        guard let raw = try optional(String.self, "media") else { return nil }
        guard let media = MediaSelection(rawValue: raw) else {
            throw ControlRequestError.bad("'media' must be \(ControlArgType.media.rawValue), got '\(raw)'")
        }
        return media
    }

    func photoSet(_ kind: ControlActionKind) throws -> ControlPhotoSet {
        let photos = try optional([String].self, "photos")
        let day = try day("day")
        switch (photos, day) {
        case (let photos?, nil):
            guard !photos.isEmpty else { throw ControlRequestError.bad("\(kind.rawValue): 'photos' is empty") }
            if let bad = photos.first(where: { !ControlAssetAliases.isAlias($0) }) {
                throw ControlRequestError.bad("\(kind.rawValue): '\(bad)' is not a photo alias like a-0001")
            }
            return .photos(photos)
        case (nil, let day?):
            return .day(day)
        default:
            throw ControlRequestError.bad("\(kind.rawValue): give exactly one of 'photos' or 'day'")
        }
    }

    private static func name<T>(of type: T.Type) -> String {
        switch type {
        case is Int.Type: "an integer"
        case is String.Type: "a string"
        case is Bool.Type: "true or false"
        case is [String].Type: "an array of strings"
        default: "\(type)"
        }
    }
}

// MARK: - ControlJSON from the wire

extension ControlJSON: Decodable {
    /// Any JSON value. Strictly typed: `true` is a bool (never 1), `10` an int, `"10"` a string; a
    /// fractional number is refused (the snapshot only has integers). Object keys are sorted (requests
    /// carry no meaningful key order).
    init(from decoder: any Decoder) throws {
        let single = try decoder.singleValueContainer()
        if single.decodeNil() {
            self = .null
        } else if let value = try? single.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? single.decode(Int.self) {
            self = .int(value)
        } else if let value = try? single.decode(String.self) {
            self = .string(value)
        } else if let value = try? single.decode([ControlJSON].self) {
            self = .array(value)
        } else if let value = try? single.decode([String: ControlJSON].self) {
            self = .object(pairs: value.keys.sorted().map { ($0, value[$0]!) })
        } else {
            throw ControlRequestError.bad("unsupported value (numbers must be integers)")
        }
    }

    var isBool: Bool {
        if case .bool = self { return true }
        return false
    }
}

#endif
