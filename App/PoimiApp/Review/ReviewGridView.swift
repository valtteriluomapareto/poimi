//
//  ReviewGridView.swift
//  PoimiApp — the review grid (issue #35), PAGED-CLUSTERS model (#35 paged-clusters redesign).
//
//  One cluster fills the screen; you SWIPE SIDEWAYS between clusters (a horizontal page `TabView`,
//  selected by group id — not a positional index — so a re-scan can't strand the selection), replacing
//  the earlier single-scroll accordion whose collapse/open reflow was jumpy on device now that the
//  Overview is itself a full cluster index (with per-cluster thumbnail strips). Each page is that
//  cluster's own vertical `LazyVGrid`. Chrome: a fixed album header on top (`ReviewHeader`: name +
//  tally), then PINNED per-cluster over the photos — a page indicator ("3 / 12" + dots, the swipe
//  affordance + orientation) and the day + Select-all glass pills; the "Mark day done" button is the
//  end-of-scroll footer (advances to the next unreviewed cluster).
//
//  Selection lives in the shared `SelectionStore` (in-memory `Set`, D15); the cells + header observe it
//  themselves, so this parent body does NOT depend on `selected` — a toggle re-renders only the cell.
//  Thumbnails flow through the injected seam with a scroll-driven prefetch window SCOPED TO THE CURRENT
//  cluster, so only its cells load at full cell size (the perf bound the accordion also relied on).
//

import SwiftUI
import UIKit
import Curation

/// Pure grid-density math (kept out of the view so it's unit-tested). Given the available width, pick
/// the column count that best fills it at ~`target`pt cells, clamped to the size-class range. This is
/// what lets the review grid open dense on iPad and reflow on a Split View / Stage Manager resize (#42).
enum ReviewGridColumns {
    static func ideal(forWidth width: CGFloat, target: CGFloat = 132, minColumns: Int, maxColumns: Int) -> Int {
        guard width > 0 else { return minColumns }
        let raw = Int((width / target).rounded())
        return max(minColumns, min(maxColumns, raw))
    }
}

struct ReviewGridView: View {
    /// The review timeline (oldest → newest) — one page per cluster (a date day-group or a trip).
    let clusters: [ReviewCluster]
    /// Resolved trip place names (`TripCluster.clusterID → name`), filling in async — a trip page shows
    /// its "Week in …" sentence once its name lands, and the date range until then.
    var tripNames: [String: String] = [:]
    /// The album name — unused as a visible title now (the header shows the current cluster); kept so
    /// the call site (ScanningView / iPad detail) stays unchanged and it's available for a11y later.
    let title: String
    /// Metadata line (kept for the same call-site-stability reason; the paged header shows per-cluster info).
    let subtitle: String
    /// Open a cell full-screen (the parent pushes the viewer + records `lastViewedID`, #36).
    let openAsset: (String) -> Void
    /// A day-group to open on entry — the overview's "drill into this cluster" target (#37). Nil → open
    /// the first unreviewed cluster (resume).
    var scrollToDay: DayKey?

    @Environment(\.thumbnailProvider) private var thumbnails
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(DoneStore.self) private var done
    @Environment(AppCoordinator.self) private var coordinator   // observe viewer dismissal to restore the page (#126)

    /// The current cluster page, identified by its GROUP ID (a stable id, not a positional index —
    /// so a re-scan that reshapes grouping can't leave the selection pointing at a different cluster).
    /// Swiping (TabView) or "Mark day done" moves it.
    @State private var currentPageID: String?
    /// Pick the entry page once per appearance (drill target, or first-unreviewed resume).
    @State private var didInitialOpen = false

