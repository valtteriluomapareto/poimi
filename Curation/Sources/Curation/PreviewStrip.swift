//
//  PreviewStrip.swift
//  Curation — the Overview cluster preview strip sampling (issue #203).
//
//  The Overview lists each cluster with a horizontal thumbnail strip. Two flavours, both pure + testable:
//    • `evenlySampled` — a representative spread across a set of ids (first + last + evenly between),
//      de-duped. The v1 "what's in this day" preview (#35).
//    • `pickedFirst` — "what I KEPT from this day" (#203): the picked ids first (chronological), then an
//      even spread of the unpicked to fill; an untouched cluster (no picks) falls back to `evenlySampled`
//      so nothing regresses for days you haven't started.
//
//  String-free (D14/D21): operates on asset-id arrays + the selected-id set; the app tier decides the
//  count + renders the thumbnails and must compute these OFF a SwiftUI `body` (a pick must not re-sample
//  the whole list) — see `AlbumOverviewView`.
//

import Foundation

public enum PreviewStrip {
    /// Up to `count` ids sampled EVENLY across `ids` (first + last included), preserving order. `count <= 0`
    /// → empty; `count >= ids.count` → all ids. Indices are de-duplicated, so a set only slightly larger
    /// than `count` yields distinct thumbs (a repeated preview would read as a bug), possibly returning
    /// fewer than `count`. (Extracted from `DayGroup.evenlySampledIDs`, which now delegates here.)
    public static func evenlySampled(_ ids: [String], count: Int) -> [String] {
        guard count > 0 else { return [] }
        let n = ids.count
        guard n > count else { return ids }
        if count == 1 { return [ids[0]] }
        var seen = Set<Int>()
        var out: [String] = []
        out.reserveCapacity(count)
        for i in 0..<count {
            let idx = Int((Double(i) * Double(n - 1) / Double(count - 1)).rounded())
            if seen.insert(idx).inserted { out.append(ids[idx]) }
        }
        return out
    }

    /// The picked-first preview (#203): the photos you KEPT, then a spread of the rest.
    ///
    /// - `orderedIDs`: the cluster's member ids, chronological.
    /// - `selected`: the picked-id set (`SelectionStore`).
    /// - `count`: the strip length.
    /// - Returns, in order:
    ///   - **No picks** (untouched cluster) → `evenlySampled(orderedIDs, count)` — the v1 behavior.
    ///   - **Picks ≥ count** → an even spread ACROSS the picks (representative "what I kept"), picks only.
    ///   - **Some picks < count** → ALL picks (chronological), then an even spread of the unpicked to fill.
    ///   So the strip reads picks-block-then-unpicked-block, each chronological. Pure + deterministic.
    public static func pickedFirst(orderedIDs: [String], selected: Set<String>, count: Int) -> [String] {
        guard count > 0 else { return [] }
        let picked = orderedIDs.filter { selected.contains($0) }
        guard !picked.isEmpty else { return evenlySampled(orderedIDs, count: count) }
        guard picked.count < count else { return evenlySampled(picked, count: count) }
        let unpicked = orderedIDs.filter { !selected.contains($0) }
        return picked + evenlySampled(unpicked, count: count - picked.count)
    }
}

public extension ReviewCluster {
    /// The Overview preview strip for this cluster (#203): picked photos first, backfilled with an even
    /// spread of the rest; an untouched cluster falls back to an even sample. Pure over the cluster's
    /// chronological member ids + the selected set.
    func previewStripIDs(selected: Set<String>, count: Int) -> [String] {
        PreviewStrip.pickedFirst(orderedIDs: assetIDs, selected: selected, count: count)
    }
}
