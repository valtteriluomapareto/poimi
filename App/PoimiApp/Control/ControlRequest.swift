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
            throw ControlRequestError.bad("'media' must be \(ControlArgType.media.text), got '\(raw)'")
        }
        return media
    }

    /// A non-empty list of photo aliases.
    func photos(_ context: String) throws -> [String] {
        let photos = try required([String].self, "photos")
        guard !photos.isEmpty else { throw ControlRequestError.bad("\(context): 'photos' is empty") }
        if let bad = photos.first(where: { !ControlAssetAliases.isAlias($0) }) {
            throw ControlRequestError.bad("\(context): '\(bad)' is not a photo alias like a-0001")
        }
        return photos
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