    @State private var columnCount = 3
    @State private var visibleIDs: Set<String> = []
    @State private var window = PrefetchWindow(orderedIDs: [])
    // Generation-guarded prefetch: a single in-flight updater loops until it has applied the latest
    // visible state, so out-of-order actor calls can't leave a stale window cached (D-review #35).
    @State private var windowGeneration = 0
    @State private var windowUpdating = false
    /// The last slice actually pushed to the cache, so an unchanged recompute skips the actor hop.
    @State private var lastAppliedSlice: [String] = []

    private let spacing: CGFloat = 3   // small inter-cell gap, Apple-Photos-style
    private let minColumns = 2
    private let windowRowMargin = 2
    /// Oversized vs the on-screen point size on purpose (Retina + density headroom).
    private let thumbnailTarget = CGSize(width: 400, height: 400)

    /// iPhone tops out at 5 columns (any more shrinks the cell below the 44pt badge); iPad allows denser.
    private var maxColumns: Int { sizeClass == .compact ? 5 : 8 }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: spacing), count: columnCount)
    }

    private var currentCluster: ReviewCluster? {
        clusters.first { $0.id == currentPageID } ?? clusters.first
    }

    /// 0-based position of the current page — for the indicator + `advance` math. 0 if unresolved.
    private var currentIndex: Int {
        clusters.firstIndex { $0.id == currentPageID } ?? 0
    }

    /// The cluster id to open on entry / album switch: the drill-or-resume `initialPage` mapped to its id.
    private func entryPageID() -> String? {
        let idx = initialPage(clusters: clusters, scrollToDay: scrollToDay, isDone: { done.isDone($0) })
        return clusters.indices.contains(idx) ? clusters[idx].id : clusters.first?.id
    }

    /// The pinned header title for a cluster: a trip's resolved location sentence ("Week in Salo"), or
    /// the date title (a plain date cluster always, or a trip whose name hasn't resolved yet).
    private func headerTitle(for cluster: ReviewCluster) -> String {
        if let trip = cluster.tripCluster, let name = tripNames[trip.clusterID] {
            return TripLabel.sentence(for: trip.shape, place: name)
        }
        return DayGroupHeader.title(for: cluster)
    }

    /// Columns that best fill `width` at ~132pt cells, clamped to the size-class range — opens dense on
    /// iPad, reflows on a Split View / Stage Manager resize (#42); iPhone lands on ~3.
    private func applyIdealColumns(width: CGFloat) {
        guard width > 0 else { return }
        let ideal = ReviewGridColumns.ideal(forWidth: width, minColumns: minColumns, maxColumns: maxColumns)
        if ideal != columnCount { columnCount = ideal }
    }

    /// The horizontal page pager — one `ClusterPage` per cluster, selected by group id. Extracted from
    /// `body` so the (long) modifier chain below type-checks as a smaller expression.
    private var pager: some View {
        TabView(selection: $currentPageID) {
            ForEach(Array(clusters.enumerated()), id: \.element.id) { index, cluster in
                ClusterPage(
                    cluster: cluster,
                    headerTitle: headerTitle(for: cluster),
                    isTrip: cluster.tripCluster != nil,
                    columns: columns,
                    spacing: spacing,
                    load: load,
                    cachedImage: cachedImage,
                    openAsset: openAsset,
                    // Only the ACTIVE page reports cell visibility — TabView pre-renders neighbours, and
                    // their cells reporting visible would churn the prefetch recompute on every swipe.
                    isActive: cluster.id == currentPageID,
                    onVisible: { visibleIDs.insert($0) },
                    onHidden: { visibleIDs.remove($0) },
                    position: index + 1,
                    total: clusters.count,
                    onMarkDone: { markDoneAndAdvance(cluster) })
                    .tag(cluster.id as String?)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
    }

    var body: some View {
        pager
        // The album header (name + subtitle + tally) is the ONE fixed chrome — same as the accordion.
        // The per-cluster day + Select-all glass pills, the "Mark day done" button, and the page dots
        // all live INSIDE each page (a pinned section header + an end-of-scroll footer), so they aren't
        // a permanent bottom bar — you reach mark-done/dots by scrolling to the end of the cluster.
        .safeAreaInset(edge: .top, spacing: 0) { ReviewHeader(title: title, subtitle: subtitle) }
        .background(Color(.systemBackground))
        // No implicit `.animation(value: currentPage)` — the TabView animates its own page transition;
        // a programmatic advance (mark-done) animates via `withAnimation` in `advance()`. Stacking both
        // double-animated the chrome on a swipe.
        // Success haptic when a day is marked done (count up), a light tap on undo.
        .sensoryFeedback(trigger: done.doneDays.count) { old, new in new > old ? .success : .impact(weight: .light) }
        .onGeometryChange(for: CGFloat.self) { proxy in proxy.size.width } action: { applyIdealColumns(width: $0) }
        .onAppear {
            Perf.event("grid.onAppear (paged)")
            if !didInitialOpen {
                didInitialOpen = true
                currentPageID = entryPageID()
            }
            rebuildWindow()
            scheduleRecomputeWindow()
        }
        .onChange(of: currentPageID) {
            // Drop the previous page's ids up front. Otherwise they linger in `visibleIDs` — foreign to
            // the new cluster's window universe — so the slice computes EMPTY and the cache is *cleared*
            // on every flick, and the new cluster only starts loading once a scroll repopulates
            // `visibleIDs`. Clearing here makes the slice prime the new cluster's head immediately, so
            // its first screenful pre-decodes on the flick (no "move to start loading").
            visibleIDs = []
            rebuildWindow()
            scheduleRecomputeWindow()
        }
        .onChange(of: visibleIDs) { scheduleRecomputeWindow() }
        .onChange(of: columnCount) { scheduleRecomputeWindow() }
        .onChange(of: maxColumns) { columnCount = min(columnCount, maxColumns) }
        .onChange(of: groupIdentity) {
            visibleIDs = []
            lastAppliedSlice = []      // new album → re-cache from scratch, don't skip on a stale match
            currentPageID = entryPageID()
            rebuildWindow()
            scheduleRecomputeWindow()
        }
        // Restore the page you ended on when the viewer closes (#126): page to the cluster that holds the
        // last-viewed photo. The viewer is a sheet, so the grid stays mounted underneath — we react to its
        // dismissal (presentedPhotoID → nil), not `.onAppear`. Paging in the viewer may have auto-marked a
        // cluster done (#128); landing on the current cluster keeps the grid consistent with where you were.
        .onChange(of: coordinator.presentedPhotoID) { previous, current in
            guard previous != nil, current == nil,
                  let id = coordinator.lastViewedID,
                  let cluster = clusters.first(where: { $0.assetIDs.contains(id) }) else { return }
            currentPageID = cluster.id
        }
    }

    // MARK: Mark done → advance

    private func markDoneAndAdvance(_ cluster: ReviewCluster) {
        let wasDone = done.isDone(cluster)
        done.toggle(cluster)
        if !wasDone {
            AccessibilityNotification.Announcement("Marked done").post()
            advance()
        }
    }

    /// Advance to the next UNREVIEWED cluster after the current page; else the literal next; else stay
    /// (finished the last stretch). Finishing a day lands you on the next one to review. The choice is
    /// the pure `nextUnreviewedPage` (tested); this just applies it with animation.
    private func advance() {
        let next = nextUnreviewedPage(after: currentIndex, count: clusters.count,
                                      isDone: { done.isDone(clusters[$0]) })
        guard clusters.indices.contains(next) else { return }
        withAnimation(reduceMotion ? nil : .snappy) { currentPageID = clusters[next].id }
    }

    // MARK: Cell load (the thumbnail seam)

    private func load(_ id: String) async -> UIImage? {
        let started = Perf.begin()
        let image = await thumbnails.thumbnail(for: id, targetSize: thumbnailTarget)
        Perf.endIO("grid.cell.load \(id.suffix(8))", since: started)
        return image
    }

    /// Synchronous cache lookup at the cell's request size — a hit lets a recycled cell skip the
    /// placeholder. `nonisolated` on the seam, so this never hops the actor.
    private func cachedImage(_ id: String) -> UIImage? {
        thumbnails.cachedThumbnail(for: id, targetSize: thumbnailTarget)
    }

    // MARK: Prefetch window (scoped to the current cluster)

    private var groupIdentity: String {
        "\(clusters.first?.id ?? "∅")#\(clusters.reduce(0) { $0 + $1.assetIDs.count })"
    }

    /// Only the CURRENT cluster's cells render at full cell size, so the window's universe is just its
    /// ids — visible ± a row margin. A neighbouring page's cells (rendered by TabView for the swipe) may
    /// report visible, but they're not in this universe so `slice` filters them out.
    private func rebuildWindow() {
        window = PrefetchWindow(orderedIDs: currentCluster?.assetIDs ?? [])
    }

    private func scheduleRecomputeWindow() {
        windowGeneration += 1
        guard !windowUpdating else { return }   // one updater in flight; it loops to the latest gen
        windowUpdating = true
        Task { @MainActor in
            var applied = -1
            while applied != windowGeneration {
                applied = windowGeneration
                let slice = window.slice(visibleIDs: visibleIDs, columnCount: columnCount, rowMargin: windowRowMargin)
                guard slice != lastAppliedSlice else { continue }   // unchanged → no redundant actor hop
                lastAppliedSlice = slice
                let started = Perf.begin()
                await thumbnails.updateCachingWindow(to: slice)
                Perf.endIO("grid.updateCachingWindow n=\(slice.count)", since: started)
            }
            windowUpdating = false
        }
    }
}

// MARK: - One cluster's page (a vertical grid of its photos)

/// A single cluster filling the screen: its photos in a vertical `LazyVGrid`, with the day + Select-all
/// as floating GLASS PILLS pinned at the top (over the photos, like the accordion header) and the
/// "Mark day done" button + page dots as the section FOOTER — so those reach you at the END of the
/// cluster's scroll, not as a permanent bottom bar. Owns its own vertical scroll (each page starts at
/// the top). Cells report visibility up so the parent's prefetch window tracks the visible ± margin.
private struct ClusterPage: View {
    let cluster: ReviewCluster
    /// The pinned header title — a trip's location sentence (or its date range until the name lands), or
    /// a plain date cluster's date title. Computed by the parent from the resolved trip names.
    let headerTitle: String
    /// A trip/visit cluster → the done CTA reads "Mark trip done"; a date cluster → "Mark day done".
    let isTrip: Bool
    let columns: [GridItem]
    let spacing: CGFloat
    let load: (String) async -> UIImage?
    let cachedImage: (String) -> UIImage?
    let openAsset: (String) -> Void
    /// Only the active (current) page reports cell visibility — keeps the prefetch recompute off the
    /// swipe hot path, since TabView pre-renders neighbours whose cells would otherwise churn it.
    let isActive: Bool
    let onVisible: (String) -> Void
    let onHidden: (String) -> Void
    let position: Int
    let total: Int
    let onMarkDone: () -> Void
    @Environment(DoneStore.self) private var done

    var body: some View {
        // The per-cell day label stays the date (a cell is one photo on one day, even inside a trip);
        // the header/chip carries the cluster title (trip sentence or date). Formatted once per page.
        let dayLabel = DayGroupHeader.title(for: cluster)
        ScrollView {
            LazyVGrid(columns: columns, spacing: spacing, pinnedViews: [.sectionHeaders]) {
                Section {
                    ForEach(cluster.assetIDs, id: \.self) { id in
                        ReviewGridCell(
                            id: id,
                            dayLabel: dayLabel,
                            load: load,
                            cachedImage: cachedImage,
                            onOpen: { Perf.event("grid.tap \(id.suffix(8))"); openAsset(id) })
                            .id(id)
                            .onAppear { if isActive { onVisible(id) } }
                            .onDisappear { if isActive { onHidden(id) } }
                    }
                } header: {
                    clusterHeader()
                } footer: {
                    footer(isDone: done.isDone(cluster))
                }
            }
            .padding(.horizontal, spacing)
            .scrollTargetLayout()
        }
    }

    /// The pinned per-cluster header: an always-visible page indicator (position + dots — the swipe
    /// affordance + "where am I in the year" orientation the paged model needs) above the title +
    /// Select-all glass pills. The title chip shows the trip sentence (or date) with a pin for trips.
    @ViewBuilder private func clusterHeader() -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if total > 1 { PageIndicatorPill(position: position, total: total) }
            ClusterChips(cluster: cluster, title: headerTitle, isTrip: isTrip, isDone: done.isDone(cluster))
        }
    }

    /// End-of-cluster CTA: "Mark trip done" for a trip (it spans several days) / "Mark day done" for a
    /// date cluster — advances to the next unreviewed cluster, reached by scrolling to the end (#38).
    @ViewBuilder private func footer(isDone: Bool) -> some View {
        let doneLabel = isTrip ? "Mark trip done" : "Mark day done"
        HStack {
            Spacer()
            Button(action: onMarkDone) {
                Label(isDone ? "Mark as not done" : doneLabel,
                      systemImage: isDone ? "checkmark.seal.fill" : "checkmark.seal")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(isDone ? Color(.systemGray) : .brandGreen)
            .accessibilityIdentifier("markDoneButton")   // stable id though the label toggles
            .accessibilityHint(isDone
                ? "Reopens this cluster for editing"
                : "Marks this cluster reviewed and opens the next")
            Spacer()
        }
        .padding(.top, 16)
        .padding(.bottom, 28)
    }
}

