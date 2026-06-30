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

    @Environment(\.thumbnailProvider) private var thumbnails
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var columnCount = 3
    @State private var pinchBaseline = 3
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
            LazyVGrid(columns: columns, spacing: spacing, pinnedViews: [.sectionHeaders]) {
                ForEach(groups) { group in
                    // Format the day title once per group (not per cell), and hand it to both the
                    // header and the cells' VoiceOver labels for orientation.
                    let title = DayGroupHeader.title(for: group)
                    Section {
                        ForEach(group.assetIDs, id: \.self) { id in
                            cell(for: id, dayLabel: title).id(id)
                        }
                    } header: {
                        ReviewSectionHeader(group: group, title: title)
                    }
                }
            }
            .scrollTargetLayout()
        }
        // Pinned under the (inline) nav title so the tally stays glanceable while scrolling the grid —
        // it's the orientation device; losing it mid-scroll would defeat the point. A `.bar` backing
        // gives scroll-edge legibility over bright thumbnails (ReviewHeader owns it).
        .safeAreaInset(edge: .top, spacing: 0) { ReviewHeader(subtitle: subtitle) }
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
            Perf.event("grid.onAppear (return from viewer)")
            Perf.measure("grid.onAppear setup") {
                // No explicit scroll restore — the grid stayed put under the pushed viewer, so it's
                // already where the user left it (an explicit re-center jumped on selection, #81).
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
            scheduleRecomputeWindow()
        }
        // NB: no cache reset on disappear — pushing the #36 viewer fires onDisappear, and resetting
        // there would cold-reload every thumbnail on return. The prefetch window bounds growth; a
        // full reset is tied to leaving review entirely (with the viewer / deactivation, later).
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
        window = PrefetchWindow(orderedIDs: groups.flatMap(\.assetIDs))
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

/// One pinned day-group header. Observes the `SelectionStore` itself (for the live per-section
/// selected/total summary + the select-all toggle) so the parent grid body stays independent of
/// `selected`. The title is formatted once by the grid and passed in.
private struct ReviewSectionHeader: View {
    let group: DayGroup
    let title: String
    @Environment(SelectionStore.self) private var selection

    var body: some View {
        let selectedCount = selection.selected.intersection(group.assetIDs).count
        let allSelected = selectedCount == group.count
        HStack(spacing: 6) {
            // A neutral busy-day marker — gold is reserved for the interactive accent (selection /
            // tally / export), so a non-interactive day indicator shouldn't borrow it.
            if group.isBusyDay {
                Circle().fill(.secondary).frame(width: 6, height: 6)
            }
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text("· \(group.count)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            sectionToggle(allSelected: allSelected)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title). \(group.count) photos, \(selectedCount) selected.")
        .accessibilityAddTraits(.isHeader)
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
