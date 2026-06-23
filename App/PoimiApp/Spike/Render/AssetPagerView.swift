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
//  Full-screen gestures (reworked in this pass per the author's on-device Part B):
//    • Zoom / pan — a `UIScrollView`-backed zoomable image (`ZoomableImageView`,
//      `UIViewRepresentable`: `UIScrollView` + `UIImageView`). Native pinch + pan +
//      double-tap-to-zoom at 60/120fps. The earlier SwiftUI `MagnifyGesture` +
//      `offset` approach panned with huge lag on-device (unusable) — this replaces it.
//    • Pull-down-to-dismiss — **interactive**: when not zoomed, a downward drag tracks
//      the finger and scales the photo down, the backdrop fades with drag progress,
//      and release past a threshold dismisses (else it springs back). Driven by a
//      `UIPanGestureRecognizer` inside the scroll view that only activates at min zoom
//      and only for predominantly-vertical drags, so left/right `TabView` paging and
//      the scroll view's own pan-when-zoomed both keep working.
//
//  Neighbour-prefetch: the pager warms the full-res load for the current ± 1 page so
//  swiping lands on a sharper image sooner (the iCloud-too-slow Part B finding;
//  remaining latency is inherent to the iCloud download — Phase 2 D12).

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
                    dismiss: dismiss,
                    // Warm full-res for this page's immediate neighbours so a swipe
                    // lands on a sharper image sooner (see neighbour-prefetch note).
                    neighbourIDs: neighbours(of: id)
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

    /// The current ± 1 ids (the swipe neighbours), excluding the page itself.
    private func neighbours(of id: String) -> [String] {
        guard let i = assetIDs.firstIndex(of: id) else { return [] }
        var out: [String] = []
        if i > 0 { out.append(assetIDs[i - 1]) }
        if i + 1 < assetIDs.count { out.append(assetIDs[i + 1]) }
        return out
    }
}

/// A single full-screen page: progressive full-res image in a `UIScrollView`-backed
/// zoomable view, interactive pull-down-to-dismiss, plus an in-place select
/// affordance tappable without leaving the pager.
private struct AssetPage: View {
    let id: String
    let isSelected: Bool
    let toggle: () -> Void
    let load: (String) -> AsyncStream<UIImage>
    let dismiss: () -> Void
    /// Immediate swipe neighbours (current ± 1) to warm in the background.
    let neighbourIDs: [String]

    @State private var image: UIImage?

    /// Live interactive-dismiss progress reported up from the scroll view's pan.
    /// `translation` tracks the finger; `isZoomed` hides the select control + drives
    /// whether a drag pans (zoomed) or dismisses (at fit).
    @State private var dragTranslation: CGSize = .zero
    @State private var isZoomed = false

    /// Past this downward travel a release dismisses; otherwise it springs back.
    private let dismissThreshold: CGFloat = 140

    /// Scale + opacity of the photo as it's pulled down (Photos-style: the photo
    /// shrinks toward the finger and the backdrop shows through).
    private var dragScale: CGFloat {
        guard dragTranslation.height > 0 else { return 1 }
        return max(0.82, 1 - dragTranslation.height / 1000)
    }

    /// Black backdrop opacity: fully opaque at rest, fading as the photo is pulled
    /// down so the grid behind shows through.
    private var backgroundOpacity: Double {
        guard dragTranslation.height > 0 else { return 1 }
        return Double(max(0, 1 - dragTranslation.height / 400))
    }