// MARK: - Page indicator (always-visible position + swipe affordance)

/// A compact glass pill pinned atop each cluster page — the paged model's orientation device: an
/// always-visible position across the album plus the cue you can swipe between clusters. Dots read
/// only for a *small* album (HIG: page controls suit ≲10 pages); past that a dot ribbon is meaningless
/// noise (a windowed "10 of 349 dots" tells you nothing), so it's the numeric position alone.
private struct PageIndicatorPill: View {
    let position: Int   // 1-based
    let total: Int
    private let maxDots = 10

    var body: some View {
        HStack(spacing: 8) {
            if total <= maxDots {
                PageDots(count: total, current: position - 1)
            }
            Text("\(position) / \(total)")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 34)
        .glassChip()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(position) / \(total)")
    }
}

// MARK: - The floating day + Select-all glass pills (pinned over the photos)

/// The cluster's day chip (date · count · done seal) and its Select-all chip — floating glass capsules
/// pinned at the top of the page, over the photos (styleguide §5, like the accordion's header). The day
/// chip is informational (no open/collapse in the paged model); Select-all toggles the whole cluster's
/// picks. Observes the stores itself so the parent grid body stays independent of `selected`.
private struct ClusterChips: View {
    let cluster: ReviewCluster
    let title: String
    var isTrip: Bool = false
    let isDone: Bool
    @Environment(SelectionStore.self) private var selection
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let selectedCount = selection.selected.intersection(cluster.assetIDs).count
        let allSelected = !cluster.assetIDs.isEmpty && selectedCount == cluster.count
        // One GlassEffectContainer so the two co-located chips sample as a single lens (styleguide §5).
        GlassEffectContainer(spacing: 8) {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 6) {
                    dayChip
                    selectAllChip(allSelected: allSelected)
                }
            } else {
                HStack(spacing: 8) {
                    dayChip
                    Spacer(minLength: 0)
                    selectAllChip(allSelected: allSelected)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isHeader)
    }

    /// The cluster identity capsule — a pin (trips) + title + count + (done) green seal. Non-interactive.
    private var dayChip: some View {
        HStack(spacing: 6) {
            if isTrip {
                Image(systemName: "mappin.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
            }
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isDone ? .secondary : .primary)
                .lineLimit(1)
            Text("· \(cluster.count)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            if isDone {
                Image(systemName: "checkmark.seal.fill")
                    .font(.subheadline)
                    .foregroundStyle(Color.brandGreen)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 44)   // ≥44pt touch floor even though it's non-interactive (visual balance)
        .glassChip()
        .accessibilityElement(children: .combine)
    }

    /// Select-all / deselect-all for this cluster — its own glass capsule.
    private func selectAllChip(allSelected: Bool) -> some View {
        Button {
            if allSelected { selection.deselect(cluster.assetIDs) } else { selection.select(cluster.assetIDs) }
        } label: {
            Text(allSelected ? "Deselect all" : "Select all")
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, 14)
                .frame(minHeight: 44)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .glassChip()
        .accessibilityIdentifier("selectAllButton")
        .accessibilityLabel(allSelected ? "Deselect all in \(title)" : "Select all in \(title)")
    }
}

