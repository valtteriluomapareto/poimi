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

    private var bars: some View {
        let maxCount = max(summaries.map(\.count).max() ?? 1, 1)
        return HStack(alignment: .bottom, spacing: 6) {
            ForEach(summaries) { month in
                VStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.accentColor.opacity(barOpacity(month.count, of: maxCount)))
                        .frame(height: max(3, maxBarHeight * CGFloat(month.count) / CGFloat(maxCount)))
                    Text(Self.monthInitial(month.month))
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

    static func monthInitial(_ month: Int) -> String {
        let symbols = Calendar.current.veryShortMonthSymbols
        guard month >= 1, month <= symbols.count else { return "" }
        return symbols[month - 1]
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
    @Environment(\.thumbnailProvider) private var thumbnails
    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?

    var body: some View {
        RoundedRectangle(cornerRadius: 5)
            .fill(Color(.secondarySystemBackground))
            .overlay {
                if let image { Image(uiImage: image).resizable().scaledToFill() }
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .task(id: id) {
                let px = size * displayScale
                image = await thumbnails.thumbnail(for: id, targetSize: CGSize(width: px, height: px))
            }
    }
}
