//
//  PhotoViewerView.swift
//  PoimiApp — the full-screen photo viewer (issue #36, D10/D22).
//
//  The borderline-call tier of the two-tier picking model: a swipeable pager over the album's
//  candidate ids (the shared list on the coordinator), reached via the `.zoom` transition from the
//  grid cell. You swipe between photos and SELECT IN PLACE; the grid restores to the photo you
//  ended on and the selection is preserved — both ride shared state (`lastViewedID` + the
//  `SelectionStore`), so "open to decide" is itself a fast multi-select path, not a dead end.
//
//  Each page is progressive: it paints the cached thumbnail immediately, then swaps to the
//  full-resolution image when it lands. Pinch-zoom / pan / double-tap-to-point land here (part 2a);
//  the filmstrip scrubber, the per-photo day label, and a zoom-aware swipe-down-to-dismiss are #36
//  part 2b (a free-floating swipe-down would fight panning a zoomed photo, so the chevron exits).
//

import SwiftUI
import UIKit

struct PhotoViewerView: View {
    /// The asset tapped in the grid — the page the viewer opens on.
    let startID: String
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(SelectionStore.self) private var selection
    @State private var currentID: String
    /// The full candidate list (for the "N of M" position) + an id→global-index map (O(1) lookup).
    /// Resolved once on appear; falls back to just this photo when there's no live review context.
    @State private var allIDs: [String] = []
    @State private var indexByID: [String: Int] = [:]
    /// A bounded *window* of `allIDs` around the current photo — what the pager and filmstrip actually
    /// render. A `LazyHStack` positioned at a mid-list id materializes its WHOLE prefix to get there
    /// (`.scrollPosition` and `scrollTo` both do) — over a few-thousand-photo album that built
    /// thousands of full-screen pages and froze the viewer. The window keeps it to a few dozen and
    /// slides as you swipe, so positioning only ever builds a handful of pages.
    @State private var pages: [String] = []

    /// Window shape: a small backward buffer (so opening/​re-centering materializes only a few pages)
    /// plus a forward run, and a margin that triggers a slide before you swipe off either end.
    private let windowBack = 8
    private let windowForward = 60
    private let rebuildMargin = 4

    init(startID: String) {
        self.startID = startID
        _currentID = State(initialValue: startID)
    }

    /// `.scrollPosition(id:)` works in `String?`; map it onto the non-optional `currentID` (a nil
    /// scroll target — momentarily between pages — leaves the last page id in place).
    private var pageBinding: Binding<String?> {
        Binding(get: { currentID }, set: { if let id = $0 { currentID = id } })
    }

