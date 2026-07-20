//
//  ReviewGridView.swift
//  PoimiApp — the review grid (issue #35), PAGED-CLUSTERS model (#35 paged-clusters redesign).
//
//  One cluster fills the screen; you SWIPE SIDEWAYS between clusters (a horizontal page `TabView`,
//  selected by group id — not a positional index — so a re-scan can't strand the selection), replacing
//  the earlier single-scroll accordion whose collapse/open reflow was jumpy on device now that the
//  Overview is itself a full cluster index (with per-cluster thumbnail strips). Each page is that
//  cluster's own vertical `LazyVGrid`. Chrome (design 4AB): a fixed TOP BAR (`ReviewTopBar`) carrying
//  the CURRENT cluster's identity (pin · name · count · done seal) + the album's progress ring, then
//  PINNED per-cluster over the photos — a page-number pill ("3 / 12", the swipe affordance + position)
//  on the leading lane and a Select-all icon on the trailing lane; the "Mark day done" button is the
//  end-of-scroll footer (advances to the next unreviewed cluster). Export lives on the Overview.
//
//  Selection lives in the shared `SelectionStore` (in-memory `Set`, D15); the cells + header observe it
//  themselves, so this parent body does NOT depend on `selected` — a toggle re-renders only the cell.
//  Thumbnails flow through the injected seam with a scroll-driven prefetch window SCOPED TO THE CURRENT
//  cluster, so only its cells load at full cell size (the perf bound the accordion also relied on).
//

import SwiftUI
import UIKit
import Curation

/// Pure grid-density math (kept out of the view so it's unit-tested). Given the available width, pick
/// the column count that best fills it at ~`target`pt cells, clamped to the size-class range. This is
/// what lets the review grid open dense on iPad and reflow on a Split View / Stage Manager resize (#42).
enum ReviewGridColumns {
    static func ideal(forWidth width: CGFloat, target: CGFloat = 132, minColumns: Int, maxColumns: Int) -> Int {
        guard width > 0 else { return minColumns }
        let raw = Int((width / target).rounded())
        return max(minColumns, min(maxColumns, raw))
    }
}

struct ReviewGridView: View {
    /// The review timeline (oldest → newest) — one page per cluster (a date day-group or a trip).
    let clusters: [ReviewCluster]
    /// Resolved trip place names (`TripCluster.clusterID → name`), filling in async — a trip page shows
    /// its "Week in …" sentence once its name lands, and the date range until then.
    var tripNames: [String: String] = [:]
    /// The album name — shown only as the top bar's fallback title before the first cluster resolves
    /// (the bar otherwise shows the current cluster); also available for a11y.
    let title: String
    /// Open a cell full-screen (the parent pushes the viewer + records `lastViewedID`, #36).
    let openAsset: (String) -> Void
    /// A day-group to open on entry — the overview's "drill into this cluster" target (#37). Nil → open
    /// the first unreviewed cluster (resume).
    var scrollToDay: DayKey?

    @Environment(\.thumbnailProvider) private var thumbnails
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(DoneStore.self) private var done
    @Environment(AppCoordinator.self) private var coordinator   // observe viewer dismissal to restore the page (#126)

    /// The current cluster page, identified by its GROUP ID (a stable id, not a positional index —
    /// so a re-scan that reshapes grouping can't leave the selection pointing at a different cluster).
    /// Swiping (TabView) or "Mark day done" moves it.
    @State private var currentPageID: String?
    /// Pick the entry page once per appearance (drill target, or first-unreviewed resume).
    @State private var didInitialOpen = false
    /// One-shot: the photo to scroll the active cluster page to on return from the viewer (#126). Set on
    /// `viewerReturnTick`; the matching `ClusterPage` scrolls to it, then clears it.
    @State private var pendingScrollID: String?

    /// Whether every cluster is marked done (#187) + the album's total candidate photos — held off the
    /// `body` (per the issue) so the O(clusters) `allSatisfy`/`reduce` don't re-run on every `visibleIDs`
    /// churn during a scroll. Refreshed by `refreshCompletion()` on the events that can change them:
    /// first appear, album switch, and any done-state change.
    @State private var reviewComplete = false
    @State private var totalCandidatePhotos = 0

