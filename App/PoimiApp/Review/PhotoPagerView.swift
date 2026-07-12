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
import AVFoundation
import Curation

/// A page in the viewer's pager — either a photo (`PhotoPageController`) or a video
/// (`VideoPageController`). The pager holds them uniformly and reads only the `id`; the concrete type
/// decides how the page paints and what a tap does. A UIViewController-constrained protocol so a page
/// is always a real view controller the `UIPageViewController` can host.
protocol ViewerPage: UIViewController {
    var id: String { get }
}

/// Which page a candidate id renders as. Pulled out of the pager as a pure decision so it's unit-tested
/// without UIKit: a video id → a `.video` page (poster + inline play), everything else → `.photo` (#125).
enum ViewerPageKind: Equatable { case photo, video }

/// The page kind for `id`, from the published `AssetRef` map (the same map the grid badge + info panel
/// read). An id absent from the map, or a still, is a `.photo`; only a known video is a `.video`.
func pageKind(for id: String, assets: [String: AssetRef]) -> ViewerPageKind {
    (assets[id]?.isVideo ?? false) ? .video : .photo
}

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
    /// The published `AssetRef` map — decides each page's kind (`photo` vs `video`, #125). Same map the
    /// grid badge + info panel read.
    let assets: [String: AssetRef]
    /// Lazily load a video's player item on the first play tap (async, off-main); `nil` for a still /
    /// unresolvable id (#125). A video page owns its own `AVPlayer` built from this.
    let loadPlayerItem: (String) async -> AVPlayerItem?
    /// VoiceOver label for a page.
    let axLabel: (String) -> String
    /// A single tap on a PHOTO page → toggle that id's selection (the secondary select path). A VIDEO
    /// page's tap plays/pauses instead (tap-to-pick is disabled there; pick a video via the viewer's
    /// Picked control, #125).
    let onTapPhoto: (String) -> Void
    /// A user-driven page SWIPE settled: `(from, to)`. Fired ONLY from the gesture-completion delegate —
    /// NOT for a filmstrip tap or programmatic page set (those go through `updateUIViewController`). So a
    /// caller can treat this as "the user deliberately paged," distinct from any `currentID` change (#128).
    var onSwipe: (String, String) -> Void = { _, _ in }

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
        // An external change (Next/Prev button, filmstrip tap, pick auto-advance) turns the page; a
        // swipe-published change is already shown, so this no-ops then.
        let shownID = (pager.viewControllers?.first as? (any ViewerPage))?.id
        guard shownID != currentID, let target = context.coordinator.makePage(for: currentID) else { return }
        let toIndex = context.coordinator.index(of: currentID) ?? 0
        let fromIndex = shownID.flatMap(context.coordinator.index) ?? 0
        // Programmatic page turns are INSTANT (`animated: false`): the built-in ~0.3s slide made rapid
        // Next-button taps feel laggy, and instant turns also can't overlap/desync the pager, so the caller
        // needn't debounce navigation. Swipes keep their natural interactive slide (they don't come through
        // here). Instant is also the correct Reduce-Motion behaviour, so no separate gate is needed.
        pager.setViewControllers([target], direction: toIndex >= fromIndex ? .forward : .reverse,
                                 animated: false)
    }

    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var parent: PhotoPagerView
        weak var pager: UIPageViewController?

        init(_ parent: PhotoPagerView) { self.parent = parent }

        func index(of id: String) -> Int? { parent.allIDs.firstIndex(of: id) }

        func makePage(for id: String) -> UIViewController? {
            guard parent.allIDs.contains(id) else { return nil }
            switch pageKind(for: id, assets: parent.assets) {
            case .photo:
                return PhotoPageController(id: id,
                                           cachedThumb: parent.cachedThumb,
                                           loadFull: parent.loadFull,
                                           axLabel: parent.axLabel(id),
                                           onTap: parent.onTapPhoto)
            case .video:
                return VideoPageController(id: id,
                                           cachedThumb: parent.cachedThumb,
                                           loadFull: parent.loadFull,
                                           loadPlayerItem: parent.loadPlayerItem,
                                           axLabel: parent.axLabel(id))
            }
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

        private func page(adjacentTo vc: UIViewController, offset: Int) -> UIViewController? {
            guard let id = (vc as? (any ViewerPage))?.id,
                  let neighbour = adjacentID(in: parent.allIDs, to: id, offset: offset) else { return nil }
            return makePage(for: neighbour)
        }

        // MARK: Delegate — publish the settled page
        func pageViewController(_ pvc: UIPageViewController, didFinishAnimating finished: Bool,
                                previousViewControllers: [UIViewController], transitionCompleted: Bool) {
            guard transitionCompleted,
                  let id = (pvc.viewControllers?.first as? (any ViewerPage))?.id else { return }
            let from = (previousViewControllers.first as? (any ViewerPage))?.id
            parent.currentID = id
            // A real user swipe settled (this delegate fires for gesture transitions only, not programmatic
            // `setViewControllers`) — report from→to so the caller can act on deliberate paging (#128).
            if let from { parent.onSwipe(from, id) }
        }

    }
}