// MARK: - Page dots

/// The cluster carousel's position indicator — one dot per cluster, the current one brighter + larger.
/// Purely decorative (the header's "3 / 12" carries the a11y position), so hidden from VoiceOver.
private struct PageDots: View {
    let count: Int
    let current: Int
    /// Cap the rendered dots so a 200-cluster album doesn't draw a 200-dot ribbon; the header's numeric
    /// position stays exact regardless.
    private let maxDots = 15

    var body: some View {
        HStack(spacing: 6) {
            if count <= maxDots {
                ForEach(0..<count, id: \.self) { dot($0 == current) }
            } else {
                // Windowed: show a fixed ribbon around the current dot.
                let window = windowRange()
                ForEach(window, id: \.self) { dot($0 == current) }
            }
        }
        .accessibilityHidden(true)
    }

    private func dot(_ isCurrent: Bool) -> some View {
        Circle()
            .fill(isCurrent ? Color.primary : Color.primary.opacity(0.3))
            .frame(width: isCurrent ? 7 : 6, height: isCurrent ? 7 : 6)
    }

    private func windowRange() -> [Int] {
        let half = maxDots / 2
        let lower = max(0, min(current - half, count - maxDots))
        return Array(lower..<(lower + maxDots))
    }
}

// MARK: - Entry page