    @State private var columnCount = 3
    /// Every candidate id oldest → newest — the pick-frontier denominator for the top bar's "~N est."
    /// projection. Built ONCE (onAppear / album switch), never in a `body`, so a pick just re-scans it.
    @State private var orderedIDs: [String] = []
    @State private var visibleIDs: Set<String> = []
    @State private var window = PrefetchWindow(orderedIDs: [])
    // Generation-guarded prefetch: a single in-flight updater loops until it has applied the latest
    // visible state, so out-of-order actor calls can't leave a stale window cached (D-review #35).
    @State private var windowGeneration = 0
    @State private var windowUpdating = false
    /// The last slice actually pushed to the cache, so an unchanged recompute skips the actor hop.
    @State private var lastAppliedSlice: [String] = []

    private let spacing: CGFloat = 3   // small inter-cell gap, Apple-Photos-style
    private let minColumns = 2
    private let windowRowMargin = 2
    /// Oversized vs the on-screen point size on purpose (Retina + density headroom).
    private let thumbnailTarget = CGSize(width: 400, height: 400)

    /// iPhone tops out at 5 columns (any more shrinks the cell below the 44pt badge); iPad allows denser.
    private var maxColumns: Int { sizeClass == .compact ? 5 : 8 }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: spacing), count: columnCount)
    }

    private var currentCluster: ReviewCluster? {
        clusters.first { $0.id == currentPageID } ?? clusters.first
    }

    /// 0-based position of the current page — for the indicator + `advance` math. 0 if unresolved.
    private var currentIndex: Int {
        clusters.firstIndex { $0.id == currentPageID } ?? 0
    }

    /// The cluster id to open on entry / album switch: the drill-or-resume `initialPage` mapped to its id.
    private func entryPageID() -> String? {
        let idx = initialPage(clusters: clusters, scrollToDay: scrollToDay, isDone: { done.isDone($0) })
        return clusters.indices.contains(idx) ? clusters[idx].id : clusters.first?.id
    }

    /// The pinned header title for a cluster: a trip's resolved location sentence ("Week in Salo"), or
    /// the date title (a plain date cluster always, or a trip whose name hasn't resolved yet).
    private func headerTitle(for cluster: ReviewCluster) -> String {
        if let trip = cluster.tripCluster, let name = tripNames[trip.clusterID] {
            return TripLabel.sentence(for: trip.shape, place: name)
        }
        return DayGroupHeader.title(for: cluster)
    }

    /// Columns that best fill `width` at ~132pt cells, clamped to the size-class range — opens dense on
    /// iPad, reflows on a Split View / Stage Manager resize (#42); iPhone lands on ~3.
    private func applyIdealColumns(width: CGFloat) {
        guard width > 0 else { return }
        let ideal = ReviewGridColumns.ideal(forWidth: width, minColumns: minColumns, maxColumns: maxColumns)
        if ideal != columnCount { columnCount = ideal }
    }

    /// The horizontal page pager — one `ClusterPage` per cluster, selected by group id. Extracted from
    /// `body` so the (long) modifier chain below type-checks as a smaller expression.
    private var pager: some View {
        TabView(selection: $currentPageID) {
            ForEach(Array(clusters.enumerated()), id: \.element.id) { index, cluster in
                ClusterPage(
                    cluster: cluster,
                    headerTitle: headerTitle(for: cluster),
                    isTrip: cluster.tripCluster != nil,
                    columns: columns,
                    spacing: spacing,
                    load: load,
                    cachedImage: cachedImage,
                    videoBadge: videoBadge,
                    openAsset: openAsset,
                    // Only the ACTIVE page reports cell visibility — TabView pre-renders neighbours, and
                    // their cells reporting visible would churn the prefetch recompute on every swipe.
                    isActive: cluster.id == currentPageID,
                    onVisible: { visibleIDs.insert($0) },
                    onHidden: { visibleIDs.remove($0) },
                    position: index + 1,
                    total: clusters.count,
                    onMarkDone: { markDoneAndAdvance(cluster) },
                    // Restore scroll to the photo you ended on in the viewer (#126); each page acts only
                    // if it holds the id, then clears it (one-shot).
                    scrollToID: pendingScrollID,
                    onScrolledToTarget: { pendingScrollID = nil },
                    reviewComplete: reviewComplete,
                    totalPhotos: totalCandidatePhotos)
                    .tag(cluster.id as String?)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
    }

    /// The fixed top bar — the CURRENT cluster's identity + the album's progress ring (design 4AB).
    /// Extracted from `body` (like `pager`) so the modifier chain type-checks as a smaller expression;
    /// updates as `currentPageID` moves. Falls back to the album title before a cluster resolves.
    @ViewBuilder private var topBar: some View {
        if let cluster = currentCluster {
            ReviewTopBar(clusterTitle: headerTitle(for: cluster),
                         count: cluster.count,
                         isTrip: cluster.tripCluster != nil,
                         isDone: done.isDone(cluster),
                         orderedIDs: orderedIDs,
                         showsProjection: showsPaceProjection,
                         onToggleDone: { toggleDone(cluster) })   // mark/un-mark from anywhere (#202)
        } else {
            ReviewTopBar(clusterTitle: title, count: 0, orderedIDs: orderedIDs,
                         showsProjection: showsPaceProjection)
        }
    }

    /// The "~N est." projection shows only on a multi-cluster album AND while review is unfinished. Once
    /// every cluster is done, #187's `ReviewCompleteBar` states the final counts in the pinned header just
    /// below — a projection there would double the pick count and over-project (frontier < 1 if the last
    /// cluster was marked done with few picks), reading as broken. O(1); reads the `reviewComplete` @State.
    private var showsPaceProjection: Bool {
        clusters.count > 1 && !reviewComplete
    }

    /// Recompute the completion state + album total OFF the `body` (#187 spec). Called on first appear,
    /// album switch (`groupIdentity`), and any done-state change (`done.doneDays`) — the only inputs that
    /// move them — so a scroll's `visibleIDs` churn never re-runs the `allSatisfy`/`reduce`.
    private func refreshCompletion() {
        reviewComplete = isReviewComplete(clusters: clusters, isDone: { done.isDone($0) })
        totalCandidatePhotos = clusters.reduce(0) { $0 + $1.count }
    }

    /// `pager` + the fixed top-bar chrome + decoration, split out of `body` so each modifier chain stays
    /// short enough for the Swift type-checker (the same reason `pager`/`topBar` are extracted).
    private var decoratedPager: some View {
        pager
        // The top bar (current cluster's identity + album progress ring) is the ONE fixed chrome. The
        // per-cluster page indicator + Select-all glass pills live INSIDE each page (pinned over the
        // photos) and the "Mark day done" button is its end-of-scroll footer — so they aren't a
        // permanent bottom bar; you reach mark-done by scrolling to the end of the cluster.
        .safeAreaInset(edge: .top, spacing: 0) { topBar }
        .background(Color(.systemBackground))
        // No implicit `.animation(value: currentPage)` — the TabView animates its own page transition;
        // a programmatic advance (mark-done) animates via `withAnimation` in `advance()`. Stacking both
        // double-animated the chrome on a swipe.
        // Success haptic when a day is marked done (count up), a light tap on undo.
        .sensoryFeedback(trigger: done.doneDays.count) { old, new in new > old ? .success : .impact(weight: .light) }
        .onGeometryChange(for: CGFloat.self) { proxy in proxy.size.width } action: { applyIdealColumns(width: $0) }
    }

    var body: some View {
        decoratedPager
        .onAppear {
            Perf.event("grid.onAppear (paged)")
            if !didInitialOpen {
                didInitialOpen = true
                currentPageID = entryPageID()
            }
            if orderedIDs.isEmpty { orderedIDs = clusters.flatMap(\.assetIDs) }   // pace-projection denominator, once
            refreshCompletion()   // #187 forward-path state, off-body
            rebuildWindow()
            scheduleRecomputeWindow()
        }
        // Recompute the forward-path state off-body (#187): a done toggle (mark/un-mark) is the only
        // in-place input that moves it while the grid is up — mirror-flips the pinned bar ↔ pills.
        .onChange(of: done.doneDays) { refreshCompletion() }
        .onChange(of: currentPageID) {
            // Drop the previous page's ids up front. Otherwise they linger in `visibleIDs` — foreign to
            // the new cluster's window universe — so the slice computes EMPTY and the cache is *cleared*
            // on every flick, and the new cluster only starts loading once a scroll repopulates
            // `visibleIDs`. Clearing here makes the slice prime the new cluster's head immediately, so
            // its first screenful pre-decodes on the flick (no "move to start loading").
            visibleIDs = []
            rebuildWindow()
            scheduleRecomputeWindow()
        }
        .onChange(of: visibleIDs) { scheduleRecomputeWindow() }
        .onChange(of: columnCount) { scheduleRecomputeWindow() }
        .onChange(of: maxColumns) { columnCount = min(columnCount, maxColumns) }
        .onChange(of: groupIdentity) {
            visibleIDs = []
            lastAppliedSlice = []      // new album → re-cache from scratch, don't skip on a stale match
            orderedIDs = clusters.flatMap(\.assetIDs)   // new album → refresh the pace denominator
            currentPageID = entryPageID()
            refreshCompletion()        // new clusters → recompute completion + total off-body (#187)
            rebuildWindow()
            scheduleRecomputeWindow()
        }
        // Restore where you ended when the viewer closes (#126): page to the cluster holding the last-
        // viewed photo AND scroll that page to it. Driven off `viewerReturnTick` (a monotonic bump on
        // dismiss), not `presentedPhotoID` — while the full-screen sheet covers the grid it may not re-
        // evaluate on the open, so a nil-transition `.onChange` can silently miss. `pendingScrollID` is
        // handed to the active `ClusterPage`, which scrolls to it (then clears it, one-shot).
        .onChange(of: coordinator.viewerReturnTick) {
            guard let id = coordinator.lastViewedID,
                  let target = clusters.first(where: { $0.assetIDs.contains(id) }) else { return }
            currentPageID = target.id
            pendingScrollID = id
        }
    }

    // MARK: Mark done → advance

    private func markDoneAndAdvance(_ cluster: ReviewCluster) {
        let wasDone = done.isDone(cluster)
        done.toggle(cluster)
        announceDone(wasDone: wasDone)   // announce BOTH directions (mark + un-mark), like the top-bar seal
        if !wasDone { advance() }
    }

    /// Toggle the CURRENT cluster's done-state from the top-bar seal (#202) — a status toggle that stays
    /// put (unlike `markDoneAndAdvance`, which is the end-cap's "done → next day" flow). Announces for
    /// VoiceOver; the sensory feedback fires off the done-count change (`decoratedPager`), same as the
    /// end-cap's mark.
    private func toggleDone(_ cluster: ReviewCluster) {
        let wasDone = done.isDone(cluster)
        done.toggle(cluster)
        announceDone(wasDone: wasDone)
    }

    /// The VoiceOver announcement for a done toggle — shared by the end-cap + the top-bar seal so both
    /// paths (mark AND un-mark) speak, and through the String Catalog (localizable-by-default).
    private func announceDone(wasDone: Bool) {
        let phrase = wasDone
            ? String(localized: "Marked not done", comment: "VoiceOver announcement: a cluster was reopened")
            : String(localized: "Marked done", comment: "VoiceOver announcement: a cluster was marked reviewed")
        AccessibilityNotification.Announcement(phrase).post()
    }

    /// Advance to the next UNREVIEWED cluster after the current page; else the literal next; else stay
    /// (finished the last stretch). Finishing a day lands you on the next one to review. The choice is
    /// the pure `nextUnreviewedPage` (tested); this just applies it with animation.
    private func advance() {
        let next = nextUnreviewedPage(after: currentIndex, count: clusters.count,
                                      isDone: { done.isDone(clusters[$0]) })
        guard clusters.indices.contains(next) else { return }
        withAnimation(reduceMotion ? nil : .snappy) { currentPageID = clusters[next].id }
    }

    // MARK: Cell load (the thumbnail seam)

    private func load(_ id: String) async -> UIImage? {
        let started = Perf.begin()
        let image = await thumbnails.thumbnail(for: id, targetSize: thumbnailTarget)
        Perf.endIO("grid.cell.load \(id.suffix(8))", since: started)
        return image
    }

    /// Synchronous cache lookup at the cell's request size — a hit lets a recycled cell skip the
    /// placeholder. `nonisolated` on the seam, so this never hops the actor.
    private func cachedImage(_ id: String) -> UIImage? {
        thumbnails.cachedThumbnail(for: id, targetSize: thumbnailTarget)
    }

    /// A cell's video badge text — the formatted running time for a video, `nil` for a still (#125). The
    /// AssetRef map is published to the coordinator on `.ready` (the same source the viewer reads), so
    /// this is an O(1) dictionary lookup + a pure format, done once per cell — not work in a `body`.
    private func videoBadge(_ id: String) -> String? {
        guard let asset = coordinator.reviewAssetsByID[id], asset.isVideo else { return nil }
        return PhotoInfoFormat.duration(asset.duration)
    }

    // MARK: Prefetch window (scoped to the current cluster)

    private var groupIdentity: String {
        "\(clusters.first?.id ?? "∅")#\(clusters.reduce(0) { $0 + $1.assetIDs.count })"
    }

    /// Only the CURRENT cluster's cells render at full cell size, so the window's universe is just its
    /// ids — visible ± a row margin. A neighbouring page's cells (rendered by TabView for the swipe) may
    /// report visible, but they're not in this universe so `slice` filters them out.
    private func rebuildWindow() {
        window = PrefetchWindow(orderedIDs: currentCluster?.assetIDs ?? [])
    }

    private func scheduleRecomputeWindow() {
        windowGeneration += 1
        guard !windowUpdating else { return }   // one updater in flight; it loops to the latest gen
        windowUpdating = true
        Task { @MainActor in
            var applied = -1
            while applied != windowGeneration {
                applied = windowGeneration
                let slice = window.slice(visibleIDs: visibleIDs, columnCount: columnCount, rowMargin: windowRowMargin)
                guard slice != lastAppliedSlice else { continue }   // unchanged → no redundant actor hop
                lastAppliedSlice = slice
                let started = Perf.begin()
                await thumbnails.updateCachingWindow(to: slice)
                Perf.endIO("grid.updateCachingWindow n=\(slice.count)", since: started)
            }
            windowUpdating = false
        }
    }
}

// MARK: - One cluster's page (a vertical grid of its photos)

/// A single cluster filling the screen: its photos in a vertical `LazyVGrid`, with the day + Select-all
/// as floating GLASS PILLS pinned at the top (over the photos, like the accordion header) and the
/// "Mark day done" button + page dots as the section FOOTER — so those reach you at the END of the
/// cluster's scroll, not as a permanent bottom bar. Owns its own vertical scroll (each page starts at
/// the top). Cells report visibility up so the parent's prefetch window tracks the visible ± margin.
private struct ClusterPage: View {
    let cluster: ReviewCluster
    /// The pinned header title — a trip's location sentence (or its date range until the name lands), or
    /// a plain date cluster's date title. Computed by the parent from the resolved trip names.
    let headerTitle: String
    /// A trip/visit cluster → the done CTA reads "Mark trip done"; a date cluster → "Mark day done".
    let isTrip: Bool
    let columns: [GridItem]
    let spacing: CGFloat
    let load: (String) async -> UIImage?
    let cachedImage: (String) -> UIImage?
    /// A cell's video badge text ("0:14"), or `nil` for a still (#125) — a dictionary lookup + pure format
    /// done once per cell, off the body.
    let videoBadge: (String) -> String?
    let openAsset: (String) -> Void
    /// Only the active (current) page reports cell visibility — keeps the prefetch recompute off the
    /// swipe hot path, since TabView pre-renders neighbours whose cells would otherwise churn it.
    let isActive: Bool
    let onVisible: (String) -> Void
    let onHidden: (String) -> Void
    let position: Int
    let total: Int
    let onMarkDone: () -> Void
    /// On return from the viewer, scroll to this photo if it's in THIS cluster (#126); nil otherwise.
    let scrollToID: String?
    /// Called after this page consumed `scrollToID`, so the parent clears it (one-shot).
    let onScrolledToTarget: () -> Void
    /// When every cluster is done, the pinned header shows the review-complete forward bar (#187) in
    /// place of the per-page pills. Album-level, rendered on the current page (all pages are done).
    let reviewComplete: Bool
    /// Total candidate photos across the album — the review-complete bar's "N photos" summary.
    let totalPhotos: Int
    @Environment(DoneStore.self) private var done

    var body: some View {
        // The per-cell day label stays the date (a cell is one photo on one day, even inside a trip);
        // the header/chip carries the cluster title (trip sentence or date). Formatted once per page.
        let dayLabel = DayGroupHeader.title(for: cluster)
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: columns, spacing: spacing, pinnedViews: [.sectionHeaders]) {
                    Section {
                        ForEach(cluster.assetIDs, id: \.self) { id in
                            ReviewGridCell(
                                id: id,
                                dayLabel: dayLabel,
                                videoBadge: videoBadge(id),
                                load: load,
                                cachedImage: cachedImage,
                                onOpen: { Perf.event("grid.tap \(id.suffix(8))"); openAsset(id) })
                                .id(id)
                                .onAppear { if isActive { onVisible(id) } }
                                .onDisappear { if isActive { onHidden(id) } }
                        }
                    } header: {
                        clusterHeader()
                    } footer: {
                        footer(isDone: done.isDone(cluster))
                    }
                }
                .padding(.horizontal, spacing)
                .scrollTargetLayout()
            }
            // Restore scroll to the ended-on photo on return from the viewer (#126). Only the cluster that
            // holds it acts; deferred a beat so a just-paged-to page has laid out before `scrollTo`. Then
            // clear the one-shot so a later swipe back here doesn't re-snap.
            .task(id: scrollToID) {
                guard let target = scrollToID, cluster.assetIDs.contains(target) else { return }
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled else { return }
                proxy.scrollTo(target, anchor: .center)
                onScrolledToTarget()
            }
        }
    }

    /// The pinned per-cluster controls, floating as aligned glass pills over the photos (design 4AB): a
    /// page-number pill on the leading lane (the paged model's position + swipe affordance) and the
    /// Select-all icon on the trailing lane. The cluster's identity, count, and done-state now live in
    /// the fixed top bar, not here — so this row is just the per-page controls, one height, aligned.
    @ViewBuilder private func clusterHeader() -> some View {
        if reviewComplete {
            // Every cluster done → the forward path replaces the per-page pills (paging/select-all are
            // moot once you're finished). Pinned like the pills, so it stays reachable as you scroll.
            ReviewCompleteBar(totalPhotos: totalPhotos)
                .frame(maxWidth: .infinity)
        } else {
            HStack(spacing: 8) {
                if total > 1 { PageIndicatorPill(position: position, total: total) }
                Spacer(minLength: 0)
                SelectAllIconChip(cluster: cluster, title: headerTitle)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
        }
    }

    /// End-of-cluster affordance (#202): the lighter "end-cap" that reaches you at the END of the
    /// cluster's scroll — reached by scrolling, not a permanent bottom bar (#38). See `ClusterEndCap`.
    @ViewBuilder private func footer(isDone: Bool) -> some View {
        ClusterEndCap(cluster: cluster, isTrip: isTrip, isDone: isDone, onMarkDone: onMarkDone)
            .padding(.top, 24)
            .padding(.bottom, 28)
    }
}

