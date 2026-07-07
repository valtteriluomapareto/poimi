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
        // `tertiarySystemFill` so an unloaded thumb still reads as a slot on the (systemBackground) row,
        // not an invisible hole.
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

/// A horizontal, scrollable preview of a cluster's photos for the Overview (#35 paged-clusters): a
/// handful of thumbnails **sampled evenly across the whole cluster** (via `ReviewCluster.evenlySampledIDs`
/// — a trip samples across its merged days), so a glance conveys the cluster's shape without opening it.
/// Thumbs are sized so **`visibleThumbs` (6.5)** fill the strip's width — the half-thumb runs off the
/// right screen edge, an unmistakable "keep scrolling" cue. `LazyHStack` so only on-screen thumbs load;
/// the rest of the sample load on horizontal scroll, not up front.
struct ClusterStrip: View {
    let cluster: ReviewCluster
    var spacing: CGFloat = 6
    /// How many thumbs fill the strip width — the fractional `.5` makes the next one run off the edge.
    var visibleThumbs: CGFloat = 6.5
    /// Sample up to this many across the cluster; ~6.5 show, the rest reveal on scroll. Bounded so a
    /// 500-photo busy day previews with a handful of thumbs, not five hundred.
    var sampleCount: Int = 14
    /// Thumb edge — derived from the measured strip width so `visibleThumbs` fit. A sensible default
    /// until the first geometry read, so the row never lays out at zero height.
    @State private var thumbSize: CGFloat = 52

    var body: some View {
        let ids = cluster.evenlySampledIDs(sampleCount)
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: spacing) {
                ForEach(ids, id: \.self) { id in
                    OverviewThumb(id: id, size: thumbSize, cornerRadius: 10)
                }
            }
        }
        .frame(height: thumbSize)
        // Size thumbs to the strip's own width so `visibleThumbs` fit. Gaps counted = the whole thumbs
        // shown (⌊visibleThumbs⌋), so the fractional thumb spills past the right edge.
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            let gaps = spacing * CGFloat(Int(visibleThumbs))
            let size = (width - gaps) / visibleThumbs
            if size > 0 { thumbSize = size }
        }
        .accessibilityHidden(true)   // the cluster row owns the a11y label; these thumbs are a preview
    }
}

/// The coverage chart's adaptive time buckets. Picks a calendar unit by the album's span so the bars
/// stay readable — a year → months, a couple months → weeks, a short album → days — then slices the
/// span into CONTIGUOUS buckets (empty ones included, so a quiet stretch reads as a real gap). When the
/// calendar unit would yield fewer than `minBuckets` bars (a short/awkward span, e.g. a 5-week album →
/// 5 weekly bars), it floors to `minBuckets` roughly-equal day-slices instead, so the chart never looks
/// sparse. Axis labels (see `axisTicks`) are month initials for a multi-month span ("… Feb … Mar …")
/// or a sparse numeric date every few bars for a short one ("7.6. … 15.6. …"). App-layer + pure (Foundation
/// only); app-tier tested. (Model `ChartBucket` lives with the other overview models.)
enum ChartBucketing {
    /// The chart never shows fewer than this many bars when the span can hold them (owner: "at least 8").
    static let minBuckets = 8

    /// The calendar unit a bar spans, chosen by the album's day-span. Thresholds are tunable; quarters
    /// aren't used (a multi-year album stays on months — rare for a "curate a year" app).
    static func unit(spanDays: Int) -> Calendar.Component {
        switch spanDays {
        case ..<19: return .day           // ≤ ~18 days → daily bars
        case ..<126: return .weekOfYear   // ~3–18 weeks
        default: return .month            // ~4+ months
        }
    }

    static func buckets(for rows: [ClusterRow], calendar: Calendar, locale: Locale) -> [ChartBucket] {
        // Dated clusters only (the undated bucket has no place on a timeline), oldest → newest.
        let dated = rows.compactMap { row -> (row: ClusterRow, date: Date)? in
            guard let day = row.firstDay, let date = day.anchorDate(in: calendar) else { return nil }
            return (row, date)
        }
        guard let firstDate = dated.first?.date, let lastDate = dated.last?.date else { return [] }
        let spanDays = calendar.dateComponents([.day], from: firstDate, to: lastDate).day ?? 0
        let starts = bucketStarts(firstDate: firstDate, lastDate: lastDate, spanDays: spanDays, calendar: calendar)

        // Sum each bucket's photos (the chart shades by density). Assign each cluster to the last bucket
        // whose start ≤ its date; both `starts` and `dated` are ascending (the caller provides
        // chronological clusters), so a single forward sweep suffices.
        var countByBucket = [Int](repeating: 0, count: starts.count)
        var bucket = 0
        for entry in dated {
            while bucket + 1 < starts.count, starts[bucket + 1] <= entry.date { bucket += 1 }
            countByBucket[bucket] += entry.row.count
        }

        let ticks = axisTicks(starts: starts, firstDate: firstDate, calendar: calendar, locale: locale)
        return starts.indices.map { ChartBucket(id: $0, count: countByBucket[$0], tick: ticks[$0]) }
    }

