//
//  ZoomableScrollView.swift
//  PoimiApp — pinch-zoom / pan / double-tap for a viewer page (issue #36 part 2).
//
//  Promoted from the spike's UIScrollView zoom/pan code. A SwiftUI image can't zoom to the quality
//  the inspection tier needs (zoom-to-point, momentum, rubber-banding, correct centering), so this
//  wraps a `UIScrollView` + `UIImageView`. Crucially, at zoom 1 the content exactly fits the bounds,
//  so the scroll view isn't scrollable and the *enclosing* paging scroll handles horizontal swipes
//  between photos; once zoomed, this view pans within the image. That nested-scroll arbitration is
//  exactly why UIKit is used here rather than hand-rolled SwiftUI gestures.
//

import SwiftUI
import UIKit

struct ZoomableScrollView: UIViewRepresentable {
    /// The image to display, loaded (progressively) by the SwiftUI page and handed in here.
    let image: UIImage?

    func makeUIView(context: Context) -> ZoomableImageScrollView {
        ZoomableImageScrollView()
    }

    func updateUIView(_ view: ZoomableImageScrollView, context: Context) {
        if view.image !== image { view.image = image }
    }
}

/// A self-laying-out zoomable image scroll view. Sizing happens in `layoutSubviews` (when real
/// bounds exist), avoiding the UIViewRepresentable frame-timing pitfall.
final class ZoomableImageScrollView: UIScrollView, UIScrollViewDelegate {
    private let imageView = UIImageView()

    /// Setting a new image resets the zoom and re-lays out (the page may be recycled onto a new id,
    /// or swapped thumbnail → full-res).
    var image: UIImage? {
        didSet {
            imageView.image = image
            setZoomScale(1, animated: false)
            isScrollEnabled = false   // back to base zoom → let the pager swipe again
            setNeedsLayout()
        }
    }

    init() {
        super.init(frame: .zero)
        delegate = self
        minimumZoomScale = 1
        maximumZoomScale = 4
        bouncesZoom = true
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        backgroundColor = .clear
        contentInsetAdjustmentBehavior = .never
        // Pan only once zoomed: at base zoom the inner scroll is disabled, so the enclosing paging
        // scroll reliably gets the horizontal swipe between photos (a nested non-scrollable inner
        // doesn't always defer to the outer otherwise).
        isScrollEnabled = false
        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        addSubview(imageView)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        // At base zoom the image fills the bounds (aspect-fit inside); zooming scales the imageView
        // and the scroll view handles panning. Don't disturb the frame mid-zoom.
        if zoomScale == 1 {
            imageView.frame = CGRect(origin: .zero, size: bounds.size)
            contentSize = bounds.size
        }
        centerImage()
    }

    /// Keep the image centered when it's smaller than the viewport (so a portrait photo sits in the
    /// middle, not pinned top-left).
    private func centerImage() {
        let content = imageView.frame.size
        let horizontal = max(0, (bounds.width - content.width) / 2)
        let vertical = max(0, (bounds.height - content.height) / 2)
        contentInset = UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical, right: horizontal)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
    func scrollViewDidZoom(_ scrollView: UIScrollView) { centerImage() }

    /// Once a pinch settles, the inner pan is enabled only if we ended up zoomed in — so a pinch back
    /// to fit hands horizontal swipes back to the pager.
    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        isScrollEnabled = scale > minimumZoomScale
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        let animated = !UIAccessibility.isReduceMotionEnabled   // Reduce Motion → snap, don't animate
        if zoomScale > minimumZoomScale {
            setZoomScale(minimumZoomScale, animated: animated)
            isScrollEnabled = false   // back to fit → pager swipes
        } else {
            // Zoom toward the tapped point.
            let point = gesture.location(in: imageView)
            let target: CGFloat = 2.5
            let width = bounds.width / target
            let height = bounds.height / target
            zoom(to: CGRect(x: point.x - width / 2, y: point.y - height / 2, width: width, height: height),
                 animated: animated)
            isScrollEnabled = true   // zoomed → inner pan within the photo
        }
    }
}
