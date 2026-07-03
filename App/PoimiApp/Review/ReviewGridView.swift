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
    /// The candidates split into adaptive day-groups (oldest → newest). Concatenating the groups'
    /// `assetIDs` reproduces the full chronological slice — the sections are headered runs of it.
    let groups: [DayGroup]
    /// The album name — shown as the bold identity title in the pinned header (the nav title is
    /// blanked, so this is the screen's one title).
    let title: String
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
    /// The single OPEN cluster (accordion): exactly one day-group shows its full grid at a time; every
    /// other cluster is a collapsed peek. DECOUPLED from "done" — a cluster collapses because another
    /// opened, not because it was marked done. Bounding the open set to one means only that cluster's
    /// full-res cells load (the rest are tiny peek thumbs) — the perf win.
    @State private var expandedGroupID: String?

    @State private var columnCount = 3
    @State private var pinchBaseline = 3
    /// Once the user pinch-zooms, their column choice sticks for the session — width changes stop
    /// re-deriving the count (a compact↔regular size-class flip resets this; see `.onChange(of:)`).
    @State private var hasPinched = false
    /// The scroll position (iOS 18 `ScrollPosition`). We only ever issue a ONE-SHOT `scrollTo` (opening
    /// a cluster, or the #37 drill); otherwise it just reflects where the user is. This replaced the
    /// older `.scrollPosition(id:)` binding, whose two-way write-back was RE-APPLIED on any re-layout —
    /// so a select-all or a mark-done snapped the grid back to the last top item (#81/#82, seen on
    /// device). `ScrollPosition` doesn't re-apply a programmatic scroll on re-layout, so the grid stays put.
    @State private var scrollPosition = ScrollPosition()
    /// Choose the initial open cluster once per appearance (first-unreviewed, or the #37 drill target).
    @State private var didInitialOpen = false
    /// A #37 drill target to scroll to AFTER its cluster has opened + laid out (set by
    /// `chooseInitialCluster`, applied by the `.task` below). Scrolling synchronously in `onAppear`
    /// targeted a cell that wasn't laid out yet (the section was still collapsed that instant) → a
    /// blank grid until a manual scroll, on a large library.
    @State private var pendingScrollID: String?
    @State private var visibleIDs: Set<String> = []
    @State private var window = PrefetchWindow(orderedIDs: [])
    // Generation-guarded prefetch: a single in-flight updater loops until it has applied the latest
    // visible state, so out-of-order actor calls can't leave a stale window cached (D-review #35).
    @State private var windowGeneration = 0
    @State private var windowUpdating = false
    /// The last slice actually pushed to the cache, so an unchanged recompute (a scroll that didn't
    /// cross a cell boundary) skips the actor hop instead of re-sending the same window every frame.
    @State private var lastAppliedSlice: [String] = []

    private let spacing: CGFloat = 3   // small inter-cell gap, Apple-Photos-style (revises the gapless §3)
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

    /// Columns that best fill `width` at ~132pt cells, clamped to the size-class range. Deriving from
    /// width (not a fixed 3) is what opens the grid dense on iPad (~6 in the detail column) and keeps it
    /// filling the pane on a Split View / Stage Manager resize (#42) — iPhone still lands on ~3.
    private func idealColumnCount(for width: CGFloat) -> Int {
        guard width > 0 else { return columnCount }
        return ReviewGridColumns.ideal(forWidth: width, minColumns: minColumns, maxColumns: maxColumns)
    }

    /// Apply the width-derived count unless the user has taken manual control via pinch this session.
    private func applyIdealColumns(width: CGFloat) {
        guard !hasPinched else { return }
        let ideal = idealColumnCount(for: width)
        if ideal != columnCount {
            columnCount = ideal
            pinchBaseline = ideal
        }
    }

    var body: some View {
        ScrollView {
            // ONE LazyVGrid of day-group SECTIONS (idea ③), not a stack of nested grids. An open
            // section's cells are direct grid items (so the grid stays lazy even for a 500-photo busy
            // day — nesting a LazyVGrid inside a LazyVStack risked eager materialisation); a done
            // section has NO cells and renders its full-width peek as the section FOOTER (a footer
            // spans the grid width, which a column-bound item can't). `pinnedViews` keeps the day
            // header glued to the top while you scroll a long open run (the #35 orientation finding).
            LazyVGrid(columns: columns, spacing: spacing, pinnedViews: [.sectionHeaders]) {
                ForEach(groups) { group in
                    // Format the day title once per group (not per cell) — header + cell a11y labels.
                    let title = DayGroupHeader.title(for: group)
                    Section {
                        if !isCollapsed(group) {
                            ForEach(group.assetIDs, id: \.self) { id in
                                cell(for: id, dayLabel: title).id(id)
                            }
                        }
                    } header: {
                        ReviewSectionHeader(group: group, title: title,
                                            isDone: done.isDone(group),
                                            isOpen: !isCollapsed(group),
                                            onToggleOpen: { toggleOpen(group) })
                    } footer: {
                        // Collapsed → a peek (tap to open). Open → the "Mark as done" button AFTER the
                        // photos, so you reach it once you've reviewed the day (discoverable, #38).
                        if isCollapsed(group) {
                            CollapsedSectionPeek(ids: group.assetIDs, dayTitle: title,
                                                 isDone: done.isDone(group)) { toggleOpen(group) }
                        } else {
                            markDoneFooter(group)
                        }
                    }
                }
            }
            .scrollTargetLayout()
        }
        // Pinned under the (inline) nav title so the tally stays glanceable while scrolling the grid —
        // it's the orientation device; losing it mid-scroll would defeat the point. ReviewHeader owns
        // its Liquid Glass backing (extended to the top edge, behind the backdrop-hidden nav bar).
        .safeAreaInset(edge: .top, spacing: 0) { ReviewHeader(title: title, subtitle: subtitle) }
        // Tracks position; we only issue a one-shot scrollTo for the #37 drill (onAppear). No
        // re-applied target, so select-all / mark-done re-layouts never snap the grid (#81/#82).
        .scrollPosition($scrollPosition, anchor: .top)
        // The #37 drill scroll, deferred: runs AFTER the target cluster has opened (`expandedGroupID`
        // applied) and laid out, so the cell exists to scroll to — a synchronous onAppear scroll hit a
        // not-yet-laid-out cell and left the grid blank until a manual scroll (large-library device bug).
        .task(id: pendingScrollID) {
            guard let id = pendingScrollID else { return }
            scrollPosition.scrollTo(id: id, anchor: .top)
            pendingScrollID = nil
        }
        // Reduce Motion → no density-change animation (the cross-fade is the system default).
        .animation(reduceMotion ? nil : .snappy, value: columnCount)
        // Success haptic when a day is marked done (count up), a light tap on undo. Keyed here because
        // the mark-done button lives in the footer and is removed before its own feedback could fire.
        .sensoryFeedback(trigger: done.doneDays.count) { old, new in new > old ? .success : .impact(weight: .light) }
        .gesture(
            MagnifyGesture()
                .onChanged { value in
                    hasPinched = true   // user is driving density now — stop auto-deriving from width
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
                if !didInitialOpen {
                    didInitialOpen = true
                    chooseInitialCluster()
                }
                rebuildWindow()
                scheduleRecomputeWindow()
            }
        }
        .onChange(of: visibleIDs) { scheduleRecomputeWindow() }
        .onChange(of: columnCount) { scheduleRecomputeWindow() }
        .onChange(of: maxColumns) { columnCount = min(columnCount, maxColumns) }
        // Derive the column count from the available width so the grid opens dense on iPad and reflows
        // on a Split View / Stage Manager resize (#42) — not stuck at the iPhone default of 3.
        .onGeometryChange(for: CGFloat.self) { proxy in proxy.size.width } action: { width in
            applyIdealColumns(width: width)
        }
        // A compact↔regular flip is a fundamentally different layout — re-derive density even if the
        // user had pinched in the old size class.
        .onChange(of: sizeClass) { hasPinched = false }
        .onChange(of: expandedGroupID) {
            // The open cluster changed → which cells can render changed; re-derive the prefetch window.
            rebuildWindow()
            scheduleRecomputeWindow()
        }
        .onChange(of: groupIdentity) {
            visibleIDs = []
            lastAppliedSlice = []      // new album → re-cache from scratch, don't skip on a stale match
            chooseInitialCluster()     // open the new album's first-unreviewed (or its drill target)
            rebuildWindow()
            scheduleRecomputeWindow()
        }
        // NB: no cache reset on disappear — pushing the #36 viewer fires onDisappear, and resetting
        // there would cold-reload every thumbnail on return. The prefetch window bounds growth; a
        // full reset is tied to leaving review entirely (with the viewer / deactivation, later).
    }

    // MARK: Accordion (one cluster open at a time)

    /// Collapsed = NOT the single open cluster. Independent of "done": a done cluster can be re-opened,
    /// and a not-done cluster is collapsed simply because another one is open.
    private func isCollapsed(_ group: DayGroup) -> Bool { group.id != expandedGroupID }

    /// On first appear (and on an album switch): open the #37 drill target if there is one, else the
    /// first UNREVIEWED cluster (resume), else the first. The drill scrolls to its cluster; a plain
    /// initial open doesn't (the grid sits at the top, done peeks above the open cluster).
    private func chooseInitialCluster() {
        // Decision extracted to `initialCluster` (tested); the drill target scrolls only once it's
        // laid out — the deferred `.task(id: pendingScrollID)` fires the scroll, fixing the blank grid.
        let choice = initialCluster(groups: groups, scrollToDay: scrollToDay, isDone: { done.isDone($0) })
        expandedGroupID = choice.expandedID
        pendingScrollID = choice.pendingScrollID
    }

    /// Tapping a cluster's header or peek toggles it: open it (auto-collapsing whoever was open), or —
    /// if it's already the open one — collapse to none. Animated; opening scrolls the cluster up.
    private func toggleOpen(_ group: DayGroup) {
        withAnimation(reduceMotion ? nil : .snappy) {
            if expandedGroupID == group.id { expandedGroupID = nil } else { open(group) }
        }
    }

    /// Make `group` the single open cluster and scroll its first cell to the top.
    private func open(_ group: DayGroup) {
        expandedGroupID = group.id
        if let first = group.assetIDs.first { scrollPosition.scrollTo(id: first, anchor: .top) }
    }

    /// The footer button's action: toggle the day's done flag. Marking done (not un-marking) flows
    /// straight into the next unreviewed cluster — finish a day, land on the next.
    private func markDone(_ group: DayGroup) {
        let wasDone = done.isDone(group)
        withAnimation(reduceMotion ? nil : .snappy) {
            done.toggle(group)
            if !wasDone { advanceAfter(group) }
        }
        if !wasDone { AccessibilityNotification.Announcement("Marked done").post() }
    }

    /// Open the next unreviewed cluster after `group`; if none remain ahead, collapse to all-peeks
    /// (the "finished this stretch" state).
    private func advanceAfter(_ group: DayGroup) {
        guard let idx = groups.firstIndex(where: { $0.id == group.id }) else { expandedGroupID = nil; return }
        if let next = groups[(idx + 1)...].first(where: { !done.isDone($0) }) {
            open(next)
        } else {
            expandedGroupID = nil
        }
    }

    /// The "Mark as done" CTA at the END of an open cluster's photos (the discoverable end-of-review
    /// affordance, #38). A CENTERED, content-sized button (not a full-width slab) — brand-green and
    /// prominent while not done; a quieter bordered "Mark as not done" once done (re-opened to edit).
    @ViewBuilder
    private func markDoneFooter(_ group: DayGroup) -> some View {
        let isDone = done.isDone(group)
        HStack {
            Spacer()
            Button { markDone(group) } label: {
                Label(isDone ? "Mark as not done" : "Mark as done",
                      systemImage: isDone ? "checkmark.seal.fill" : "checkmark.seal")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(isDone ? Color(.systemGray) : .brandGreen)
            Spacer()
        }
        .padding(.top, 10)
        .padding(.bottom, 28)
        .accessibilityHint(isDone ? "Reopens this day for editing" : "Marks this day reviewed and opens the next")
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

/// One day-group (cluster) header — the accordion's open/collapse control. Tapping the left region
/// opens the cluster (auto-collapsing whoever was open) or collapses it; a disclosure chevron signals
/// it expands, a brand-green seal badge marks a done day (at a glance, even while collapsed), and
/// "Select all" shows while open. Observes the `SelectionStore` itself so the parent grid body stays
/// independent of `selected`. The toggle and Select-all are SEPARATE buttons (side by side) so a
/// Select-all tap can't also fire the open/collapse. The title is formatted once by the grid.
private struct ReviewSectionHeader: View {
    let group: DayGroup
    let title: String
    let isDone: Bool
    let isOpen: Bool
    let onToggleOpen: () -> Void
    @Environment(SelectionStore.self) private var selection
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let selectedCount = selection.selected.intersection(group.assetIDs).count
        let allSelected = selectedCount == group.count
        // No full-width background: the day header is FLOATING GLASS CHIPS over the photos (like the
        // viewer's controls), so the TOP header stays the ONE full-width glass surface — no second slab
        // mashed against it (device feedback). Each chip's own glass backs its text over photos (when
        // pinned) AND the plain background (at rest), in light + dark, via glass vibrancy — an adaptive
        // material a fixed scrim couldn't match. Photos scroll through the transparent gaps around them.
        dayHeaderContent(selectedCount: selectedCount, allSelected: allSelected)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isHeader)
    }

    /// Leading day chip + trailing Select-all chip, floating over the photos. At accessibility
    /// Dynamic-Type sizes they stack (they'd otherwise crowd one line) — we WRAP, never
    /// `minimumScaleFactor` (shrinking the user's chosen size is itself an a11y regression).
    private func dayHeaderContent(selectedCount: Int, allSelected: Bool) -> some View {
        // One GlassEffectContainer so the two co-located chips sample as a single lens (styleguide §5:
        // group co-located glass, never two independent glass surfaces side by side).
        GlassEffectContainer(spacing: 8) {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 6) {
                    dayChip(selectedCount: selectedCount)
                    if isOpen { selectAllChip(allSelected: allSelected) }
                }
            } else {
                HStack(spacing: 8) {
                    dayChip(selectedCount: selectedCount)
                    Spacer(minLength: 0)
                    if isOpen { selectAllChip(allSelected: allSelected) }
                }
            }
        }
    }

    /// The open/collapse control — a floating glass capsule holding the disclosure chevron, day title,
    /// count, and (for a done day) the green seal. Tapping it opens/collapses the cluster. Its glass
    /// backs the text; photos scroll through the transparent area around it when pinned.
    private func dayChip(selectedCount: Int) -> some View {
        Button(action: onToggleOpen) {
            HStack(spacing: 6) {
                disclosure; titleText; countText(selectedCount); if isDone { doneBadge }
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 44)              // ≥44pt touch floor (HIG)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassChip()
        // "kept" (not "selected") to match the visible collapsed count and the app's pick vocabulary.
        .accessibilityLabel("\(title). \(selectedCount) of \(group.count) kept.\(isDone ? " Done." : "")")
        .accessibilityValue(isOpen ? "Expanded" : "Collapsed")
        .accessibilityHint("Double tap to \(isOpen ? "collapse" : "open") this day")
    }

    /// Disclosure chevron — signals the chip expands; rotates down when open.
    private var disclosure: some View {
        Image(systemName: "chevron.right")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .rotationEffect(.degrees(isOpen ? 90 : 0))
            .frame(width: 14)
            .accessibilityHidden(true)
    }

    /// Non-interactive done indicator (the styleguide §7 completion seal, brand green) so finished days
    /// read at a glance even when collapsed. Marking done is the footer button, not this badge.
    private var doneBadge: some View {
        Image(systemName: "checkmark.seal.fill")
            .font(.subheadline)
            .foregroundStyle(Color.brandGreen)
            .accessibilityHidden(true)
    }

    private var titleText: some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(isDone ? .secondary : .primary)   // a done day reads quieter
            .lineLimit(2)                  // wrap if long; never shrink (a11y)
            .accessibilityHidden(true)
    }

    /// Open → the total ("· 10"); collapsed → the pick result ("3 of 10 kept"), since the cells aren't
    /// visible to show their own selection — it's the one number the app tracks.
    private func countText(_ selectedCount: Int) -> some View {
        Text(isOpen ? "· \(group.count)" : "\(selectedCount) of \(group.count) kept")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .monospacedDigit()
            .accessibilityHidden(true)
    }

    /// Select-all / deselect-all for this day-group — its own floating glass chip (the contextual bulk
    /// action, #35). Bulk ops schedule a single debounced flush.
    private func selectAllChip(allSelected: Bool) -> some View {
        Button {
            if allSelected { selection.deselect(group.assetIDs) } else { selection.select(group.assetIDs) }
        } label: {
            Text(allSelected ? "Deselect all" : "Select all")
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, 14)
                .frame(minHeight: 44)        // touch-target floor (WCAG 2.5.8)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        // Primary label (glass vibrancy), NOT the gold accent: gold is for graphical marks — small gold
        // text fails the contrast caveat (styleguide §1). Position + weight signal it's tappable.
        .foregroundStyle(.primary)
        .glassChip()
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

/// Decide which cluster to open (and whether to scroll to it) on first appear / album switch — pulled
/// out of the View so the drill-vs-resume decision is unit-tested (the `@State` writes stay in
/// `chooseInitialCluster`). A #37 drill (`scrollToDay` matching a group) opens that group AND targets
/// its first cell for a scroll (the caller defers that to a `.task`, after layout — the fix for the
/// blank-until-manual-scroll bug); otherwise open the first UNREVIEWED cluster (resume), else the
/// first, and DON'T scroll (the grid sits at the top). `pendingScrollID` is nil unless we drilled to a
/// group that actually has a first asset id — an empty group scrolls nowhere.
func initialCluster(groups: [DayGroup], scrollToDay: DayKey?,
                    isDone: (DayGroup) -> Bool) -> (expandedID: String?, pendingScrollID: String?) {
    if let day = scrollToDay, let target = groups.first(where: { $0.days.contains(day) }) {
        return (target.id, target.assetIDs.first)
    }
    let resume = groups.first(where: { !isDone($0) }) ?? groups.first
    return (resume?.id, nil)
}
