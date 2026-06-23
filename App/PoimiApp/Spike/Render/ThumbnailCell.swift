//
//  ThumbnailCell.swift
//  PoimiApp — Spike render layer
//
//  RENDER LAYER — promotable. A single grid cell: loads its thumbnail via an
//  injected `load(id:)` closure, cancels on recycle (`.task(id:)`), and renders
//  the selection affordance (redundant encoding: checkmark badge + dim, per D9).
//  The cell's *shape* (square vs aspect — Fix 3) and the badge hit target (≥44pt)
//  are spike-tunable so the ★ "square scans faster vs aspect shows the real shot"
//  question can be felt on a real library.
//
//  Typed on `id: String` (localIdentifier) + closures — never on `PHAsset` — so
//  it stays `Sendable`-value-shaped and lifts behind the protocol seam in Phase 1
//  with no type substitution (D17/§2: a live `PHAsset` never crosses to the view).
//  Actual PhotoKit access lives inside `ThumbnailImageManager`; the natural aspect
//  ratio is injected as a plain `CGFloat?`.
//
//  Not throwaway: this is the salvageable tier.

import SwiftUI
import UIKit

/// One photo cell in the review grid.
struct ThumbnailCell: View {
    /// The asset's `localIdentifier` — the only identity the view tier carries.
    let id: String
    let isSelected: Bool

    /// Square (fixed 1:1) or aspect (the asset's natural ratio so framing isn't
    /// cropped) — the ★ A/B (Fix 3).
    let shape: CellShape

    /// Natural aspect ratio (width / height). `nil` → fall back to square so an
    /// unknown ratio never collapses the cell.
    let aspectRatio: CGFloat?

    /// Inject the thumbnail load. The closure owns the `PHAsset` / PhotoKit access
    /// (it's backed by `ThumbnailImageManager`); the view stays value-shaped.
    let load: (String) async -> UIImage?

    @State private var image: UIImage?

    /// The aspect ratio the cell lays out at: 1:1 for square, the natural ratio
    /// (clamped to a sane range) for aspect.
    private var layoutAspect: CGFloat {
        switch shape {
        case .square:
            return 1
        case .aspect:
            guard let aspectRatio, aspectRatio.isFinite, aspectRatio > 0 else { return 1 }
            // Clamp to keep extreme panoramas/strips from blowing out a grid row.
            return min(2.2, max(0.45, aspectRatio))
        }
    }

    /// Square crops to fill; aspect fits the whole frame (no crop — that's the point).
    private var contentFill: Bool { shape == .square }

    var body: some View {
        ZStack {
            Color(.secondarySystemBackground)
            if let image {
                if contentFill {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                }
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .aspectRatio(layoutAspect, contentMode: .fit)
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
        // `.task(id:)` reloads when the cell is recycled onto a new asset and
        // cancels the in-flight request for the previous asset.
        .task(id: id) {
            image = nil
            image = await load(id)
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
