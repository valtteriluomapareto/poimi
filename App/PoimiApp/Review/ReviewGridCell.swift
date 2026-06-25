//
//  ReviewGridCell.swift
//  PoimiApp — one photo cell in the review grid (issue #35; promoted from the spike's ThumbnailCell).
//
//  Fixed 1:1 square (resolved by the spike — square scans fastest). Loads its thumbnail via an
//  injected `load(id:)` closure and cancels on recycle (`.task(id:)`). Selection uses redundant
//  encoding (D9): a filled checkmark badge AND a dim overlay, so the state survives color-blindness
//  and bright thumbnails.
//
//  The cell observes the shared `SelectionStore` itself (rather than taking `isSelected` from the
//  parent) so a toggle re-renders only the visible cells, not the whole grid body — and the light
//  selection haptic (design language) fires exactly when *this* cell's membership flips.
//

import SwiftUI
import UIKit

struct ReviewGridCell: View {
    /// The asset's `localIdentifier` — the only identity the view tier carries.
    let id: String
    /// Inject the thumbnail load; the closure owns PhotoKit access (the seam), so the cell stays
    /// free of any live `PHAsset`.
    let load: (String) async -> UIImage?
    /// Open this cell full-screen (the parent pushes the viewer + records the scroll anchor, #36).
    let onOpen: () -> Void
    /// Pairs the cell with the `.zoom` viewer destination (#36).
    let zoomNamespace: Namespace.ID

    @Environment(SelectionStore.self) private var selection
    @State private var image: UIImage?

    var body: some View {
        let isSelected = selection.contains(id)
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
        .overlay(alignment: .bottomTrailing) { selectionBadge(isSelected) }
        .matchedTransitionSource(id: id, in: zoomNamespace)
        .contentShape(Rectangle())
        .onTapGesture { onOpen() }
        // VoiceOver: double-tap opens; a named rotor action selects (the badge is a touch target).
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Photo")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { onOpen() }
        .accessibilityAction(named: isSelected ? "Deselect" : "Select") { selection.toggle(id) }
        // Instant light haptic on this cell's own select/deselect (design language).
        .sensoryFeedback(.selection, trigger: isSelected)
        // Reloads when the cell recycles onto a new asset and cancels the previous in-flight request.
        .task(id: id) {
            image = nil
            image = await load(id)
        }
    }

    /// Redundant selection encoding: a filled checkmark when selected, an empty ring otherwise,
    /// centered in a ≥44pt corner tap target that toggles selection (the parent's open-tap handles
    /// the rest of the cell, D9).
    private func selectionBadge(_ isSelected: Bool) -> some View {
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
            .contentShape(Rectangle())
            .onTapGesture { selection.toggle(id) }
    }
}