    var body: some View {
        // A lazy horizontal paging scroll: `LazyHStack` only materializes the visible + adjacent
        // pages (so a thousands-photo album stays light), `.scrollTargetBehavior(.paging)` snaps
        // page-to-page, and `.scrollPosition(id:)` both restores the opening page and two-way-binds
        // the current one. Each page is a `ZoomableScrollView` (pinch-zoom / pan / double-tap).
        //
        // Positioning is done by `.scrollPosition(id:)` ALONE — deliberately NOT a `ScrollViewReader`
        // `scrollTo`. Over a whole album (thousands of candidates) `scrollTo` to a mid-list id walks
        // the lazy stack from the start, materializing every page up to the target — full-screen
        // pages × thousands froze the app on device. `.scrollPosition(id:)` lands on the bound id
        // lazily, without building the prefix.
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(pages, id: \.self) { id in
                    PhotoPage(id: id, accessibilityLabel: photoAXLabel(for: id))
                        .containerRelativeFrame(.horizontal)
                        .id(id)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: pageBinding)
        .scrollIndicators(.hidden)
        .background(Color.black)
        .ignoresSafeArea()
        .overlay(alignment: .top) { topBar }
        .overlay(alignment: .bottom) { bottomBar }
        .toolbar(.hidden, for: .navigationBar)
        // Keep the shared anchor on the photo in view, so the grid restores here and the `.zoom`
        // return pairs with this cell; and slide the window before a swipe runs off its end.
        .onChange(of: currentID) {
            Perf.measure("viewer.onChange→\(currentID.suffix(8))") {
                coordinator.lastViewedID = currentID
                slideWindowIfNeeded()
            }
        }
        .onAppear {
            Perf.event("viewer.onAppear (open span end)")
            Perf.measure("viewer.onAppear build") {
                let list = coordinator.reviewOrderedIDs.contains(startID) ? coordinator.reviewOrderedIDs : [startID]
                allIDs = list
                indexByID = Dictionary(list.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
                rebuildWindow(around: startID)
            }
        }
        .onDisappear { Perf.event("viewer.onDisappear") }
    }

    // MARK: Windowing (bound the LazyHStack so positioning never builds thousands of pages)

    /// Rebuild `pages` as the slice of `allIDs` spanning `windowBack` before `id` … `windowForward`
    /// after it (clamped to the list). No-op when the slice is unchanged, so re-centering at the very
    /// start/end of the album doesn't churn state.
    private func rebuildWindow(around id: String) {
        guard let idx = indexByID[id] else {
            if pages != [id] { pages = [id] }
            return
        }
        let lo = max(0, idx - windowBack)
        let hi = min(allIDs.count, idx + windowForward + 1)
        let next = Array(allIDs[lo..<hi])
        if next != pages {
            pages = next   // `.scrollPosition(id:)` keeps `currentID` put across this
            Perf.event("viewer.window [\(lo)..<\(hi)] n=\(next.count) around \(id.suffix(8))")
        }
    }

    /// When the current photo nears either end of the window, re-center the window on it. Most swipes
    /// sit mid-window and do nothing; a slide only fires every ~`windowForward` photos.
    private func slideWindowIfNeeded() {
        guard let local = pages.firstIndex(of: currentID) else {
            rebuildWindow(around: currentID)
            return
        }
        if local < rebuildMargin || local > pages.count - 1 - rebuildMargin {
            rebuildWindow(around: currentID)
        }
    }

    // MARK: Chrome (floats on scrims over the photo — Liquid Glass behavior)

    private var topBar: some View {
        let isSelected = selection.contains(currentID)
        let position = (indexByID[currentID] ?? 0) + 1
        return HStack(spacing: 12) {
            Button { coordinator.pop() } label: {
                Image(systemName: "chevron.left")
                    .font(.title3.weight(.semibold))
                    .frame(minWidth: 44, minHeight: 44)   // ≥44pt hit target (HIG)
            }
            .contentShape(Rectangle())
            .accessibilityLabel("Back to the grid")
            Spacer()
            positionLabel(position)
            Spacer()
            Button { selection.toggle(currentID) } label: {
                selectionGlyph(isSelected).frame(minWidth: 44, minHeight: 44)
            }
            .contentShape(Rectangle())
            .accessibilityLabel("Select photo")
            .accessibilityValue(isSelected ? "selected" : "")
            .accessibilityAddTraits(.isToggle)
            .sensoryFeedback(.selection, trigger: isSelected)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .background(scrim(.top))
    }

    /// The centered title: the current photo's calendar day over its position in the album, e.g.
    /// "Sat, Jul 5" / "12 of 53" (design WZ-0). With no review context the day map is empty, so it
    /// degrades to just the position.
    private func positionLabel(_ position: Int) -> some View {
        let day = dayLabel(for: currentID)
        let count = allIDs.count   // position is over the whole album, not the render window
        return VStack(spacing: 1) {
            if !day.isEmpty {
                Text(day)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)   // a long day at AX type sizes shrinks, not crowds the buttons
            }
            Text("\(position) of \(count)")
                .font(day.isEmpty ? .subheadline.weight(.medium) : .caption)
                .foregroundStyle(.white.opacity(day.isEmpty ? 1 : 0.75))
                .monospacedDigit()
        }
        .shadow(color: .black.opacity(0.4), radius: 2)   // legible over a bright photo, like the glyphs
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(day.isEmpty ? "Photo \(position) of \(count)"
                                        : "\(day), photo \(position) of \(count)")
    }

    /// The current photo's day, "" when there's no review context (the day map is empty).
    private func dayLabel(for id: String) -> String {
        coordinator.reviewDayByID[id].map { DayGroupHeader.dayLabel(for: $0) } ?? ""
    }

    /// The per-page VoiceOver label: "Photo, Sat, Jul 5, 7 of 13" (day dropped if unavailable).
    private func photoAXLabel(for id: String) -> String {
        let position = (indexByID[id] ?? 0) + 1
        let day = dayLabel(for: id)
        return day.isEmpty ? "Photo, \(position) of \(allIDs.count)"
                           : "Photo, \(day), \(position) of \(allIDs.count)"
    }

    @ViewBuilder
    private func selectionGlyph(_ isSelected: Bool) -> some View {
        if isSelected {
            // Gold circle, dark check — the same affordance as the grid (styleguide §1).
            Image(systemName: "checkmark.circle.fill")
                .font(.title)
                .foregroundStyle(Color.onAccent, Color.accentColor)
        } else {
            Image(systemName: "circle")
                .font(.title)
                .foregroundStyle(.white)
                .shadow(radius: 2)
        }
    }

    /// The live tally over the filmstrip scrubber (design WZ-0). The strip both orients (where am I,
    /// what's picked) and jumps; the tally keeps the running count visible while you scrub.
    private var bottomBar: some View {
        VStack(spacing: 12) {
            tally
            Filmstrip(pages: pages, currentID: $currentID)
        }
        .padding(.top, 18)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity)
        .background(scrim(.bottom))
    }