    var body: some View {
        ZStack {
            Color.black.opacity(backgroundOpacity)
                .ignoresSafeArea()

            if let image {
                ZoomableImageView(
                    pageID: id,
                    image: image,
                    onZoomChanged: { zoomed in
                        if isZoomed != zoomed { isZoomed = zoomed }
                    },
                    onDragChanged: { translation in
                        dragTranslation = translation
                    },
                    onDragEnded: { translation in
                        if translation.height > dismissThreshold {
                            dismiss()
                        } else {
                            // Spring the photo back to rest.
                            withAnimation(.interactiveSpring(
                                response: 0.35, dampingFraction: 0.8)) {
                                dragTranslation = .zero
                            }
                        }
                    }
                )
                // Track the interactive pull-down: move + scale the photo with the
                // finger. (Pan-when-zoomed is handled natively inside the scroll view,
                // so this only ever fires at fit scale.)
                .scaleEffect(dragScale)
                .offset(dragTranslation)
                .ignoresSafeArea()
            } else {
                ProgressView()
                    .tint(.white)
            }
        }
        .overlay(alignment: .bottom) { selectButton }
        // Progressive: degraded → final, cancels on page recycle.
        .task(id: id) {
            image = nil
            dragTranslation = .zero
            for await delivered in load(id) {
                image = delivered
            }
        }
        // Neighbour-prefetch: warm current ± 1 full-res so a swipe lands on a sharper
        // image sooner. Each neighbour's stream is drained to drive the PhotoKit
        // load; the downloaded original is cached, so the neighbour's own `.task`
        // then resolves fast (degraded → final without the long blur). The `load`
        // closure is main-actor isolated, so the warmers run as main-actor child
        // tasks; they're cancelled when this page recycles so we never warm pages the
        // user swiped away from.
        .task(id: id) {
            let warmers = neighbourIDs.map { neighbour in
                Task { @MainActor in
                    for await _ in load(neighbour) {
                        if Task.isCancelled { break }
                    }
                }
            }
            await withTaskCancellationHandler {
                for warmer in warmers { _ = await warmer.value }
            } onCancel: {
                for warmer in warmers { warmer.cancel() }
            }
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
        // Hide the control while zoomed (the scroll view owns the pan) or mid-dismiss.
        .opacity(isZoomed || dragTranslation.height > 0 ? 0 : 1)
    }
}

// MARK: - UIScrollView-backed zoomable image (performant pinch / pan / double-tap)

/// A `UIScrollView` + `UIImageView` zoomable image. Native pinch-to-zoom, pan when
/// zoomed, and double-tap-to-zoom (fit ↔ ~3×) at 60/120fps — the reliable fix for
/// the SwiftUI-gesture pan lag the author hit on-device.
///
/// At **min zoom** (fit) the scroll view's own panning is disabled and an attached
/// `UIPanGestureRecognizer` instead drives the interactive pull-down-to-dismiss,
/// reporting progress back through the `onDrag*` closures. It only claims
/// predominantly-vertical-downward drags, so horizontal swipes fall through to the
/// enclosing `TabView` pager and the photo keeps paging left/right.
private struct ZoomableImageView: UIViewRepresentable {
    /// The logical asset id of the page. Zoom resets only when *this* changes (the
    /// page recycled onto a new asset) — never on a degraded→final upgrade of the
    /// same asset, which delivers a larger image but must keep the user's zoom.
    let pageID: String
    let image: UIImage
    /// `true` once zoomed past fit; lets the parent hide the select control + know
    /// the scroll view owns the pan.
    let onZoomChanged: (Bool) -> Void
    /// Live pull-down translation while dragging at fit scale.
    let onDragChanged: (CGSize) -> Void
    /// Final pull-down translation on release (parent decides dismiss vs spring-back).
    let onDragEnded: (CGSize) -> Void

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = LayoutNotifyingScrollView()
        // Re-aspect-fit on every layout pass (initial sizing + rotation), but only
        // while at fit scale so it can't stomp the user's active zoom/pan.
        scrollView.onLayout = { [weak coordinator = context.coordinator] sv in
            coordinator?.relayoutIfAtFit(in: sv)
        }
        scrollView.delegate = context.coordinator
        scrollView.maximumZoomScale = 4
        scrollView.minimumZoomScale = 1
        scrollView.bouncesZoom = true
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.backgroundColor = .clear
        // Don't fight the TabView's horizontal paging at fit scale.
        scrollView.alwaysBounceHorizontal = false
        scrollView.alwaysBounceVertical = false

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        scrollView.addSubview(imageView)
        context.coordinator.imageView = imageView
        context.coordinator.scrollView = scrollView
        context.coordinator.pageID = pageID

        // Double-tap to toggle fit ↔ ~3×, centred on the tap point (native).
        let doubleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)

