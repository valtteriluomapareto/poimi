//
//  Completion.swift
//  Curation — section completion, resume, and stats (issue #20, D32(d)/D34).
//
//  Completion lives on the stable per-day atom (`DayKey`), and "section done" is a derived
//  *view* over that per-day truth — so progress survives the day-groups re-computing when
//  the library changes (architecture §13). All pure functions over value inputs; the
//  SwiftData persistence of `doneDays` and the mark-as-done UI are Phase 2.
//

import Foundation

public enum Completion {
    /// A section renders done iff every calendar day it spans is in `doneDays` (D32(d)).
    public static func isDone(_ group: DayGroup, doneDays: Set<DayKey>) -> Bool {
        group.days.allSatisfy { doneDays.contains($0) }
    }

    /// Marking a section done flags every calendar day it spans.
    public static func markingDone(_ group: DayGroup, in doneDays: Set<DayKey>) -> Set<DayKey> {
        doneDays.union(group.days)
    }

    /// Unmarking a section removes the days it spans.
    public static func markingUndone(_ group: DayGroup, in doneDays: Set<DayKey>) -> Set<DayKey> {
        doneDays.subtracting(group.days)
    }

    /// The distinct calendar days that actually hold photos, in chronological order
    /// (undated last). Day-level and so independent of how the days are grouped.
    public static func daysWithPhotos(in assets: [AssetRef], calendar: Calendar) -> [DayKey] {
        var seen = Set<DayKey>()
        var ordered: [DayKey] = []
        for asset in assets {
            let key = asset.dayKey(in: calendar)
            if seen.insert(key).inserted {
                ordered.append(key)
            }
        }
        return ordered.sorted()
    }

    /// Resume = the earliest day-with-photos not yet done. Day-level, so it is invariant to
    /// the grouping. `nil` when every such day is done.
    public static func resumeDay(
        assets: [AssetRef],
        doneDays: Set<DayKey>,
        calendar: Calendar
    ) -> DayKey? {
        daysWithPhotos(in: assets, calendar: calendar).first { !doneDays.contains($0) }
    }

    /// "Done but changed" reconcile (D32(d) / architecture §13): when the library changes
    /// under a curation, a done day whose photo count **grew** re-opens (its flag clears),
    /// so a newly-added photo isn't silently skipped by resume/stats; a day that only lost
    /// photos stays done. Pure and day-level — pass the asset slices from before and after
    /// the change. Returns the reconciled `doneDays`.
    public static func reopening(
        doneDays: Set<DayKey>,
        from previous: [AssetRef],
        to current: [AssetRef],
        calendar: Calendar
    ) -> Set<DayKey> {
        let before = countsByDay(previous, calendar: calendar)
        let after = countsByDay(current, calendar: calendar)
        let grew = doneDays.filter { (after[$0] ?? 0) > (before[$0] ?? 0) }
        return doneDays.subtracting(grew)
    }

    private static func countsByDay(_ assets: [AssetRef], calendar: Calendar) -> [DayKey: Int] {
        var counts: [DayKey: Int] = [:]
        for asset in assets {
            counts[asset.dayKey(in: calendar), default: 0] += 1
        }
        return counts
    }
}

/// The completion-screen stats, derived from the stable per-day truth + the selection.
///
/// Domains are deliberately pinned so the percentage can never exceed 100 (the review's
/// blocking bug): the denominator is assets **on done days** (labelled "marked done"), and
/// `kept` is the selected subset of *those* — never the project-wide pick count, which is
/// surfaced separately as `totalPicked`.
public struct CompletionStats: Sendable, Equatable {
    /// Assets on done days within range — the denominator (label it "marked done").
    public let markedDone: Int
    /// Selected assets among the marked-done ones.
    public let kept: Int
    /// All selected assets in range (shown separately; can exceed `kept`).
    public let totalPicked: Int

    /// `kept / markedDone` in `0...1`; `0` when nothing is marked done.
    public var fractionKept: Double {
        guard markedDone > 0 else { return 0 }
        return Double(kept) / Double(markedDone)
    }

    public init(
        assets: [AssetRef],
        doneDays: Set<DayKey>,
        selection: Set<String>,
        calendar: Calendar
    ) {
        var markedDone = 0
        var kept = 0
        var totalPicked = 0
        for asset in assets {
            let isSelected = selection.contains(asset.id)
            if isSelected { totalPicked += 1 }
            let onDoneDay = doneDays.contains(asset.dayKey(in: calendar))
            if onDoneDay {
                markedDone += 1
                if isSelected { kept += 1 }
            }
        }
        self.markedDone = markedDone
        self.kept = kept
        self.totalPicked = totalPicked
    }
}