    private var tally: some View {
        let progress = selection.progress
        return (Text("\(progress.picked)").fontWeight(.semibold)
            + Text(" / \(progress.target) picked").foregroundStyle(.white.opacity(0.7)))
            .font(.subheadline)
            .monospacedDigit()
            .foregroundStyle(.white)
            .accessibilityLabel("\(progress.picked) of \(progress.target) picked")
    }

    private func scrim(_ edge: VerticalEdge) -> some View {
        let stops: [Gradient.Stop] = edge == .top
            ? [.init(color: .black.opacity(0.45), location: 0), .init(color: .clear, location: 1)]
            : [.init(color: .clear, location: 0), .init(color: .black.opacity(0.45), location: 1)]
        return LinearGradient(stops: stops, startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
            .allowsHitTesting(false)
    }
}

/// One full-screen page: progressive thumbnail → full-resolution, fit to the screen on black.
private struct PhotoPage: View {
    let id: String
    /// The day + position, prebuilt by the viewer (which holds the day map + index) so the photo
    /// element carries real context for VoiceOver — "Photo, Sat, Jul 5, 7 of 13" — not just "Photo".
    let accessibilityLabel: String
    @Environment(\.thumbnailProvider) private var thumbnails
    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                if let image {
                    ZoomableScrollView(image: image)   // pinch-zoom / pan / double-tap
                } else {
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
            .task(id: id) {
                Perf.event("page.task \(id.suffix(8))")   // a page materialized — should be only a few
                // Paint the already-decoded thumbnail first (no black flash), then the full-res.
                if image == nil,
                   let cached = thumbnails.cachedThumbnail(for: id, targetSize: CGSize(width: 400, height: 400)) {
                    image = cached
                }
                let pixels = CGSize(width: geo.size.width * displayScale, height: geo.size.height * displayScale)
                let started = Perf.begin()
                let full = await thumbnails.fullImage(for: id, targetSize: pixels)
                Perf.endIO("page.fullImage \(id.suffix(8))", since: started)
                if let full { image = full }
            }
        }
    }
}
