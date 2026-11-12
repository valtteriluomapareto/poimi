//
//  ControlJSON.swift
//  PoimiApp — the control plane's JSON value (#296, docs/plans/control-plane.md §5). DEBUG-only (D30).
//
//  A tiny ordered JSON tree for `state.json`. Hand-rolled rather than `Codable` structs for three
//  reasons: keys keep a stable, readable order; an absent value is an explicit `null` (so `jq`
//  predicates see the declared key, never a missing one); and the tree is `Equatable`, which is how
//  the writer decides whether content changed (`rev` bumps only then).
//
#if DEBUG

import Foundation

enum ControlJSON: Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case string(String)
    case array([ControlJSON])
    case object([Member])

    struct Member: Equatable, Sendable {
        let key: String
        let value: ControlJSON
    }

    /// An object from ordered `(key, value)` pairs.
    static func object(_ pairs: (String, ControlJSON)...) -> ControlJSON {
        .object(pairs.map { Member(key: $0.0, value: $0.1) })
    }

    /// An object from an ordered pair list (for computed keys).
    static func object(pairs: [(String, ControlJSON)]) -> ControlJSON {
        .object(pairs.map { Member(key: $0.0, value: $0.1) })
    }

    /// `.string`, or `.null` for `nil`.
    static func string(_ value: String?) -> ControlJSON { value.map(ControlJSON.string) ?? .null }

    /// `.int`, or `.null` for `nil`.
    static func int(_ value: Int?) -> ControlJSON { value.map(ControlJSON.int) ?? .null }

    /// A copy of this object with `pairs` inserted at the front (used to stamp `run`/`rev`).
    func prepending(_ pairs: (String, ControlJSON)...) -> ControlJSON {
        guard case .object(let members) = self else { return self }
        return .object(pairs.map { Member(key: $0.0, value: $0.1) } + members)
    }

    /// The value for `key` when this is an object (tests and the runtime read back through this).
    subscript(key: String) -> ControlJSON? {
        guard case .object(let members) = self else { return nil }
        return members.first { $0.key == key }?.value
    }

    // MARK: - Serialization

    /// Pretty-printed UTF-8 JSON (two-space indent, trailing newline) — readable with a plain `cat`.
    func serialized() -> Data {
        var out = ""
        write(into: &out, indent: 0)
        out.append("\n")
        return Data(out.utf8)
    }

    private func write(into out: inout String, indent: Int) {
        switch self {
        case .null: out.append("null")
        case .bool(let value): out.append(value ? "true" : "false")
        case .int(let value): out.append(String(value))
        case .string(let value): Self.writeString(value, into: &out)
        case .array(let items):
            guard !items.isEmpty else { out.append("[]"); return }
            // Arrays of scalars stay on one line (alias lists); nested structure gets one item per line.
            if items.allSatisfy(\.isScalar) {
                out.append("[")
                for (index, item) in items.enumerated() {
                    if index > 0 { out.append(", ") }
                    item.write(into: &out, indent: indent)
                }
                out.append("]")
                return
            }
            out.append("[\n")
            for (index, item) in items.enumerated() {
                out.append(String(repeating: "  ", count: indent + 1))
                item.write(into: &out, indent: indent + 1)
                out.append(index < items.count - 1 ? ",\n" : "\n")
            }
            out.append(String(repeating: "  ", count: indent) + "]")
        case .object(let members):
            guard !members.isEmpty else { out.append("{}"); return }
            out.append("{\n")
            for (index, member) in members.enumerated() {
                out.append(String(repeating: "  ", count: indent + 1))
                Self.writeString(member.key, into: &out)
                out.append(": ")
                member.value.write(into: &out, indent: indent + 1)
                out.append(index < members.count - 1 ? ",\n" : "\n")
            }
            out.append(String(repeating: "  ", count: indent) + "}")
        }
    }

    private var isScalar: Bool {
        switch self {
        case .array, .object: false
        default: true
        }
    }

    private static func writeString(_ value: String, into out: inout String) {
        out.append("\"")
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out.append("\\\"")
            case "\\": out.append("\\\\")
            case "\n": out.append("\\n")
            case "\r": out.append("\\r")
            case "\t": out.append("\\t")
            case let control where control.value < 0x20:
                out.append(String(format: "\\u%04x", control.value))
            default: out.unicodeScalars.append(scalar)
            }
        }
        out.append("\"")
    }
}

#endif
