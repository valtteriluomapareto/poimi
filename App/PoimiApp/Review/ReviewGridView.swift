//
//  ReviewGridView.swift
//  PoimiApp — the review grid (issue #35; promoted from the spike's AssetGridView).
//
//  THE make-or-break screen: a `LazyVGrid` in a `ScrollView`, split into Curation's adaptive
//  day-groups with **pinned section headers** (the headline Phase-0 finding — a flat year-grid is
//  harder to curate than grouped). The grid still scrolls as one chronological flow. It keeps:
//    • badge-select (resolved by the spike): tap a cell opens it; tap the ≥44pt badge selects,
//    • pinch-to-adjust column density (default 3 on iPhone; clamped by size class),
//    • a scroll-driven prefetch window (visible range ± a row margin) feeding the thumbnail seam.
//
//  Scroll position on return from the viewer is NOT explicitly restored: the grid stays put under
//  the pushed viewer (NavigationStack preserves it), which already lands the user back where they
//  were. An earlier `.scrollPosition(anchor: .center)` *did* restore explicitly, but its continuous
//  two-way re-centering jumped the grid whenever a selection toggle re-laid-out a cell (#81) — so it
//  was removed; natural stay-put covers the common case without the jump.
//
//  Selection lives in the shared `SelectionStore` (the in-memory `Set`, D15) — but the cells and
//  section headers observe it themselves, so this parent body does NOT depend on `selected`. A
//  toggle therefore re-renders only the visible cells / pinned headers, never the whole O(n) grid.
//  The tally + export chrome and the select-mode toolbar land in #35 part 3.
//

import SwiftUI
import UIKit
import Curation

struct ReviewGridView: View {
    /// The candidates split into adaptive day-groups (oldest → newest). Concatenating the groups'
    /// `assetIDs` reproduces the full chronological slice — the sections are headered runs of it.
    let groups: [DayGroup]
    /// Metadata line under the title (e.g. "1,847 photos · Jan 2025 – Dec 2025"), shown in the
    /// scroll-top header above the tally.
    let subtitle: String
    /// Open a cell full-screen (the parent pushes the viewer + records `lastViewedID`, #36).
    let openAsset: (String) -> Void
    /// A day-group to scroll to on open — the overview's "drill into this month" target (#37). Nil →
    /// open at the top (the normal entry).
    var scrollToDay: DayKey?

    @Environment(\.thumbnailProvider) private var thumbnails
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(DoneStore.self) private var done
    /// Day-groups the user has temporarily expanded via "Show all" even though they're done — UI
    /// only (not persisted). A section renders collapsed iff it's done AND not in this set.
    @State private var manuallyExpanded: Set<String> = []

    @State private var columnCount = 3
    @State private var pinchBaseline = 3
    /// One-shot scroll position for the #37 drill — set ONCE on appear from `scrollToDay`, then just
    /// tracks. Deliberately no `.center` anchor + a LOCAL state (the #81/#82 jump was a `.center`
    /// two-way bind to a shared observable; `.scrollPosition` itself is lazy-safe, unlike `scrollTo`).
    @State private var scrollTarget: String?
    @State private var visibleIDs: Set<String> = []
    @State private var window = PrefetchWindow(orderedIDs: [])
    // Generation-guarded prefetch: a single in-flight updater loops until it has applied the latest
    // visible state, so out-of-order actor calls can't leave a stale window cached (D-review #35).
    @State private var windowGeneration = 0
    @State private var windowUpdating = false
    /// The last slice actually pushed to the cache, so an unchanged recompute (a scroll that didn't
    /// cross a cell boundary) skips the actor hop instead of re-sending the same window every frame.
    @State private var lastAppliedSlice: [String] = []

    private let spacing: CGFloat = 0   // gapless photo wall (Paper design / styleguide §3)
    private let minColumns = 2
    private let windowRowMargin = 2
    /// Oversized vs the on-screen point size on purpose (Retina + density headroom).
    private let thumbnailTarget = CGSize(width: 400, height: 400)

