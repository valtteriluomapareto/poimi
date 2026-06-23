//
//  AssetPagerView.swift
//  PoimiApp — Spike render layer
//
//  RENDER LAYER — promotable. The full-screen inspection view, reached as a
//  navigation destination via `.navigationTransition(.zoom)` (D10). It is a
//  swipe-between-photos pager that lets you **select in place** (D9/★) so
//  "open to decide" is itself a fast multi-select path, never a dead-end.
//  Progressive full-res via the injected `load(id:)` loader.
//
//  Salvageable tier. Typed on `id: String` (localIdentifier) + closures — never
//  on `PHAsset` (D17/§2). The PhotoKit access lives behind the injected `load`.
//
//  Full-screen gesture exploration (Phase 0 ★, from the author's manual test):
//    • Pinch-to-zoom (magnify) the current photo, with pan when zoomed in.
//    • Double-tap to toggle fit ↔ ~2.5×, centred on the tap point.
//    • Pull-down-to-dismiss: drag the un-zoomed photo down to return to the grid.
//  These coexist with the left/right swipe-between-photos and the select control:
//  the page only consumes drags once zoomed (pan) or past a downward threshold
//  (dismiss), so horizontal paging keeps working at rest.

import SwiftUI
import UIKit

struct AssetPagerView: View {
    /// Ordered `localIdentifier`s of the slice — the value snapshot to page over.
    let assetIDs: [String]

    /// Progressive full-res load by id (degraded → final), backed by
    /// `FullImageLoader` in the caller. Yields each delivery so the page can
    /// show something instantly and sharpen in place.
    let load: (String) -> AsyncStream<UIImage>

    let isSelected: (String) -> Bool
    let toggleSelection: (String) -> Void

    /// Dismiss back to the grid (used by pull-down-to-dismiss).
    let dismiss: () -> Void

    /// The currently-shown asset's localIdentifier. Bound so the parent grid can
    /// restore scroll position to whichever photo the user swiped to (the ★
    /// "which photo we land back on" question).
    @Binding var currentID: String?

    var body: some View {
        TabView(selection: $currentID) {
            ForEach(assetIDs, id: \.self) { id in
                AssetPage(
                    id: id,
                    isSelected: isSelected(id),
                    toggle: { toggleSelection(id) },
                    load: load,
                    dismiss: dismiss
                )
                .tag(Optional(id))
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))   // swipe left/right
        .ignoresSafeArea(edges: .bottom)
        .background(Color.black)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if let currentID {
                    Button {
                        toggleSelection(currentID)
                    } label: {
                        Label(
                            isSelected(currentID) ? "Selected" : "Select",
                            systemImage: isSelected(currentID) ? "checkmark.circle.fill" : "circle"
                        )
                    }
                }
            }
        }
    }
}

/// A single full-screen page: progressive full-res image, zoom/pan/double-tap and
/// pull-down-to-dismiss gestures, plus an in-place select affordance tappable
/// without leaving the pager.
private struct AssetPage: View {
    let id: String
    let isSelected: Bool
    let toggle: () -> Void
    let load: (String) -> AsyncStream<UIImage>
    let dismiss: () -> Void

    @State private var image: UIImage?

    // MARK: Zoom / pan state
    @State private var zoom: CGFloat = 1            // committed zoom scale
    @GestureState private var pinch: CGFloat = 1    // live pinch delta
    @State private var offset: CGSize = .zero       // committed pan offset
    @GestureState private var dragTranslation: CGSize = .zero

    // MARK: Pull-down-to-dismiss state
    @State private var dragDown: CGFloat = 0        // live downward drag (when not zoomed)

    private let maxZoom: CGFloat = 4
    private let doubleTapZoom: CGFloat = 2.5
    private let dismissThreshold: CGFloat = 140

    private var isZoomed: Bool { zoom > 1.01 }
    private var effectiveScale: CGFloat { zoom * pinch }

