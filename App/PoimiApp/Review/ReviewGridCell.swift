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
    /// A synchronous cache lookup (the `ThumbnailProviding` front) so a recycled cell can paint an
    /// already-loaded image immediately instead of flashing a placeholder (Finding 2). Returns `nil`
    /// on a miss, which falls back to `load`.
    let cachedImage: (String) -> UIImage?
    /// Open this cell full-screen (the parent pushes the viewer + records the scroll anchor, #36).
    let onOpen: () -> Void
    /// Pairs the cell with the `.zoom` viewer destination (#36).
    let zoomNamespace: Namespace.ID

    @Environment(SelectionStore.self) private var selection
    @State private var image: UIImage?
    /// The id that `image` was loaded for. On recycle the cell instance is reused with a new `id`
    /// while `image` still holds the previous asset's thumbnail, so this guards against painting a
    /// stale image — we trust `image` only when it matches the current `id`.
    @State private var loadedID: String?

    var body: some View {
        let isSelected = selection.contains(id)
        // Decide what to paint *now*, synchronously: the matching loaded image, else a synchronous
        // cache hit (no placeholder flash), else the placeholder. A cache read is O(1) — not the
        // "heavy work in a body" the smoothness convention forbids.
        let display = thumbnailDisplay(loadedID: loadedID, cellID: id, loaded: image, cached: cachedImage(id))
        ZStack {
            Color(.secondarySystemBackground)
            switch display {
            case .image(let uiImage):
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
            case .placeholder:
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
            // Synchronous cache hit → adopt it without ever showing the placeholder (Finding 2).
            if let hit = cachedImage(id) {
                image = hit
                loadedID = id
                return
            }
            // Cold load: clear the stale image so the placeholder (not the previous asset) shows,
            // then await the real thumbnail.
            image = nil
            loadedID = nil
            let loaded = await load(id)
            // If the cell recycled while awaiting, this task is cancelled and a fresh one runs for
            // the new id — don't commit this (now-stale) result over it.
            guard !Task.isCancelled else { return }
            image = loaded
            loadedID = id
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

/// What a grid cell should paint right now. Pulled out of the view as a pure function so the
/// "never flash a placeholder when an image is available" rule (Finding 2) is unit-tested without
/// rendering — the regression is "a recycle with a cache hit shows `.placeholder`".
enum ThumbnailDisplay {
    case image(UIImage)
    case placeholder
}

/// Resolve the cell's display from its load state and a synchronous cache lookup:
///   1. the loaded image, but only if it belongs to the current cell id (else it is stale);
///   2. otherwise a synchronous cache hit (a recycle onto a primed asset — no placeholder);
///   3. otherwise the placeholder (a genuine cold load).
func thumbnailDisplay(loadedID: String?, cellID: String, loaded: UIImage?, cached: UIImage?) -> ThumbnailDisplay {
    if loadedID == cellID, let loaded { return .image(loaded) }
    if let cached { return .image(cached) }
    return .placeholder
}
