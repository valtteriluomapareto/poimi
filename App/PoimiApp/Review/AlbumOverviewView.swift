//
//  AlbumOverviewView.swift
//  PoimiApp — the album's zoom-out overview: a scannable index of ALL day-clusters (issue #37;
//  design 3BL, the 5-persona-panel recommendation).
//
//  Opening an album lands here. It scans the candidate set, groups it into the same adaptive
//  day-clusters the review grid uses, and presents: a big title, the running "N / target" tally,
//  a per-cluster bar chart (one bar per cluster, height ∝ photos, colour = review state), and a
//  dense vertical list of every cluster under sticky month headers. Tapping a cluster drills into
//  the review grid scrolled to that cluster's first day.
//
//  This reframes the earlier month-card overview (design 19P) at CLUSTER granularity — density and
//  coverage in one view, matching how the grid already thinks in day-clusters. Each cluster's state
//  (done / in-progress / untouched) is `Curation.ClusterState`, a pure derivation from picks + done.
//
//  The cluster index (grouping + formatting) is built ONCE in `.task` into `@State`, never in a `body`
//  (the no-grouping-in-views guard + no-heavy-work-in-body); picked counts + done are read where drawn.
//

import SwiftUI
import UIKit
import Curation

struct AlbumOverviewView: View {
    let project: CurationProject
    @Environment(\.photoLibrary) private var library
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(SelectionStore.self) private var selection
    @Environment(DoneStore.self) private var doneStore
    @State private var store: CandidateStore?
    /// The finished cluster index — built once when the scan settles, so `body` never groups/formats.
    @State private var index: ClusterIndex?
    /// Gate the scanning indicator behind a short grace delay so an instant scan never flashes it.
    @State private var indicatorVisible = false

