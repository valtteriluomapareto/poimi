//
//  ThumbnailCell.swift
//  PoimiApp — Spike render layer
//
//  RENDER LAYER — promotable. A single grid cell: loads its thumbnail via the
//  `ThumbnailImageManager`, cancels on recycle (`.task(id:)`), and renders the
//  selection affordance (redundant encoding: checkmark badge + dim, per D9). The
//  cell's *shape* (square) and the badge hit target (≥44pt) are spike-tunable.
//
//  Not throwaway: this is the salvageable tier.

import Photos
import SwiftUI

/// One photo cell in the review grid.
struct ThumbnailCell: View {
    let asset: PHAsset
    let isSelected: Bool
    let imageManager: ThumbnailImageManager

    @State private var image: UIImage?

    var body: some View {
        GeometryReader { proxy in
            let side = proxy.size.width
            ZStack {
                Color(.secondarySystemBackground)
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .frame(width: side, height: side)
            .clipped()
            .overlay {
                if isSelected {
                    Color.black.opacity(0.28)   // dim — redundant with the badge
                }
            }
            .overlay(alignment: .bottomTrailing) {
                selectionBadge
            }
            .contentShape(Rectangle())
        }
        .aspectRatio(1, contentMode: .fit)   // square cells — scan faster
        // `.task(id:)` reloads when the cell is recycled onto a new asset and
        // cancels the in-flight request for the previous asset.
        .task(id: asset.localIdentifier) {
            image = nil
            image = await imageManager.thumbnail(for: asset)
        }
    }

    /// Redundant selection encoding: a filled checkmark when selected, an empty
    /// ring when not. The tappable target is enlarged by the parent's badge tap
    /// area; here we render the glyph centered in a ≥44pt corner zone.
    private var selectionBadge: some View {
        ZStack {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.9))
                .background(
                    Circle()
                        .fill(isSelected ? Color.accentColor : Color.black.opacity(0.25))
                        .padding(2)
                )
                .shadow(radius: 1)
        }
        .frame(width: 44, height: 44)   // ≥44pt hit target (D9)
    }
}
