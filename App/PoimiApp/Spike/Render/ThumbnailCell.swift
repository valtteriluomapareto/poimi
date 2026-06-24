//
//  ThumbnailCell.swift
//  PoimiApp — Spike render layer
//
//  RENDER LAYER — promotable. A single grid cell: loads its thumbnail via an
//  injected `load(id:)` closure, cancels on recycle (`.task(id:)`), and renders
//  the selection affordance (redundant encoding: checkmark badge + dim, per D9).
//
//  Cell shape is **square** (resolved by the spike, Part B — "square is good";
//  square scans fastest). The earlier square/aspect A/B and its dead aspect path
//  were removed once the question was settled.
//
//  Typed on `id: String` (localIdentifier) + closures — never on `PHAsset` — so
//  it stays `Sendable`-value-shaped and lifts behind the protocol seam in Phase 1
//  with no type substitution (D17/§2: a live `PHAsset` never crosses to the view).
//  Actual PhotoKit access lives inside `ThumbnailImageManager`.
//
//  Not throwaway: this is the salvageable tier.

import SwiftUI
import UIKit

/// One photo cell in the review grid. Fixed 1:1 square.
struct ThumbnailCell: View {
    /// The asset's `localIdentifier` — the only identity the view tier carries.
    let id: String
    let isSelected: Bool

    /// Inject the thumbnail load. The closure owns the `PHAsset` / PhotoKit access
    /// (it's backed by `ThumbnailImageManager`); the view stays value-shaped.
    let load: (String) async -> UIImage?

    @State private var image: UIImage?

    var body: some View {
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
        .aspectRatio(1, contentMode: .fit)   // fixed square (resolved)
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
