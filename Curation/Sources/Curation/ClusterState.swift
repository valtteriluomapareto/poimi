//
//  ClusterState.swift
//  Curation — a day-cluster's review state, derived from picks + done (issue #37, the cluster index).
//
//  The Overview colours each cluster (its bar in the chart, its row) by how far along it is. Only two
//  honest signals exist per cluster, both already tracked: whether it's been marked **done** (DoneStore
//  / `Completion`) and how many of its photos are **picked** (SelectionStore). "Opened/viewed" is NOT a
//  signal — opening a cluster isn't reviewing it. So the state is a pure derivation with no new tracking
//  (the 3IF-0 spec): done wins (a day you finished but kept nothing is still done); otherwise a single
//  pick reads as in-progress; otherwise untouched. Lives here as a tested value function, like
//  `TargetProgress` — the view just maps a state to a colour.
//

/// How far a day-cluster has been reviewed. A pure function of (done, picked) — see `of(isDone:pickedCount:)`.
public enum ClusterState: Sendable, Equatable {
    /// Marked done — "I've finished this day", even with zero picks (reviewed, kept nothing).
    case done
    /// Not done, but at least one photo picked — engaged, short of finishing.
    case inProgress
    /// Not done and nothing picked yet.
    case untouched

    /// Derive the state from the two tracked signals. `isDone` is authoritative (a done cluster with
    /// zero picks is still done — that's the trustworthy completion signal); otherwise any pick at all
    /// reads as in-progress, and no picks reads as untouched.
    public static func of(isDone: Bool, pickedCount: Int) -> ClusterState {
        if isDone { return .done }
        return pickedCount > 0 ? .inProgress : .untouched
    }
}
