//
//  PhotoPagerView.swift
//  PoimiApp — the photo viewer's horizontal pager (#80; #36 viewer).
//
//  A `UIPageViewController`-backed pager. SwiftUI's paging `ScrollView` couldn't share a screen with
//  a vertical swipe-to-dismiss: the scroll greedily claimed the drag, so a downward swipe degraded
//  into a sideswipe. UIKit arbitrates the two axes cleanly — the page controller's internal scroll
//  owns horizontal paging, and a dismiss pan (gated to begin only on a vertical-dominant drag of an
//  un-zoomed photo, with the page scroll `require(toFail:)`'d behind it) owns the vertical.
//
//  It's also inherently windowed: the page controller only holds the current page ± its neighbours
//  (built on demand from the data source), so the few-thousand-photo materialisation hang that the
//  SwiftUI `LazyHStack` pager fought simply can't arise here. Each page is a `ZoomableImageScrollView`
//  (the same UIKit zoom/pan view the SwiftUI pager used).
//

import SwiftUI
import UIKit

struct PhotoPagerView: UIViewControllerRepresentable {
    /// The pager's universe: every candidate id, in order. Prev/next come straight off this.
    let allIDs: [String]
    /// The on-screen photo — two-way: a page turn publishes it; an external set (filmstrip tap,
    /// initial open) turns the page.
    @Binding var currentID: String
    /// Instant paint from the already-decoded grid cache (sync, no actor hop); nil → cold load.
    let cachedThumb: (String) -> UIImage?
    /// Full-resolution load at a pixel size (async, off the thumbnail actor).
    let loadFull: (String, CGSize) async -> UIImage?
    /// VoiceOver label for a page.
    let axLabel: (String) -> String
    /// A single tap on a page's photo → toggle that id's selection (the secondary select path).
    let onTapPhoto: (String) -> Void
    /// Commit the swipe-down dismiss (pop the viewer).
    let onDismiss: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let pager = UIPageViewController(transitionStyle: .scroll,
                                         navigationOrientation: .horizontal,
                                         options: [.interPageSpacing: 20])
        pager.dataSource = context.coordinator
        pager.delegate = context.coordinator
        pager.view.backgroundColor = .black
        context.coordinator.pager = pager
        if let first = context.coordinator.makePage(for: currentID) {
            pager.setViewControllers([first], direction: .forward, animated: false)
        }
        context.coordinator.installDismissGesture()
        return pager
    }

    func updateUIViewController(_ pager: UIPageViewController, context: Context) {
        context.coordinator.parent = self
        // An external change (filmstrip tap) turns the page; a page-turn-published change is already
        // shown, so this no-ops then.
        let shownID = (pager.viewControllers?.first as? PhotoPageController)?.id
        guard shownID != currentID, let target = context.coordinator.makePage(for: currentID) else { return }
        let toIndex = context.coordinator.index(of: currentID) ?? 0
        let fromIndex = shownID.flatMap(context.coordinator.index) ?? 0
        pager.setViewControllers([target], direction: toIndex >= fromIndex ? .forward : .reverse,
                                 animated: !UIAccessibility.isReduceMotionEnabled)   // RM → jump, don't slide
    }

    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate,
                             UIGestureRecognizerDelegate {
        var parent: PhotoPagerView
        weak var pager: UIPageViewController?

        init(_ parent: PhotoPagerView) { self.parent = parent }

        func index(of id: String) -> Int? { parent.allIDs.firstIndex(of: id) }

        func makePage(for id: String) -> PhotoPageController? {
            guard parent.allIDs.contains(id) else { return nil }
            return PhotoPageController(id: id,
                                       cachedThumb: parent.cachedThumb,
                                       loadFull: parent.loadFull,
                                       axLabel: parent.axLabel(id),
                                       onTap: parent.onTapPhoto)
        }

        // MARK: Data source — prev / next over `allIDs`
        func pageViewController(_ pvc: UIPageViewController,
                                viewControllerBefore vc: UIViewController) -> UIViewController? {
            page(adjacentTo: vc, offset: -1)
        }
        func pageViewController(_ pvc: UIPageViewController,
                                viewControllerAfter vc: UIViewController) -> UIViewController? {
            page(adjacentTo: vc, offset: +1)
        }

        private func page(adjacentTo vc: UIViewController, offset: Int) -> PhotoPageController? {
            guard let id = (vc as? PhotoPageController)?.id,
                  let neighbour = adjacentID(in: parent.allIDs, to: id, offset: offset) else { return nil }
            return makePage(for: neighbour)
        }

        // MARK: Delegate — publish the settled page
        func pageViewController(_ pvc: UIPageViewController, didFinishAnimating finished: Bool,
                                previousViewControllers: [UIViewController], transitionCompleted: Bool) {
            guard transitionCompleted,
                  let id = (pvc.viewControllers?.first as? PhotoPageController)?.id else { return }
            parent.currentID = id
        }

        // MARK: Swipe-down-to-dismiss
        func installDismissGesture() {
            guard let pager else { return }
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handleDismissPan(_:)))
            pan.delegate = self
            pan.maximumNumberOfTouches = 1   // dismiss is one-finger; don't begin on a two-finger pinch-start
            pager.view.addGestureRecognizer(pan)
            // Page scroll waits on this pan: a vertical drag keeps the pan alive (page scroll blocked,
            // no sideswipe); a horizontal drag fails the pan (shouldBegin=false) and pages normally.
            // The internal queuing scroll is an undocumented subview, so search the tree and make a
            // regression loud rather than silently losing the arbitration.
            if let scroll = Self.firstScrollView(in: pager.view) {
                scroll.panGestureRecognizer.require(toFail: pan)
            } else {
                assertionFailure("UIPageViewController internal scroll not found; dismiss arbitration degraded")
            }
        }

        /// Depth-first search for the shallowest `UIScrollView` (the page controller's queuing scroll,
        /// a direct subview today — recursed so a future nesting doesn't silently break the lookup).
        private static func firstScrollView(in view: UIView) -> UIScrollView? {
            for subview in view.subviews {
                if let scroll = subview as? UIScrollView { return scroll }
            }
            for subview in view.subviews {
                if let scroll = firstScrollView(in: subview) { return scroll }
            }
            return nil
        }

        private var currentPageZoomed: Bool {
            (pager?.viewControllers?.first as? PhotoPageController)?.isZoomed ?? false
        }

        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer,
                  let view = pan.view, !currentPageZoomed else { return false }
            // Ignore drags that start on the bottom chrome (the filmstrip) — reaching for it to scrub
            // shouldn't dismiss.
            if pan.location(in: view).y > view.bounds.height - 140 { return false }
            let velocity = pan.velocity(in: view)
            return velocity.y > 0 && abs(velocity.y) > abs(velocity.x)   // downward, vertical-dominant
        }

        @objc func handleDismissPan(_ pan: UIPanGestureRecognizer) {
            guard pan.state == .ended, let view = pan.view else { return }
            let translation = pan.translation(in: view), velocity = pan.velocity(in: view)
            if translation.y > 120 || velocity.y > 900 { parent.onDismiss() }
        }
    }
}

