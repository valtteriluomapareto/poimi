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
    /// The pages to swipe + an id→index map, resolved once on appear so the position lookup is O(1)
    /// per render rather than scanning the candidate list. Fall back to just this photo if the
    /// shared list isn't populated (viewer opened without a live review context).
    @State private var pages: [String] = []
    @State private var indexByID: [String: Int] = [:]

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
        // pages (so a thousands-photo album stays light — the TabView(.page) scale risk is gone),
        // `.scrollTargetBehavior(.paging)` snaps page-to-page, and `.scrollPosition` two-way-binds
        // the current page id. Each page is a `ZoomableScrollView` (pinch-zoom / pan / double-tap).
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(pages, id: \.self) { id in
                        PhotoPage(id: id)
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
            .overlay(alignment: .bottom) { bottomTally }
            .toolbar(.hidden, for: .navigationBar)
            // Keep the shared anchor on the photo in view, so the grid restores here and the `.zoom`
            // return pairs with this cell.
            .onChange(of: currentID) { coordinator.lastViewedID = currentID }
            .onAppear {
                let list = coordinator.reviewOrderedIDs.contains(startID) ? coordinator.reviewOrderedIDs : [startID]
                pages = list
                indexByID = Dictionary(list.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
                // `.scrollPosition` to a *mid-list* id in a `LazyHStack` doesn't reliably land on the
                // first layout (the target page isn't built yet), so scroll to it explicitly once the
                // pages exist — otherwise the viewer opens on page 0 while the chrome reads the tapped
                // photo's position.
                DispatchQueue.main.async { proxy.scrollTo(startID, anchor: .center) }
            }
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
            Text("\(position) of \(pages.count)")
                .font(.subheadline.weight(.medium))
                .monospacedDigit()
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

    private var bottomTally: some View {
        let progress = selection.progress
        return (Text("\(progress.picked)").fontWeight(.semibold)
            + Text(" / \(progress.target) picked").foregroundStyle(.white.opacity(0.7)))
            .font(.subheadline)
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.bottom, 16)
            .padding(.top, 20)
            .frame(maxWidth: .infinity)
            .background(scrim(.bottom))
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
            .accessibilityLabel("Photo")   // the per-photo date label rides #36 part 2b
            .task(id: id) {
                // Paint the already-decoded thumbnail first (no black flash), then the full-res.
                if image == nil,
                   let cached = thumbnails.cachedThumbnail(for: id, targetSize: CGSize(width: 400, height: 400)) {
                    image = cached
                }
                let pixels = CGSize(width: geo.size.width * displayScale, height: geo.size.height * displayScale)
                if let full = await thumbnails.fullImage(for: id, targetSize: pixels) {
                    image = full
                }
            }
        }
    }
}
