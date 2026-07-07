//
//  AlbumOverviewView.swift
//  PoimiApp — the album's zoom-out overview: a scannable index of ALL day-clusters (issue #37;
//  design 3BL, the 5-persona-panel recommendation).
//
//  Opening an album lands here. It scans the candidate set, groups it into the same adaptive
//  day-clusters the review grid uses, and presents: a big title, the running "N / target" tally, a
//  coverage chart (one bar per adaptive time slice — month/week/day by span — shaded gold by density),
//  and a dense list of every cluster under sticky month headers. Tapping a cluster drills into the grid.
//
//  This reframes the earlier month-card overview (design 19P) into a cluster index: the LIST is at
//  day-cluster granularity (how the grid thinks); the chart is a fits-on-screen density skyline over
//  adaptive time slices. Review state (done / in-progress / untouched, `Curation.ClusterState`) lives
//  in the list (seals + picked counts), NOT the chart, which is pure density.
//
//  The cluster index (grouping + formatting) is built ONCE in `.task` into `@State`, never in a `body`
//  (the no-grouping-in-views guard + no-heavy-work-in-body); picked counts + done are read where drawn.
//

import SwiftUI
import UIKit
import Curation

/// The `.task` identity for the Overview scan: re-scan when the album changes OR its period does (a
/// Settings edit mutates the range on this same project), so the cluster index never lags the range.
private struct OverviewScanKey: Hashable {
    let id: UUID
    let start: Date
    let end: Date
    let locationEnabled: Bool
}

