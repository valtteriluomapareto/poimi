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
    /// The cell's day-group title, for the VoiceOver label — so a wall of cells reads "Photo, Sat
    /// Jul 5" rather than an undifferentiated "Photo, Photo, Photo".
    let dayLabel: String
    /// A video's formatted running time ("0:14"), or `nil` for a still (#125). Non-nil ⇒ the cell paints
    /// a corner video badge and reads as "Video" to VoiceOver. Precomputed by the parent (a dictionary
    /// lookup + pure format) so the cell body does no work.
    var videoBadge: String? = nil
    /// Inject the thumbnail load; the closure owns PhotoKit access (the seam), so the cell stays
    /// free of any live `PHAsset`.
    let load: (String) async -> UIImage?
    /// A synchronous cache lookup (the `ThumbnailProviding` front) so a recycled cell can paint an
    /// already-loaded image immediately instead of flashing a placeholder (Finding 2). Returns `nil`
    /// on a miss, which falls back to `load`.
    let cachedImage: (String) -> UIImage?
    /// Open this cell full-screen (the parent pushes the viewer + records the scroll anchor, #36).
    let onOpen: () -> Void

    @Environment(SelectionStore.self) private var selection
    @State private var image: UIImage?
    /// Small corner rounding, Apple-Photos-style — pairs with the grid's small inter-cell gap. Both
    /// selection overlays (dim, border) round to the same radius so they hug the clipped photo.
    private let cornerRadius: CGFloat = 6
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
        // A flexible square sized by the column width (`Color` has no intrinsic size, so the photo's
        // own dimensions can't drive layout). The photo OVERLAYS that square and is clipped to it, so
        // a landscape/portrait shot fills + crops instead of overflowing into the neighbouring cell
        // (the earlier `ZStack { … }.aspectRatio.clipped()` let `scaledToFill`'s natural size leak when
        // the grid proposed an unbounded height).
        Color(.secondarySystemBackground)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
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
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.black.opacity(0.28))   // dim — redundant with the badge (D9)
                    .allowsHitTesting(false)
            }
        }
        .overlay {
            if isSelected {
                // The third selection layer (styleguide §6): a green inset border. The gold check stays
                // the affordance; the border marks the selected cell at a glance (now that the grid has
                // gaps, separation comes from the gutter, so this reads purely as selection). Rounds to
                // the cell radius; `strokeBorder` insets so it isn't clipped; non-interactive so its ring
                // can't absorb an edge tap. BRAND green (§6 secondary), matching the done seal.
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.brandGreen, lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
        // Video badge bottom-leading (opposite the top-trailing selection check so they never collide):
        // a play glyph + running time, Apple-Photos-style. Non-interactive so a tap anywhere still opens.
        .overlay(alignment: .bottomLeading) {
            if let videoBadge { videoDurationBadge(videoBadge) }
        }
        // Badge top-trailing (Paper design): the gold check sits in the top-right corner.
        .overlay(alignment: .topTrailing) { selectionBadge(isSelected) }
        .contentShape(Rectangle())
        .onTapGesture { onOpen() }
        // VoiceOver: double-tap opens; a named rotor action selects (the badge is a touch target).
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(videoBadge.map { "Video, \(dayLabel), \($0)" } ?? "Photo, \(dayLabel)")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { onOpen() }
        .accessibilityAction(named: pickVerb(isPicked: isSelected)) { selection.toggle(id) }
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
        Group {
            if isSelected {
                // Solid gold circle with a DARK check — styleguide §1: foreground on the gold accent
                // is dark (#1C1C1E), not white (the gold is light in both modes). Palette: the check
                // glyph (primary) = on-accent dark, the circle (secondary) = accent gold.
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.onAccent, Color.accentColor)
            } else {
                // Empty ring; a subtle dark backing keeps it visible over bright thumbnails.
                Image(systemName: "circle")
                    .foregroundStyle(.white)
                    .background(Circle().fill(Color.black.opacity(0.25)).padding(2))
            }
        }
        .font(.title3)
        .shadow(radius: 1)
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
        .onTapGesture { selection.toggle(id) }
    }

    /// The corner video badge: a play glyph + running time on a dark capsule (legible over any
    /// thumbnail), non-interactive. `Text(verbatim:)` — the duration is a formatted value, not a
    /// catalog string, so it must not be extracted for localization.
    private func videoDurationBadge(_ text: String) -> some View {
        HStack(spacing: 2) {
            Image(systemName: "play.fill")
            Text(verbatim: text)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(Capsule().fill(Color.black.opacity(0.55)))
        .shadow(radius: 1)
        .padding(5)
        .allowsHitTesting(false)
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
