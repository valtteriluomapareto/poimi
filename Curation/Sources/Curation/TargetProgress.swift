//
//  TargetProgress.swift
//  Curation — running-total / target math (issue #20, D5).
//
//  The running total toward a soft target is authoritative; any per-section figure is a
//  light advisory guide, never a quota (D5).
//

/// The picked-vs-target progress shown by the always-visible tally.
public struct TargetProgress: Sendable, Equatable {
    public let picked: Int
    public let target: Int

    public init(picked: Int, target: Int) {
        self.picked = picked
        self.target = target
    }

    /// Photos still wanted to reach the target (never negative).
    public var remaining: Int { max(0, target - picked) }

    /// Whether the target has been reached.
    public var isComplete: Bool { target > 0 && picked >= target }

    /// Photos picked PAST the target — unclamped (0 at or under, and 0 when there's no target to be over,
    /// consistent with `isOver`). The over-target signal the clamped `remaining` hides: `remaining` reads
    /// "0 left" whether you're exactly at target or far over (#170).
    public var overage: Int { target > 0 ? max(0, picked - target) : 0 }

    /// Whether the pick count has passed the target (strictly over, not merely reached).
    public var isOver: Bool { target > 0 && picked > target }

    /// Progress in `0...1` (clamped at both ends); `0` when the target is non-positive.
    public var fraction: Double {
        guard target > 0 else { return 0 }
        return max(0, min(1, Double(picked) / Double(target)))
    }
}

public enum Target {
    /// An advisory per-section share (D5 — guidance for a header, never enforced).
    /// `nil` when there are no sections or no target.
    public static func suggestedPerSection(target: Int, sectionCount: Int) -> Int? {
        guard sectionCount > 0, target > 0 else { return nil }
        return Int((Double(target) / Double(sectionCount)).rounded())
    }
}

/// How far your picks reach through the album: the chronological position of the latest-dated picked
/// candidate. `orderedIDs` is the review's candidate list oldest → newest (undated sorts last, so an
/// undated pick lands at the tail → frontier ≈ 1). Returns `(lastPickedIndex + 1) / count`, or `0`
/// when nothing in `orderedIDs` is picked. Pure so the pacing denominator is unit-tested. NOTE: for the
/// projection to be honest, the numerator (total picks) must range over this SAME candidate universe —
/// `orderedIDs` must enumerate every candidate `SelectionStore.selected` can contain (the undated bucket
/// included).
public func pickFrontierFraction(orderedIDs: [String], selected: Set<String>) -> Double {
    guard !orderedIDs.isEmpty,
          let last = orderedIDs.lastIndex(where: selected.contains) else { return 0 }
    return Double(last + 1) / Double(orderedIDs.count)
}

/// Pace vs a soft target, projected from the picks so far (#170; docs/design/pacing.md).
/// ORIENTATION ONLY (D5) — never enforced. The view maps this to colour/copy; the domain stays string-free.
public enum Pace: Sendable, Equatable { case onPace, ahead, behind }

/// A projection of the final pick count from the pace so far, coupling total picks to the pick frontier
/// (how far the picks reach). `projectedTotal` is `nil` until the frontier passes a confidence floor —
/// early on, thin coverage makes any projection noise.
public struct Pacing: Sendable, Equatable {
    /// Total picks so far. Every pick is at or before the frontier by construction, so it pairs with
    /// `frontier` over the same candidate universe.
    public let picked: Int
    /// The pick frontier, `0...1` (`pickFrontierFraction`).
    public let frontier: Double
    public let target: Int

    /// Minimum frontier before a projection is trustworthy — roughly two months into a year; below it
    /// "picked 8, frontier 4% → ~200" is meaningless. Tunable, not magic.
    public static let confidenceFloor = 0.15

    public init(picked: Int, frontier: Double, target: Int) {
        self.picked = picked
        self.frontier = frontier
        self.target = target
    }

    /// Projected final pick count if the current pick density holds across the rest of the album;
    /// `nil` below the confidence floor or without a positive target.
    public var projectedTotal: Int? {
        guard target > 0, frontier >= Self.confidenceFloor else { return nil }
        return Int((Double(picked) / frontier).rounded())
    }

    /// Pace vs target with a ±10% dead-band, so small deviations read `.onPace`. `nil` when there's no
    /// projection to judge. Compares the ROUNDED `projectedTotal` (what the UI shows), not the raw ratio.
    public var pace: Pace? {
        guard let projected = projectedTotal, target > 0 else { return nil }
        let ratio = Double(projected) / Double(target)
        if ratio > 1.10 { return .ahead }
        if ratio < 0.90 { return .behind }
        return .onPace
    }
}
