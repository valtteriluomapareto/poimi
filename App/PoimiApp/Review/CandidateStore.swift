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
    /// The phases the scanning surface renders. `Equatable` so the view (and tests) can compare
    /// without unwrapping the associated groups.
    enum Phase: Equatable {
        case idle
        case scanning
        /// The filtered candidates grouped into adaptive day-groups, oldest → newest. Non-empty by
        /// construction (empty → `.empty`). The review grid renders these directly — grouping is
        /// done here, once, not in the view (Finding 1).
        case ready([DayGroup])
        /// Nothing matched the range and filters — a real, expected outcome, not an error.
        case empty
        case failed
    }

    private(set) var phase: Phase = .idle
    /// Each candidate's calendar day, keyed by asset id — the per-photo day the viewer labels with
    /// (#36). `DayGroup` only records the days a group *spans* (a merged quiet run spans several),
    /// so the per-asset day is derived here from `captureDate` under the same `calendar`. Empty
    /// until a pass settles to `.ready`.
    private(set) var dayByID: [String: DayKey] = [:]
    /// The candidates aggregated by calendar month — the album overview's rows + coverage histogram
    /// (#37). Coarser than `groups` (which the review grid uses); derived from the same candidates +
    /// calendar. Empty until `.ready`.
    private(set) var monthSummaries: [MonthSummary] = []
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
        monthSummaries = []

        // An empty / inverted range has no candidates — and `DateInterval(start:end:)` traps when
        // end < start, so guard before constructing it. Setup disables Create on an inverted range
        // (#33), but a malformed persisted project must degrade to "empty", never crash.
        guard project.rangeEnd > project.rangeStart else {
            phase = .empty
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
            let groups = DayGrouping.groups(for: candidates, calendar: calendar)
            // Per-photo day map for the viewer's label (#36), built from the same candidates +
            // calendar so it agrees with the grouping (a busy day and the viewer read the same day).
            // In practice every value is a real day: a range fetch never returns a nil-capture-date
            // asset, so `.undated` doesn't arise here — the viewer's `.undated` label is defensive
            // (and `DayKey(date: nil,…)`'s mapping is pinned in CurationTests regardless).
            dayByID = Dictionary(
                candidates.map { ($0.id, DayKey(date: $0.captureDate, calendar: calendar)) },
                uniquingKeysWith: { first, _ in first })
            // Month aggregation for the overview (#37) — same candidates + calendar as the grouping.
            monthSummaries = MonthGrouping.summaries(for: candidates, calendar: calendar)
            phase = groups.isEmpty ? .empty : .ready(groups)
        } catch {
            Log.photoLibrary.error("CandidateStore.load failed: \(String(describing: error), privacy: .public)")
            phase = .failed
        }
    }
}
