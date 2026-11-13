//
//  ControlSchema.swift
//  PoimiApp — what the control plane speaks, as data (#298, docs/plans/control-plane.md §4 C/§5).
//  DEBUG-only (D30).
//
//  - The declared `state.json` paths + their JSON types. A `wait` on a path not declared here fails at
//    once (a typo must not wait 30 s and then blame the app); a test keeps this list and the real
//    snapshot in step, both ways (ControlMachineryTests).
//  - The outcomes of an action, and every refusal reason.
//  - `schema` — the whole vocabulary printed from the same declarations the decoder and the host use
//    (actions + arguments, fixture ops, predicate ops, refusals, paths, fixtures, routes), so the
//    `poimi-control` skill points at `poimi.sh schema` instead of copying tables that would rot.
//
#if DEBUG

import Foundation

/// Why the app refused an action. Each is a fact about the app's state, not about the request.
enum ControlRefusal: String, CaseIterable {
    /// What the action acts on isn't on screen (a photo outside the open review, a back button under the
    /// viewer, a screen the user couldn't reach from here).
    case notShown
    /// An alias that names nothing in this run (never assigned, or its album was deleted).
    case unknownAlias
    /// The app isn't in a state the action applies to (no album hydrated in the selection store, an
    /// invalid new album or period).
    case invalidState
    /// The app is doing something that must finish first (that album's export is running).
    case busy
    /// The lever doesn't exist in this run (not the fake library; a reset, which is a relaunch).
    case unavailable

    var summary: String {
        switch self {
        case .notShown: "what it acts on isn't on screen (or the screen can't be reached from here)"
        case .unknownAlias: "the alias names nothing in this run"
        case .invalidState: "the app isn't in a state the action applies to"
        case .busy: "something must finish first (the album's export is running)"
        case .unavailable: "not available in this run (e.g. reset is a relaunch; a lever the library lacks)"
        }
    }
}

/// An action's outcome. `accepted` means ADMITTED, not finished: follow it with a `wait`.
enum ControlOutcome: Equatable {
    /// Admitted; `seq` settles (`settledSeq >= seq`) when the async work it started has finished.
    case accepted(seq: Int, extra: [ControlJSON.Member] = [])
    case refused(ControlRefusal, String)
    /// Nothing to do (already so — the UI's own idempotence guards).
    case noop(String)

    var json: ControlJSON {
        switch self {
        case .accepted(let seq, let extra):
            .object([.init(key: "outcome", value: .string("accepted")), .init(key: "seq", value: .int(seq))] + extra)
        case .refused(let reason, let message):
            .object(("outcome", .string("refused")), ("reason", .string(reason.rawValue)),
                    ("message", .string(message)))
        case .noop(let message):
            .object(("outcome", .string("noop")), ("message", .string(message)))
        }
    }
}

enum ControlSchema {
    /// Every `state.json` path a `wait` may name, with its JSON type(s). `*` is one album alias.
    static let statePaths: [(path: String, type: String)] = [
        ("snapshotVersion", "int"), ("run", "string"), ("rev", "int"),
        ("settledSeq", "int"), ("lastSeq", "int"),
        ("app", "object"),
        ("app.rootPhase", "string"), ("app.authorization", "string"), ("app.library", "string"),
        ("app.fixture", "string"), ("app.host", "string"), ("app.idiom", "string"), ("app.timeZone", "string"),
        ("app.launchError", "string|null"),
        ("nav", "object"),
        ("nav.screen", "string"), ("nav.path", "array"), ("nav.sheet", "string|null"),
        ("nav.sheetAlbum", "string|null"), ("nav.viewerPhoto", "string|null"), ("nav.viewerEndOfSet", "bool|null"),
        ("nav.viewerToast", "object|null"), ("nav.viewerToast.day", "string"), ("nav.viewerToast.marks", "int"),
        ("albums", "object"), ("albums.*", "object"),
        ("albums.*.status", "string"), ("albums.*.toAdd", "int|null"), ("albums.*.target", "int"),
        ("albums.*.picked", "int"), ("albums.*.titleLength", "int"), ("albums.*.exported", "bool"),
        ("albums.*.inPhotos", "int|null"),
        ("active", "object"),
        ("active.album", "string|null"),
        ("active.scan", "object|null"),
        ("active.scan.phase", "string"), ("active.scan.reason", "string|null"),
        ("active.scan.candidates", "int"), ("active.scan.clusters", "int"), ("active.scan.trips", "int"),
        ("active.selection", "object|null"),
        ("active.selection.count", "int"), ("active.selection.target", "int"), ("active.selection.active", "bool"),
        ("active.done", "object|null"),
        ("active.done.days", "int"), ("active.done.clusters", "int"), ("active.done.of", "int"),
        ("active.done.active", "bool"),
        ("active.export", "object|null"),
        ("active.export.phase", "string"), ("active.export.wasReExport", "bool|null"),
        ("active.export.added", "int|null"), ("active.export.total", "int|null"),
        ("active.overview", "object|null"), ("active.overview.filter", "string"),
        ("active.grid", "object|null"), ("active.grid.cluster", "string|null"),
        ("library", "object"),
        ("library.heldExports", "int"), ("library.exportCalls", "int"), ("library.albumsCreated", "int"),
        ("pending", "object"),
        ("pending.selectionFlush", "bool"), ("pending.doneFlush", "bool"), ("pending.scan", "bool"),
        ("pending.naming", "bool"), ("pending.export", "bool"), ("pending.thumbnails", "int"),
        ("idle", "bool")
    ]

