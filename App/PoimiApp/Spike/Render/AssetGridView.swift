//
//  AssetGridView.swift
//  PoimiApp — Spike render layer
//
//  RENDER LAYER — promotable. The review grid: a `LazyVGrid` in a `ScrollView`,
//  split into **adaptive day-group sections** with **pinned section headers** (THE
//  headline Phase-0 finding — a flat chronological grid makes curating a year harder
//  than Apple Photos; grouping has to be felt). The whole grid still scrolls as one
//  chronological flow. It keeps `.scrollPosition` restore to the source cell on
//  dismiss, `.matchedTransitionSource` for the `.navigationTransition(.zoom)` expand,
//  and **pinch-to-adjust column density** (default 3). It drives the
//  `ThumbnailImageManager` prefetch window from the *visible range* across sections,
//  so the windowing — the "does it stay smooth over thousands of assets" exit
//  criterion — is exercised under scroll rather than primed once with the whole slice.
//
//  This is the salvageable tier (D1). It deliberately knows nothing about how the
//  assets/selection are sourced — that's injected as plain `id: String` values
//  (localIdentifiers) + value-shaped `AssetDayGroup` metadata + closures, never a
//  live `[PHAsset]` (D17/§2). So it is `Sendable`-value-shaped and promotes behind
//  the protocol seam in Phase 1 with no type substitution pass.
//
//  Resolved by the spike (Part B), so hard-coded — no runtime toggles:
//    • Tap mapping → **badge-select**: tap the badge selects, tap the rest opens.
//    • Cell shape → **square**.
//  (The earlier A/B toggles and the dead aspect path were removed once the spike
//  settled both questions.)

import SwiftUI
import UIKit

struct AssetGridView: View {
    /// The slice split into adaptive day-groups (oldest → newest). Concatenating the
    /// groups' `assetIDs` reproduces the full chronological slice, so the grid still
    /// scrolls as one flow — the sections are just headered runs of it.
    let dayGroups: [AssetDayGroup]

    /// Thumbnail load by id. Backed by `ThumbnailImageManager` in the caller;
    /// the closure owns the PhotoKit access so the view stays value-shaped.
    let load: (String) async -> UIImage?

    /// Selection set membership and toggle, owned by the caller (in-memory `Set`).
    let isSelected: (String) -> Bool
    let toggleSelection: (String) -> Void

    /// Opening a cell full-screen — the caller pushes the pager onto the stack.
    let openAsset: (String) -> Void

    /// Report the windowed slice (visible range ± a row margin) to prefetch. The
    /// caller resolves these ids to live `PHAsset`s and feeds the
    /// `ThumbnailImageManager` caching window. Driven from the visible range below
    /// (across sections), so the windowing is exercised as the user scrolls — not
    /// primed once.
    let updateWindow: ([String]) -> Void

    /// Namespace for the zoom matched-transition source/destination pairing.
    let zoomNamespace: Namespace.ID

    /// The asset to restore scroll position to (the source cell of the last
    /// expand). Bound so the pager can update it on swipe and the grid scrolls
    /// back to it on return.
    @Binding var scrollAnchorID: String?

    /// Column density, pinch-adjustable. Default 3 on iPhone (the resolved default).
    @State private var columnCount: Int = 3
    @State private var pinchBaseline: Int = 3

    /// Visible-id tracking for the scroll-driven prefetch window. Each cell reports
    /// its appear/disappear; the union is the visible set from which we compute the
    /// windowed slice (visible range ± `windowRowMargin` rows).
    @State private var visibleIDs: Set<String> = []

    /// Flattened chronological id order (all groups concatenated) — the basis for the
    /// prefetch window index math. Built **once** when `dayGroups` changes, alongside
    /// `indexByID`, so windowing stays O(visible) per scroll tick across sections.
    @State private var orderedIDs: [String] = []

    /// `id → index` map over `orderedIDs`, built once when `dayGroups` changes.
    /// `recomputeWindow` reuses it instead of rebuilding an O(n) dictionary on every
    /// visible-set change / scroll tick.
    @State private var indexByID: [String: Int] = [:]

    /// Coalescing flag for `recomputeWindow`. A burst of cell appear/disappear (a
    /// fast scroll) all flips this true; the first flip schedules a single
    /// `Task { @MainActor }` that does one recompute per runloop turn.
    @State private var recomputeScheduled = false

    private let spacing: CGFloat = 2
    private let minColumns = 2
    private let maxColumns = 8