// MARK: - End-of-cluster end-cap (#202)

/// The end-of-cluster affordance (#202) — the redesign of the lone `.borderedProminent` footer button
/// into a considered "end-cap": a green (day-level) sibling of the viewer's gold (album-level)
/// end-of-set card. NOT done → a green seal + "You've reached the end · N photos · M picked" + an
/// explicit green "Mark day done" pill that marks the cluster reviewed and advances to the next
/// unreviewed one ("Opens your next day to review"). DONE (revisiting a sealed day) → a filled green
/// seal + "This day is done" + a low-emphasis, reversible "Mark not done" (no confirmation dialog, no
/// time-boxed toast — HIG). GREEN, never gold: gold stays the album-level "Save to Photos" export CTA,
/// so the routine per-day action doesn't compete with the big finish. Reads the `SelectionStore` itself
/// for the picked count, so it updates as you pick without the page depending on `selected`. Keeps the
/// `markDoneButton` identifier (the #43 XCUITest contract) though the label + form change.
private struct ClusterEndCap: View {
    let cluster: ReviewCluster
    let isTrip: Bool
    let isDone: Bool
    let onMarkDone: () -> Void
    @Environment(SelectionStore.self) private var selection

    var body: some View {
        // Alloc-free pick count (mirrors ClusterListRow.pickedCount) — no throwaway Set per pick.
        let picked = cluster.assetIDs.reduce(into: 0) { if selection.selected.contains($1) { $0 += 1 } }
        VStack(spacing: 14) {
            seal
            VStack(spacing: 5) {
                Text(doneHeadline)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                Text("^[\(cluster.count) photo](inflect: true) · \(picked) picked")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            markButton
            Text(isDone ? "You can change your picks any time" : "Opens your next day to review")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 24)
    }

    /// The headline names the cluster kind honestly: a multi-day trip is "This trip is done", not "This
    /// day is done" (the mark button + a11y already branch on `isTrip`). The open state is kind-neutral —
    /// you've reached the end of this cluster's photos either way.
    private var doneHeadline: LocalizedStringKey {
        guard isDone else { return "You've reached the end" }
        return isTrip ? "This trip is done" : "This day is done"
    }

    /// The seal echoes the top-bar toggle glyph so "done" reads consistently: an outline seal (open) or a
    /// white-on-green filled seal (done).
    @ViewBuilder private var seal: some View {
        Group {
            if isDone {
                Image(systemName: "checkmark.seal.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.brandGreen)
            } else {
                Image(systemName: "checkmark.seal")
                    .foregroundStyle(Color.brandGreen)
            }
        }
        .font(.system(size: 52))
        .accessibilityHidden(true)
    }

    /// Open → a solid green "Mark day/trip done" pill (green = done; a solid fill, not a material, so the
    /// pure-glass guard is satisfied). Done → a bordered, low-emphasis "Mark not done". A solid COLOR is
    /// used, never gold — gold is reserved for the album-level export CTA.
    @ViewBuilder private var markButton: some View {
        Button(action: onMarkDone) {
            if isDone {
                Text("Mark not done")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 11)
                    .overlay { Capsule().strokeBorder(Color.secondary.opacity(0.4), lineWidth: 1) }
            } else {
                Text(isTrip ? "Mark trip done" : "Mark day done")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 26)
                    .padding(.vertical, 13)
                    .background(Capsule().fill(Color.brandGreen))
            }
        }
        .buttonStyle(.plain)
        .padding(.top, 2)
        .accessibilityIdentifier("markDoneButton")   // stable id though the label + form change (#43)
        .accessibilityLabel(isDone
            ? String(localized: "Mark not done", comment: "End-cap: reopen a done cluster")  // matches the visible text
            : (isTrip ? String(localized: "Mark trip done", comment: "End-cap: mark a trip reviewed")
                      : String(localized: "Mark day done", comment: "End-cap: mark a day reviewed")))
        .accessibilityHint(isDone
            ? String(localized: "Reopens this cluster for editing", comment: "End-cap hint when done")
            : String(localized: "Marks this cluster reviewed and opens the next", comment: "End-cap hint when open"))
    }
}

