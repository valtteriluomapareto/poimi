//
//  ReviewProgress.swift
//  Curation — the album's REVIEW progress (days reviewed / where to resume), issue #202.
//
//  Distinct from PICK progress (`TargetProgress`, "147 / 200 picked"): this is the "how far through the
//  review am I" dimension the Overview was missing — a "12 of 47 days reviewed" readout and a bookmark
//  that always points at the first day still needing review. Both derive from the stable per-day done
//  truth (`Completion` over `doneDays`), so they survive the clusters re-computing when the library
//  changes. Pure + string-free (D14/D21): the app tier phrases the numbers + navigates to the index.
//

import Foundation

public enum ReviewProgress {
    /// How many dated days-with-photos are marked done — the numerator of "N of M days reviewed" (M is
    /// the album's total dated days). Counted at DAY granularity (not whole clusters), so a multi-day
    /// trip that's only partly reconciled-open still contributes its days that remain done. The undated
    /// bucket isn't a real calendar day, so it never counts.
    public static func reviewedDayCount(clusters: [ReviewCluster], doneDays: Set<DayKey>) -> Int {
        clusters.reduce(0) { total, cluster in
            cluster.days.reduce(total) { running, day in
                day != .undated && doneDays.contains(day) ? running + 1 : running
            }
        }
    }

    /// The index of the first DATED cluster not yet fully done — the resume/bookmark target, the earliest
    /// day still needing review. `nil` when every dated cluster is done (or the album is empty): there's
    /// nowhere left to resume, so the caller hides the "Continue" affordance. Cluster granularity (a
    /// cluster is done iff every day it spans is done), matching the grid's `initialPage` resume choice.
    ///
    /// The undated bucket is deliberately NOT a resume target: it isn't a real calendar day, so it's also
    /// excluded from `reviewedDayCount` and the album's total-days denominator. Were it eligible, once
    /// every dated day was done the card would read "Undated · N of N days reviewed" — claiming
    /// completion while still inviting you to continue. (The undated bucket stays reachable via the list
    /// + the "To review" filter; it's just not the bookmark.)
    public static func firstUnreviewedIndex(clusters: [ReviewCluster], doneDays: Set<DayKey>) -> Int? {
        clusters.firstIndex { cluster in
            !cluster.isUndated && !cluster.dayGroups.allSatisfy { Completion.isDone($0, doneDays: doneDays) }
        }
    }
}
