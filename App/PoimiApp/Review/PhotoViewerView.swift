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
import Curation

struct PhotoViewerView: View {
    /// The asset tapped in the grid — the page the viewer opens on.
    let startID: String
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(SelectionStore.self) private var selection
    @Environment(DoneStore.self) private var doneStore
    @Environment(\.thumbnailProvider) private var thumbnails
    @Environment(\.displayScale) private var displayScale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var currentID: String
    /// The cluster just auto-marked done by paging past its end (#128) — drives the undoable toast. `nil`
    /// hides it. Auto-done is opinionated, so it MUST be obviously reversible: a haptic + this toast.
    @State private var autoDoneCluster: ReviewCluster?
    /// Bumped on each auto-mark so `.sensoryFeedback` fires a success haptic.
    @State private var autoDoneHaptic = 0
    /// A bounded window of candidates around the current photo — for the FILMSTRIP only. The pager
    /// windows itself; the filmstrip is a SwiftUI `LazyHStack` whose `.scrollPosition` to a mid-list id
    /// would materialise its whole prefix, so this keeps it to a few dozen thumbs and slides as you swipe.
    @State private var filmstripPages: [String] = []
    /// A copy of the current photo painting the sheet's ambient background (the Now-Playing colour
    /// wash). Loaded cache-first at the grid's 400² key, so it's usually instant.
    @State private var ambientImage: UIImage?
    /// Whether the ⓘ info panel is showing (#127). It swaps in for the filmstrip in the lower chrome;
    /// the Pick control stays above it, so you can judge + pick with the metadata in view.
    @State private var showInfoPanel = false
    /// The viewer's info labels, formatted ONCE when `currentID` settles (never in a `body`, repo rule):
    /// the date line's capture time + the panel's resolution. Async fields (device, file size) are a
    /// follow-up; this is the free tier (straight from the published `AssetRef`).
    @State private var info = InfoLabels()

    private let windowBack = 25
    private let windowForward = 25
    private let rebuildMargin = 5