    /// The declared pattern `path` matches (`albums.album-3.picked` → `albums.*.picked`), or `nil`.
    static func declaredPattern(for path: String) -> String? {
        let segments = path.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard !segments.contains("") else { return nil }
        var pattern = segments
        if pattern.count >= 2, pattern[0] == "albums" { pattern[1] = "*" }
        let joined = pattern.joined(separator: ".")
        return statePaths.contains { $0.path == joined } ? joined : nil
    }

    private static func args(_ specs: [ControlArgSpec]) -> ControlJSON {
        .object(pairs: specs.map { ($0.name, .string($0.type.text + ($0.required ? "" : " (optional)"))) })
    }

    /// The `schema` reply.
    static func json() -> ControlJSON {
        .object(
            ("protocol", .int(ControlRequest.version)),
            ("commands", .object(
                ("send", .string("{action: {type, …args}} → accepted{seq} | refused{reason} | noop")),
                ("mailbox", .string("requests are handled one at a time, in order — except waits, which run "
                    + "alongside (an action never queues behind a wait)")),
                ("snapshot", .string("→ the current state.json content")),
                ("wait", .string("{predicates: [{path, op, value?}], timeoutMs: 0…30000} → met, or error unmet")),
                ("schema", .string("→ this")),
                ("fixture", .string("{fixture: {op, …}} → accepted{seq} | refused")))),
            ("actions", .array(ControlActionKind.allCases.map { kind in
                .object(("type", .string(kind.rawValue)),
                        ("args", args(kind.args)),
                        ("summary", .string(kind.summary)))
            })),
            ("outcomes", .object(
                ("accepted",
                 .string("admitted, NOT finished — wait on settledSeq >= seq / idle / the state you expect")),
                ("refused", .string("the app said no; `reason` is one of refusals")),
                ("noop", .string("already so; nothing started")))),
            ("refusals", .object(pairs: ControlRefusal.allCases.map { ($0.rawValue, .string($0.summary)) })),
            ("errors", .array(ControlRequestError.Code.allCases.map { .string($0.rawValue) })),
            ("fixtureOps", .array(ControlFixtureOpKind.allCases.map { kind in
                .object(("op", .string(kind.rawValue)), ("args", args(kind.args)), ("summary", .string(kind.summary)))
            })),
            ("predicateOps", .object(
                ("eq", .string("same JSON type and value (10 ≠ \"10\"; null matches null)")),
                ("ne", .string("not eq (a missing path is not equal)")),
                ("gte", .string("both integers, observed ≥ value")),
                ("lte", .string("both integers, observed ≤ value")),
                ("exists", .string("present and not null; value false inverts")))),
            ("statePaths", .object(pairs: statePaths.map { ($0.path, .string($0.type)) })),
            ("fixtures", .array(ControlFixture.allCases.map { .string($0.rawValue) })),
            ("routes", .array(ControlRoute.grammar.map(ControlJSON.string))))
    }
}

#endif