struct AlbumOverviewView: View {
    let project: CurationProject
    @Environment(\.photoLibrary) private var library
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(SelectionStore.self) private var selection
    @Environment(DoneStore.self) private var doneStore
    @Environment(\.placeNaming) private var placeNaming
    @Environment(\.modelContext) private var modelContext
    /// The album's scanned store — obtained from the coordinator (shared with the grid), held here so
    /// `body` reads its phase. Store freshness (album / range / location) is the coordinator's key, so
    /// this view no longer tracks the scanned range/setting itself.
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
            // A SOLID (not glass) nav bar background so scrolling clusters are fully hidden behind the
            // top controls (back / adjustments / Export) — the earlier `.visible` gave a translucent
            // glass bar, so content still showed through, dimmed, above the pinned month header. An
            // opaque `systemBackground` bar matches the list ground (black in dark, white in light).
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(Color(.systemBackground), for: .navigationBar)
            // Settings + Export at the album level. The Overview is the album's landing screen and shows
            // the running tally, so it's the natural "I'm done → make the album" spot; the gear reaches
            // per-album settings (#41). No "Clear" here — clearing all picks now lives in Settings as
            // "Reset picks"; Clear stays in the review grid for per-session use.
            // TWO separate trailing items, not one HStack in a single item: iOS 26 then lays them out in
            // its own Liquid Glass group with standard insets, instead of the glass hugging a hand-rolled
            // HStack tightly against the capsule edges (the icon + "Export" looked cramped otherwise).
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    // A sliders "adjustments" icon (NOT a cog) — the cog is app-level settings on the album
                    // library; per-album settings gets its own glyph so the two never look alike.
                    Button { coordinator.openSettings(project.id) } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                    .accessibilityLabel("Album settings")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Export") { coordinator.openExport(project.id) }
                        .disabled(selection.progress.picked == 0)
                }
            }
            // Done-state here is display-only — the Overview doesn't reconcile (the grid does, on entry),
            // so a photo added to a done day can lag its seal here until you drill in. Rare, acceptable.
            // Keyed on the range too (not just the id): a period edit in Settings mutates this same
            // project, so the key changes and the task re-runs, re-scanning even while Settings is still
            // on top — so the cluster index is fresh by the time you pop back.
            .task(id: OverviewScanKey(id: project.id, start: project.rangeStart, end: project.rangeEnd,
                                      locationEnabled: project.locationEnabled)) {
                selection.activate(project)     // hydrate persisted picks so the counts are live
                doneStore.activate(project)     // hydrate marked-done days so the state colours are live
                // Get the album's shared store (created here on the album-landing scan; the grid reuses
                // it on drill-in). A Settings edit changes the coordinator's key → a fresh store to scan.
                let store = coordinator.candidateStore(for: project) {
                    CandidateStore(library: library, locationEnabled: project.locationEnabled,
                                   naming: placeNaming,
                                   nameCache: NameCacheStore(modelContainer: modelContext.container),
                                   timelineCache: coordinator.timelineCache)
                }
                self.store = store
                if store.phase == .idle {
                    await scan()
                } else if case .ready(let clusters) = store.phase {
                    index = ClusterIndexBuilder.build(from: clusters, tripNames: store.tripNames)
                }
            }
            // Trip place names resolve asynchronously after `.ready` (§7); rebuild the (cheap) index so
            // the trip titles swap from their date fallback to "Week in …" as the names land.
            .onChange(of: store?.tripNames ?? [:]) { _, names in
                guard let store, case .ready(let clusters) = store.phase else { return }
                index = ClusterIndexBuilder.build(from: clusters, tripNames: names)
            }
    }

    /// Run (or re-run, e.g. a "Try again") the fetch pass and rebuild the cluster index from the result.
    /// Reuses the current `store` so a retry re-scans the same album.
    private func scan() async {
        guard let store else { return }
        index = nil
        await store.load(project)
        if case .ready(let clusters) = store.phase {
            index = ClusterIndexBuilder.build(from: clusters, tripNames: store.tripNames)
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
        case .empty(let reason):
            ReviewEmptyView(
                reason: reason, rangeStart: project.rangeStart, rangeEnd: project.rangeEnd,
                onChangeRange: { coordinator.openSettings(project.id) },
                onReviewExclusions: { coordinator.openSettings(project.id) })
        case .failed(.loadError):
            ReviewLoadFailedView(onRetry: { Task { await scan() } })
        case .failed(.accessLost):
            ReviewAccessLostView(onRecovered: { Task { await scan() } })
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
                            // No horizontal padding here — ClusterListRow insets its own text but lets the
                            // preview strip bleed to the right screen edge.
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
                Text("\(index.totalDays) day\(index.totalDays == 1 ? "" : "s") · \(periodLabel)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ReviewTally()   // "147 / 200" + bar + "N left" — reads the SelectionStore
            // The chart earns its place only with more than one cluster to distribute.
            if index.totalClusters > 1 {
                CoverageChart(buckets: index.chartBuckets)
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

/// One cluster as the Overview renders it. Carries the `ReviewCluster` itself so the row/bar can read
/// its live done-state (DoneStore) + picked count (SelectionStore); everything else is formatted once.
struct ClusterRow: Identifiable {
    let id: String
    let cluster: ReviewCluster
    /// The primary title: a trip's location sentence ("Week in Salo") once its name resolves, else the
    /// date title. A plain date cluster is always "Sat, Jul 5" / "Jul 16 – Jul 18" — formatted once.
    let title: String
    /// A trip's date-range subline ("Jul 16 – Jul 18"); `nil` for a plain date cluster.
    let dateSubtitle: String?
    let count: Int
    /// The representative thumbnail — the cluster's first asset.
    let thumbID: String?
    /// The drill target — the cluster's first day. For the undated bucket this is `.undated`, which
    /// the grid resolves to the undated cluster (so the drill lands on it, not the top).
    let firstDay: DayKey?
    /// Whether this row is a trip/visit (drives the pin + the date subline).
    var isTrip: Bool { cluster.tripCluster != nil }
}

/// A month's clusters under one sticky list header.
struct MonthSection: Identifiable {
    let id: String        // "yyyy-MM" (or "9999-99" for undated) — stable across a year boundary
    let title: String     // "February" / "Undated"
    var rows: [ClusterRow]
}

/// One bar in the coverage chart — a contiguous time slice (day / week / month, chosen by span), its
/// photo `count` (drives the bar's height + gold intensity; 0 = a quiet-slice gap), and a month-initial
/// tick when it opens a new month. Built by `ChartBucketing`.
struct ChartBucket: Identifiable {
    let id: Int
    let count: Int
    let tick: String?     // "F" when this bucket starts a new month, else nil
}

/// The finished overview data: month-sectioned clusters (the list), adaptive time buckets (the chart),
/// and the header totals. `totalDays` is the number of distinct dated days that hold photos (a folded
/// quiet run counts each of its days), so the "N days" header is honest; `totalClusters` gates the chart.
struct ClusterIndex {
    let sections: [MonthSection]
    let chartBuckets: [ChartBucket]
    let totalClusters: Int
    let totalDays: Int
}

/// Builds the overview view-model from the store's already-grouped `[DayGroup]`. Pure, and called once
/// from `.task` (never a `body`): it walks the chronological groups into per-month list sections + the
/// chart's adaptive time buckets, formatting each label a single time.
enum ClusterIndexBuilder {
    static func build(from clusters: [ReviewCluster],
                      tripNames: [String: String] = [:],
                      calendar: Calendar = .current,
                      locale: Locale = .current) -> ClusterIndex {
        var monthStyle = Date.FormatStyle.dateTime.month(.wide).locale(locale)
        monthStyle.timeZone = calendar.timeZone

        var sections: [MonthSection] = []
        var rows: [ClusterRow] = []
        for cluster in clusters {
            let dateTitle = DayGroupHeader.title(for: cluster, calendar: calendar, locale: locale)
            // A trip shows its location sentence once the name resolves, falling back to the date range
            // until then; a plain date cluster is always the date title.
            let title: String
            let dateSubtitle: String?
            if let trip = cluster.tripCluster {
                title = tripNames[trip.clusterID].map { TripLabel.sentence(for: trip.shape, place: $0) } ?? dateTitle
                dateSubtitle = dateTitle
            } else {
                title = dateTitle
                dateSubtitle = nil
            }
            let row = ClusterRow(id: cluster.id,
                                 cluster: cluster,
                                 title: title,
                                 dateSubtitle: dateSubtitle,
                                 count: cluster.count,
                                 thumbID: cluster.assetIDs.first,
                                 firstDay: cluster.firstDay)
            rows.append(row)

            let key: String, monthTitle: String
            if !cluster.isUndated, let day = cluster.firstDay, let date = day.anchorDate(in: calendar) {
                key = String(format: "%04d-%02d",
                             calendar.component(.year, from: date), calendar.component(.month, from: date))
                monthTitle = date.formatted(monthStyle)
            } else {
                // The undated bucket (no capture date) sorts last as its own section.
                key = "9999-99"; monthTitle = String(localized: "Undated")
            }
            if let last = sections.last, last.id == key {
                sections[sections.count - 1].rows.append(row)
            } else {
                sections.append(MonthSection(id: key, title: monthTitle, rows: [row]))
            }
        }
        // Distinct dated days with photos (a folded quiet run / trip contributes each of its days) — the
        // honest "N days" count; the undated bucket isn't a real day.
        let totalDays = clusters.reduce(0) { $0 + ($1.isUndated ? 0 : $1.days.count) }
        return ClusterIndex(sections: sections,
                            chartBuckets: ChartBucketing.buckets(for: rows, calendar: calendar, locale: locale),
                            totalClusters: clusters.count,
                            totalDays: totalDays)
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
        let done = doneStore.isDone(row.cluster)
        let picked = pickedCount()
        let state = ClusterState.of(isDone: done, pickedCount: picked)

        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 5) {
                            // A gold pin marks a location (trip/visit) cluster; date clusters have none.
                            if row.isTrip {
                                Image(systemName: "mappin.circle.fill")
                                    .font(.subheadline)
                                    .foregroundStyle(Color.accentColor)
                                    .accessibilityHidden(true)
                            }
                            Text(row.title)
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                        }
                        // A trip's date range sits under its sentence ("Jul 16 – Jul 18"); a date
                        // cluster has none (its title already IS the date).
                        if let dateSubtitle = row.dateSubtitle {
                            Text(dateSubtitle)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
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
                .padding(.horizontal, 20)   // the text row stays inset both sides
                // The evenly-sampled preview strip — replaces the single cover thumb, so a glance shows
                // the whole cluster, not one photo (#35 paged-clusters). Leading inset only, so it runs
                // off the right screen edge (the shelf "keep scrolling" read) instead of stopping short.
                ClusterStrip(cluster: row.cluster)
                    .padding(.leading, 20)
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(a11yLabel(state: state, picked: picked))
        .accessibilityHint("Opens this day in review")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("overviewClusterRow")
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
        row.cluster.assetIDs.reduce(into: 0) { if selection.selected.contains($1) { $0 += 1 } }
    }

    private func a11yLabel(state: ClusterState, picked: Int) -> String {
        switch state {
        case .done:
            return String(localized: "\(row.title). Done. \(picked) of \(row.count) picked.",
                          comment: "Cluster row a11y: %@ day, done, N of M picked")
        case .inProgress:
            return String(localized: "\(row.title). \(picked) of \(row.count) picked.",
                          comment: "Cluster row a11y: %@ day, N of M picked")
        case .untouched:
            return String(localized: "\(row.title). Not reviewed. \(row.count) photos.",
                          comment: "Cluster row a11y: %@ day, not reviewed, M photos")
        }
    }
}
