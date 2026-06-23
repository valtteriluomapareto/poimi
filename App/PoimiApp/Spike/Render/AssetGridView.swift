//
//  AssetGridView.swift
//  PoimiApp — Spike render layer
//
//  RENDER LAYER — promotable. The review grid: `LazyVGrid` in a `ScrollView`,
//  `.scrollPosition` restore to the source cell on dismiss, `.matchedTransitionSource`
//  for the `.navigationTransition(.zoom)` expand, and **pinch-to-adjust column
//  density** (default 3, per the ★ picking-interaction questions). It drives the
//  `ThumbnailImageManager` prefetch window from the *visible range* (Fix 2), so the
//  windowing — the "does it stay smooth over thousands of assets" exit criterion —
//  is actually exercised under scroll rather than primed once with the whole slice.
//
//  This is the salvageable tier (D1). It deliberately knows nothing about how the
//  assets/selection are sourced — that's injected as plain `id: String` values
//  (localIdentifiers) plus closures, never a live `[PHAsset]` (D17/§2). So it is
//  `Sendable`-value-shaped and promotes behind the protocol seam with no type
//  substitution pass — the `assetIDs` become an `AssetRef`-id snapshot in Phase 1.
//
//  Two ★ A/B controls live in the grid's top bar so the author can flip them on the
//  same real year in one session:
//    • Tap mapping (the #5 PRIMARY GATE): which gesture selects vs opens —
//        A) badge tap → select, cell tap → open   [default]
//        B) cell tap → select, long-press → open  (inspect via long-press; pinch is
//           taken by density)
//    • Cell shape: square (scan faster, crops framing) vs aspect (natural framing).

import SwiftUI
import UIKit

/// Which gesture selects and which opens — the ★ primary-gate A/B (issue #5).
enum TapMapping: String, CaseIterable, Identifiable {
    /// Badge tap → select; whole-cell tap → open full-screen. [plan default]
    case badgeSelect = "Badge select"
    /// Whole-cell tap → select; long-press → open full-screen.
    case cellSelect = "Tap select"

    var id: Self { self }
}

/// Square cells scan faster but crop framing; aspect cells show the real shot.
enum CellShape: String, CaseIterable, Identifiable {
    case square = "Square"
    case aspect = "Aspect"

    var id: Self { self }
}

struct AssetGridView: View {
    /// Ordered `localIdentifier`s of the slice — the value snapshot the grid
    /// renders. No `PHAsset` crosses into the view tier.
    let assetIDs: [String]

    /// Thumbnail load by id. Backed by `ThumbnailImageManager` in the caller;
    /// the closure owns the PhotoKit access so the view stays value-shaped.
    let load: (String) async -> UIImage?

    /// Natural aspect ratio (width / height) for `id`, used by the aspect cell
    /// shape. Injected so the view never touches a `PHAsset`; the caller resolves
    /// it (the throwaway model reads `pixelWidth`/`pixelHeight`). `nil` → fall back
    /// to square framing for that cell.
    let aspectRatio: (String) -> CGFloat?

    /// Selection set membership and toggle, owned by the caller (in-memory `Set`).
    let isSelected: (String) -> Bool
    let toggleSelection: (String) -> Void

    /// Opening a cell full-screen — the caller pushes the pager onto the stack.
    let openAsset: (String) -> Void

    /// Report the windowed slice (visible range ± a row margin) to prefetch (Fix 2).
    /// The caller resolves these ids to live `PHAsset`s and feeds the
    /// `ThumbnailImageManager` caching window. Driven from the visible range below,
    /// so the windowing is exercised as the user scrolls — not primed once.
    let updateWindow: ([String]) -> Void

    /// Namespace for the zoom matched-transition source/destination pairing.
    let zoomNamespace: Namespace.ID

    /// The asset to restore scroll position to (the source cell of the last
    /// expand). Bound so the pager can update it on swipe and the grid scrolls
    /// back to it on return.
    @Binding var scrollAnchorID: String?

    /// Column density, pinch-adjustable. Default 3 on iPhone (the ★ default).
    @State private var columnCount: Int = 3
    @State private var pinchBaseline: Int = 3