// MARK: - Page indicator (always-visible position + swipe affordance)

/// A compact glass pill pinned atop each cluster page — the paged model's orientation device: an
/// always-visible position across the album plus the cue you can swipe between clusters. A stacked-page
/// glyph reinforces "cluster N of M"; the position is numeric (dots were dropped — a windowed
/// "10 of 349 dots" tells you nothing, and for a small album the number reads just as clearly, design 4AB).
/// The review-complete forward affordance (#187): once EVERY cluster is marked done, this replaces the
/// per-page pills in the pinned header — a green check + "All photos reviewed · N photos · M picks" + the
/// Photos-qualified finish action (#185's re-export-aware label). Reads the shared `SelectionStore` ITSELF
/// (like the cells + top bar) so the grid parent stays independent of `selected`; adaptive `.primary`/
/// `.secondary` over glass (never hardcoded white — matches the pills, sidesteps the RT-legibility trap).
/// Its action is the one coordinator transition that dismisses any viewer then pushes export.
private struct ReviewCompleteBar: View {
    let totalPhotos: Int
    @Environment(SelectionStore.self) private var selection
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        let picked = selection.progress.picked
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(Color.brandGreen)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("All photos reviewed")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text("\(totalPhotos) photos · \(picked) picks")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .accessibilityElement(children: .combine)   // one VO utterance, not two fragments
            Spacer(minLength: 8)
            if picked > 0 {
                // A SOLID gold pill (not glass): this bar floats over bright photos, where a translucent
                // glass-tinted button washes out (device-caught) — the signed-off mock is a solid capsule.
                // A solid fill is not a material, so it's fine under the pure-Liquid-Glass guard.
                Button { coordinator.finishToExport() } label: {
                    Text(finishActionLabel(isReExport: coordinator.reviewIsReExport))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.onAccent)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .background(Capsule().fill(Color.accentColor))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("reviewCompleteFinishButton")
            } else {
                // Reviewed everything but picked nothing → there's nothing to save yet. Guide, rather than
                // show a dead greyed button (which device testing showed reads as "is this broken?").
                Text("Pick photos to save")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 8)
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .glassSurface(in: Capsule())
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

private struct PageIndicatorPill: View {
    let position: Int   // 1-based
    let total: Int

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "rectangle.stack")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("\(position) / \(total)")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 36)
        .glassChip()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Cluster \(position) of \(total)",
                                   comment: "Page-indicator a11y: current cluster of total"))
    }
}

