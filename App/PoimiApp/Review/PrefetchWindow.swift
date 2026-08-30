//
//  PrefetchWindow.swift
//  PoimiApp — the grid's scroll-driven prefetch slice (issue #35).
//
//  Extracted from the spike's `AssetGridView` so the windowing math — the "does it stay smooth over
//  thousands of assets" exit criterion — is a pure, unit-tested value rather than buried in a View.
//  Built once per slice (the O(n) index map) and queried per scroll tick (O(visible)).
//

import Foundation

/// The flattened chronological id order for one grouping, plus the index map, so the grid can ask
/// for "the ids around the visible range" cheaply as the user scrolls across section boundaries.
struct PrefetchWindow {
    /// All group ids concatenated (oldest → newest) — the grid renders this exact order.
    let orderedIDs: [String]
    private let indexByID: [String: Int]

    init(orderedIDs: [String]) {
        self.orderedIDs = orderedIDs
        self.indexByID = Dictionary(orderedIDs.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// The ids to prefetch for the current scroll position: the visible index range (over the
    /// flattened order, so it spans sections) expanded by `rowMargin` rows of `columnCount` each.
    ///
    /// - With no visible cells yet (first layout, before any `onAppear`), primes the head of the
    ///   slice so the first screen caches without waiting for visibility reports.
    /// - Visible ids not in this slice (a stale grouping) are ignored.
    func slice(visibleIDs: Set<String>, columnCount: Int, rowMargin: Int) -> [String] {
        let count = orderedIDs.count
        guard count > 0 else { return [] }

        guard !visibleIDs.isEmpty else {
            let headCount = min(count, max(1, columnCount) * (rowMargin + 1) * 2)
            return Array(orderedIDs.prefix(headCount))
        }

        var minVisible = Int.max
        var maxVisible = Int.min
        for id in visibleIDs {
            guard let index = indexByID[id] else { continue }
            if index < minVisible { minVisible = index }
            if index > maxVisible { maxVisible = index }
        }
        guard minVisible <= maxVisible else { return [] }   // visible ids were all stale

        let margin = max(0, columnCount) * max(0, rowMargin)
        let lower = max(0, minVisible - margin)
        let upper = min(count - 1, maxVisible + margin)
        return Array(orderedIDs[lower...upper])
    }
}

// MARK: - Warming the neighbouring pages (#277)

extension PrefetchWindow {
    /// The ids worth warming for the pages either side of the current one — the paged grid's
    /// "don't arrive on a screen of placeholders" prime (#277).
    ///
    /// The live window's universe is the CURRENT cluster only (`ReviewGridView.rebuildWindow`), so a
    /// swipe lands on a page PhotoKit has never been asked about. This names a bounded head for each
    /// neighbour: the same first screenful the empty-visible path of `slice` primes
    /// (`columnCount * (rowMargin + 1) * 2` ids), taken from the next page first (the likelier swipe
    /// direction) and then the previous one.
    ///
    /// Deliberately pure `[String]`/`Int` math, so the "which ids" decision is unit-tested rather than
    /// inferred from the grid, and bounded by construction — one head per neighbour, never a whole
    /// cluster — which is what keeps the memory cost flat and lets `updateCachingWindow`'s add/remove
    /// diff release the head you page away from.
    ///
    /// - Parameters:
    ///   - clusters: each page's ids, in page order (the review timeline).
    ///   - currentIndex: the page the user is on; out of range yields no warm set.
    ///   - columnCount: the grid's current column count.
    ///   - rowMargin: the window's row margin — the same value `slice` is called with.
    /// - Returns: the next page's head followed by the previous page's, deduped, with the current
    ///   page's own ids removed (those are the live window's job and must not be appended after it).
    static func adjacentHeadIDs(clusters: [[String]],
                                currentIndex: Int,
                                columnCount: Int,
                                rowMargin: Int) -> [String] {
        guard clusters.indices.contains(currentIndex) else { return [] }
        let headCount = max(1, columnCount) * (max(0, rowMargin) + 1) * 2
        var seen = Set(clusters[currentIndex])
        var heads: [String] = []
        for neighbour in [currentIndex + 1, currentIndex - 1] {
            guard clusters.indices.contains(neighbour) else { continue }
            for id in clusters[neighbour].prefix(headCount) {
                guard seen.insert(id).inserted else { continue }
                heads.append(id)
            }
        }
        return heads
    }
}