    /// ★ A/B controls (default to the plan's mapping + square shape).
    @State private var tapMapping: TapMapping = .badgeSelect
    /// Cell shape (Fix 4). `square`/`aspect` is a plain parameter on `ThumbnailCell`,
    /// so flipping it does **not** change any cell's identity (the cells stay keyed
    /// by `.id(id)`) — no subtree teardown, no `onAppear`/`onDisappear` churn.
    /// `aspect` does change row heights → a `LazyVGrid` relayout; any visibility
    /// changes that produces are coalesced by `scheduleRecomputeWindow()` into one
    /// window recompute per runloop turn, so the relayout can't re-trigger a churn
    /// storm under `.scrollPosition(id:)`.
    @State private var cellShape: CellShape = .square

    /// Visible-id tracking for the scroll-driven prefetch window (Fix 2). Each cell
    /// reports its appear/disappear; the union is the visible set from which we
    /// compute the windowed slice (visible range ± `windowRowMargin` rows).
    @State private var visibleIDs: Set<String> = []

    /// `id → index` map for the current slice, built **once** when `assetIDs`
    /// changes (Fix 2). `recomputeWindow` reuses it instead of rebuilding an O(n)
    /// dictionary over the whole slice on every visible-set change / scroll tick.
    @State private var indexByID: [String: Int] = [:]

    /// Coalescing flag for `recomputeWindow` (Fix 2). A burst of cell
    /// appear/disappear (a toggle, a fast scroll) all flips this true; the first
    /// flip schedules a single `Task { @MainActor }` that does one recompute per
    /// runloop turn, instead of one recompute per individual mutation.
    @State private var recomputeScheduled = false

    private let spacing: CGFloat = 2
    private let minColumns = 2
    private let maxColumns = 8