// MARK: - The floating Select-all glass pill (pinned over the photos)

/// The cluster's Select-all control — an icon-only glass capsule floating on the trailing lane over the
/// photos (design 4AB). It toggles the whole cluster's picks and reflects state: an outline checkbox
/// when not everything's picked, a filled gold one when it is (tying to the gold-check selection
/// language). Observes the `SelectionStore` itself so the parent grid body stays independent of
/// `selected`. `title` is the resolved cluster title, used only for the VoiceOver label.
private struct SelectAllIconChip: View {
    let cluster: ReviewCluster
    let title: String
    @Environment(SelectionStore.self) private var selection

    var body: some View {
        let selectedCount = selection.selected.intersection(cluster.assetIDs).count
        let allSelected = !cluster.assetIDs.isEmpty && selectedCount == cluster.count
        Button {
            if allSelected { selection.deselect(cluster.assetIDs) } else { selection.select(cluster.assetIDs) }
        } label: {
            Image(systemName: allSelected ? "checkmark.square.fill" : "checkmark.square")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(allSelected ? Color.accentColor : Color.primary)
                .frame(width: 36, height: 36)
                .glassChip()                     // glass capsule at the 36pt visual size (aligns with the page pill)
                .frame(width: 44, height: 44)    // ≥44pt hit area, glass centred (HIG touch floor)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("selectAllButton")   // identifier stays; only the label's verb changes (#190)
        .accessibilityLabel(allSelected
            ? String(localized: "Remove all in \(title)", comment: "Pick-all toggle: un-pick state")
            : String(localized: "Pick all in \(title)", comment: "Pick-all toggle: pick state"))
        .accessibilityHint(String(localized: "Picks or removes every photo in this cluster",
                                  comment: "Pick-all toggle hint"))
    }
}

// MARK: - Entry page

/// The cluster PAGE to open on first appear / album switch (#35 paged-clusters). A #37-style drill
/// (`scrollToDay` matching a group's days) opens that group's page; otherwise the first UNREVIEWED
/// cluster (resume), else the first. Pure so the drill-vs-resume choice is unit-tested. Returns 0 for
/// an empty slice (the view guards `currentGroup`).
func initialPage(clusters: [ReviewCluster], scrollToDay: DayKey?, isDone: (ReviewCluster) -> Bool) -> Int {
    if let day = scrollToDay, let idx = clusters.firstIndex(where: { $0.days.contains(day) }) {
        return idx
    }
    return clusters.firstIndex(where: { !isDone($0) }) ?? 0
}

/// The page to land on after marking `current` done (#38 mark-done → next-day heartbeat): the first
/// UNREVIEWED cluster AFTER `current`, else the literal next page, else stay on `current` (the last
/// stretch is finished). Pure so this — the core of the paged mark-done flow — is unit-tested, per the
/// codebase's "pull the decision out of the View" convention. `isDone` is indexed into `0..<count`.
func nextUnreviewedPage(after current: Int, count: Int, isDone: (Int) -> Bool) -> Int {
    guard count > 0 else { return 0 }
    if let next = (current + 1..<count).first(where: { !isDone($0) }) { return next }
    return current + 1 < count ? current + 1 : current
}

/// True when EVERY cluster is marked done — the whole album is reviewed, so the grid offers the forward
/// path to export instead of `advance()` silently holding (#187). Pure, unit-tested. Guarded on a
/// NON-EMPTY slice: `allSatisfy` is vacuously true for an empty list, which would falsely report
/// "review complete" (and offer to create an album) for an empty-range album — so guard it explicitly.
func isReviewComplete(clusters: [ReviewCluster], isDone: (ReviewCluster) -> Bool) -> Bool {
    !clusters.isEmpty && clusters.allSatisfy(isDone)
}
