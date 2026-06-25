//
//  ReviewGridCell.swift
//  PoimiApp — one photo cell in the review grid (issue #35; promoted from the spike's ThumbnailCell).
//
//  Fixed 1:1 square (resolved by the spike — square scans fastest). Loads its thumbnail via an
//  injected `load(id:)` closure and cancels on recycle (`.task(id:)`). Selection uses redundant
//  encoding (D9): a filled checkmark badge AND a dim overlay, so the state survives color-blindness
//  and bright thumbnails. Value-shaped (`id: String` + `Bool` + closure) — no `PHAsset`, no store.
//

import SwiftUI
import UIKit

struct ReviewGridCell: View {
    /// The asset's `localIdentifier` — the only identity the view tier carries.
    let id: String
    let isSelected: Bool
    /// Inject the thumbnail load; the closure owns PhotoKit access (the seam), so the cell stays
    /// value-shaped.
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
                Color.black.opacity(0.28)   // dim — redundant with the badge (D9)
            }
        }
        .overlay(alignment: .bottomTrailing) { selectionBadge }
        .contentShape(Rectangle())
        // Reloads when the cell recycles onto a new asset and cancels the previous in-flight request.
        .task(id: id) {
            image = nil
            image = await load(id)
        }
    }

    /// Redundant selection encoding: a filled checkmark when selected, an empty ring otherwise,
    /// centered in a ≥44pt corner zone (the parent overlays the matching tap target, D9).
    private var selectionBadge: some View {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(.title3)
            .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.9))
            .background(
                Circle()
                    .fill(isSelected ? Color.accentColor : Color.black.opacity(0.25))
                    .padding(2)
            )
            .shadow(radius: 1)
            .frame(width: 44, height: 44)
    }
}