    /// Black backdrop opacity: fully opaque at rest, fading as the photo is
    /// pulled down so the grid behind shows through.
    private var backgroundOpacity: Double {
        guard dragDown > 0 else { return 1 }
        return Double(max(0, 1 - dragDown / 400))
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(effectiveScale)
                        .offset(panOffset())
                        // Pull-down translation (only meaningful when not zoomed).
                        .offset(y: dragDown)
                        .gesture(magnify(in: proxy.size))
                        .gesture(drag(in: proxy.size))
                        .onTapGesture(count: 2) { location in
                            handleDoubleTap(at: location, in: proxy.size)
                        }
                        .animation(.snappy(duration: 0.25), value: zoom)
                        .animation(.snappy(duration: 0.25), value: offset)
                } else {
                    ProgressView()
                        .tint(.white)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        // Background dims as the photo is pulled down so the dismiss reads as
        // "peeling away" to the grid behind it.
        .background(Color.black.opacity(backgroundOpacity))
        .overlay(alignment: .bottom) { selectButton }
        // Progressive: degraded → final, cancels on page recycle.
        .task(id: id) {
            image = nil
            for await delivered in load(id) {
                image = delivered
            }
        }
        // Reset zoom/pan when the page recycles onto a new asset.
        .onChange(of: id) {
            zoom = 1
            offset = .zero
            dragDown = 0
        }
    }

    private var selectButton: some View {
        Button(action: toggle) {
            Label(
                isSelected ? "Selected" : "Tap to select",
                systemImage: isSelected ? "checkmark.circle.fill" : "circle"
            )
            .font(.headline)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial, in: Capsule())
            .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
        }
        .padding(.bottom, 40)
        // Hide the control while zoomed so it doesn't fight the pan gesture.
        .opacity(isZoomed ? 0 : 1)
    }

    // MARK: - Gestures

    /// Pinch-to-zoom. Commits the scale on end, clamped to [1, maxZoom]; when it
    /// snaps back to 1 the pan offset is cleared so the photo re-centres.
    private func magnify(in size: CGSize) -> some Gesture {
        MagnifyGesture()
            .updating($pinch) { value, state, _ in
                state = value.magnification
            }
            .onEnded { value in
                let proposed = zoom * value.magnification
                zoom = min(maxZoom, max(1, proposed))
                if zoom <= 1.01 {
                    zoom = 1
                    offset = .zero
                } else {
                    offset = clampedOffset(offset, scale: zoom, in: size)
                }
            }
    }

    /// One drag gesture serving two roles:
    ///   • zoomed in  → pan within the magnified photo (offset committed on end).
    ///   • at rest    → vertical pull-down-to-dismiss (past the threshold dismisses;
    ///                   otherwise springs back). Mostly-horizontal drags at rest
    ///                   are left to the `TabView` so paging still works.
    private func drag(in size: CGSize) -> some Gesture {
        DragGesture()
            .updating($dragTranslation) { value, state, _ in
                state = value.translation
            }
            .onChanged { value in
                guard !isZoomed else { return }
                // Only treat a clearly-downward drag as a dismiss pull; let
                // horizontal swipes through to the pager.
                if value.translation.height > 0,
                   value.translation.height > abs(value.translation.width) {
                    dragDown = value.translation.height
                }
            }
            .onEnded { value in
                if isZoomed {
                    offset = clampedOffset(
                        CGSize(width: offset.width + value.translation.width,
                               height: offset.height + value.translation.height),
                        scale: zoom, in: size)
                } else if dragDown > dismissThreshold {
                    dismiss()
                } else {
                    dragDown = 0
                }
            }
    }

    /// Live pan = committed offset + the in-flight drag translation (only while
    /// zoomed; otherwise the drag drives pull-down, not pan).
    private func panOffset() -> CGSize {
        guard isZoomed else { return offset }
        return CGSize(width: offset.width + dragTranslation.width,
                      height: offset.height + dragTranslation.height)
    }

    /// Double-tap toggles fit ↔ doubleTapZoom. When zooming in we offset toward
    /// the tap point so the tapped region ends up roughly centred.
    private func handleDoubleTap(at location: CGPoint, in size: CGSize) {
        if isZoomed {
            zoom = 1
            offset = .zero
        } else {
            zoom = doubleTapZoom
            // Translate so the tapped point moves toward centre.
            let dx = (size.width / 2 - location.x) * (doubleTapZoom - 1)
            let dy = (size.height / 2 - location.y) * (doubleTapZoom - 1)
            offset = clampedOffset(CGSize(width: dx, height: dy), scale: zoom, in: size)
        }
    }

    /// Keep the panned photo from drifting off-screen: clamp the offset to the
    /// overscroll the current scale allows.
    private func clampedOffset(_ proposed: CGSize, scale: CGFloat, in size: CGSize) -> CGSize {
        let maxX = max(0, (size.width * scale - size.width) / 2)
        let maxY = max(0, (size.height * scale - size.height) / 2)
        return CGSize(
            width: min(maxX, max(-maxX, proposed.width)),
            height: min(maxY, max(-maxY, proposed.height))
        )
    }
}