    var body: some View {
        content
            // No visible nav title — the big title lives in the scroll header (like the design); the
            // nav bar keeps just the back button.
            .navigationBarTitleDisplayMode(.inline)
            // Done-state here is display-only — the Overview doesn't reconcile (the grid does, on entry),
            // so a photo added to a done day can lag its seal here until you drill in. Rare, acceptable.
            .task(id: project.id) {
                selection.activate(project)     // hydrate persisted picks so the counts are live
                doneStore.activate(project)     // hydrate marked-done days so the state colours are live
                let resolved = store ?? CandidateStore(library: library)
                store = resolved
                if resolved.phase == .idle { await resolved.load(project) }
                if case .ready(let groups) = resolved.phase {
                    index = ClusterIndexBuilder.build(from: groups)
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch store?.phase ?? .idle {
        case .idle, .scanning:
            scanningIndicator
        case .ready:
            if let index {
                clusterIndex(index)
            } else {
                scanningIndicator   // groups settled but the index build hasn't run yet (one tick)
            }
        case .empty:
            ContentUnavailableView {
                Label("No photos in range", systemImage: "photo.on.rectangle")
            } description: {
                Text("Nothing matched this album's date range and filters.")
            }
        case .failed:
            ContentUnavailableView {
                Label("Couldn't load your photos", systemImage: "exclamationmark.triangle")
            } description: {
                Text("Something went wrong while scanning your library. Try again.")
            } actions: {
                Button("Try again") { Task { await store?.load(project) } }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var scanningIndicator: some View {
        ZStack {
            if indicatorVisible {
                VStack(spacing: 16) {
                    ProgressView().controlSize(.large)
                    Text("Looking over your year…").font(.headline).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            indicatorVisible = false
            try? await Task.sleep(for: .milliseconds(300))   // UI grace — replaced before it shows on a fast scan
            indicatorVisible = true
        }
    }

    // MARK: Cluster index

    private func clusterIndex(_ index: ClusterIndex) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                header(index)
                ForEach(index.sections) { section in
                    Section {
                        ForEach(section.rows) { row in
                            ClusterListRow(row: row) {
                                coordinator.openReview(project.id, day: row.firstDay)
                            }
                            .padding(.horizontal, 20)
                        }
                    } header: {
                        ClusterMonthHeader(title: section.title)
                    }
                }
            }
            .padding(.bottom, 24)
        }
    }

    private func header(_ index: ClusterIndex) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(project.title)
                    .font(.largeTitle.bold())
                Text("\(index.totalClusters) day\(index.totalClusters == 1 ? "" : "s") · \(periodLabel)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ReviewTally()   // "147 / 200" + bar + "N left" — reads the SelectionStore
            // The chart earns its place only with more than one cluster to distribute.
            if index.totalClusters > 1 {
                ClusterBarChart(sections: index.sections, maxCount: index.maxCount)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    /// "Jan 2025 – Dec 2025" (or a single month for a one-month album). `rangeEnd` is exclusive, so
    /// step back a calendar day to land on the last included day's month (mirrors `ScanningView`).
    private var periodLabel: String {
        let style = Date.FormatStyle.dateTime.month(.abbreviated).year()
        let start = project.rangeStart.formatted(style)
        let lastDay = Calendar.current.date(byAdding: .day, value: -1, to: project.rangeEnd) ?? project.rangeEnd
        let end = lastDay.formatted(style)
        return start == end ? start : "\(start) – \(end)"
    }
}

// MARK: - The cluster index model (built once, off the body)

/// One day-cluster as the Overview renders it. Carries the `DayGroup` itself so the row/bar can read
/// its live done-state (DoneStore) + picked count (SelectionStore); everything else is formatted once.
struct ClusterRow: Identifiable {
    let id: String
    let group: DayGroup
    /// "Sat, Jul 5" or "Jul 16 – Jul 18" — formatted once via `DayGroupHeader`.
    let title: String
    let count: Int
    /// The representative thumbnail — the cluster's first asset.
    let thumbID: String?
    /// The drill target — the cluster's first day. For the undated bucket this is `.undated`, which
    /// the grid resolves to the undated cluster (so the drill lands on it, not the top).
    let firstDay: DayKey?
}

/// A month's clusters under one sticky header, plus the single-letter axis initial for the chart.
struct MonthSection: Identifiable {
    let id: String        // "yyyy-MM" (or "9999-99" for undated) — stable across a year boundary
    let title: String     // "February" / "Undated"
    let initial: String   // "F" — the bar chart's month tick ("" for undated)
    var rows: [ClusterRow]
}

/// The finished overview data: month-sectioned clusters + the totals the header/chart need.
struct ClusterIndex {
    let sections: [MonthSection]
    let totalClusters: Int
    let maxCount: Int     // the busiest cluster's photo count — the chart's height baseline
}

/// Builds the month-sectioned cluster index from the store's already-grouped `[DayGroup]`. Pure, and
/// called once from `.task` (never a `body`) — it walks the chronological groups, buckets them by
/// calendar month, and formats each label a single time.
enum ClusterIndexBuilder {
    static func build(from groups: [DayGroup],
                      calendar: Calendar = .current,
                      locale: Locale = .current) -> ClusterIndex {
        var monthStyle = Date.FormatStyle.dateTime.month(.wide).locale(locale)
        monthStyle.timeZone = calendar.timeZone
        // `veryShortMonthSymbols` reads the calendar's OWN locale — bind the passed one so the axis
        // initials ("J F M …") match the caller's locale (and the tests are deterministic).
        var localizedCalendar = calendar
        localizedCalendar.locale = locale
        let initials = localizedCalendar.veryShortMonthSymbols

        var sections: [MonthSection] = []
        var maxCount = 1
        for group in groups {
            maxCount = max(maxCount, group.count)
            let row = ClusterRow(id: group.id,
                                 group: group,
                                 title: DayGroupHeader.title(for: group, calendar: calendar, locale: locale),
                                 count: group.count,
                                 thumbID: group.assetIDs.first,
                                 firstDay: group.days.first)

            let key: String, title: String, initial: String
            if !group.isUndated, let day = group.days.first, let date = day.anchorDate(in: calendar) {
                let month = calendar.component(.month, from: date)
                key = String(format: "%04d-%02d", calendar.component(.year, from: date), month)
                title = date.formatted(monthStyle)
                initial = initials.indices.contains(month - 1) ? initials[month - 1] : ""
            } else {
                // The undated bucket (no capture date) sorts last as its own section.
                key = "9999-99"; title = String(localized: "Undated"); initial = ""
            }

            if let last = sections.last, last.id == key {
                sections[sections.count - 1].rows.append(row)
            } else {
                sections.append(MonthSection(id: key, title: title, initial: initial, rows: [row]))
            }
        }
        return ClusterIndex(sections: sections, totalClusters: groups.count, maxCount: maxCount)
    }
}

// MARK: - The per-cluster bar chart

/// One fixed-width bar per cluster, height ∝ photos, colour = review state (green done / gold
/// in-progress / grey untouched), grouped into month columns with a month initial beneath each.
/// A whole year is often 100+ clusters, so the strip scrolls HORIZONTALLY (oldest → newest) rather
/// than compressing to an unreadable comb; a sparse album is just a short left-aligned strip. Reads
/// the stores itself (state is live) so the overview body stays selection-independent. Orientation
/// only — `accessibilityHidden`; the rows below carry the per-cluster detail.
struct ClusterBarChart: View {
    let sections: [MonthSection]
    let maxCount: Int
    @Environment(SelectionStore.self) private var selection
    @Environment(DoneStore.self) private var doneStore

    private let barWidth: CGFloat = 6
    private let barSpacing: CGFloat = 2
    private let monthGap: CGFloat = 8
    private let maxBarHeight: CGFloat = 72
    /// The header insets its content 20pt; the chart cancels that (below) to scroll edge-to-edge, then
    /// re-applies it here so the first bar still aligns under the title and the last scrolls off-screen.
    private let edgeInset: CGFloat = 20

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .bottom, spacing: monthGap) {
                ForEach(sections) { section in
                    VStack(spacing: 6) {
                        HStack(alignment: .bottom, spacing: barSpacing) {
                            ForEach(section.rows) { row in
                                RoundedRectangle(cornerRadius: 2, style: .continuous)
                                    .fill(color(for: row))
                                    .frame(width: barWidth, height: barHeight(row.count))
                            }
                        }
                        .frame(height: maxBarHeight, alignment: .bottom)
                        Text(section.initial)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, edgeInset)
        }
        .frame(height: maxBarHeight + 18)
        .padding(.horizontal, -edgeInset)   // full-bleed within the header's 20pt inset
        .accessibilityHidden(true)
    }

    private func barHeight(_ count: Int) -> CGFloat {
        max(3, maxBarHeight * CGFloat(count) / CGFloat(max(maxCount, 1)))
    }

    private func color(for row: ClusterRow) -> Color {
        switch ClusterState.of(isDone: doneStore.isDone(row.group), pickedCount: pickedCount(row)) {
        case .done: return .brandGreen
        case .inProgress: return .accentColor
        case .untouched: return Color(.systemGray3)
        }
    }

    // O(cluster size) per bar; a selection/done write re-renders every bar. Fine because the overview
    // isn't the rapid-toggle surface (picking happens in the grid) — precompute a map if that changes.
    private func pickedCount(_ row: ClusterRow) -> Int {
        row.group.assetIDs.reduce(into: 0) { if selection.selected.contains($1) { $0 += 1 } }
    }
}

// MARK: - The cluster list row + sticky month header

/// A sticky month header ("February") over its clusters. Opaque so scrolling rows don't bleed through.
struct ClusterMonthHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.title3.bold())
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 8)
            .background(Color(.systemBackground))
    }
}

/// One cluster row: thumbnail · day title · "N picked · total" (or "Not reviewed · total") · a green
/// done-seal when finished · a chevron. Reads the stores itself so the overview body stays independent
/// of selection. Tapping drills into the review grid at this cluster.
struct ClusterListRow: View {
    let row: ClusterRow
    let onOpen: () -> Void
    @Environment(SelectionStore.self) private var selection
    @Environment(DoneStore.self) private var doneStore

