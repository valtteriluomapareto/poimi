//
//  OverviewComponents.swift
//  PoimiApp — the album overview's coverage histogram + month thumbnail strip (issue #37; design 19P).
//

import SwiftUI
import UIKit
import Curation

/// "Where your photos pile up" — a month-by-month bar chart of how the candidates are distributed,
/// with a one-line insight (the biggest month). Orientation, not interaction: it tells you where the
/// year is dense so you know where the picking work is.
struct CoverageHistogram: View {
    let summaries: [MonthSummary]

    private let maxBarHeight: CGFloat = 56
    /// Cap the bar width so a sparse album (2–3 months) reads as a small chart, not giant slabs.
    private let maxBarWidth: CGFloat = 30

    /// One bar — a calendar month and its photo count. `id` is "yyyy-MM" so it's stable across a
    /// year boundary (Jan 2025 ≠ Jan 2026).
    private struct Bar: Identifiable { let id: String; let month: Int; let count: Int }

    var body: some View {
        if summaries.count > 1 {   // a single month has nothing to distribute
            VStack(alignment: .leading, spacing: 10) {
                Text("WHERE YOUR PHOTOS PILE UP")
                    .font(.caption2.weight(.semibold))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
                bars
                if let insight { Text(insight).font(.footnote).foregroundStyle(.secondary) }
            }
        }
    }

    /// A CONTINUOUS month axis from the first to the last month with photos — months with none in
    /// between render as 0-height slots, so the chart reads as a real timeline rather than a collapsed
    /// list that hides the gaps.
    private var monthBars: [Bar] {
        guard let first = summaries.first, let last = summaries.last else { return [] }
        let countByID = Dictionary(uniqueKeysWithValues: summaries.map { ($0.id, $0.count) })
        var bars: [Bar] = []
        var year = first.year
        var month = first.month
        while year < last.year || (year == last.year && month <= last.month) {
            let key = String(format: "%04d-%02d", year, month)
            bars.append(Bar(id: key, month: month, count: countByID[key] ?? 0))
            month += 1
            if month > 12 { month = 1; year += 1 }
        }
        return bars
    }

    private var bars: some View {
        let symbols = Calendar.current.veryShortMonthSymbols
        let maxCount = max(monthBars.map(\.count).max() ?? 1, 1)
        return HStack(alignment: .bottom, spacing: 6) {
            ForEach(monthBars) { bar in
                VStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.accentColor.opacity(barOpacity(bar.count, of: maxCount)))
                        .frame(maxWidth: maxBarWidth)
                        .frame(height: max(2, maxBarHeight * CGFloat(bar.count) / CGFloat(maxCount)))
                    Text(symbols.indices.contains(bar.month - 1) ? symbols[bar.month - 1] : "")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: maxBarHeight + 16, alignment: .bottom)
        .accessibilityHidden(true)   // the insight line + the rows below carry the same information
    }

    /// Denser months read more saturated, so the peak stands out (the design's brighter summer bars).
    private func barOpacity(_ count: Int, of maxCount: Int) -> Double {
        0.45 + 0.55 * Double(count) / Double(maxCount)
    }

    private var insight: String? {
        // Summaries are non-empty by construction (MonthGrouping never emits a 0-photo month).
        guard let peak = summaries.max(by: { $0.count < $1.count }) else { return nil }
        let name = MonthLabel.name(year: peak.year, month: peak.month)
        return "\(name) is your biggest month — \(peak.count.formatted()) photos."
    }
}

/// A non-scrolling preview strip of a month's first photos — the visual signature of the 19P design.
/// Lazily loads small thumbnails through the injected provider; only the rows on screen build, since
/// the overview's month rows are in a `LazyVStack`.
struct OverviewThumbnailStrip: View {
    let ids: [String]

    private let thumbSize: CGFloat = 30
    private let maxThumbs = 11

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(ids.prefix(maxThumbs)), id: \.self) { id in
                OverviewThumb(id: id, size: thumbSize)
            }
        }
        .frame(height: thumbSize)
    }
}

private struct OverviewThumb: View {
    let id: String
    let size: CGFloat
    /// Proportional to `size` — a 5pt radius reads tighter on a 56pt peek thumb than on the 30pt strip.
    var cornerRadius: CGFloat = 5
    @Environment(\.thumbnailProvider) private var thumbnails
    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(Color(.secondarySystemBackground))
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

/// Keeps-first ordering for the collapsed peek: the picked ids (in source order) then the rest.
/// Pure + `internal` so the "foreground the keeps" blocker fix is unit-tested and can't silently
/// regress back to raw chronology (the product-blocker the ruthless review flagged).
func keptFirstOrdering(ids: [String], picked: Set<String>) -> [String] {
    ids.filter(picked.contains) + ids.filter { !picked.contains($0) }
}

/// The collapsed state of a done cluster in the review grid (idea ③). A done run's summary is about
/// what the user KEPT, not raw chronology — so the peek foregrounds the *picked* photos and a "N of M
/// kept" count (the number the whole app tracks). With zero picks it falls back to the first few,
/// dimmed, so "done with nothing kept" stays legible rather than silent. Tapping re-opens the cluster
/// without un-marking done. Reads `SelectionStore` itself, so the grid body stays selection-independent.
struct CollapsedSectionPeek: View {
    let ids: [String]
    /// The day-group title, threaded in for the VoiceOver label (a peek is otherwise contextless).
    let dayTitle: String
    let onShowAll: () -> Void
    @Environment(SelectionStore.self) private var selection

    private let thumbSize: CGFloat = 56
    private let thumbRadius: CGFloat = 8
    // Capped so the row (≤3 thumbs + the "+N" tile + "Show all") fits the narrowest supported width
    // without overflowing; the total kept count lives in the pinned header.
    private let maxThumbs = 3

    var body: some View {
        // O(group size), bounded; runs in this subview, not the grid body.
        let pickedSet = selection.selected.intersection(ids)
        let kept = pickedSet.count
        // Keeps first (foregrounded, full opacity), then the rest dimmed — the peek is ABOUT what you
        // kept, but still has visual body and shows the run wasn't empty.
        let ordered = keptFirstOrdering(ids: ids, picked: pickedSet)
        let shown = Array(ordered.prefix(maxThumbs))
        let overflow = ids.count - shown.count

        // The kept-count lives in the pinned header ("N of M kept"); the peek is the visual preview —
        // keeps bright, the rest dimmed — so it doesn't repeat the count text.
        Button(action: onShowAll) {
            HStack(spacing: 6) {
                ForEach(shown, id: \.self) { id in
                    OverviewThumb(id: id, size: thumbSize, cornerRadius: thumbRadius)
                        .opacity(pickedSet.contains(id) ? 1 : 0.45)   // dim the not-kept
                }
                if overflow > 0 {
                    RoundedRectangle(cornerRadius: thumbRadius)
                        .fill(Color(.tertiarySystemBackground))
                        .overlay {
                            Text("+\(overflow)")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        .frame(width: thumbSize, height: thumbSize)
                }
                Spacer(minLength: 8)
                HStack(spacing: 2) {
                    Text("Show all")
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            }
            // Leading flush to 0 so the peek thumbs line up with the gapless grid cells (a done day's
            // photos don't jump left when you "Show all" it); trailing keeps "Show all" off the edge.
            .padding(.trailing, 12)
            .padding(.bottom, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(dayTitle). \(kept) of \(ids.count) photos kept. Show all.")
    }
}