/// One full-screen page: a `ZoomableImageScrollView` that paints the cached thumbnail immediately,
/// then the full-resolution image. Created fresh by the data source each time a page comes into
/// view, so it always starts at fit (no stale zoom to track).
final class PhotoPageController: UIViewController, ViewerPage {
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

/// One full-screen VIDEO page (#125): a poster (the cached thumbnail, upgraded to the full-res still)
/// under a centered play button. Tapping plays/pauses an inline `AVPlayer` built lazily from the seam on
/// the first play — there's no scrubber (a deliberately minimal player; the design is "glance + play, not
/// edit"). The player is torn down on disappear, so paging away always frees it and a re-appear starts
/// from the poster. Tap-to-PICK is disabled here (a tap plays) — a video is picked via the viewer's Picked
/// control, so a play tap can never be mistaken for a pick.
final class VideoPageController: UIViewController, ViewerPage {
    let id: String
    private let cachedThumb: (String) -> UIImage?
    private let loadFull: (String, CGSize) async -> UIImage?
    private let loadPlayerItem: (String) async -> AVPlayerItem?
    private let label: String

    private let posterView = UIImageView()
    private let playButton = UIButton(type: .system)
    private let spinner = UIActivityIndicatorView(style: .large)

    private var player: AVPlayer?
    private var playerLayer: AVPlayerLayer?
    private var endObserver: (any NSObjectProtocol)?
    private var playerTask: Task<Void, Never>?
    private var posterTask: Task<Void, Never>?
    private var posterState = FullImageLoadState()
    /// Our INTENDED play state — the pause toggle branches on this, not `AVPlayer.timeControlStatus`.
    /// During an iCloud buffer the status is `.waitingToPlayAtSpecifiedRate` (neither paused nor playing),
    /// so reading it would treat a "still loading" tap as pause and stall the clip (review finding).
    private var intendedPlaying = false

    init(id: String,
         cachedThumb: @escaping (String) -> UIImage?,
         loadFull: @escaping (String, CGSize) async -> UIImage?,
         loadPlayerItem: @escaping (String) async -> AVPlayerItem?,
         axLabel: String) {
        self.id = id
        self.cachedThumb = cachedThumb
        self.loadFull = loadFull
        self.loadPlayerItem = loadPlayerItem
        self.label = axLabel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        posterView.frame = view.bounds
        posterView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        posterView.contentMode = .scaleAspectFit
        posterView.isAccessibilityElement = true
        posterView.accessibilityLabel = label
        posterView.accessibilityTraits = .image
        if let cached = cachedThumb(id) { posterView.image = cached }   // instant poster, no black flash
        view.addSubview(posterView)

        // A large, legible play button (white glyph + shadow over any poster). A real UIButton so
        // VoiceOver can focus + activate it; a tap anywhere on the page also toggles playback.
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: "play.circle.fill",
                               withConfiguration: UIImage.SymbolConfiguration(pointSize: 64))
        config.baseForegroundColor = .white
        playButton.configuration = config
        playButton.layer.shadowOpacity = 0.4
        playButton.layer.shadowRadius = 4
        playButton.layer.shadowOffset = .zero
        playButton.accessibilityLabel = String(localized: "Play video", comment: "Viewer: play an inline video")
        playButton.addAction(UIAction { [weak self] _ in self?.togglePlayback() }, for: .touchUpInside)
        playButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(playButton)

        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.color = .white
        spinner.hidesWhenStopped = true
        view.addSubview(spinner)