    var body: some View {
        let done = doneStore.isDone(row.group)
        let picked = pickedCount()
        let state = ClusterState.of(isDone: done, pickedCount: picked)

        Button(action: onOpen) {
            HStack(spacing: 14) {
                OverviewThumb(id: row.thumbID ?? "", size: 60, cornerRadius: 14)
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.title)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    subtitle(state: state, picked: picked)
                }
                Spacer(minLength: 8)
                // The done-seal is a graphical mark (gold's contrast caveat, styleguide §1) — green,
                // shown only when the whole cluster is done.
                if done {
                    Image(systemName: "checkmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.brandGreen)
                        .font(.title3)
                        .accessibilityHidden(true)
                }
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(a11yLabel(state: state, picked: picked))
        .accessibilityHint("Opens this day in review")
        .accessibilityAddTraits(.isButton)
    }

    // `.primary` (semibold carries the emphasis), not gold — small gold text fails the styleguide §1
    // contrast caveat; gold stays for the graphical marks (the bars + the seal).
    @ViewBuilder
    private func subtitle(state: ClusterState, picked: Int) -> some View {
        switch state {
        case .untouched:
            Text("Not reviewed · \(row.count)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        case .inProgress, .done:
            (Text("\(picked) picked").fontWeight(.semibold).foregroundStyle(.primary)
                + Text(" · \(row.count)").foregroundStyle(.secondary))
                .font(.subheadline)
                .monospacedDigit()
        }
    }

    private func pickedCount() -> Int {
        row.group.assetIDs.reduce(into: 0) { if selection.selected.contains($1) { $0 += 1 } }
    }

    private func a11yLabel(state: ClusterState, picked: Int) -> String {
        switch state {
        case .done: return "\(row.title). Done. \(picked) of \(row.count) picked."
        case .inProgress: return "\(row.title). \(picked) of \(row.count) picked."
        case .untouched: return "\(row.title). Not reviewed. \(row.count) photos."
        }
    }
}