        // Interactive pull-down-to-dismiss at fit scale.
        let dismissPan = UIPanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleDismissPan(_:)))
        dismissPan.delegate = context.coordinator
        scrollView.addGestureRecognizer(dismissPan)
        context.coordinator.dismissPan = dismissPan

        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        guard context.coordinator.imageView?.image !== image else { return }
        // A new *page* (the cell recycled onto a different asset) resets zoom + relays
        // out; a degraded→final upgrade of the *same* page keeps the user's zoom even
        // though PhotoKit's opportunistic delivery hands us a larger final image.
        let pageChanged = context.coordinator.pageID != pageID
        context.coordinator.pageID = pageID
        context.coordinator.imageView?.image = image
        if pageChanged {
            scrollView.setZoomScale(1, animated: false)
            context.coordinator.layoutImage(in: scrollView)
        } else if scrollView.zoomScale <= scrollView.minimumZoomScale + 0.01 {
            // Same page, sharper image, user not zoomed: re-fit (a larger final image
            // changes the aspect-fit content size) without touching their (absent) zoom.
            context.coordinator.layoutImage(in: scrollView)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate {
        let parent: ZoomableImageView
        weak var scrollView: UIScrollView?
        weak var imageView: UIImageView?
        weak var dismissPan: UIPanGestureRecognizer?
        /// The page id currently laid out, to distinguish a new asset (reset zoom)
        /// from a degraded→final upgrade of the same asset (keep zoom).
        var pageID: String?

        init(parent: ZoomableImageView) {
            self.parent = parent
        }

        // MARK: Layout — size the image view to the aspect-fit rect, centre it.

        /// Re-fit on a layout pass, but only at fit scale so an active zoom/pan isn't
        /// stomped (the scroll view re-lays-out on every bounds change).
        func relayoutIfAtFit(in scrollView: UIScrollView) {
            guard scrollView.zoomScale <= scrollView.minimumZoomScale + 0.01 else { return }
            layoutImage(in: scrollView)
        }

        /// Aspect-fit the image into the scroll view bounds and centre it.
        func layoutImage(in scrollView: UIScrollView) {
            guard let imageView, let image = imageView.image else { return }
            let bounds = scrollView.bounds.size
            guard bounds.width > 0, bounds.height > 0,
                  image.size.width > 0, image.size.height > 0 else { return }
            let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
            let fitted = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            imageView.frame = CGRect(origin: .zero, size: fitted)
            scrollView.contentSize = fitted
            centreImage(in: scrollView)
        }

        /// Keep the image centred when it's smaller than the viewport (at fit and
        /// while zooming back out).
        private func centreImage(in scrollView: UIScrollView) {
            guard let imageView else { return }
            let bounds = scrollView.bounds.size
            let content = imageView.frame.size
            let insetX = max(0, (bounds.width - content.width) / 2)
            let insetY = max(0, (bounds.height - content.height) / 2)
            scrollView.contentInset = UIEdgeInsets(
                top: insetY, left: insetX, bottom: insetY, right: insetX)
        }

        // MARK: UIScrollViewDelegate

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            centreImage(in: scrollView)
            let zoomed = scrollView.zoomScale > scrollView.minimumZoomScale + 0.01
            parent.onZoomChanged(zoomed)
            // While zoomed the scroll view owns the pan; disable the dismiss pan so it
            // doesn't fight. Re-enable at fit so pull-down works again.
            dismissPan?.isEnabled = !zoomed
        }

        // MARK: Double-tap to zoom

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scrollView else { return }
            if scrollView.zoomScale > scrollView.minimumZoomScale + 0.01 {
                scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
            } else {
                let target: CGFloat = 3
                let point = gesture.location(in: imageView)
                let size = scrollView.bounds.size
                let w = size.width / target
                let h = size.height / target
                let rect = CGRect(x: point.x - w / 2, y: point.y - h / 2, width: w, height: h)
                scrollView.zoom(to: rect, animated: true)
            }
        }

        // MARK: Interactive pull-down-to-dismiss (fit scale only)

        @objc func handleDismissPan(_ gesture: UIPanGestureRecognizer) {
            guard let scrollView,
                  scrollView.zoomScale <= scrollView.minimumZoomScale + 0.01 else { return }
            let translation = gesture.translation(in: scrollView)
            switch gesture.state {
            case .changed:
                // Only meaningful downward; let the gesture delegate keep horizontal
                // swipes away from us so the TabView still pages.
                let down = max(0, translation.y)
                parent.onDragChanged(CGSize(width: translation.x * 0.4, height: down))
            case .ended, .cancelled, .failed:
                parent.onDragEnded(CGSize(width: translation.x, height: max(0, translation.y)))
            default:
                break
            }
        }

        // Only claim predominantly-vertical-downward drags at fit scale; leave
        // horizontal swipes to the TabView pager and pan-when-zoomed to the scroll
        // view. Returning false for a horizontal/upward drag lets it fall through.
        func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
            guard let pan = gesture as? UIPanGestureRecognizer,
                  let scrollView else { return true }
            guard scrollView.zoomScale <= scrollView.minimumZoomScale + 0.01 else { return false }
            let velocity = pan.velocity(in: scrollView)
            return velocity.y > 0 && velocity.y > abs(velocity.x)
        }
    }
}

/// A `UIScrollView` that reports each layout pass, so the coordinator can re-fit the
/// image on the initial sizing and on rotation (`UIViewRepresentable` gives no
/// reliable post-layout hook otherwise).
private final class LayoutNotifyingScrollView: UIScrollView {
    var onLayout: ((UIScrollView) -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?(self)
    }
}
