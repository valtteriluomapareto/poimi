//
//  PhotoViewerView.swift
//  PoimiApp — the full-screen photo viewer (issue #36, D10/D22; pager #80).
//
//  Presented as a MODAL CARD (a `.sheet`, #36 revision) — it rises from the bottom, carries a grabber,
//  and you pull it down to dismiss: the "single-song" Now-Playing feel. The photo is CENTRED like album
//  art in a rounded card, the controls sit in a band BENEATH it (never overlapping the image), and the
//  background is an ambient blur of the current photo, so the card takes on the image's colour.
//
//  The photo is a `UIPageViewController` pager (`PhotoPagerView`) windowing the album's candidates —
//  swipe the photo to page (like swapping tracks). The sheet owns the vertical pull-to-dismiss: a
//  down-drag on an un-zoomed photo isn't claimed by the horizontal pager or the base-zoom-disabled
//  inner scroll, so the sheet's interactive dismiss gets it (once zoomed, the inner scroll pans instead
//  and the sheet defers). Pinch / double-tap zoom and tap-to-pick still work per page.
//

import SwiftUI
import UIKit

struct PhotoViewerView: View {
    /// The asset tapped in the grid — the page the viewer opens on.
    let startID: String
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(SelectionStore.self) private var selection
    @Environment(\.thumbnailProvider) private var thumbnails
    @Environment(\.displayScale) private var displayScale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var currentID: String
    /// A bounded window of candidates around the current photo — for the FILMSTRIP only. The pager
    /// windows itself; the filmstrip is a SwiftUI `LazyHStack` whose `.scrollPosition` to a mid-list id
    /// would materialise its whole prefix, so this keeps it to a few dozen thumbs and slides as you swipe.
    @State private var filmstripPages: [String] = []
    /// A copy of the current photo painting the sheet's ambient background (the Now-Playing colour
    /// wash). Loaded cache-first at the grid's 400² key, so it's usually instant.
    @State private var ambientImage: UIImage?

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
        VStack(spacing: 0) {
            photoCard
            chrome
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The ambient wash is a plain background (not `.presentationBackground`) so it renders both
        // inside the real sheet AND when the screenshot harness hosts the view directly. It's opaque,
        // so it fully backs the card; the sheet chrome (corners, grabber, pull-to-dismiss) comes from
        // the detent + drag-indicator below, which are no-ops outside a sheet.
        .background { ambientBackground }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        // The ambient wash follows the photo (cache-first; auto-cancels on a further page turn).
        .task(id: currentID) {
            let size = CGSize(width: 400, height: 400)
            if let cached = thumbnails.cachedThumbnail(for: currentID, targetSize: size) {
                ambientImage = cached
            } else {
                let loaded = await thumbnails.thumbnail(for: currentID, targetSize: size)
                guard !Task.isCancelled else { return }   // a fast page-turn cancelled us — don't paint a stale wash
                ambientImage = loaded
            }
        }
        // Track the on-screen photo (grid restore anchor) and slide + warm the filmstrip with it.
        .onChange(of: currentID) {
            coordinator.lastViewedID = currentID
            slideFilmstripIfNeeded()
            prefetchFilmstrip(around: currentID)
        }
        .onAppear {
            rebuildFilmstrip(around: startID)
            prefetchFilmstrip(around: startID)
        }
    }

    // MARK: The centred photo — the "album art": a rounded, shadowed pager the chrome never overlaps.

    private var photoCard: some View {
        PhotoPagerView(
            allIDs: allIDs,
            currentID: $currentID,
            cachedThumb: { thumbnails.cachedThumbnail(for: $0, targetSize: CGSize(width: 400, height: 400)) },
            loadFull: { await thumbnails.fullImage(for: $0, targetSize: $1) },
            axLabel: { photoAXLabel(for: $0) },
            onTapPhoto: { selection.toggle($0) })   // single-tap the photo = pick (2nd path; the Pick button is primary)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .shadow(color: .black.opacity(0.35), radius: 20, y: 8)
            .padding(.horizontal, 12)
            .padding(.top, 28)   // clears the sheet grabber (harmless inset in the harness)
            .frame(maxHeight: .infinity)
    }

    // MARK: The control band beneath the photo (title · tally · the Pick hero · the filmstrip scrubber)

    private var chrome: some View {
        VStack(spacing: 16) {
            titleRow
            pickButton
            Filmstrip(pages: filmstripPages, currentID: $currentID)
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 8)
    }