    /// Extra rows of lead/trail prefetch beyond the visible range. ±2 rows keeps the
    /// cache one flick ahead of the eye without over-fetching.
    private let windowRowMargin = 2

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: spacing), count: columnCount)
    }

    var body: some View {
        ScrollView {
            // Pinned section headers so the current day-group label stays visible as
            // you scroll through it — the grid reads as one chronological flow split
            // into adaptive day-groups (busy days alone, quiet runs merged).
            LazyVGrid(columns: columns, spacing: spacing, pinnedViews: [.sectionHeaders]) {
                ForEach(dayGroups) { group in
                    Section {
                        ForEach(group.assetIDs, id: \.self) { id in
                            cell(for: id)
                                .id(id)
                        }
                    } header: {
                        sectionHeader(group)
                    }
                }
            }
            .scrollTargetLayout()
        }
        // `.scrollPosition` restores to the source cell after a zoom dismiss (D22).
        // The anchor is updated by the pager on swipe so we land back on the photo
        // the user ended on.
        .scrollPosition(id: $scrollAnchorID, anchor: .center)
        .animation(.snappy, value: columnCount)
        // Pinch anywhere on the grid to change density. Pinch out → fewer, larger
        // columns; pinch in → more, smaller. Clamped to [minColumns, maxColumns].
        .gesture(
            MagnifyGesture()
                .onChanged { value in
                    let proposed = Double(pinchBaseline) / value.magnification
                    columnCount = min(maxColumns, max(minColumns, Int(proposed.rounded())))
                }
                .onEnded { _ in pinchBaseline = columnCount }
        )
        // Build the flattened order + id → index map once for the initial slice, and
        // prime the head on first layout so the first screen is cached before any
        // cell's `onAppear` has reported a visible id.
        .onAppear {
            if indexByID.isEmpty { rebuildIndex() }
            scheduleRecomputeWindow()
        }
        // Recompute the prefetch window whenever the visible set or the column count
        // changes (column count changes how many rows the margin spans). Coalesced:
        // a burst of appear/disappear does at most one recompute per runloop turn.
        .onChange(of: visibleIDs) { scheduleRecomputeWindow() }
        .onChange(of: columnCount) { scheduleRecomputeWindow() }
        .onChange(of: groupIdentity) {
            // New slice: rebuild the flattened order + id → index map once, drop
            // stale visibility, and re-window from scratch.
            rebuildIndex()
            visibleIDs = visibleIDs.intersection(indexByID.keys)
            scheduleRecomputeWindow()
        }
    }

    /// A cheap identity for the current grouping so `.onChange` fires on a new slice
    /// without comparing every group's payload. The first id of the first group plus
    /// the slice size changes whenever the fetch changes.
    private var groupIdentity: String {
        "\(dayGroups.first?.id ?? "∅")#\(orderedIDsCount)"
    }
    private var orderedIDsCount: Int { dayGroups.reduce(0) { $0 + $1.assetIDs.count } }

    // MARK: Section header (adaptive day-group label)

    private func sectionHeader(_ group: AssetDayGroup) -> some View {
        HStack(spacing: 6) {
            // Tint busy days (their own group, ≥ N) so the author can *see* the
            // adaptive heuristic at work vs the merged quiet runs while re-evaluating.
            if group.isBusyDay {
                Circle().fill(.tint).frame(width: 6, height: 6)
            }
            Text(group.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(group.isBusyDay ? Color.accentColor : Color.primary)
            Text("· \(group.count)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        // A pinned header floats over the grid; back it so cells don't show through.
        .background(.bar)
    }

    // MARK: Cell

    /// One square cell with the resolved badge-select mapping: tapping the cell opens
    /// full-screen, tapping the 44pt badge zone selects. No runtime toggle.
    private func cell(for id: String) -> some View {
        ThumbnailCell(
            id: id,
            isSelected: isSelected(id),
            load: load
        )
        // Source for the zoom transition, keyed by localIdentifier (D10).
        .matchedTransitionSource(id: id, in: zoomNamespace)
        // Whole-cell tap opens full-screen (badge-select mapping, resolved by the spike).
        .onTapGesture {
            scrollAnchorID = id
            openAsset(id)
        }
        // 44pt badge zone bottom-trailing — a tap here beats the whole-cell tap so the
        // badge wins, and toggles selection (the resolved badge-select mapping).
        .overlay(alignment: .bottomTrailing) {
            Color.clear
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
                .onTapGesture { toggleSelection(id) }
        }
        // Track visibility for the scroll-driven prefetch window.
        .onAppear { visibleIDs.insert(id) }
        .onDisappear { visibleIDs.remove(id) }
    }

    // MARK: Prefetch window

    /// Rebuild the flattened chronological order + `id → index` map for the current
    /// slice. Called once when the grouping changes (and on first appear) — not per
    /// scroll tick — so the O(n) build happens once per slice instead of per event.
    private func rebuildIndex() {
        orderedIDs = dayGroups.flatMap(\.assetIDs)
        indexByID = Dictionary(
            uniqueKeysWithValues: orderedIDs.enumerated().map { ($1, $0) })
    }

    /// Coalesce recompute requests: a burst of cell appear/disappear (a fast scroll)
    /// sets the flag once and schedules a single `recomputeWindow()` on the next
    /// runloop turn, so we do at most one recompute per turn.
    private func scheduleRecomputeWindow() {
        guard !recomputeScheduled else { return }
        recomputeScheduled = true
        Task { @MainActor in
            recomputeScheduled = false
            recomputeWindow()
        }
    }

    /// Compute the windowed slice — visible index range (over the *flattened*
    /// chronological order, so it spans section boundaries) expanded by
    /// `windowRowMargin` rows on each side — and hand it to the caller to prefetch.
    /// Reuses the cached `indexByID` so this is O(visible), not O(slice), per call.
    private func recomputeWindow() {
        let count = orderedIDs.count
        guard count > 0 else {
            updateWindow([])
            return
        }
        guard !visibleIDs.isEmpty else {
            // Before any cell has reported (first layout), prime the head of the
            // slice so the first screen is cached without waiting for `onAppear`.
            let headCount = min(count, columnCount * (windowRowMargin + 1) * 2)
            updateWindow(Array(orderedIDs.prefix(headCount)))
            return
        }

        // Reuse the cached id → index map; only the (small) visible set is scanned.
        var minVisible = Int.max
        var maxVisible = Int.min
        for id in visibleIDs {
            guard let idx = indexByID[id] else { continue }
            if idx < minVisible { minVisible = idx }
            if idx > maxVisible { maxVisible = idx }
        }
        guard minVisible <= maxVisible else {
            updateWindow([])
            return
        }
        let margin = columnCount * windowRowMargin
        let lower = max(0, minVisible - margin)
        let upper = min(count - 1, maxVisible + margin)
        updateWindow(Array(orderedIDs[lower...upper]))
    }
}
