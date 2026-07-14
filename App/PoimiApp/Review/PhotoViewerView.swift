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
    /// The viewer's info labels, formatted ONCE when `currentID` settles (never in a `body`, repo rule):
    /// the localized date+time line + the resolution (+ a video's duration). Async fields (device, file
    /// size) are a follow-up (#175); this is the free tier (straight from the published `AssetRef`).
    @State private var info = InfoLabels()
    /// Bumped on each pick/un-pick so `.sensoryFeedback` fires the selection haptic — the single,
    /// intent-driven confirmation a fast, eyes-on-photo triage loop needs (#180).
    @State private var pickHaptic = 0
    /// A brief bounce-guard (~150ms) after a pick auto-advances, so a fumbled double-tap on Pick can't
    /// also pick the photo that just slid in. Navigation isn't guarded — programmatic turns are instant, so
    /// rapid Next is immediate (#180).
    @State private var pickBounce = false
    /// True once you pick/Next past the LAST photo — shows the end-of-set card instead of a dead tap (#180).
    @State private var endReached = false

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
        .sensoryFeedback(.selection, trigger: pickHaptic)
        .overlay(alignment: .bottom) { autoDoneToast }
        .overlay { endOfSetCard }
        // Move VoiceOver focus to the end-of-set card when it appears (it's a modal takeover; otherwise a
        // VO user wouldn't notice the controls behind it went away).
        .onChange(of: endReached) { _, reached in
            if reached { UIAccessibility.post(notification: .screenChanged, argument: nil) }
        }
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
            .glassSurface(in: Capsule())   // native glass; RT → solid (styleguide §5) — unified with the info panel
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

    /// The end-of-set card (#180): shown after Pick/Next past the LAST photo, instead of a dead tap. Names
    /// the finish, shows the tally, and offers "Back to grid" (where Export/finalize live) — the richer
    /// "mark album done" affordance is #179's. A full-screen scrim blocks the controls behind it.
    @ViewBuilder
    private var endOfSetCard: some View {
        if endReached {
            VStack(spacing: 14) {
                Image(systemName: "flag.checkered")
                    .font(.system(size: 40))
                    .foregroundStyle(Color.accentColor)
                Text("You’ve reached the end")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                Text("\(selection.progress.picked) of \(selection.progress.target) picked")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.7))
                    .monospacedDigit()
                VStack(spacing: 10) {
                    Button { coordinator.dismissPhoto() } label: {
                        Text("Back to grid").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent).tint(Color.accentColor).foregroundStyle(Color.onAccent)
                    Button("Keep reviewing") { endReached = false }
                        .buttonStyle(.glass).foregroundStyle(.white)
                }
                .padding(.top, 6)
            }
            .padding(28)
            .frame(maxWidth: 300)
            .glassSurface(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.opacity(0.55).ignoresSafeArea())
            .accessibilityAddTraits(.isModal)
        }
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
            // The published AssetRef map decides each page's kind (photo vs video, #125); the player item
            // loads lazily on the first play tap and is unboxed here for the video page's own AVPlayer.
            assets: coordinator.reviewAssetsByID,
            loadPlayerItem: { await thumbnails.playerItem(for: $0)?.item },
            axLabel: { photoAXLabel(for: $0) },
            // Single-tap the photo = the same Pick action as the button (toggle + auto-advance) — the
            // accelerator (#180). The tapped page is always the current one, so `performPick` acts on it.
            onTapPhoto: { _ in performPick() },
            // Auto-done fires on a real SWIPE only (not a filmstrip tap), so browsing/jumping never marks (#128).
            onSwipe: { autoMarkDoneIfPagedPastCluster(from: $0, to: $1) })
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .shadow(color: .black.opacity(0.35), radius: 20, y: 8)
            .padding(.horizontal, 12)
            .padding(.top, 28)   // clears the sheet grabber (harmless inset in the harness)
            .frame(maxHeight: .infinity)
    }

    // MARK: The control band beneath the photo (date · info · counts · the Pick hero · the filmstrip)

    private var chrome: some View {
        VStack(spacing: 16) {
            metaHeader
            transportControls
            Filmstrip(pages: filmstripPages, currentID: $currentID)
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 8)
    }

    /// The photo's identity + progress (#183): TWO center-aligned rows — the compact ISO date + the gold
    /// pick tally on the first, the muted photo-info + the "N of M" position on the second. Center-aligning
    /// each row keeps the (bigger) gold tally's centre on the date's line, rather than top-aligned where it
    /// hangs below. All strings are formatted off-body in `refreshInfo` (repo rule); this only lays them out.
    private var metaHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 12) {
                if !info.dateTime.isEmpty {
                    Text(info.dateTime)
                        .font(.body)                   // ~17pt REGULAR — not semibold
                        .monospacedDigit()             // tidy, aligned digits for the ISO timestamp
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .accessibilityAddTraits(.isHeader)
                }
                Spacer(minLength: 0)
                tallyText
            }
            HStack(alignment: .center, spacing: 12) {
                if !detailLine.isEmpty {
                    Text(detailLine)
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.6))
                        .accessibilityLabel(detailA11y)
                }
                Spacer(minLength: 0)
                positionText
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The always-on photo facts (#183): a video leads with its running time, then the resolution — e.g.
    /// "0:14 · 1920 × 1080 · 2 MP" or "3024 × 4032 · 12 MP". Empty when there's no size (undated/zero).
    private var detailLine: String {
        [info.duration, info.resolution].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private var detailA11y: String {
        info.duration.isEmpty
            ? info.resolutionA11y
            : String(localized: "Video length \(info.duration). \(info.resolutionA11y)",
                     comment: "Viewer info a11y: a video's running time then its resolution")
    }

    /// The gold pick tally "163 / 500" (echoes the grid tally) — the first row's trailing item.
    private var tallyText: some View {
        let progress = selection.progress
        return (Text("\(progress.picked)").font(.title2.weight(.semibold)).foregroundStyle(Color.accentColor)
            + Text(" / \(progress.target)").font(.body).foregroundStyle(.white.opacity(0.6)))
            .monospacedDigit()
            .accessibilityLabel("\(progress.picked) of \(progress.target) picked")
    }

    /// The "N of M" position within the album — the second row's trailing item, under the tally.
    private var positionText: some View {
        let ids = allIDs
        let position = (ids.firstIndex(of: currentID) ?? 0) + 1
        return Text("\(position) of \(ids.count)")
            .font(.footnote)
            .foregroundStyle(.white.opacity(0.6))
            .monospacedDigit()
            .accessibilityLabel("Photo \(position) of \(ids.count)")
    }

    /// The triage control band (#180): **‹ Previous · Pick · Next ›**, centre-weighted like a Now-Playing
    /// transport. Pick is the hero; the chevrons are pure navigation (‹ › + swipe never change a pick —
    /// "Skip" is honestly just Next, since the only per-photo decision the model has is *picked*).
    private var transportControls: some View {
        let ids = allIDs
        let isPicked = selection.contains(currentID)
        let hasPrev = viewerStep(from: currentID, in: ids, offset: -1) != nil
        // TOP-aligned so the chevrons line up with the Pick CIRCLE's centre, not the centre of the
        // circle-plus-label block (the label hangs below and would otherwise drag the chevrons down). The
        // chevron frames match the circle's 64pt height, so top-aligned their glyph centres coincide.
        return HStack(alignment: .top, spacing: 0) {
            navButton(system: "chevron.backward", label: "Previous photo", enabled: hasPrev) { goToStep(-1) }
            Spacer(minLength: 0)
            pickToggle(isPicked: isPicked)
            Spacer(minLength: 0)
            // Next stays enabled on the last photo — there it opens the end-of-set card rather than a dead tap.
            navButton(system: "chevron.forward", label: "Next photo", enabled: true) { goToStep(1) }
        }
        .padding(.horizontal, 24)
    }

    /// The reversible **Pick** hero. Reflects the current photo's state: a hollow gold ring + "Pick" when
    /// unpicked; a filled gold circle + dark check + "Picked" when picked. Tapping an unpicked photo adds
    /// it and auto-advances; tapping a picked one removes it and stays (`pickOutcome`).
    private func pickToggle(isPicked: Bool) -> some View {
        Button(action: performPick) {
            VStack(spacing: 5) {
                ZStack {
                    Circle()
                        .fill(isPicked ? Color.accentColor : Color.accentColor.opacity(0.12))
                        .frame(width: 64, height: 64)
                    if !isPicked {
                        Circle().strokeBorder(Color.accentColor, lineWidth: 3).frame(width: 64, height: 64)
                    }
                    Image(systemName: "checkmark")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(isPicked ? Color.onAccent : Color.accentColor)
                }
                Text(isPicked ? "Picked" : "Pick")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)
        // Haptic fires from the ROOT `pickHaptic` (one intent-driven source); no `trigger: isPicked` here —
        // that would double-buzz on un-pick and buzz spuriously on plain navigation between picked/unpicked.
        // Shared with the grid rotor via the one `pickVerb` source (#190), so both surfaces speak the
        // same verb. The photo's media type is carried by the page's own a11y label, not this action verb.
        .accessibilityLabel(pickVerb(isPicked: isPicked))
        .accessibilityValue(isPicked ? "Picked" : "Not picked")
        // State-aware: adding advances; removing stays put (so don't promise "moves to the next photo").
        .accessibilityHint(isPicked ? "Removes it from the album."
                                    : "Adds it to the album and moves to the next photo.")
        .accessibilityAddTraits(.isToggle)
    }

    /// A pure-navigation chevron (‹ / ›). Icon-only but each carries a VoiceOver label; disabled (dimmed)
    /// when there's nowhere to go (‹ on the first photo). ≥44pt target.
    private func navButton(system: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white.opacity(enabled ? 0.9 : 0.25))
                // Height matches the Pick circle (64) so, top-aligned in the row, the chevron glyph's
                // centre lines up with the circle's centre — the label hangs below without dragging it down.
                .frame(width: 56, height: 64)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
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
}

// MARK: - PhotoViewerView helpers (filmstrip window + label/info formatting)
//
// Kept in an extension so they don't count toward the view's `type_body_length`; behaviour unchanged
// (same-file `private` stays reachable from the struct's `body`).
extension PhotoViewerView {

    // MARK: Pick + navigation actions (#180)
    // In the extension (not the struct body) so they don't push the view over SwiftLint's type_body_length;
    // same-file `private` keeps them reachable from the control views.

    /// Toggle the current photo's pick, then apply the pure `pickPlan`: adding advances (or opens the
    /// end-of-set card if it was the last photo); removing stays put so you see what you dropped. Guarded by
    /// `isPaging` so a fast double-tap can't act on the photo that just slid in.
    private func performPick() {
        guard !pickBounce else { return }   // swallow a fumbled double-tap, not deliberate picks
        let plan = pickPlan(currentID: currentID, in: allIDs, currentlyPicked: selection.contains(currentID))
        selection.toggle(plan.toggleID)
        pickHaptic &+= 1
        if let next = plan.advanceTo {
            armPickBounce()
            advance(to: next, from: plan.toggleID)
        } else if plan.reachedEnd {
            endReached = true
        }
        // else: a removal — stay on this photo.
    }

    /// A chevron step. Forward past the last photo opens the end-of-set card; otherwise a forward step seals
    /// a crossed cluster done (matching swipe, #128). Pure navigation — never changes a pick. NOT guarded:
    /// programmatic turns are instant (pager `animated: false`), so rapid Next registers immediately and
    /// can't overlap/desync the pager.
    private func goToStep(_ offset: Int) {
        let from = currentID
        guard let target = viewerStep(from: from, in: allIDs, offset: offset) else {
            if offset > 0 { endReached = true }
            return
        }
        if offset > 0 { advance(to: target, from: from) } else { currentID = target }
    }

    /// Apply a FORWARD programmatic advance: seal the cluster if this crossed its boundary (the pager's
    /// swipe delegate doesn't fire for a programmatic set, #128), then turn the page instantly.
    private func advance(to target: String, from: String) {
        autoMarkDoneIfPagedPastCluster(from: from, to: target)
        currentID = target   // instant (pager uses animated: false) — safe to fire back-to-back
    }

    /// A short guard so a *fumbled double-tap* on Pick can't pick the photo that just slid in — a
    /// finger-bounce window, deliberately tiny so it never throttles intentional picking. Released even on
    /// cancellation (`try?` falls through), so Pick can't get stuck disabled.
    private func armPickBounce() {
        pickBounce = true
        Task { @MainActor in try? await Task.sleep(for: .milliseconds(150)); pickBounce = false }
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

    /// Whether `id` is a video — so the viewer's a11y (page label + Pick control) reads "Video" like the
    /// grid cell does, rather than always "Photo" (#125). Reads the same published `AssetRef` map.
    private func isVideo(_ id: String) -> Bool {
        coordinator.reviewAssetsByID[id]?.isVideo ?? false
    }

    /// Re-format the info labels for `id` — called when `currentID` settles / on appear, NEVER in a body
    /// (repo rule). Free tier (#127): the day + capture time for the date line, and the resolution for the
    /// panel, both from the published `AssetRef`. Async device + file size are a follow-up.
    private func refreshInfo(for id: String) {
        let asset = coordinator.reviewAssetsByID[id]
        // Compact ISO timestamp "2025-01-01 17:34" (#183) — the localized spelled form ran edge-to-edge
        // (esp. Finnish "keskiviikkona 1. tammikuuta 2025 klo 17.34"); ISO is short + unambiguous everywhere.
        let dateTime = asset?.captureDate.map { PhotoInfoFormat.timestamp($0) } ?? ""
        info = InfoLabels(
            dateTime: dateTime,
            resolution: asset.map { PhotoInfoFormat.resolution($0.pixelSize) } ?? "",
            resolutionA11y: Self.resolutionA11y(asset?.pixelSize),
            // A video → its running time leads the info line (#125); a still → "".
            duration: asset?.isVideo == true ? (PhotoInfoFormat.duration(asset?.duration) ?? "") : "")
    }

    /// VoiceOver form of the resolution ("Resolution, 4032 by 3024, 12 megapixels"), or "Resolution
    /// unavailable" when the size is missing/zero (so the row is never a silent blank for VoiceOver).
    /// Goes through the shared `PhotoInfoFormat.megapixels`, so it can't diverge from the visible string.
    private static func resolutionA11y(_ pixelSize: PixelSize?) -> String {
        guard let pixelSize, pixelSize.width > 0, pixelSize.height > 0 else {
            return String(localized: "Resolution unavailable", comment: "Viewer info a11y: no resolution")
        }
        if let mp = PhotoInfoFormat.megapixels(pixelSize) {
            return String(localized: "Resolution, \(pixelSize.width) by \(pixelSize.height), \(mp) megapixels",
                         comment: "Viewer info a11y: resolution + megapixels")
        }
        return String(localized: "Resolution, \(pixelSize.width) by \(pixelSize.height)",
                     comment: "Viewer info a11y: resolution")
    }

    /// The per-page VoiceOver label: "Photo, Sat, Jul 5, 7 of 13" — or "Video, …" for a video (#125),
    /// matching the grid cell (day dropped if unavailable).
    private func photoAXLabel(for id: String) -> String {
        let ids = allIDs
        let position = (ids.firstIndex(of: id) ?? 0) + 1
        let day = dayLabel(for: id)
        if isVideo(id) {
            return day.isEmpty
                ? String(localized: "Video, \(position) of \(ids.count)", comment: "Viewer a11y: video position, no day")
                : String(localized: "Video, \(day), \(position) of \(ids.count)", comment: "Viewer a11y: video day, position")
        }
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
    /// A video's running time ("0:14"), empty for a still (#125) — leads the info line only for videos.
    var duration = ""
}


/// Pure display formatting for the viewer's info fields (#127), kept out of the view so it's unit-tested
/// (the no-formatting-in-body rule). `Curation` stays string-free (D14/D21), so these app-facing strings
/// live here, not in the domain.
enum PhotoInfoFormat {
    /// A compact capture timestamp — "2025-01-01 17:34" (ISO date + 24-hour time, no seconds). Deliberately
    /// **not localized**: the spelled localized form (`.formatted(date: .complete, …)`) ran edge-to-edge in
    /// the viewer, especially in Finnish ("keskiviikkona 1. tammikuuta 2025 klo 17.34"); ISO is compact and
    /// unambiguous in every language (#183). Built from `DateComponents` so it's pure + deterministic;
    /// `timeZone` is injectable for tests, and the app passes `.current` to show the device's local time.
    static func timestamp(_ date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return String(format: "%04d-%02d-%02d %02d:%02d",
                      c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0)
    }

    /// Rounded megapixels (round-half-away-from-zero, so exactly 0.5 MP shows), or `nil` below ~0.5 MP /
    /// for a zero size. The single source of the MP count — the visible resolution string AND the
    /// VoiceOver label both go through this, so they can't drift.
    static func megapixels(_ pixelSize: PixelSize) -> Int? {
        guard pixelSize.width > 0, pixelSize.height > 0 else { return nil }
        let mp = Int((Double(pixelSize.pixelCount) / 1_000_000).rounded())
        return mp >= 1 ? mp : nil
    }

    /// "4032 × 3024 · 12 MP" — dimensions + rounded megapixels (MP dropped below ~0.5 MP). "" for a
    /// zero/empty size.
    static func resolution(_ pixelSize: PixelSize) -> String {
        guard pixelSize.width > 0, pixelSize.height > 0 else { return "" }
        let dims = "\(pixelSize.width) × \(pixelSize.height)"
        return megapixels(pixelSize).map { "\(dims) · \($0) MP" } ?? dims
    }

    /// A video's running time as a compact clock: `nil` → `nil` (a still, so no badge); otherwise
    /// "M:SS" under an hour ("0:14", "1:05") and "H:MM:SS" at/over an hour ("1:02:09"). Seconds are
    /// floored to whole seconds. Negative input clamps to 0. The single source of the duration string —
    /// the grid badge (#125) and the viewer read through this, so they can't drift.
    static func duration(_ seconds: Double?) -> String? {
        guard let seconds else { return nil }
        let total = max(0, Int(seconds))          // floor to whole seconds; clamp any negative
        let (h, m, s) = (total / 3600, (total % 3600) / 60, total % 60)
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
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

/// The outcome of a **Pick** tap in the viewer (#180). Picking an *unpicked* photo adds it and advances to
/// the next; tapping an *already-picked* photo removes it and STAYS put (a reversible correction, e.g.
/// dropping one when over target). Pure so the load-bearing rule — "auto-advance only when a pick is added,
/// never when it's removed" — is unit-tested rather than buried in the control's closure.
struct PickOutcome: Equatable {
    /// The photo's selection state after the tap.
    let nowPicked: Bool
    /// Whether the viewer should auto-advance to the next photo after this tap.
    let advance: Bool
}

func pickOutcome(currentlyPicked: Bool) -> PickOutcome {
    currentlyPicked
        ? PickOutcome(nowPicked: false, advance: false)   // un-pick → stay, so you can see what you removed
        : PickOutcome(nowPicked: true, advance: true)     // pick → add + move on (the one-tap churn)
}

/// The id to move to for a navigation step (`offset` −1 previous / +1 next), or `nil` at the ends — so the
/// viewer disables the chevron there and a Next past the last photo becomes the end-of-set state instead of
/// a dead tap (#180). Thin wrapper over `adjacentID` naming the end-of-set intent at the call site.
func viewerStep(from id: String, in ids: [String], offset: Int) -> String? {
    adjacentID(in: ids, to: id, offset: offset)
}

/// The full plan for a **Pick** tap (#180) — pure, so the whole wiring is unit-tested instead of living in
/// the View: flip `toggleID`, then either move to `advanceTo`, show the end-of-set card (`reachedEnd`), or
/// stay put. Adding a pick advances (to the next id, or the end card if it was the last photo); removing a
/// pick stays where you are so you see what you dropped.
struct PickPlan: Equatable {
    let toggleID: String     // the id to flip in the selection
    let advanceTo: String?   // move here after adding; nil ⇒ stay (a removal) or the end was reached
    let reachedEnd: Bool     // added on the LAST photo ⇒ show the end-of-set card
}

func pickPlan(currentID: String, in ids: [String], currentlyPicked: Bool) -> PickPlan {
    guard pickOutcome(currentlyPicked: currentlyPicked).advance else {
        return PickPlan(toggleID: currentID, advanceTo: nil, reachedEnd: false)   // un-pick → stay
    }
    if let next = adjacentID(in: ids, to: currentID, offset: 1) {
        return PickPlan(toggleID: currentID, advanceTo: next, reachedEnd: false)  // pick → advance
    }
    return PickPlan(toggleID: currentID, advanceTo: nil, reachedEnd: true)         // picked the last → end
}