    /// The current photo's day + position (like a track title / subtitle) with the live tally trailing.
    /// At accessibility Dynamic-Type sizes the tally drops BELOW the title instead of sharing one line
    /// (mirrors `ReviewSectionHeader` — shrinking the user's chosen size is itself an a11y regression,
    /// so we reflow, not squeeze). With no review context the day map is empty → just the position.
    @ViewBuilder
    private var titleRow: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 6) {
                titleBlock
                tallyLabel
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(.white)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                titleBlock
                Spacer(minLength: 0)
                tallyLabel
            }
            .foregroundStyle(.white)
        }
    }

    /// The day (title) over "N of M" (subtitle); day dropped when there's no review context.
    private var titleBlock: some View {
        let ids = allIDs
        let position = (ids.firstIndex(of: currentID) ?? 0) + 1
        let day = dayLabel(for: currentID)
        return VStack(alignment: .leading, spacing: 2) {
            if !day.isEmpty {
                Text(day)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            Text("\(position) of \(ids.count)")
                .font(day.isEmpty ? .title3.weight(.semibold) : .subheadline)
                .foregroundStyle(day.isEmpty ? .white : .white.opacity(0.7))
                .monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(day.isEmpty ? "Photo \(position) of \(ids.count)"
                                        : "\(day), photo \(position) of \(ids.count)")
    }

    /// The live target tally, glanceable beside the title (gold count / target — echoes the grid tally).
    private var tallyLabel: some View {
        let progress = selection.progress
        return (Text("\(progress.picked)").foregroundStyle(Color.accentColor).fontWeight(.semibold)
            + Text(" / \(progress.target)").foregroundStyle(.white.opacity(0.6)))
            .font(.subheadline)
            .monospacedDigit()
            .accessibilityLabel("\(progress.picked) of \(progress.target) picked")
    }

    /// The primary pick action — the Now-Playing "play" analog: a big glass toggle centred under the
    /// photo. Clear glass "Pick" when unpicked; a prominent GOLD "Picked" (dark check) when picked —
    /// gold is the interactive accent (styleguide §1/§6), matching the grid's gold check, and
    /// "Pick/Picked" matches the tally's vocabulary. Tapping the photo is the secondary accelerator;
    /// the filmstrip stays navigation-only (each thumb already carries its own gold check).
    @ViewBuilder
    private var pickButton: some View {
        let isSelected = selection.contains(currentID)
        let button = Button { selection.toggle(currentID) } label: {
            Label(isSelected ? "Picked" : "Pick",
                  systemImage: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.headline)
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
        }
        .controlSize(.large)
        .sensoryFeedback(.selection, trigger: isSelected)
        .accessibilityLabel("Pick photo")
        .accessibilityValue(isSelected ? "Picked" : "Not picked")
        .accessibilityAddTraits(.isToggle)

        if isSelected {
            button.buttonStyle(.glassProminent).tint(Color.accentColor).foregroundStyle(Color.onAccent)
        } else {
            button.buttonStyle(.glass).foregroundStyle(.white)
        }
    }

    // MARK: Ambient background — a heavy blur of the current photo (the card's colour wash)

    private var ambientBackground: some View {
        ZStack {
            Color.black
            if let ambientImage {
                Image(uiImage: ambientImage)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: 44, opaque: true)
                    .overlay(Color.black.opacity(0.5))
            }
        }
        .ignoresSafeArea()
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

    /// Warm the filmstrip's lead thumbs at the STRIP's ~56pt size, ahead of appearance. The grid's
    /// 400² caching window doesn't serve these small requests, so without this each thumb pops in
    /// on-demand as it scrolls in (the "strip updates slowly" lag). Only the not-yet-cached leading
    /// ids are requested; combined with the filmstrip's cache-first paint, warmed thumbs appear instantly.
    private func prefetchFilmstrip(around id: String) {
        let ids = allIDs
        guard let idx = ids.firstIndex(of: id) else { return }
        // ±8 covers the ~7–9 thumbs visible in the strip plus a small lead in each swipe direction.
        let lead = viewerWindow(count: ids.count, around: idx, back: 8, forward: 8)
        let px = Filmstrip.thumbnailLoadSide * displayScale   // shared size → warms the strip's exact cache key
        let size = CGSize(width: px, height: px)
        let provider = thumbnails
        let targets = ids[lead].filter { provider.cachedThumbnail(for: $0, targetSize: size) == nil }
        guard !targets.isEmpty else { return }
        // `.utility`: never steal PhotoKit/actor time from the current photo's full-res load (that's
        // what the user is waiting for). Not cancelled on a further swipe — overlapping batches just
        // warm the cache and the cache-first filter above dedups next time; cancelling would only lose
        // warmth on a fast swipe.
        Task(priority: .utility) {
            await withTaskGroup(of: Void.self) { group in
                for tid in targets {
                    group.addTask { _ = await provider.thumbnail(for: tid, targetSize: size) }
                }
            }
        }
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