/// One full-screen page: a `ZoomableImageScrollView` that paints the cached thumbnail immediately,
/// then the full-resolution image. Created fresh by the data source each time a page comes into
/// view, so it always starts at fit (no stale zoom to track).
final class PhotoPageController: UIViewController {
    let id: String
    private let scrollView = ZoomableImageScrollView()
    private let cachedThumb: (String) -> UIImage?
    private let loadFull: (String, CGSize) async -> UIImage?
    private let label: String
    private var loadTask: Task<Void, Never>?
    private var didLoadFull = false

    var isZoomed: Bool { scrollView.zoomScale > scrollView.minimumZoomScale }

    init(id: String,
         cachedThumb: @escaping (String) -> UIImage?,
         loadFull: @escaping (String, CGSize) async -> UIImage?,
         axLabel: String,
         onTap: @escaping (String) -> Void) {
        self.id = id
        self.cachedThumb = cachedThumb
        self.loadFull = loadFull
        self.label = axLabel
        super.init(nibName: nil, bundle: nil)
        // Capture the `onTap` PARAMETER + the value `id` — never `self` (no controller↔scrollView↔
        // closure cycle). Set here, not in a later lifecycle hook where `onTap` would resolve to a
        // stored `self.onTap` and capture self.
        scrollView.onSingleTap = { [id] in onTap(id) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func loadView() { view = scrollView }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.isAccessibilityElement = true
        view.accessibilityLabel = label
        if let cached = cachedThumb(id) { scrollView.image = cached }   // instant paint, no black flash
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Load the full-res once bounds are real (so we request the right pixel size).
        guard !didLoadFull, view.bounds.width > 0 else { return }
        didLoadFull = true
        let scale = view.traitCollection.displayScale > 0 ? view.traitCollection.displayScale : 2
        let pixels = CGSize(width: view.bounds.width * scale, height: view.bounds.height * scale)
        loadTask = Task { @MainActor [weak self] in
            guard let self, let full = await self.loadFull(self.id, pixels) else { return }
            self.scrollView.image = full
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        loadTask?.cancel()
    }
}

/// The id `offset` away from `id` in `ids`, or nil at the ends / for an unknown id. Pulled out of the
/// data source so the edge bounds (no prev before the first, no next after the last) are unit-tested
/// — an off-by-one here is an index-out-of-bounds crash when you swipe to the first/last photo.
func adjacentID(in ids: [String], to id: String, offset: Int) -> String? {
    guard let i = ids.firstIndex(of: id) else { return nil }
    let j = i + offset
    return ids.indices.contains(j) ? ids[j] : nil
}
