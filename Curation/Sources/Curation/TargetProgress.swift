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

    /// Progress in `0...1` (clamped); `0` when the target is non-positive.
    public var fraction: Double {
        guard target > 0 else { return 0 }
        return min(1, Double(picked) / Double(target))
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
