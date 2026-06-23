//
//  AssetGridView.swift
//  PoimiApp — Spike render layer
//
//  RENDER LAYER — promotable. The review grid: `LazyVGrid` in a `ScrollView`,
//  `.scrollPosition` restore to the source cell on dismiss, `.matchedTransitionSource`
//  for the `.navigationTransition(.zoom)` expand, and **pinch-to-adjust column
//  density** (default 3, per the ★ picking-interaction questions). It drives the
//  `ThumbnailImageManager` prefetch window from the visible range.
//
//  This is the salvageable tier (D1). It deliberately knows nothing about how the
//  assets/selection are sourced — that's injected — so it promotes cleanly.
//
//  Tap mapping (spike): badge tap → toggle select; cell tap → open full-screen.
//  This is one of the two mappings the ★ spike pressure-tests on a real library.

import Photos
import SwiftUI

struct AssetGridView: View {
    let assets: [PHAsset]
    let imageManager: ThumbnailImageManager

    /// Selection set membership and toggle, owned by the caller (in-memory `Set`).
    let isSelected: (PHAsset) -> Bool
    let toggleSelection: (PHAsset) -> Void

    /// Opening a cell full-screen — the caller pushes the pager onto the stack.
    let openAsset: (PHAsset) -> Void

    /// Namespace for the zoom matched-transition source/destination pairing.
    let zoomNamespace: Namespace.ID

    /// The asset to restore scroll position to (the source cell of the last
    /// expand). Bound so the pager can update it on swipe and the grid scrolls
    /// back to it on return.
    @Binding var scrollAnchorID: String?

    /// Column density, pinch-adjustable. Default 3 on iPhone (the ★ default).
    @State private var columnCount: Int = 3
    @State private var pinchBaseline: Int = 3

    private let spacing: CGFloat = 2
    private let minColumns = 2
    private let maxColumns = 8

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: spacing), count: columnCount)
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: spacing) {
                ForEach(assets, id: \.localIdentifier) { asset in
                    cell(for: asset)
                        .id(asset.localIdentifier)
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
    }

    @ViewBuilder
    private func cell(for asset: PHAsset) -> some View {
        ThumbnailCell(
            asset: asset,
            isSelected: isSelected(asset),
            imageManager: imageManager
        )
        // Source for the zoom transition, keyed by localIdentifier (D10).
        .matchedTransitionSource(id: asset.localIdentifier, in: zoomNamespace)
        // Whole-cell tap → open full-screen (this mapping is one of the two the
        // ★ spike compares; the other is whole-cell-tap → select).
        .onTapGesture {
            scrollAnchorID = asset.localIdentifier
            openAsset(asset)
        }
        // Badge corner tap → toggle selection. The 44pt badge sits bottom-trailing;
        // a high-priority tap there beats the cell-open tap so the badge wins.
        .overlay(alignment: .bottomTrailing) {
            Color.clear
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
                .onTapGesture { toggleSelection(asset) }
        }
    }
}