    /// iPhone tops out at 5 columns (any more shrinks the cell below the 44pt badge, leaving no
    /// room to tap "open"); iPad allows denser grids. Matches the styleguide's 2–5 iPhone range.
    private var maxColumns: Int { sizeClass == .compact ? 5 : 8 }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: spacing), count: columnCount)
    }

    var body: some View {
        ScrollView {
            // A LazyVStack of per-cluster SECTIONS (idea ③). Each section is a pinned header +
            // either the gapless cell grid (open) or a full-width thumbnail peek (done → collapsed):
            // a done cluster shrinks to a peek so the wall declutters as you finish runs; "Show all"
            // re-opens one without un-marking it. Sections (not one big LazyVGrid) because a
            // full-width peek can't live in grid columns — and `pinnedViews` keeps the day header
            // glued to the top while you scroll a long open run (the #35 orientation finding).
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(groups) { group in
                    // Format the day title once per group (not per cell) — header + cell a11y labels.
                    let title = DayGroupHeader.title(for: group)
                    Section {
                        if isCollapsed(group) {
                            CollapsedSectionPeek(ids: group.assetIDs) { expand(group) }
                        } else {
                            LazyVGrid(columns: columns, spacing: spacing) {
                                ForEach(group.assetIDs, id: \.self) { id in
                                    cell(for: id, dayLabel: title).id(id)
                                }
                            }
                        }
                    } header: {
                        // `.id(group.id)` is the #37 month-drill's scroll anchor — a header is a
                        // direct child of the `.scrollTargetLayout()` below, so `.scrollPosition`
                        // resolves it; a cell id (a grandchild inside the nested grid) would not.
                        ReviewSectionHeader(group: group, title: title,
                                            isDone: done.isDone(group),
                                            onToggleDone: { toggleDone(group) })
                            .id(group.id)
                    }
                }
            }
            .scrollTargetLayout()
        }
        // Pinned under the (inline) nav title so the tally stays glanceable while scrolling the grid —
        // it's the orientation device; losing it mid-scroll would defeat the point. A `.bar` backing
        // gives scroll-edge legibility over bright thumbnails (ReviewHeader owns it).
        .safeAreaInset(edge: .top, spacing: 0) { ReviewHeader(subtitle: subtitle) }
        // One-shot position for the #37 drill (lazy-safe; nil target = no positioning = top).
        .scrollPosition(id: $scrollTarget)
        // Reduce Motion → no density-change animation (the cross-fade is the system default).
        .animation(reduceMotion ? nil : .snappy, value: columnCount)
        .gesture(
            MagnifyGesture()
                .onChanged { value in
                    let proposed = Double(pinchBaseline) / value.magnification
                    // MagnifyGesture fires continuously, but the column count only crosses an
                    // integer boundary a few times across a whole pinch. Write only on a real
                    // change so the grid re-layout, the .snappy animation, and the prefetch-window
                    // recompute (.onChange below) each fire once per step, not per gesture sample
                    // (smoothness review, Finding 4).
                    let next = clampedColumnCount(proposed, min: minColumns, max: maxColumns)
                    if next != columnCount { columnCount = next }
                }
                .onEnded { _ in pinchBaseline = columnCount }
        )
        .onAppear {
            Perf.event("grid.onAppear (return from viewer / drill)")
            Perf.measure("grid.onAppear setup") {
                // Drill from the overview (#37): scroll once to the first cell of the day-group holding
                // the target day. No explicit RESTORE otherwise — the grid stays put under the pushed
                // viewer, and an explicit re-center jumped on selection (#81).
                if scrollTarget == nil, let day = scrollToDay,
                   let target = groups.first(where: { $0.days.contains(day) }) {
                    if done.isDone(target) { manuallyExpanded.insert(target.id) }   // expand so its cells render
                    scrollTarget = target.id   // the section header anchor, not a (grandchild) cell id
                }
                rebuildWindow()
                scheduleRecomputeWindow()
            }
        }
        .onChange(of: visibleIDs) { scheduleRecomputeWindow() }
        .onChange(of: columnCount) { scheduleRecomputeWindow() }
        .onChange(of: maxColumns) { columnCount = min(columnCount, maxColumns) }
        .onChange(of: groupIdentity) {
            rebuildWindow()
            visibleIDs = []
            lastAppliedSlice = []   // new album → re-cache from scratch, don't skip on a stale match
            manuallyExpanded = []   // group ids belong to the old album; drop them so none leaks an expand
            scheduleRecomputeWindow()
        }
        // NB: no cache reset on disappear — pushing the #36 viewer fires onDisappear, and resetting
        // there would cold-reload every thumbnail on return. The prefetch window bounds growth; a
        // full reset is tied to leaving review entirely (with the viewer / deactivation, later).
    }

    // MARK: Collapse (idea ③)

    /// A done section renders collapsed unless the user re-opened it via "Show all".
    private func isCollapsed(_ group: DayGroup) -> Bool {
        done.isDone(group) && !manuallyExpanded.contains(group.id)
    }

    /// Toggle a section done. Clearing the manual-expand override means done→collapsed and
    /// undone→open follow naturally from `isCollapsed`. The collapse set just changed, so the
    /// prefetch window (open groups only) has to be rebuilt.
    private func toggleDone(_ group: DayGroup) {
        done.toggle(group)
        manuallyExpanded.remove(group.id)
        refreshWindowForCollapse()
    }

    /// "Show all" on a done cluster: re-open it (its cells render again) without un-marking done.
    /// Its ids re-enter the prefetch window, so rebuild it.
    private func expand(_ group: DayGroup) {
        manuallyExpanded.insert(group.id)
        refreshWindowForCollapse()
    }

    /// A collapse/expand changes which ids can actually render as cells; the prefetch window's
    /// universe is open groups only (a collapsed peek loads its own small thumbs), so re-derive it.
    private func refreshWindowForCollapse() {
        rebuildWindow()
        scheduleRecomputeWindow()
    }

    // MARK: Cell

    private func cell(for id: String, dayLabel: String) -> some View {
        ReviewGridCell(
            id: id,
            dayLabel: dayLabel,
            load: load,
            cachedImage: cachedImage,
            onOpen: { Perf.event("grid.tap \(id.suffix(8))"); openAsset(id) })
            .onAppear { visibleIDs.insert(id) }
            .onDisappear { visibleIDs.remove(id) }
    }

    private func load(_ id: String) async -> UIImage? {
        let started = Perf.begin()
        let image = await thumbnails.thumbnail(for: id, targetSize: thumbnailTarget)
        Perf.endIO("grid.cell.load \(id.suffix(8))", since: started)
        return image
    }

    /// Synchronous cache lookup at the cell's request size — a hit lets a recycled cell skip the
    /// placeholder (Finding 2). `nonisolated` on the seam, so this never hops the actor.
    private func cachedImage(_ id: String) -> UIImage? {
        thumbnails.cachedThumbnail(for: id, targetSize: thumbnailTarget)
    }

    // MARK: Prefetch window

    private var groupIdentity: String {
        "\(groups.first?.id ?? "∅")#\(groups.reduce(0) { $0 + $1.assetIDs.count })"
    }

    private func rebuildWindow() {
        // Only OPEN groups can render cells; a collapsed cluster shows a peek (its own 56pt thumbs),
        // never a 400² cell. Keeping collapsed ids out of the window's universe stops the
        // visible ± margin slice from pre-caching a neighbouring collapsed run at full cell size.
        window = PrefetchWindow(orderedIDs: groups.filter { !isCollapsed($0) }.flatMap(\.assetIDs))
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

/// One day-group (cluster) header. Observes the `SelectionStore` itself (for the live per-section
/// selected/total summary + the select-all toggle) so the parent grid body stays independent of
/// `selected`. A leading ✓/○ circle marks the section done (which collapses it, idea ③). The title
/// is formatted once by the grid and passed in.
private struct ReviewSectionHeader: View {
    let group: DayGroup
    let title: String
    let isDone: Bool
    let onToggleDone: () -> Void
    @Environment(SelectionStore.self) private var selection

    var body: some View {
        let selectedCount = selection.selected.intersection(group.assetIDs).count
        let allSelected = selectedCount == group.count
        HStack(spacing: 8) {
            doneToggle
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isDone ? .secondary : .primary)   // a done run reads quieter
                .lineLimit(1)
                .minimumScaleFactor(0.8)   // long date title + "Select all" must still fit at AX sizes
            Text("· \(group.count)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if !isDone { sectionToggle(allSelected: allSelected) }   // select-all only matters while open
        }
        .padding(.leading, 8)
        .padding(.trailing, 12)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title). \(group.count) photos, \(selectedCount) selected.\(isDone ? " Done." : "")")
        .accessibilityAddTraits(.isHeader)
    }

    /// The done circle — green ✓ when done, empty ○ otherwise. ≥44pt tap target. Marking done
    /// collapses the section (idea ③).
    private var doneToggle: some View {
        Button(action: onToggleDone) {
            Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(isDone ? Color.green : .secondary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isDone ? "Mark \(title) not done" : "Mark \(title) done")
    }

    /// Select-all / deselect-all for this day-group (the contextual bulk action, #35). Bulk ops
    /// schedule a single debounced flush.
    private func sectionToggle(allSelected: Bool) -> some View {
        Button {
            if allSelected { selection.deselect(group.assetIDs) } else { selection.select(group.assetIDs) }
        } label: {
            Text(allSelected ? "Deselect all" : "Select all")
                .font(.footnote.weight(.semibold))
        }
        .buttonStyle(.plain)
        // Primary label color, NOT the gold accent: gold is for graphical marks — small gold text on
        // the light `.bar` header fails the contrast caveat (styleguide §1). Position + weight signal
        // that it's tappable.
        .foregroundStyle(.primary)
        .accessibilityLabel(allSelected ? "Deselect all in \(title)" : "Select all in \(title)")
    }
}

/// Round a proposed (fractional) pinch column count to the nearest whole column, clamped to the
/// allowed range. Pulled out of the gesture closure so the clamping is unit-tested (the gesture's
/// write-frequency guard around it stays UI-bound). `minColumns ≤ maxColumns` is the caller's
/// contract (the grid derives both from the size class).
func clampedColumnCount(_ proposed: Double, min minColumns: Int, max maxColumns: Int) -> Int {
    Swift.min(maxColumns, Swift.max(minColumns, Int(proposed.rounded())))
}