    /// The per-bucket axis labels. A span covering ≥ 2 months gets a month-initial where each new month
    /// opens ("… F … M …"). A short span (a single month's worth of bucket-starts — where month letters
    /// would be a lone stranded "J") instead gets a compact numeric date every few bars ("7.6. … 15.6.
    /// …"), so the axis still orients without labelling every bar. `nil` = no label on that bucket.
    private static func axisTicks(starts: [Date], firstDate: Date, calendar: Calendar, locale: Locale) -> [String?] {
        // `veryShortMonthSymbols` reads the calendar's OWN locale — bind the passed one so labels match
        // the caller's locale (and the tests are deterministic). A unit-aligned start can precede the
        // album (a week starting in the prior month), so key each tick off the album's real start.
        var localizedCalendar = calendar
        localizedCalendar.locale = locale
        let initials = localizedCalendar.veryShortMonthSymbols
        var monthTicks: [String?] = []
        var previousMonthKey: Int?
        for start in starts {
            let date = max(start, firstDate)
            let month = calendar.component(.month, from: date)
            let monthKey = calendar.component(.year, from: date) * 12 + month
            monthTicks.append(monthKey != previousMonthKey && initials.indices.contains(month - 1) ? initials[month - 1] : nil)
            previousMonthKey = monthKey
        }
        if monthTicks.compactMap({ $0 }).count > 1 { return monthTicks }

        // Short span → a compact numeric date (locale order/separator, e.g. "7.6." / "6/7") on every
        // `stride`-th bar (≈ 4 labels total), not every bar.
        var dateStyle = Date.FormatStyle.dateTime.day().month(.defaultDigits).locale(locale)
        dateStyle.timeZone = calendar.timeZone
        let stride = max(2, Int((Double(starts.count) / 4).rounded(.up)))
        return starts.indices.map { $0 % stride == 0 ? max(starts[$0], firstDate).formatted(dateStyle) : nil }
    }

    /// The contiguous bucket start-dates covering `firstDate … lastDate`: calendar-unit-aligned by span,
    /// or — when that yields fewer than `minBuckets` and the span can hold that many day-boundaries —
    /// `minBuckets` roughly-equal day-slices instead.
    private static func bucketStarts(firstDate: Date, lastDate: Date, spanDays: Int, calendar: Calendar) -> [Date] {
        let unit = unit(spanDays: spanDays)
        let aligned = calendar.dateInterval(of: unit, for: firstDate)?.start ?? calendar.startOfDay(for: firstDate)
        var starts: [Date] = []
        var cursor = aligned
        while cursor <= lastDate {
            starts.append(cursor)
            guard let next = calendar.date(byAdding: unit, value: 1, to: cursor), next > cursor else { break }
            cursor = next
        }
        // Floor: a short/awkward span splits into `minBuckets` roughly-equal day-slices so the chart
        // fills out. Only when the span holds that many day-boundaries (else keep the finer unit as-is).
        // A floored (single-month) span then also drives `axisTicks` to numeric-date labels, not letters.
        guard starts.count < minBuckets, spanDays >= minBuckets - 1 else { return starts }
        let dayStart = calendar.startOfDay(for: firstDate)
        let totalDays = spanDays + 1
        return (0..<minBuckets).compactMap { slice in
            calendar.date(byAdding: .day, value: (slice * totalDays) / minBuckets, to: dayStart)
        }
    }
}

/// The overview's coverage chart — "where your photos pile up": one bar per adaptive time bucket
/// (day / week / month by span — see `ChartBucketing`), height ∝ that slice's photos and shaded in gold
/// that brightens with density (the busiest slices are tall + bright). A quiet slice reads as a gap;
/// month-initial ticks mark the axis (dropped when there's only one). Fits the width at any album length
/// — bars flex to a constant gap, never scroll. Pure density (no per-photo state): it doesn't read the
/// stores, so it never re-renders on a pick; review state lives in the list below. Orientation only.
struct CoverageChart: View {
    let buckets: [ChartBucket]

    private let maxBarHeight: CGFloat = 88
    /// Constant gap between bars; the bars themselves widen/narrow to fill the width (the minimum-bucket
    /// floor keeps the count high enough that "fill the width" never makes a lone giant slab).
    private let barGap: CGFloat = 4

    var body: some View {
        let maxCount = max(buckets.map(\.count).max() ?? 1, 1)
        return HStack(alignment: .bottom, spacing: barGap) {
            ForEach(buckets) { bucket in
                VStack(spacing: 4) {
                    bar(count: bucket.count, of: maxCount)
                        .frame(maxWidth: .infinity)   // fill the column → constant gap, bars just get wider
                    Text(bucket.tick ?? "")
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

    /// A gold bar: height ∝ density, and denser slices read more saturated so the peak stands out. An
    /// empty slice draws nothing (a gap). A one-photo slice still floors to a visible sliver.
    @ViewBuilder
    private func bar(count: Int, of maxCount: Int) -> some View {
        if count > 0 {   // an empty slice draws nothing → a gap (the column still reserves its width)
            let ratio = Double(count) / Double(maxCount)
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Color.accentColor.opacity(0.5 + 0.5 * ratio))
                .frame(height: max(3, maxBarHeight * CGFloat(ratio)))
        }
    }
}

/// Keeps-first ordering for the collapsed peek: the picked ids (in source order) then the rest.
/// Pure + `internal` so the "foreground the keeps" ordering is unit-tested and can't silently regress
/// to raw chronology. Currently unused by the paged grid (which shows every cell, no collapsed peek);
/// retained as a tested helper for a future done-cluster "kept first" treatment. (The accordion's
/// `CollapsedSectionPeek`, its only former caller, was removed with the paged-clusters redesign.)
func keptFirstOrdering(ids: [String], picked: Set<String>) -> [String] {
    ids.filter(picked.contains) + ids.filter { !picked.contains($0) }
}