        NSLayoutConstraint.activate([
            playButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            playButton.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])

        // A tap anywhere plays/pauses (not just the button) — matches the photo page's tap-to-act ergonomics.
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        view.addGestureRecognizer(tap)
    }

    @objc private func handleTap() { togglePlayback() }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        posterState.retryOnReappear()
        loadPosterIfNeeded()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        playerLayer?.frame = view.bounds
        loadPosterIfNeeded()
    }

    /// Upgrade the poster from the thumbnail to the full-res still once bounds are real (same policy as a
    /// photo page). The player layer, once playing, sits above this — so the poster is what shows before
    /// play and again after teardown.
    private func loadPosterIfNeeded() {
        guard posterState.shouldLoad(boundsReady: view.bounds.width > 0) else { return }
        let token = posterState.begin()
        let scale = view.traitCollection.displayScale > 0 ? view.traitCollection.displayScale : 2
        let pixels = CGSize(width: view.bounds.width * scale, height: view.bounds.height * scale)
        posterTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let full = await self.loadFull(self.id, pixels)
            if self.posterState.completed(token: token, gotImage: full != nil), let full {
                self.posterView.image = full
            }
        }
    }

    /// First tap: load the player item (spinner up), build the player, play. Later taps: play ⇄ pause,
    /// toggling the play button. A load that yields no item (fake provider / unavailable original) simply
    /// restores the play button — never a dead spinner.
    private func togglePlayback() {
        if let player {
            intendedPlaying.toggle()
            if intendedPlaying { player.play() } else { player.pause() }
            playButton.isHidden = intendedPlaying
            return
        }
        guard playerTask == nil else { return }   // a load is already in flight
        playButton.isHidden = true
        spinner.startAnimating()
        playerTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let item = await self.loadPlayerItem(self.id)
            self.spinner.stopAnimating()
            self.playerTask = nil
            guard !Task.isCancelled, let item else {
                self.playButton.isHidden = false   // couldn't load → let the user try again
                return
            }
            self.startPlaying(item)
        }
    }

    private func startPlaying(_ item: AVPlayerItem) {
        // Route audio through `.playback` so the clip is audible even with the ring/silent switch on —
        // judging a video means judging its sound, and this matches Photos' inline playback.
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)
        let player = AVPlayer(playerItem: item)
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspect
        layer.frame = view.bounds
        view.layer.insertSublayer(layer, above: posterView.layer)
        self.player = player
        self.playerLayer = layer
        // At end: rewind and re-show the play button, so the page rests on the first frame ready to replay.
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            self?.player?.seek(to: .zero)
            self?.intendedPlaying = false
            self?.playButton.isHidden = false
        }
        intendedPlaying = true
        playButton.isHidden = true
        player.play()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        teardownPlayer()
        posterTask?.cancel()
        posterState.cancel()
    }

    /// Stop + free the player entirely (paging away, or the sheet closing). Cheap to rebuild on the next
    /// play tap, and keeping a torn-down page player-free avoids N idle players across a long album.
    private func teardownPlayer() {
        player?.pause()
        playerTask?.cancel()
        playerTask = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        playerLayer?.removeFromSuperlayer()
        playerLayer = nil
        player = nil
        intendedPlaying = false
        spinner.stopAnimating()
        playButton.isHidden = false   // back to the poster + play affordance
    }

    // No `endObserver` cleanup here: the observer is created only in `startPlaying` (a play tap on a
    // visible page), and `teardownPlayer()` on `viewDidDisappear` — which always precedes dealloc for a
    // shown page — removes it. A never-shown prebuilt page never made one. (A nonisolated deinit also
    // can't touch the non-Sendable token.)
    deinit {
        playerTask?.cancel()
        posterTask?.cancel()
    }
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
