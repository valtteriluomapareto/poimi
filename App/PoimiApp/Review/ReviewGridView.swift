//
//  ReviewGridView.swift
//  PoimiApp — the review grid (issue #35), PAGED-CLUSTERS model (#35 paged-clusters redesign).
//
//  One cluster fills the screen; you SWIPE SIDEWAYS between clusters (a horizontal page `TabView`),
//  replacing the earlier single-scroll accordion — whose collapse/open reflow was jumpy on device now
//  that the Overview is itself a full cluster index (with per-cluster thumbnail strips). Each page is
//  that cluster's own vertical `LazyVGrid`. Shared chrome (safe-area insets, so it never overlaps the
//  photos) shows the CURRENT cluster: a top glass header (day · "N photos · M kept" · position "3 / 12")
//  and a bottom glass bar (page dots + a "Mark day done" button that advances to the next cluster).
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
    /// The candidates split into adaptive day-groups (oldest → newest) — one page per group.
    let groups: [DayGroup]
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

    /// The current cluster page — an index into `groups`. Swiping (TabView) or "Mark day done" moves it.
    @State private var currentPage = 0
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

    private var currentGroup: DayGroup? {
        groups.indices.contains(currentPage) ? groups[currentPage] : nil
    }

    /// Columns that best fill `width` at ~132pt cells, clamped to the size-class range — opens dense on
    /// iPad, reflows on a Split View / Stage Manager resize (#42); iPhone lands on ~3.
    private func applyIdealColumns(width: CGFloat) {
        guard width > 0 else { return }
        let ideal = ReviewGridColumns.ideal(forWidth: width, minColumns: minColumns, maxColumns: maxColumns)
        if ideal != columnCount { columnCount = ideal }
    }

    var body: some View {
        TabView(selection: $currentPage) {
            ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                ClusterPage(
                    group: group,
                    columns: columns,
                    spacing: spacing,
                    load: load,
                    cachedImage: cachedImage,
                    openAsset: openAsset,
                    onVisible: { visibleIDs.insert($0) },
                    onHidden: { visibleIDs.remove($0) })
                    .tag(index)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        // Shared chrome as safe-area insets so it reserves space (never overlaps the photos).
        .safeAreaInset(edge: .top, spacing: 0) { header }
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
        .background(Color(.systemBackground))
        .animation(reduceMotion ? nil : .snappy, value: currentPage)
        // Success haptic when a day is marked done (count up), a light tap on undo.
        .sensoryFeedback(trigger: done.doneDays.count) { old, new in new > old ? .success : .impact(weight: .light) }
        .onGeometryChange(for: CGFloat.self) { proxy in proxy.size.width } action: { applyIdealColumns(width: $0) }
        .onAppear {
            Perf.event("grid.onAppear (paged)")
            if !didInitialOpen {
                didInitialOpen = true
                currentPage = initialPage(groups: groups, scrollToDay: scrollToDay, isDone: { done.isDone($0) })
            }
            rebuildWindow()
            scheduleRecomputeWindow()
        }
        .onChange(of: currentPage) { rebuildWindow(); scheduleRecomputeWindow() }
        .onChange(of: visibleIDs) { scheduleRecomputeWindow() }
        .onChange(of: columnCount) { scheduleRecomputeWindow() }
        .onChange(of: maxColumns) { columnCount = min(columnCount, maxColumns) }
        .onChange(of: groupIdentity) {
            visibleIDs = []
            lastAppliedSlice = []      // new album → re-cache from scratch, don't skip on a stale match
            currentPage = initialPage(groups: groups, scrollToDay: scrollToDay, isDone: { done.isDone($0) })
            rebuildWindow()
            scheduleRecomputeWindow()
        }
    }

    // MARK: Chrome (reads the CURRENT cluster)

    @ViewBuilder private var header: some View {
        if let group = currentGroup {
            ClusterPageHeader(title: DayGroupHeader.title(for: group), group: group,
                              position: currentPage + 1, total: groups.count)
        }
    }

    @ViewBuilder private var bottomBar: some View {
        if let group = currentGroup {
            VStack(spacing: 12) {
                markDoneButton(group)
                if groups.count > 1 { PageDots(count: groups.count, current: currentPage) }
            }
            .padding(.top, 12)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity)
            .glassBarBackground()
        }
    }

    /// The "Mark day done" CTA — brand-green + filled seal while not done; a quieter grey "Mark as not
    /// done" once done (re-opened to edit). Marking done advances to the next unreviewed cluster (#38).
    private func markDoneButton(_ group: DayGroup) -> some View {
        let isDone = done.isDone(group)
        return Button { markDoneAndAdvance(group) } label: {
            Label(isDone ? "Mark as not done" : "Mark day done",
                  systemImage: isDone ? "checkmark.seal.fill" : "checkmark.seal")
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .tint(isDone ? Color(.systemGray) : .brandGreen)
        .accessibilityIdentifier("markDoneButton")   // stable id though the label toggles
        .accessibilityHint(isDone ? "Reopens this day for editing" : "Marks this day reviewed and opens the next")
    }

    private func markDoneAndAdvance(_ group: DayGroup) {
        let wasDone = done.isDone(group)
        done.toggle(group)
        if !wasDone {
            AccessibilityNotification.Announcement("Marked done").post()
            advance()
        }
    }

    /// Advance to the next UNREVIEWED cluster after the current page; else the literal next; else stay
    /// (finished the last stretch). Finishing a day lands you on the next one to review.
    private func advance() {
        let next = groups.indices.first { $0 > currentPage && !done.isDone(groups[$0]) }
            ?? (currentPage + 1 < groups.count ? currentPage + 1 : currentPage)
        withAnimation(reduceMotion ? nil : .snappy) { currentPage = next }
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
        "\(groups.first?.id ?? "∅")#\(groups.reduce(0) { $0 + $1.assetIDs.count })"
    }

    /// Only the CURRENT cluster's cells render at full cell size, so the window's universe is just its
    /// ids — visible ± a row margin. A neighbouring page's cells (rendered by TabView for the swipe) may
    /// report visible, but they're not in this universe so `slice` filters them out.
    private func rebuildWindow() {
        window = PrefetchWindow(orderedIDs: currentGroup?.assetIDs ?? [])
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

/// A single cluster filling the screen: its photos in a vertical `LazyVGrid`. No accordion, no pinned
/// header (the shared paged header shows the day) — just the grid. Owns its own vertical scroll, so
/// each page starts at the top. Cells report visibility up so the parent's prefetch window can track
/// the visible ± margin slice within this cluster.
private struct ClusterPage: View {
    let group: DayGroup
    let columns: [GridItem]
    let spacing: CGFloat
    let load: (String) async -> UIImage?
    let cachedImage: (String) -> UIImage?
    let openAsset: (String) -> Void
    let onVisible: (String) -> Void
    let onHidden: (String) -> Void

    var body: some View {
        // Formatted once per page (not per cell) — the cell a11y label reuses it.
        let dayLabel = DayGroupHeader.title(for: group)
        ScrollView {
            LazyVGrid(columns: columns, spacing: spacing) {
                ForEach(group.assetIDs, id: \.self) { id in
                    ReviewGridCell(
                        id: id,
                        dayLabel: dayLabel,
                        load: load,
                        cachedImage: cachedImage,
                        onOpen: { Perf.event("grid.tap \(id.suffix(8))"); openAsset(id) })
                        .id(id)
                        .onAppear { onVisible(id) }
                        .onDisappear { onHidden(id) }
                }
            }
            .padding(.horizontal, spacing)
            .scrollTargetLayout()
        }
    }
}

// MARK: - The paged header (current cluster)

/// The top glass header for the current cluster: the day title, "N photos · M kept" (kept = picks in
/// this cluster, read from the `SelectionStore`), and the cluster's position in the album ("3 / 12").
/// Glass bar backing so photos refract under it when a page scrolls (styleguide §5); RT-safe via the
/// shared modifier.
private struct ClusterPageHeader: View {
    let title: String
    let group: DayGroup
    let position: Int
    let total: Int
    @Environment(SelectionStore.self) private var selection

    var body: some View {
        let kept = group.assetIDs.reduce(into: 0) { if selection.selected.contains($1) { $0 += 1 } }
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.title2.bold())
                    .lineLimit(1)
                Text("\(group.count) photos · \(kept) kept")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer(minLength: 8)
            Text("\(position) / \(total)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassBarBackground(extendTop: true)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
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
func initialPage(groups: [DayGroup], scrollToDay: DayKey?, isDone: (DayGroup) -> Bool) -> Int {
    if let day = scrollToDay, let idx = groups.firstIndex(where: { $0.days.contains(day) }) {
        return idx
    }
    return groups.firstIndex(where: { !isDone($0) }) ?? 0
}
