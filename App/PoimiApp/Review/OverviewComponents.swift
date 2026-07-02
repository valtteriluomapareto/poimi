//
//  OverviewComponents.swift
//  PoimiApp — shared overview/grid building blocks: the rounded thumbnail loader (`OverviewThumb`)
//  and the review grid's collapsed cluster peek. The cluster-index Overview screen itself lives in
//  AlbumOverviewView (issue #37).
//

import SwiftUI
import UIKit
import Curation

/// A rounded, lazily-loaded thumbnail — the shared image tile behind the Overview's cluster rows and
/// the review grid's collapsed peek. Loads through the injected provider; cache-first so a re-appear
/// doesn't flash a placeholder.
struct OverviewThumb: View {
    let id: String
    let size: CGFloat
    /// Set by the caller — a cluster row's thumb and the grid's 56pt peek use different radii.
    let cornerRadius: CGFloat
    @Environment(\.thumbnailProvider) private var thumbnails
    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?

    var body: some View {
        // `tertiarySystemFill` (not `secondarySystemBackground`) so an unloaded thumb still reads as a
        // slot on the month card, which is itself `secondarySystemBackground` — else it's an invisible hole.
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(Color(.tertiarySystemFill))
            .overlay {
                if let image { Image(uiImage: image).resizable().scaledToFill() }
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .task(id: id) {
                let px = size * displayScale
                let target = CGSize(width: px, height: px)
                // Cache-first paint (no placeholder flash on a re-appear), then the async load.
                if image == nil, let cached = thumbnails.cachedThumbnail(for: id, targetSize: target) {
                    image = cached
                }
                image = await thumbnails.thumbnail(for: id, targetSize: target)
            }
    }
}

/// The overview's coverage chart: one bar per adaptive time bucket (day / week / month by span — see
/// `ChartBucketing`), height ∝ that slice's photos, each bar stacked by review state — green (done) at
/// the base, gold (in-progress) above it, grey (untouched) on top. Density AND how much is finished, in
/// one glance; a quiet slice reads as a gap and month-initial ticks mark the axis. Fits the width at any
/// album length — bars flex, never scroll (the earlier per-cluster chart went 100+ bars wide) — so
/// per-cluster detail lives in the list below. Reads the stores itself (state is live) so the overview
/// body stays selection-independent. Orientation only — `accessibilityHidden`.
struct CoverageChart: View {
    let buckets: [ChartBucket]
    @Environment(SelectionStore.self) private var selection
    @Environment(DoneStore.self) private var doneStore

    private let maxBarHeight: CGFloat = 72
    /// Cap the bar width so a few-bar album reads as a small chart, not giant slabs; bars thin down (via
    /// the equal-width columns) when there are many.
    private let maxBarWidth: CGFloat = 28

    private struct Bar: Identifiable {
        let id: Int
        let tick: String?
        let done: Int
        let inProgress: Int
        let untouched: Int
        var total: Int { done + inProgress + untouched }
    }