    /// The grid's quantized thumbnail size — the primary instant-paint cache for a viewer page.
    private var gridThumbSize: CGSize { CGSize(width: 400, height: 400) }
    /// The filmstrip's small thumbnail size (same key `prefetchFilmstrip` warms) — the fallback floor so
    /// a page paints something even when the 400² isn't cached (#158).
    private var filmstripThumbSize: CGSize {
        let px = Filmstrip.thumbnailLoadSide * displayScale
        return CGSize(width: px, height: px)
    }

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
        // Track the on-screen photo (grid restore anchor) and slide + warm the filmstrip with it. This
        // fires for ANY currentID change (swipe, filmstrip tap, open); auto-done is deliberately NOT here
        // — it's driven off the pager's swipe delegate so a filmstrip tap can't mark a cluster done (#128).
        .onChange(of: currentID) { _, current in
            coordinator.lastViewedID = current
            refreshInfo(for: current)
            slideFilmstripIfNeeded()
            prefetchFilmstrip(around: current)
        }
        .onAppear {
            refreshInfo(for: startID)
            rebuildFilmstrip(around: startID)
            prefetchFilmstrip(around: startID)
        }
        .sensoryFeedback(.success, trigger: autoDoneHaptic)
        .overlay(alignment: .bottom) { autoDoneToast }
    }

    // MARK: Auto-mark-done on paging past a cluster's end (#128)

    /// Forward-paging past a cluster's last photo marks it done — once, forward-only (backward paging
    /// never marks/un-marks), reconciling through the same `DoneStore`/`Completion` path as the grid's
    /// button (so it reflects in the grid on return, #126). Opinionated, so it fires a success haptic +
    /// an undoable toast. (Deferred to #128 follow-up: an end-of-album terminal affordance + an opt-out.)
    private func autoMarkDoneIfPagedPastCluster(from previous: String, to current: String) {
        guard let finished = clusterToAutoMarkDone(from: previous, to: current,
                                                   clusters: coordinator.reviewClusters,
                                                   isDone: doneStore.isDone) else { return }
        doneStore.toggle(finished)
        autoDoneHaptic &+= 1
        autoDoneCluster = finished
    }

    /// A brief, undoable "Marked <day> done" toast — the reversibility affordance for the automatic mark.
    @ViewBuilder
    private var autoDoneToast: some View {
        if let cluster = autoDoneCluster {
            HStack(spacing: 12) {
                Label(toastTitle(for: cluster), systemImage: "checkmark.seal.fill")
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Button("Undo") {
                    doneStore.toggle(cluster)      // reverse the auto-mark
                    autoDoneCluster = nil
                }
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.borderless)
                .tint(Color.accentColor)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .glassEffect(.regular, in: Capsule())   // native iOS 26 glass (pure-glass invariant)
            .foregroundStyle(.white)
            .padding(.bottom, 12)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .accessibilityElement(children: .combine)
            // Auto-dismiss after a few seconds (re-armed each time a new cluster is marked).
            .task(id: cluster.id) {
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled else { return }
                withAnimation(reduceMotion ? nil : .easeOut) { autoDoneCluster = nil }
            }
        }
    }

    /// The toast label. For a SINGLE-day cluster, name the day ("Marked Sat, Jul 5 done"). For a trip or a
    /// merged multi-day run, a single date would mislead (it marks the whole span, and the trip name isn't
    /// in the viewer's scope), so fall back to the plain "Marked done".
    private func toastTitle(for cluster: ReviewCluster) -> String {
        let datedDays = cluster.days.filter { $0 != .undated }
        let day = datedDays.count == 1 ? (cluster.assetIDs.first.map(dayLabel) ?? "") : ""
        return day.isEmpty
            ? String(localized: "Marked done", comment: "Viewer auto-done toast (trip / multi-day / undated)")
            : String(localized: "Marked \(day) done", comment: "Viewer auto-done toast: which single day was marked")
    }

    // MARK: The centred photo — the "album art": a rounded, shadowed pager the chrome never overlaps.

    private var photoCard: some View {
        PhotoPagerView(
            allIDs: allIDs,
            currentID: $currentID,
            // Paint whatever thumbnail is ALREADY cached so a page is never a bare black rectangle while
            // its full-res loads (or if that fails): the grid's 400² first, else the filmstrip's small
            // thumb — which is often warm for the current photo even when the 400² isn't (#158).
            cachedThumb: { id in
                thumbnails.cachedThumbnail(for: id, targetSize: gridThumbSize)
                    ?? thumbnails.cachedThumbnail(for: id, targetSize: filmstripThumbSize)
            },
            loadFull: { await thumbnails.fullImage(for: $0, targetSize: $1) },
            axLabel: { photoAXLabel(for: $0) },
            onTapPhoto: { selection.toggle($0) },   // single-tap the photo = pick (Pick button is primary)
            // Auto-done fires on a real SWIPE only (not a filmstrip tap), so browsing/jumping never marks (#128).
            onSwipe: { autoMarkDoneIfPagedPastCluster(from: $0, to: $1) })
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            // ⓘ at the photo's bottom-right corner — reveals the info panel; photo-first chrome is
            // otherwise untouched until you tap it (#127).
            .overlay(alignment: .bottomTrailing) { infoButton }
            .shadow(color: .black.opacity(0.35), radius: 20, y: 8)
            .padding(.horizontal, 12)
            .padding(.top, 28)   // clears the sheet grabber (harmless inset in the harness)
            .frame(maxHeight: .infinity)
    }

    /// The ⓘ toggle: a small glass circle inset in the photo's bottom-right. Fills + tints gold while
    /// the panel is open. Toggling animates the filmstrip↔panel swap in the chrome below.
    private var infoButton: some View {
        Button {
            withAnimation(reduceMotion ? nil : .snappy) { showInfoPanel.toggle() }
        } label: {
            Image(systemName: showInfoPanel ? "info.circle.fill" : "info.circle")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(showInfoPanel ? Color.accentColor : .white)
                .frame(width: 38, height: 38)
                .glassEffect(.regular, in: Circle())   // native iOS 26 glass (pure-glass invariant)
        }
        .buttonStyle(.plain)
        .padding(12)
        .accessibilityLabel("Photo info")
        .accessibilityValue(showInfoPanel ? "Shown" : "Hidden")
        .accessibilityAddTraits(.isToggle)
    }

    // MARK: The control band beneath the photo (title · tally · the Pick hero · the filmstrip scrubber)

    private var chrome: some View {
        VStack(spacing: 16) {
            titleRow
            pickButton
            // The info panel takes the filmstrip's slot while open — Pick + the title/tally stay above,
            // so you can pick with the metadata in view; the photo above yields height as the panel grows.
            if showInfoPanel {
                PhotoInfoPanel(labels: info)
            } else {
                Filmstrip(pages: filmstripPages, currentID: $currentID)
            }
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
        let line = info.dateTime   // "Sat, Jul 5 · 14.32" — day + capture time (#127), formatted off-body
        return VStack(alignment: .leading, spacing: 2) {
            if !line.isEmpty {
                Text(line)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            Text("\(position) of \(ids.count)")
                .font(line.isEmpty ? .title3.weight(.semibold) : .subheadline)
                .foregroundStyle(line.isEmpty ? .white : .white.opacity(0.7))
                .monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(line.isEmpty ? "Photo \(position) of \(ids.count)"
                                         : "\(line), photo \(position) of \(ids.count)")
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

    /// Re-format the info labels for `id` — called when `currentID` settles / on appear, NEVER in a body
    /// (repo rule). Free tier (#127): the day + capture time for the date line, and the resolution for the
    /// panel, both from the published `AssetRef`. Async device + file size are a follow-up.
    private func refreshInfo(for id: String) {
        let asset = coordinator.reviewAssetsByID[id]
        let time = asset?.captureDate.map { $0.formatted(.dateTime.hour().minute()) } ?? ""
        let pixelSize = asset?.pixelSize
        info = InfoLabels(
            dateTime: PhotoInfoFormat.dateTimeLine(day: dayLabel(for: id), time: time),
            resolution: pixelSize.map(PhotoInfoFormat.resolution) ?? "",
            resolutionA11y: pixelSize.map(Self.resolutionA11y) ?? "")
    }

    /// VoiceOver form of the resolution ("Resolution, 4032 by 3024, 12 megapixels").
    private static func resolutionA11y(_ pixelSize: PixelSize) -> String {
        guard pixelSize.width > 0, pixelSize.height > 0 else { return "" }
        let mp = Int((Double(pixelSize.pixelCount) / 1_000_000).rounded())
        return mp >= 1
            ? String(localized: "Resolution, \(pixelSize.width) by \(pixelSize.height), \(mp) megapixels",
                     comment: "Viewer info a11y: resolution + megapixels")
            : String(localized: "Resolution, \(pixelSize.width) by \(pixelSize.height)",
                     comment: "Viewer info a11y: resolution")
    }

    /// The per-page VoiceOver label: "Photo, Sat, Jul 5, 7 of 13" (day dropped if unavailable).
    private func photoAXLabel(for id: String) -> String {
        let ids = allIDs
        let position = (ids.firstIndex(of: id) ?? 0) + 1
        let day = dayLabel(for: id)
        return day.isEmpty
            ? String(localized: "Photo, \(position) of \(ids.count)", comment: "Viewer a11y: position, no day")
            : String(localized: "Photo, \(day), \(position) of \(ids.count)", comment: "Viewer a11y: day, position")
    }
}

/// The viewer's preformatted info strings (#127) — held in `@State`, recomputed only when `currentID`
/// settles, so no date/number formatting runs in a `body`.
private struct InfoLabels: Equatable {
    var dateTime = ""
    var resolution = ""
    var resolutionA11y = ""
}

/// The metadata panel (design 4FE) — a glass card revealed by the viewer's ⓘ, swapped in for the
/// filmstrip. Phase 1 (free tier, #127) shows the resolution; the async device + file-size rows are a
/// follow-up (they need a `metadata(for:)` provider capability + a persisted cache), and will slot in
/// here. Closes by tapping ⓘ again.
private struct PhotoInfoPanel: View {
    let labels: InfoLabels

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row(systemImage: "aspectratio",
                value: labels.resolution.isEmpty ? "—" : labels.resolution,
                a11y: labels.resolutionA11y)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))   // native iOS 26 glass
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func row(systemImage: String, value: String, a11y: String) -> some View {
        HStack(spacing: 13) {
            Image(systemName: systemImage)
                .font(.system(size: 18))
                .foregroundStyle(.white.opacity(0.65))
                .frame(width: 24)
            Text(value)
                .font(.body)
                .foregroundStyle(.white)
        }
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(a11y)
    }
}

/// Pure display formatting for the viewer's info fields (#127), kept out of the view so it's unit-tested
/// (the no-formatting-in-body rule). `Curation` stays string-free (D14/D21), so these app-facing strings
/// live here, not in the domain.
enum PhotoInfoFormat {
    /// "4032 × 3024 · 12 MP" — dimensions + rounded megapixels (MP dropped below ~0.5 MP). "" for a
    /// zero/empty size.
    static func resolution(_ pixelSize: PixelSize) -> String {
        guard pixelSize.width > 0, pixelSize.height > 0 else { return "" }
        let dims = "\(pixelSize.width) × \(pixelSize.height)"
        let mp = Int((Double(pixelSize.pixelCount) / 1_000_000).rounded())
        return mp >= 1 ? "\(dims) · \(mp) MP" : dims
    }

    /// Join the day + capture time for the viewer's date line: "Sat, Jul 5 · 14.32". Either piece may be
    /// empty (no review context → no day; an undated asset → no time); the " · " appears only when both do.
    static func dateTimeLine(day: String, time: String) -> String {
        switch (day.isEmpty, time.isEmpty) {
        case (false, false): return "\(day) · \(time)"
        case (false, true): return day
        case (true, false): return time
        case (true, true): return ""
        }
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

/// The cluster to auto-mark done (#128) when the viewer pages from `previousID` to `currentID`: non-nil
/// ONLY when `previousID` was the LAST photo of its cluster and `currentID` is the FIRST photo of the
/// immediately-following cluster — the deliberate "I paged past the end of this cluster" signal. Returns
/// nil for backward paging (never un-marks), mid-cluster paging, a non-adjacent filmstrip jump, or the
/// final cluster (nothing to page into). Pure + unit-tested; the trigger/toast is eyeballed on device.
func clusterFinishedByPagingPast(from previousID: String, to currentID: String,
                                 clusters: [ReviewCluster]) -> ReviewCluster? {
    guard let prev = clusters.firstIndex(where: { $0.assetIDs.contains(previousID) }),
          previousID == clusters[prev].assetIDs.last,          // was on that cluster's LAST photo
          clusters.indices.contains(prev + 1),                 // there is a next cluster
          currentID == clusters[prev + 1].assetIDs.first       // landed on its FIRST photo (adjacent, fwd)
    else { return nil }
    return clusters[prev]
}

/// The cluster to actually auto-mark done on a swipe from `previousID`→`currentID`: the finished cluster
/// (per `clusterFinishedByPagingPast`) UNLESS it's already done. Folding the idempotency guard in here (vs
/// inline in the view) makes it unit-testable — re-crossing an already-done boundary must be a no-op, so a
/// back-and-forth never re-toggles (#128). `isDone` is injected (the view passes `doneStore.isDone`).
func clusterToAutoMarkDone(from previousID: String, to currentID: String, clusters: [ReviewCluster],
                           isDone: (ReviewCluster) -> Bool) -> ReviewCluster? {
    guard let finished = clusterFinishedByPagingPast(from: previousID, to: currentID, clusters: clusters),
          !isDone(finished) else { return nil }
    return finished
}
