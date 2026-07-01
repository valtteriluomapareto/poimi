//
//  Filmstrip.swift
//  PoimiApp — the photo viewer's bottom scrubber (issue #36 part 2b; design WZ-0).
//
//  A horizontal strip of the album's candidate thumbnails under the full-screen photo: the current
//  photo is enlarged and ringed, picked photos carry the gold check, and the strip auto-centers the
//  current thumb as you swipe the main pager. Tapping a thumb jumps the viewer to it — so the strip
//  is both an orientation aid (where am I in the album, what have I picked) and a fast jump control.
//  Free-drag browses without committing; only a tap changes the displayed photo (a live drag-scrub
//  that cross-binds two scroll views is a later refinement — it risks an oscillation loop that can't
//  be confirmed without a device).
//

import SwiftUI
import UIKit

struct Filmstrip: View {
    /// The same ordered candidate ids the main pager shows.
    let pages: [String]
    /// The current photo — shared with the main pager. Tapping a thumb writes it (the pager then
    /// scrolls); a main-pager swipe writes it (this strip then re-centers).
    @Binding var currentID: String
    @Environment(SelectionStore.self) private var selection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Drives the strip's scroll position; follows `currentID` one-way. Kept separate so a free-drag
    /// scrolls the strip (browsing) WITHOUT changing the displayed photo — only a tap commits.
    @State private var stripID: String?

    /// The size the strip loads + caches thumbs at (the current thumb's on-screen side). Shared with
    /// the viewer's prefetch so both warm the SAME cache key — if they drift, the prefetch silently
    /// misses and the lag fix becomes a no-op.
    static let thumbnailLoadSide: CGFloat = 56
    private let thumbSize: CGFloat = 44
    private let currentSize = Filmstrip.thumbnailLoadSide

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 6) {
                ForEach(pages, id: \.self) { id in
                    thumb(id).id(id)
                }
            }
            .padding(.horizontal, 16)
            .scrollTargetLayout()
        }
        .scrollIndicators(.hidden)
        .frame(height: currentSize)
        // A visual accelerator only: every thumb would be a focusable button, flooding VoiceOver
        // with ~1 per photo and duplicating the main pager (the real AX content surface). AT users
        // page the photo, read position from the "N of M" label, and pick with the top-bar toggle.
        .accessibilityHidden(true)
        // Center the current thumb via `.scrollPosition` (lazy), NOT `scrollTo`: over a whole album a
        // `scrollTo` to a mid-strip id materializes every thumb up to it, each firing a thumbnail
        // request — thousands at once. This positions lazily and never builds the prefix.
        .scrollPosition(id: $stripID, anchor: .center)
        .onAppear { stripID = currentID }
        .onChange(of: currentID) {
            // Re-center on a pager swipe / tap. Non-essential motion: jump under Reduce Motion.
            if reduceMotion {
                stripID = currentID
            } else {
                withAnimation(.easeOut(duration: 0.2)) { stripID = currentID }
            }
        }
    }

    private func thumb(_ id: String) -> some View {
        let isCurrent = id == currentID
        return Button {
            currentID = id   // the main pager observes this and scrolls to the photo
        } label: {
            FilmstripThumb(id: id,
                           side: currentSize,           // always load at the larger side, so a thumb
                           scaledSide: isCurrent ? currentSize : thumbSize,   // stays crisp once current
                           isCurrent: isCurrent,
                           isPicked: selection.contains(id))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isCurrent ? "Current photo" : "Jump to photo")
        .accessibilityAddTraits(selection.contains(id) ? [.isButton, .isSelected] : .isButton)
    }
}

/// One filmstrip cell: a small rounded thumbnail, ringed when current and gold-checked when picked.
private struct FilmstripThumb: View {
    let id: String
    /// The pixel side the image is loaded at (always the larger, so the current thumb is crisp).
    let side: CGFloat
    /// The on-screen side (smaller until this thumb is the current one).
    let scaledSide: CGFloat
    let isCurrent: Bool
    let isPicked: Bool
    @Environment(\.thumbnailProvider) private var thumbnails
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var image: UIImage?

    var body: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(Color.white.opacity(0.12))
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                }
            }
            .frame(width: scaledSide, height: scaledSide)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isCurrent ? .white : .white.opacity(0.15),
                                  lineWidth: isCurrent ? 2 : 0.5)
            }
            .overlay(alignment: .bottomTrailing) {
                if isPicked {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(Color.onAccent, Color.accentColor)
                        .padding(2)
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: isCurrent)
            .task(id: id) {
                let px = side * displayScale
                let target = CGSize(width: px, height: px)
                // Cache-first: a warmed thumb (the viewer prefetches the lead window, or a re-appearance)
                // paints instantly — no gray flash — then the async load refreshes it.
                if image == nil, let cached = thumbnails.cachedThumbnail(for: id, targetSize: target) {
                    image = cached
                }
                let started = Perf.begin()
                image = await thumbnails.thumbnail(for: id, targetSize: target)
                Perf.endIO("filmstrip.thumb \(id.suffix(8))", since: started)
            }
    }
}
