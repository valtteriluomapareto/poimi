//
//  ControlWait.swift
//  PoimiApp — `wait`: block until predicates over the snapshot hold, or say which don't (#298,
//  docs/plans/control-plane.md §4 C). DEBUG-only (D30).
//
//  Evaluation is Observation-driven: each pass computes the snapshot inside `withObservationTracking`,
//  whose `onChange` fires BEFORE the change lands — so it only wakes the waiter, and the next pass runs
//  on a later main-actor turn, once the write has landed. A 20 ms poll backs it up (state that changes
//  off the observed graph, e.g. the writer's `rev`). The deadline is real; there is no fixed sleep.
//
//  Vacuous-wait detection (a predicate that already held before the action it follows) is DEFERRED: done
//  naively it rejects the true → false → true barriers (`idle`, a re-scan's `ready`). Wait on
//  `settledSeq >= <the send's seq>` to tie a wait to an action.
//
#if DEBUG

import Foundation
import Observation

/// What a path resolves to: a value (possibly `null`), or nothing at all.
enum ControlLookup: Equatable {
    case missing
    case value(ControlJSON)
}

extension ControlJSON {
    /// The JSON type name, as the schema declares types (`int`, `string`, `bool`, `null`, `array`, `object`).
    var typeName: String {
        switch self {
        case .null: "null"
        case .bool: "bool"
        case .int: "int"
        case .string: "string"
        case .array: "array"
        case .object: "object"
        }
    }

    /// Compact JSON text, for messages.
    var literal: String {
        (String(bytes: serialized(), encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Resolve a dot path (`active.scan.phase`, `albums.album-1.picked`) through objects.
    func lookup(_ path: String) -> ControlLookup {
        var node = self
        for segment in path.split(separator: ".") {
            guard case .object(let members) = node,
                  let next = members.first(where: { $0.key == segment })?.value else { return .missing }
            node = next
        }
        return .value(node)
    }
}

/// A predicate that didn't hold, with what was there.
struct ControlUnmet: Equatable {
    let predicate: ControlPredicate
    let observed: ControlLookup

    var json: ControlJSON {
        let observedValue: ControlJSON = if case .value(let value) = observed { value } else { .null }
        return .object(("path", .string(predicate.path)), ("op", .string(predicate.op.rawValue)),
                       ("expected", predicate.value), ("observed", observedValue),
                       ("present", .bool(observed != .missing)))
    }
}

enum ControlWait {
    /// The first predicate whose path the snapshot doesn't declare, if any.
    static func undeclared(_ predicates: [ControlPredicate]) -> ControlPredicate? {
        predicates.first { ControlSchema.declaredPattern(for: $0.path) == nil }
    }

    /// A predicate whose value can never match its path's declared type (`idle != "true"` would be
    /// silently, permanently met), described — or `nil`. Ordering ops need an int path.
    static func typeMismatch(_ predicates: [ControlPredicate]) -> String? {
        for predicate in predicates {
            guard let pattern = ControlSchema.declaredPattern(for: predicate.path),
                  let declared = ControlSchema.statePaths.first(where: { $0.path == pattern })?.type else { continue }
            let types = Set(declared.split(separator: "|").map(String.init))
            switch predicate.op {
            case .eq, .ne:
                let type = predicate.value.typeName
                if !types.contains(type) {
                    let article = type == "null" ? "null" : "a \(type)"
                    return "'\(predicate.path)' is \(declared); \(predicate.value.literal) is \(article)"
                }
            case .gte, .lte:
                if !types.contains("int") {
                    return "'\(predicate.path)' is \(declared); \(predicate.op.rawValue) needs an int path"
                }
            case .exists:
                break
            }
        }
        return nil
    }

    /// The predicates `state` doesn't satisfy (empty = all met).
    static func unmet(_ predicates: [ControlPredicate], in state: ControlJSON) -> [ControlUnmet] {
        predicates.compactMap { predicate in
            let observed = state.lookup(predicate.path)
            return holds(predicate, observed) ? nil : ControlUnmet(predicate: predicate, observed: observed)
        }
    }

    static func holds(_ predicate: ControlPredicate, _ observed: ControlLookup) -> Bool {
        switch predicate.op {
        case .eq:
            return observed == .value(predicate.value)
        case .ne:
            return observed != .value(predicate.value)
        case .gte, .lte:
            guard case .value(.int(let value)) = observed, case .int(let bound) = predicate.value else { return false }
            return predicate.op == .gte ? value >= bound : value <= bound
        case .exists:
            let present = if case .value(let value) = observed { value != .null } else { false }
            return present == (predicate.value == .bool(true))
        }
    }

    /// Wait until every predicate holds on `state()` (→ `[]`), or the timeout passes (→ the unmet ones).
    /// A timeout of zero evaluates once. `state` is read inside observation tracking each pass.
    @MainActor
    static func wait(for predicates: [ControlPredicate], timeout: Duration,
                     poll: Duration = .milliseconds(20),
                     state: () -> ControlJSON) async -> [ControlUnmet] {
        let deadline = ContinuousClock.now + timeout
        while true {
            let signal = ControlSignal()
            let snapshot = withObservationTracking(state) {
                Task { @MainActor in signal.fire() }
            }
            let unmet = unmet(predicates, in: snapshot)
            let now = ContinuousClock.now
            if unmet.isEmpty || now >= deadline { return unmet }
            await signal.wait(upTo: min(poll, deadline - now))
        }
    }
}

/// A one-shot wake-up: `fire()` (an observed change) or the poll interval, whichever comes first.
@MainActor
final class ControlSignal {
    private var continuation: CheckedContinuation<Void, Never>?
    private var fired = false

    func fire() {
        fired = true
        continuation?.resume()
        continuation = nil
    }

    func wait(upTo interval: Duration) async {
        guard !fired else { return }
        let timer = Task { @MainActor [weak self] in
            try? await Task.sleep(for: interval)   // the poll fallback, bounded by the caller's deadline
            self?.fire()
        }
        await withCheckedContinuation { continuation = $0 }
        timer.cancel()
    }
}

#endif
