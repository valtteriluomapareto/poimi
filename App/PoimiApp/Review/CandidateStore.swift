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

import Foundation
import Curation

@MainActor
@Observable
final class CandidateStore {
    /// The phases the scanning surface renders. `Equatable` so the view (and tests) can compare
    /// without unwrapping the associated assets.
    enum Phase: Equatable {
        case idle
        case scanning
        /// The filtered candidates, oldest → newest. Non-empty by construction (empty → `.empty`).
        case ready([AssetRef])
        /// Nothing matched the range and filters — a real, expected outcome, not an error.
        case empty
        case failed
    }

    private(set) var phase: Phase = .idle
    private let library: any PhotoLibraryProviding

    init(library: any PhotoLibraryProviding) {
        self.library = library
    }

    /// Run the fetch → resolve → filter pass for `project`, publishing each phase as it settles.
    /// Idempotent: callable again (e.g. a "Try again" after `.failed`) — it restarts from
    /// `.scanning`.
    func load(_ project: CurationProject) async {
        phase = .scanning

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
            phase = candidates.isEmpty ? .empty : .ready(candidates)
        } catch {
            Log.photoLibrary.error("CandidateStore.load failed: \(String(describing: error), privacy: .public)")
            phase = .failed
        }
    }
}
