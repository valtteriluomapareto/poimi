//
//  PhotoViewerView.swift
//  PoimiApp — the full-screen photo viewer (issue #36, D10/D22; pager #80).
//
//  The borderline-call tier of the two-tier picking model: a swipeable pager over the album's
//  candidate ids. You swipe between photos and SELECT IN PLACE; the selection is preserved on the
//  shared `SelectionStore`, so "open to decide" is itself a fast multi-select path, not a dead end.
//
//  The pager is a `UIPageViewController` (`PhotoPagerView`) — UIKit cleanly separates horizontal
//  paging from the vertical swipe-down-to-dismiss (SwiftUI's paging scroll claimed the drag, turning
//  a dismiss into a sideswipe), and it windows itself so a thousands-photo album never materialises
//  a giant stack. This view owns the chrome (day label + position + select; tally + filmstrip) that
//  floats over the pager, and the shared `currentID` that the pager, filmstrip, and chrome track.
//

import SwiftUI
import UIKit

struct PhotoViewerView: View {
    /// The asset tapped in the grid — the page the viewer opens on.
    let startID: String
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(SelectionStore.self) private var selection
    @Environment(\.thumbnailProvider) private var thumbnails
    @State private var currentID: String
    /// A bounded window of candidates around the current photo — for the FILMSTRIP only. The pager
    /// (UIPageViewController) windows itself, but the filmstrip is a SwiftUI `LazyHStack` whose
    /// `.scrollPosition` to a mid-list id would materialise its whole prefix; the window keeps it
    /// to a few dozen thumbnails and slides as you swipe.
    @State private var filmstripPages: [String] = []

    private let windowBack = 25
    private let windowForward = 25
    private let rebuildMargin = 5

    init(startID: String) {
        self.startID = startID
        _currentID = State(initialValue: startID)
    }

    /// Every candidate, in order — the pager's universe; falls back to just this photo with no live
    /// review context. (COW array, so passing it to the pager is cheap.)
    private var allIDs: [String] {
        coordinator.reviewOrderedIDs.contains(startID) ? coordinator.reviewOrderedIDs : [startID]
    }

    var body: some View {
        PhotoPagerView(
            allIDs: allIDs,
            currentID: $currentID,
            cachedThumb: { thumbnails.cachedThumbnail(for: $0, targetSize: CGSize(width: 400, height: 400)) },
            loadFull: { await thumbnails.fullImage(for: $0, targetSize: $1) },
            axLabel: { photoAXLabel(for: $0) },
            onDismiss: { coordinator.pop() })
            .background(Color.black)
            .ignoresSafeArea()
            .overlay(alignment: .top) { topBar }
            .overlay(alignment: .bottom) { bottomBar }
            .toolbar(.hidden, for: .navigationBar)
            // Track the on-screen photo (grid restore anchor) and slide the filmstrip window with it.
            .onChange(of: currentID) {
                coordinator.lastViewedID = currentID
                slideFilmstripIfNeeded()
            }
            .onAppear { rebuildFilmstrip(around: startID) }
    }

    // MARK: Filmstrip window (the pager windows itself; this is just for the SwiftUI strip)

    private func rebuildFilmstrip(around id: String) {
        let ids = allIDs
        guard let idx = ids.firstIndex(of: id) else {
            if filmstripPages != [id] { filmstripPages = [id] }
            return
        }
        let range = viewerWindow(count: ids.count, around: idx, back: windowBack, forward: windowForward)
        let next = Array(ids[range])
        if next != filmstripPages { filmstripPages = next }
    }

    private func slideFilmstripIfNeeded() {
        guard let local = filmstripPages.firstIndex(of: currentID) else {
            rebuildFilmstrip(around: currentID)
            return
        }
        if local < rebuildMargin || local > filmstripPages.count - 1 - rebuildMargin {
            rebuildFilmstrip(around: currentID)
        }
    }

    // MARK: Chrome (floats on scrims over the photo — Liquid Glass behavior)

    private var topBar: some View {
        let ids = allIDs
        let isSelected = selection.contains(currentID)
        let position = (ids.firstIndex(of: currentID) ?? 0) + 1
        return HStack(spacing: 12) {
            Button { coordinator.pop() } label: {
                Image(systemName: "chevron.left")
                    .font(.title3.weight(.semibold))
                    .frame(minWidth: 44, minHeight: 44)   // ≥44pt hit target (HIG)
            }
            .contentShape(Rectangle())
            .accessibilityLabel("Back to the grid")
            Spacer()
            positionLabel(position, of: ids.count)
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
    private func positionLabel(_ position: Int, of count: Int) -> some View {
        let day = dayLabel(for: currentID)
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
        let ids = allIDs
        let position = (ids.firstIndex(of: id) ?? 0) + 1
        let day = dayLabel(for: id)
        return day.isEmpty ? "Photo, \(position) of \(ids.count)"
                           : "Photo, \(day), \(position) of \(ids.count)"
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
            Filmstrip(pages: filmstripPages, currentID: $currentID)
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

/// The bounded window of indices to render around `index` in a list of `count` — `back` before and
/// `forward` after, clamped to `0..<count`. Pulled out of the view (like `clampedColumnCount` /
/// `PrefetchWindow`) so the invariant is unit-tested without rendering: the slice ALWAYS contains
/// `index` and never exceeds `back + forward + 1`.
func viewerWindow(count: Int, around index: Int, back: Int, forward: Int) -> Range<Int> {
    guard count > 0 else { return 0..<0 }
    let clamped = min(max(index, 0), count - 1)
    let lo = max(0, clamped - back)
    let hi = min(count, clamped + forward + 1)
    return lo..<hi
}