/// The cluster PAGE to open on first appear / album switch (#35 paged-clusters). A #37-style drill
/// (`scrollToDay` matching a group's days) opens that group's page; otherwise the first UNREVIEWED
/// cluster (resume), else the first. Pure so the drill-vs-resume choice is unit-tested. Returns 0 for
/// an empty slice (the view guards `currentGroup`).
func initialPage(clusters: [ReviewCluster], scrollToDay: DayKey?, isDone: (ReviewCluster) -> Bool) -> Int {
    if let day = scrollToDay, let idx = clusters.firstIndex(where: { $0.days.contains(day) }) {
        return idx
    }
    return clusters.firstIndex(where: { !isDone($0) }) ?? 0
}

/// The page to land on after marking `current` done (#38 mark-done → next-day heartbeat): the first
/// UNREVIEWED cluster AFTER `current`, else the literal next page, else stay on `current` (the last
/// stretch is finished). Pure so this — the core of the paged mark-done flow — is unit-tested, per the
/// codebase's "pull the decision out of the View" convention. `isDone` is indexed into `0..<count`.
func nextUnreviewedPage(after current: Int, count: Int, isDone: (Int) -> Bool) -> Int {
    guard count > 0 else { return 0 }
    if let next = (current + 1..<count).first(where: { !isDone($0) }) { return next }
    return current + 1 < count ? current + 1 : current
}