    /// Extra rows of lead/trail prefetch beyond the visible range (Fix 2). ±2 rows
    /// keeps the cache one flick ahead of the eye without over-fetching.
    private let windowRowMargin = 2

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: spacing), count: columnCount)
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            grid
        }
    }

    // MARK: Controls (★ A/B toggles)

    private var controls: some View {
        HStack(spacing: 12) {
            Picker("Tap", selection: $tapMapping) {
                ForEach(TapMapping.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            Picker("Shape", selection: $cellShape) {
                ForEach(CellShape.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 140)
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
    }

    // MARK: Grid

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: spacing) {
                ForEach(assetIDs, id: \.self) { id in
                    cell(for: id)
                        .id(id)
                }
            }
            .scrollTargetLayout()
        }
        // `.scrollPosition` restores to the source cell after a zoom dismiss
        // (post-condition we verify per D22). The anchor is updated by the pager
        // on swipe so we land back on the photo the user ended on.
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
        // Build the id → index map once for the initial slice, and prime the head
        // of the slice on first layout so the first screen is cached before any
        // cell's `onAppear` has reported a visible id.
        .onAppear {
            if indexByID.isEmpty { rebuildIndex() }
            scheduleRecomputeWindow()
        }
        // Recompute the prefetch window whenever the visible set or the column
        // count changes (column count changes how many rows the margin spans).
        // Coalesced: a burst of appear/disappear (a toggle, a fast scroll) does at
        // most one recompute per runloop turn (Fix 2).
        .onChange(of: visibleIDs) { scheduleRecomputeWindow() }
        .onChange(of: columnCount) { scheduleRecomputeWindow() }
        .onChange(of: assetIDs) {
            // New slice: rebuild the id → index map once, drop stale visibility,
            // and re-window from scratch.
            rebuildIndex()
            visibleIDs = visibleIDs.intersection(indexByID.keys)
            scheduleRecomputeWindow()
        }
    }

    /// One stable cell structure for **both** tap mappings (Fix 1).
    ///
    /// The earlier version `switch`-ed on `tapMapping` and returned a different
    /// modifier chain per case, which compiles to `_ConditionalContent`. Flipping
    /// the toggle changed every visible cell's view identity, tearing the whole
    /// subtree down and rebuilding it — so every cell's `.onAppear`/`.onDisappear`
    /// (attached here, on `base`) fired, churning `visibleIDs`, which re-triggered
    /// `.onChange(of: visibleIDs)` → `recomputeWindow()` for the entire visible
    /// range. At thousands of assets that froze the toggle.
    ///
    /// Now the modifier chain is **structurally identical** regardless of
    /// `tapMapping` — only the closures' behaviour branches. The tap gesture, the
    /// long-press, and the badge tap zone are *always* attached; each is a no-op in
    /// the mode where it doesn't apply. So toggling the tap mapping does not change
    /// view identity, does not re-run `onAppear`/`onDisappear`, and does not churn
    /// `visibleIDs`.
    private func cell(for id: String) -> some View {
        ThumbnailCell(
            id: id,
            isSelected: isSelected(id),
            shape: cellShape,
            aspectRatio: aspectRatio(id),
            load: load
        )
        // Source for the zoom transition, keyed by localIdentifier (D10).
        .matchedTransitionSource(id: id, in: zoomNamespace)
        // Whole-cell tap: opens in mapping (A), selects in mapping (B). Branching
        // the action — not the view tree — keeps identity stable across the toggle.
        .onTapGesture {
            switch tapMapping {
            case .badgeSelect:
                scrollAnchorID = id
                openAsset(id)
            case .cellSelect:
                toggleSelection(id)
            }
        }
        // Long-press opens in mapping (B); inert in mapping (A) (the cell tap opens
        // there). Always attached so the toggle doesn't add/remove a gesture.
        .onLongPressGesture(minimumDuration: 0.3) {
            guard tapMapping == .cellSelect else { return }
            scrollAnchorID = id
            openAsset(id)
        }
        // 44pt badge zone bottom-trailing — always present; a tap there beats the
        // whole-cell tap so the badge wins. It always toggles selection: in mapping
        // (A) that's the badge's job; in mapping (B) the whole cell selects too, so
        // a corner tap selecting is consistent. (No identity swap on toggle.)
        .overlay(alignment: .bottomTrailing) {
            Color.clear
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
                .onTapGesture { toggleSelection(id) }
        }
        // Track visibility for the scroll-driven prefetch window (Fix 2).
        .onAppear { visibleIDs.insert(id) }
        .onDisappear { visibleIDs.remove(id) }
    }

    // MARK: Prefetch window (Fix 2)

    /// Rebuild the `id → index` map for the current slice. Called once when
    /// `assetIDs` changes (and on first appear) — not per scroll tick — so the
    /// O(n) build happens once per slice instead of once per event.
    private func rebuildIndex() {
        indexByID = Dictionary(
            uniqueKeysWithValues: assetIDs.enumerated().map { ($1, $0) })
    }

    /// Coalesce recompute requests: a burst of cell appear/disappear (a toggle, a
    /// fast scroll) sets the flag once and schedules a single `recomputeWindow()`
    /// on the next runloop turn, so we do at most one recompute per turn instead of
    /// one per individual `visibleIDs` mutation.
    private func scheduleRecomputeWindow() {
        guard !recomputeScheduled else { return }
        recomputeScheduled = true
        Task { @MainActor in
            recomputeScheduled = false
            recomputeWindow()
        }
    }

    /// Compute the windowed slice — visible index range expanded by
    /// `windowRowMargin` rows on each side — and hand it to the caller to prefetch.
    /// Driven from the visible set, so it tracks the scroll and exercises the
    /// `ThumbnailImageManager` windowing under load. Reuses the cached `indexByID`
    /// (built once per slice) so this is O(visible), not O(slice), per call.
    private func recomputeWindow() {
        let count = assetIDs.count
        guard count > 0 else {
            updateWindow([])
            return
        }
        guard !visibleIDs.isEmpty else {
            // Before any cell has reported (first layout), prime the head of the
            // slice so the first screen is cached without waiting for `onAppear`.
            let headCount = min(count, columnCount * (windowRowMargin + 1) * 2)
            updateWindow(Array(assetIDs.prefix(headCount)))
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
        updateWindow(Array(assetIDs[lower...upper]))
    }
}
