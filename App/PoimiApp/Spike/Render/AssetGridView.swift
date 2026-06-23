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
    @State private var cellShape: CellShape = .square

    /// Visible-id tracking for the scroll-driven prefetch window (Fix 2). Each cell
    /// reports its appear/disappear; the union is the visible set from which we
    /// compute the windowed slice (visible range ± `windowRowMargin` rows).
    @State private var visibleIDs: Set<String> = []

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
        // Prime the head of the slice on first layout so the first screen is
        // cached before any cell's `onAppear` has reported a visible id.
        .onAppear { recomputeWindow() }
        // Recompute the prefetch window whenever the visible set or the column
        // count changes (column count changes how many rows the margin spans).
        .onChange(of: visibleIDs) { recomputeWindow() }
        .onChange(of: columnCount) { recomputeWindow() }
        .onChange(of: assetIDs) {
            // New slice: drop stale visibility and re-window from scratch.
            visibleIDs = visibleIDs.intersection(assetIDs)
            recomputeWindow()
        }
    }

    @ViewBuilder
    private func cell(for id: String) -> some View {
        let base = ThumbnailCell(
            id: id,
            isSelected: isSelected(id),
            shape: cellShape,
            aspectRatio: aspectRatio(id),
            load: load
        )
        // Source for the zoom transition, keyed by localIdentifier (D10).
        .matchedTransitionSource(id: id, in: zoomNamespace)
        // Track visibility for the scroll-driven prefetch window (Fix 2).
        .onAppear { visibleIDs.insert(id) }
        .onDisappear { visibleIDs.remove(id) }

        switch tapMapping {
        case .badgeSelect:
            // (A) Whole-cell tap → open; badge corner tap → toggle selection.
            base
                .onTapGesture {
                    scrollAnchorID = id
                    openAsset(id)
                }
                // 44pt badge zone bottom-trailing; a high-priority tap there beats
                // the cell-open tap so the badge wins.
                .overlay(alignment: .bottomTrailing) {
                    Color.clear
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                        .onTapGesture { toggleSelection(id) }
                }
        case .cellSelect:
            // (B) Whole-cell tap → toggle selection; long-press → open full-screen
            // (inspect via long-press, since pinch is taken by density). The badge
            // still renders (redundant select encoding) but isn't its own tap zone
            // here — the whole cell selects.
            base
                .onTapGesture { toggleSelection(id) }
                .onLongPressGesture(minimumDuration: 0.3) {
                    scrollAnchorID = id
                    openAsset(id)
                }
        }
    }

    // MARK: Prefetch window (Fix 2)

    /// Compute the windowed slice — visible index range expanded by
    /// `windowRowMargin` rows on each side — and hand it to the caller to prefetch.
    /// Driven from the visible set, so it tracks the scroll and exercises the
    /// `ThumbnailImageManager` windowing under load.
    private func recomputeWindow() {
        guard !assetIDs.isEmpty else {
            updateWindow([])
            return
        }
        guard !visibleIDs.isEmpty else {
            // Before any cell has reported (first layout), prime the head of the
            // slice so the first screen is cached without waiting for `onAppear`.
            let headCount = min(assetIDs.count, columnCount * (windowRowMargin + 1) * 2)
            updateWindow(Array(assetIDs.prefix(headCount)))
            return
        }

        // Map the visible ids to their indices, then expand by the row margin.
        let indexByID = Dictionary(
            uniqueKeysWithValues: assetIDs.enumerated().map { ($1, $0) })
        let visibleIndices = visibleIDs.compactMap { indexByID[$0] }
        guard let minVisible = visibleIndices.min(),
              let maxVisible = visibleIndices.max() else {
            updateWindow([])
            return
        }
        let margin = columnCount * windowRowMargin
        let lower = max(0, minVisible - margin)
        let upper = min(assetIDs.count - 1, maxVisible + margin)
        updateWindow(Array(assetIDs[lower...upper]))
    }
}