    var body: some View {
        // Per-bucket photo totals split by state, computed here (orientation; the overview isn't the
        // rapid-toggle surface). An empty bucket totals 0 → a gap in the skyline.
        let bars = buckets.map(bar)
        let unit = maxBarHeight / CGFloat(max(bars.map(\.total).max() ?? 1, 1))
        return HStack(alignment: .bottom, spacing: 3) {
            ForEach(bars) { bar in
                VStack(spacing: 4) {
                    stackedBar(bar, unit: unit)
                        .frame(maxWidth: maxBarWidth)
                    Text(bar.tick ?? "")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(height: 13)   // fixed so bar bottoms align whether or not a tick shows
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: maxBarHeight + 17, alignment: .bottom)
        .accessibilityHidden(true)
    }

    /// Green (done) at the base, gold (in-progress), grey (untouched) on top — completion fills up from
    /// the bottom. Rounded as one bar; each present state floors at a 1pt sliver so it never vanishes.
    private func stackedBar(_ bar: Bar, unit: CGFloat) -> some View {
        VStack(spacing: 0) {
            segment(bar.untouched, unit: unit, color: Color(.systemGray3))
            segment(bar.inProgress, unit: unit, color: .accentColor)
            segment(bar.done, unit: unit, color: .brandGreen)
        }
        .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
    }

    @ViewBuilder
    private func segment(_ count: Int, unit: CGFloat, color: Color) -> some View {
        if count > 0 {
            color.frame(height: max(1, CGFloat(count) * unit))
        }
    }

    private func bar(_ bucket: ChartBucket) -> Bar {
        var done = 0, inProgress = 0, untouched = 0
        for row in bucket.rows {
            switch ClusterState.of(isDone: doneStore.isDone(row.group), pickedCount: pickedCount(row)) {
            case .done: done += row.count
            case .inProgress: inProgress += row.count
            case .untouched: untouched += row.count
            }
        }
        return Bar(id: bucket.id, tick: bucket.tick, done: done, inProgress: inProgress, untouched: untouched)
    }

    // O(bucket photos) per bar; a selection/done write re-renders the chart. Fine — the overview isn't
    // the rapid-toggle surface (picking happens in the grid).
    private func pickedCount(_ row: ClusterRow) -> Int {
        row.group.assetIDs.reduce(into: 0) { if selection.selected.contains($1) { $0 += 1 } }
    }
}

/// Keeps-first ordering for the collapsed peek: the picked ids (in source order) then the rest.
/// Pure + `internal` so the "foreground the keeps" blocker fix is unit-tested and can't silently
/// regress back to raw chronology (the product-blocker the ruthless review flagged).
func keptFirstOrdering(ids: [String], picked: Set<String>) -> [String] {
    ids.filter(picked.contains) + ids.filter { !picked.contains($0) }
}

/// The collapsed peek for a cluster in the accordion review grid — a width-filling strip of that
/// day's photos; tap anywhere to open it (the disclosure chevron in its header signals that, so no
/// "Show all"/overflow chrome). The count lives in the pinned header ("N of M kept" / "· total").
/// A DONE cluster foregrounds the kept photos and dims the rest (its summary is "what I kept"); a
/// not-done cluster shows a clean chronological preview at full opacity. Reads `SelectionStore`
/// itself, so the grid body stays selection-independent.
struct CollapsedSectionPeek: View {
    let ids: [String]
    /// The day-group title, threaded in for the VoiceOver label (a peek is otherwise contextless).
    let dayTitle: String
    /// Done clusters dim their not-kept thumbs (kept-emphasis); not-done clusters never dim.
    let isDone: Bool
    let onOpen: () -> Void
    @Environment(SelectionStore.self) private var selection

    private let thumbSize: CGFloat = 56
    private let thumbSpacing: CGFloat = 6
    private let thumbRadius: CGFloat = 8
    private let trailingInset: CGFloat = 12

    var body: some View {
        // O(group size), bounded; runs in this subview, not the grid body.
        let pickedSet = selection.selected.intersection(ids)
        // Done → lead with the keeps; not-done → plain chronological order.
        let ordered = isDone ? keptFirstOrdering(ids: ids, picked: pickedSet) : ids

        Button(action: onOpen) {
            GeometryReader { geo in
                // Fill the available width with as many 56pt thumbs as fit (Pro Max shows more than a
                // mini) — no fixed cap, no "+N", just photos.
                let fit = max(1, Int((geo.size.width - trailingInset + thumbSpacing) / (thumbSize + thumbSpacing)))
                HStack(spacing: thumbSpacing) {
                    ForEach(Array(ordered.prefix(fit)), id: \.self) { id in
                        OverviewThumb(id: id, size: thumbSize, cornerRadius: thumbRadius)
                            .opacity(isDone && !pickedSet.contains(id) ? 0.55 : 1)   // dim not-kept on DONE only
                    }
                    Spacer(minLength: 0)
                }
            }
            .frame(height: thumbSize)
            .padding(.bottom, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(dayTitle). \(pickedSet.count) of \(ids.count) photos kept. Open.")
    }
}
