//
//  PhotoPagerView.swift
//  PoimiApp — the photo viewer's horizontal pager (#80; #36 viewer).
//
//  A `UIPageViewController`-backed pager. SwiftUI's paging `ScrollView` couldn't share a screen with
//  the enclosing sheet's vertical pull-to-dismiss: the scroll greedily claimed the drag, so a downward
//  swipe degraded into a sideswipe. UIKit arbitrates cleanly — the page controller's internal scroll
//  owns HORIZONTAL paging only; a VERTICAL down-drag on an un-zoomed photo is claimed by neither it nor
//  the base-zoom-disabled inner scroll, so the presenting sheet's interactive dismiss gets it (#36).
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

    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
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
    private var loadState = FullImageLoadState()

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

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Retry when the page (re)appears: a prebuilt neighbour's load may have been cancelled when it was
        // scrolled past (see `loadFullIfNeeded`), and a prior terminal failure is cleared here — this is
        // the retry that keeps a page from staying black once it's actually shown.
        loadState.retryOnReappear()
        loadFullIfNeeded()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        loadFullIfNeeded()
    }

    /// (Re)load the full-res image once bounds are real — unless we already have it, one's in flight, or a
    /// terminal failure is awaiting a re-appearance. Crucially, a load that returns nil (cancelled when the
    /// page was scrolled past during the pager's ±1 prebuild, or an unavailable original) is NOT latched as
    /// "loaded": with no cached thumbnail for this id, latching-on-failure left the page permanently black.
    private func loadFullIfNeeded() {
        guard loadState.shouldLoad(boundsReady: view.bounds.width > 0) else { return }
        let token = loadState.begin()
        let scale = view.traitCollection.displayScale > 0 ? view.traitCollection.displayScale : 2
        let pixels = CGSize(width: view.bounds.width * scale, height: view.bounds.height * scale)
        loadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let full = await self.loadFull(self.id, pixels)
            // `completed` ignores a superseded token (a disappear / newer load) and reports whether it
            // applied — paint only a current, successful load.
            if self.loadState.completed(token: token, gotImage: full != nil), let full {
                self.scrollView.image = full
            }
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        loadTask?.cancel()
        loadState.cancel()   // supersede the in-flight load; eligible to reload when shown again
    }

    deinit { loadTask?.cancel() }
}

/// The full-resolution load/retry policy for a viewer page. Extracted from `PhotoPageController` so the
/// whole policy — including the stale-completion (clobber) guard — is pure and unit-testable. It latches
/// "loaded" ONLY on a real image; a nil result is handled so the page can never stay permanently black:
///
///   • A **terminal failure** (PhotoKit returned nil — e.g. an iCloud original that won't download) sets
///     `failed`, which stops layout passes from re-requesting on a loop, but `retryOnReappear()` clears it
///     so showing the page again tries once more.
///   • A **superseded** completion (the page disappeared / a newer load started, detected by the `token`)
///     is ignored — it can't clobber a fresh load or paint a stale image.
///
/// The `token` lives here (not the controller) so that guard is testable rather than UIKit-only glue.
struct FullImageLoadState {
    private(set) var loaded = false
    private(set) var loading = false
    private(set) var failed = false
    private var token = 0

    /// Start a load only if we don't already have the image, none is in flight, no terminal failure is
    /// pending a re-appearance, and bounds are real.
    func shouldLoad(boundsReady: Bool) -> Bool { !loaded && !loading && !failed && boundsReady }

    /// Begin a load; returns the token the caller passes back to `completed`. Only reachable when
    /// `shouldLoad` is true (not already loading), so it never bumps the token mid-flight.
    mutating func begin() -> Int {
        loading = true
        failed = false
        token += 1
        return token
    }

    /// Apply a finished load IF it's still current (`token` matches — else it was superseded and is
    /// ignored). A real image latches `loaded`; a nil result is a terminal failure. Returns whether it
    /// applied, so the caller paints the image only for a current, successful load.
    @discardableResult
    mutating func completed(token: Int, gotImage: Bool) -> Bool {
        guard token == self.token else { return false }
        loading = false
        if gotImage { loaded = true } else { failed = true }
        return true
    }

    /// The page disappeared with a load in flight: supersede it (bump `token` so its result is ignored)
    /// and clear the in-flight flag. `loaded`/`failed` are untouched — a successfully-loaded page stays
    /// loaded; it becomes eligible to reload only if it wasn't.
    mutating func cancel() {
        token += 1
        loading = false
    }

    /// On (re)appearance, clear a prior terminal failure so we try once more now that we're on screen.
    mutating func retryOnReappear() { failed = false }
}

/// The id `offset` away from `id` in `ids`, or nil at the ends / for an unknown id. Pulled out of the
/// data source so the edge bounds (no prev before the first, no next after the last) are unit-tested
/// — an off-by-one here is an index-out-of-bounds crash when you swipe to the first/last photo.
func adjacentID(in ids: [String], to id: String, offset: Int) -> String? {
    guard let i = ids.firstIndex(of: id) else { return nil }
    let j = i + offset
    return ids.indices.contains(j) ? ids[j] : nil
}
