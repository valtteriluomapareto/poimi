//
//  CandidateStore.swift
//  PoimiApp — the review-fetch pipeline (issue #34; architecture §3, D2/D12/D17).
//
//  Given a `CurationProject`, this drives the two-call fetch tier behind the `PhotoLibrary`
//  actor and applies the two exact source filters, producing the candidate set the review grid
//  (#35) renders:
//
//      1. fetch the project's date-range assets               (oldest → newest)
//      2. resolve the excluded albums → their member asset ids (set-difference input)
//      3. `Filtering.included`: drop screenshots + excluded-album members
//
//  Step 2 is where #33's persisted `excludedAlbumIDs` finally *resolve* into a concrete
//  membership set. The whole thing is a `@MainActor @Observable` so the scanning surface can
//  bind to `phase` and react as the pass settles.
//
//  Scope note: the candidates are materialized flat here — the windowed-by-index snapshot (D17)
//  and its access-counting guard (D29) are #47, which depends on this. The flat array matches
//  the existing `fetchAssets` contract, so this introduces no regression for #47 to undo.
//
//  Grouping lives here, NOT in the review grid's `body` (smoothness review, Finding 1):
//  `DayGrouping.groups` is an O(n log n) sort + bucket over the whole candidate set, so it must
//  run exactly once — when the pass settles to `.ready` — never on a view re-render (a scroll
//  anchor write would otherwise recompute it on the interaction hot path). The `calendar` is
//  owned + injected here so the timezone policy is explicit and testable (rather than implicitly
//  `.current` inside a `body`), and the grouped `.ready` is the value the grid renders directly.
//

import Foundation
import Curation

@MainActor
@Observable
final class CandidateStore {
    /// Why a settled pass has no candidates — so the empty state can be actionable (#40, design 2JE):
    /// point at the range vs the exclusions rather than a generic dead-end.
    enum EmptyReason: Equatable {
        /// The date range itself yielded no photos (or the range is inverted). Fix: widen the range.
        case noPhotosInRange
        /// Photos existed in range, but every one was filtered out (screenshots / excluded albums).
        /// Fix: relax the exclusions.
        case allExcluded
    }

    /// Why a pass failed — a transient load error (retry) vs photo access lost mid-session (recover).
    enum FailureReason: Equatable {
        /// The fetch threw while access is still granted — likely iCloud/network. Retryable.
        case loadError
        /// The fetch threw AND photo access is no longer authorized (revoked mid-session, D6/§10).
        /// A retry can't succeed — the app should route to the recovery screen.
        case accessLost
    }

    /// The phases the scanning surface renders. `Equatable` so the view (and tests) can compare
    /// without unwrapping the associated groups.
    enum Phase: Equatable {
        case idle
        case scanning
        /// The filtered candidates grouped into adaptive day-groups, oldest → newest. Non-empty by
        /// construction (empty → `.empty`). The review grid renders these directly — grouping is
        /// done here, once, not in the view (Finding 1).
        case ready([DayGroup])
        /// Nothing matched the range and filters — a real, expected outcome, not an error (#40).
        case empty(EmptyReason)
        case failed(FailureReason)
    }

    private(set) var phase: Phase = .idle
    /// Each candidate's calendar day, keyed by asset id — the per-photo day the viewer labels with
    /// (#36). `DayGroup` only records the days a group *spans* (a merged quiet run spans several),
    /// so the per-asset day is derived here from `captureDate` under the same `calendar`. Empty
    /// until a pass settles to `.ready`.
    private(set) var dayByID: [String: DayKey] = [:]
    private let library: any PhotoLibraryProviding
    /// The calendar the day-grouping buckets by. Injected (default `.current`) so the timezone
    /// policy is explicit and a test can pin it — and so a locale/timezone change is a property of
    /// this store, not an accident of where grouping used to run.
    private let calendar: Calendar

    init(library: any PhotoLibraryProviding, calendar: Calendar = .current) {
        self.library = library
        self.calendar = calendar
    }

    /// Run the fetch → resolve → filter pass for `project`, publishing each phase as it settles.
    /// Idempotent: callable again (e.g. a "Try again" after `.failed`) — it restarts from
    /// `.scanning`.
    func load(_ project: CurationProject) async {
        phase = .scanning
        dayByID = [:]   // clear any prior pass's map (e.g. a retry after .failed)

        // An empty / inverted range has no candidates — and `DateInterval(start:end:)` traps when
        // end < start, so guard before constructing it. Setup disables Create on an inverted range
        // (#33), but a malformed persisted project must degrade to "empty", never crash.
        guard project.rangeEnd > project.rangeStart else {
            phase = .empty(.noPhotosInRange)
            return
        }
        let interval = DateInterval(start: project.rangeStart, end: project.rangeEnd)

        do {
            let fetched = try await library.fetchAssets(in: interval)
            let excludedAssetIDs = try await library.assetIDs(inAlbums: project.excludedAlbumIDs)
            let candidates = Filtering.included(
                fetched,
                excludeScreenshots: project.excludeScreenshots,
                excludedAssetIDs: excludedAssetIDs)
            // Group once, here — the grid renders the groups directly and never recomputes them
            // (Finding 1). Concatenating the groups' `assetIDs` reproduces the chronological slice.
            // The busy-day threshold is ADAPTIVE — derived from this album's own photo density (mean
            // per active day, clamped) — so "busy" tracks how much this person shoots, not a fixed 10.
            let groups = DayGrouping.groups(adaptiveFor: candidates, calendar: calendar)
            // Per-photo day map for the viewer's label (#36), built from the same candidates +
            // calendar so it agrees with the grouping (a busy day and the viewer read the same day).
            // In practice every value is a real day: a range fetch never returns a nil-capture-date
            // asset, so `.undated` doesn't arise here — the viewer's `.undated` label is defensive
            // (and `DayKey(date: nil,…)`'s mapping is pinned in CurationTests regardless).
            dayByID = Dictionary(
                candidates.map { ($0.id, DayKey(date: $0.captureDate, calendar: calendar)) },
                uniquingKeysWith: { first, _ in first })
            if groups.isEmpty {
                // Distinguish WHY it's empty so the state is actionable (#40): the range yielded
                // nothing (widen it) vs photos existed but were all filtered out (relax exclusions).
                phase = .empty(fetched.isEmpty ? .noPhotosInRange : .allExcluded)
            } else {
                phase = .ready(groups)
            }
        } catch {
            Log.photoLibrary.error("CandidateStore.load failed: \(String(describing: error), privacy: .public)")
            // A transient load error is retryable; but if access was revoked mid-session the fetch
            // fails for good — re-check authorization so the view can route to recovery instead of a
            // retry that can't succeed (#40, D6/§10).
            let stillAuthorized = await library.authorizationStatus() == .authorized
            phase = .failed(stillAuthorized ? .loadError : .accessLost)
        }
    }
}
