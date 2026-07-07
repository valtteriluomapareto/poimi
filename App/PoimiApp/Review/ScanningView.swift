//
//  ScanningView.swift
//  PoimiApp — the long-scan surface for the review-fetch pass (issue #34, D12; architecture §3).
//
//  Drives a `CandidateStore` for the opened project and renders its phase. This is the *minimal*
//  scan surface sanctioned by the build plan (project-phases): an indicator while the fetch+filter
//  pass runs, then the candidate summary, an empty state, or a recoverable failure. The full
//  non-blocking, cancelable curate-*while*-scanning surface (D12) lands in Phase 4 with the async
//  quality filter; the `.ready` summary here is replaced by the actual review grid in #35.
//
//  To honor "no full-screen blocking spinner" as far as the interim allows, the indicator only
//  appears after a short grace period — a fast fetch (small/recent library, the common case) goes
//  straight to the result with no spinner flash.
//

import SwiftUI
import Curation

struct ScanningView: View {
    let project: CurationProject
    /// A day-group to scroll the grid to on open — the overview's "drill into this month" target (#37).
    var scrollToDay: DayKey?
    @Environment(\.photoLibrary) private var library
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(SelectionStore.self) private var selection
    @Environment(DoneStore.self) private var doneStore
    @Environment(\.placeNaming) private var placeNaming
    @Environment(\.modelContext) private var modelContext
    @State private var store: CandidateStore?
    /// The album the current `store` loaded — so a reused view instance reloads for a NEW album
    /// rather than republishing the previous one's candidates (the iPad detail-column retarget, #42).
    @State private var loadedProjectID: UUID?
    /// Gates the scanning indicator behind a grace delay (below) so instant scans never flash it.
    @State private var indicatorVisible = false

    var body: some View {
        content()
            // Blanked once the grid is up — the pinned ReviewHeader carries the bold album title
            // there, so a nav title too would be a double title. Other phases (scanning / empty /
            // failed) keep it as their only label.
            .navigationTitle(isReady ? "" : project.title)
            // Inline, not large: a collapsing large title fought the pinned `.safeAreaInset` tally
            // header and the section headers in the same top zone (the "glitch between the title and
            // the first group" seen on device) and drove the Liquid Glass nav backdrop into an
            // observation feedback loop. The ReviewHeader below carries the album context prominently.
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { reviewChrome }
            // Hide the system nav backdrop so the ReviewHeader's own glass (extended to the top edge)
            // is the single continuous glass surface up there — back/Clear/Export float on it, with no
            // bright photo band between the nav bar and the header. We supply a STATIC glass (not the
            // system backdrop reacting to a collapsing title), which removes the specific feedback loop
            // below — verified on device (no scroll flicker); re-check if the top-title layout changes.
            .toolbarBackground(.hidden, for: .navigationBar)
            // Keyed by project id so re-targeting (e.g. iPad detail column) reloads for the new
            // album rather than showing the previous one's candidates.
            .task(id: project.id) {
                // Hydrate the selection + done-state for this project (idempotent — activate() no-ops
                // if already active, so re-entry never clobbers unflushed picks/done-days).
                selection.activate(project)
                doneStore.activate(project)
                // Reload when the album actually changed (or first load); reuse only survives a
                // benign re-appear of the SAME album, so returning from the viewer doesn't re-scan.
                // Gating on project identity (not `.idle`) stops a reused view instance from serving
                // the previous album's candidates + day map to the viewer (#42).
                if store == nil || loadedProjectID != project.id {
                    store = CandidateStore(library: library, naming: placeNaming,
                                           nameCache: NameCacheStore(modelContainer: modelContext.container))
                    loadedProjectID = project.id
                    await scan()
                } else {
                    publishForViewer()   // benign re-appear (same album) — republish for the viewer
                }
            }
    }

    /// Run (or re-run, e.g. a "Try again") the fetch pass, then reconcile done-state and publish the
    /// candidate list for the viewer. Reuses the current `store` so a retry re-scans the same album.
    private func scan() async {
        guard let store else { return }
        await store.load(project)
        // Reconcile done-state against the freshly-loaded candidates: a done day that gained a photo
        // since the last load re-opens, so the collapse never hides a new unreviewed photo (D32(d)).
        // Only on a real .ready load — an empty/failed load would record a bogus (empty) baseline.
        if case .ready = store.phase {
            doneStore.reconcile(currentIDsByDay: Self.idsByDay(store.dayByID))
        }
        publishForViewer()
    }

    /// Publish the candidate list + per-photo day map so the photo viewer can page through it and
    /// label each photo's day (#36). A no-op until the pass is `.ready`.
    private func publishForViewer() {
        if case .ready(let clusters) = store?.phase {
            coordinator.reviewOrderedIDs = clusters.flatMap(\.assetIDs)
            coordinator.reviewDayByID = store?.dayByID ?? [:]
        }
    }

    /// The Export/Clear chrome, shown only once the grid is up (`.ready`). The large nav title keeps
    /// the album name (Paper design); the tally lives in the scroll-top `ReviewHeader`, not the nav.
    /// `ReviewToolbarActions` reads the `SelectionStore` internally, so hosting it here doesn't make
    /// this view re-render on a selection toggle.
    @ToolbarContentBuilder
    private var reviewChrome: some ToolbarContent {
        if isReady {
            ToolbarItem(placement: .topBarTrailing) {
                ReviewToolbarActions(onExport: { coordinator.openExport(project.id) })
            }
        }
    }

    private var isReady: Bool {
        if case .ready = store?.phase { return true }
        return false
    }

    /// The header metadata line: total candidates + the album's period, e.g.
    /// "1,847 photos · Jan 2025 – Dec 2025".
    private func headerSubtitle(_ clusters: [ReviewCluster]) -> String {
        let total = clusters.reduce(0) { $0 + $1.count }
        return String(localized: "\(total.formatted()) photos · \(periodLabel)",
                      comment: "Review header subtitle: photo count (grouped) · date-range period")
    }

    private var periodLabel: String {
        let style = Date.FormatStyle.dateTime.month(.abbreviated).year()
        let start = project.rangeStart.formatted(style)
        // rangeEnd is exclusive: step back a calendar DAY to land on the last included day's month
        // (a 2025 album ends at 2026-01-01 → "Dec 2025", not "Jan 2026"). A real calendar day (not a
        // fixed interval) so it's correct across DST; a 1s step would land at 23:59:59 UTC, which a
        // positive-offset timezone rolls back into January.
        let lastDay = Calendar.current.date(byAdding: .day, value: -1, to: project.rangeEnd) ?? project.rangeEnd
        let end = lastDay.formatted(style)
        return start == end ? start : "\(start) – \(end)"
    }

    /// Invert the store's per-photo `id → DayKey` map into the `DayKey → ids` shape the done-state
    /// reconcile diffs against the persisted baseline.
    private static func idsByDay(_ dayByID: [String: DayKey]) -> [DayKey: Set<String>] {
        var out: [DayKey: Set<String>] = [:]
        for (id, day) in dayByID { out[day, default: []].insert(id) }
        return out
    }

    @ViewBuilder
    private func content() -> some View {
        switch store?.phase ?? .idle {
        case .idle, .scanning:
            ZStack {
                if indicatorVisible {
                    VStack(spacing: 16) {
                        ProgressView()          // default app accent (not the first-run identity green)
                            .controlSize(.large)
                        Text("Scanning your photos…")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task {
                // A UI grace period (not a test delay): if the pass finishes first, this branch is
                // replaced and the sleep cancels before the indicator ever shows.
                indicatorVisible = false
                try? await Task.sleep(for: .milliseconds(300))
                indicatorVisible = true
            }

        case .ready(let clusters):
            // The store already assembled the timeline (date + trip clusters), ONCE, off-main when the
            // pass settled (Finding 1). The grid renders it directly. `store?.tripNames` is read here so
            // ScanningView re-renders as names resolve, handing the grid its fresh trip labels.
            ReviewGridView(
                clusters: clusters,
                tripNames: store?.tripNames ?? [:],
                title: project.title,
                subtitle: headerSubtitle(clusters),
                openAsset: { coordinator.openPhoto($0) },
                scrollToDay: scrollToDay)

        case .empty(let reason):
            ReviewEmptyView(
                reason: reason, rangeStart: project.rangeStart, rangeEnd: project.rangeEnd,
                onChangeRange: { coordinator.openSettings(project.id) },
                onReviewExclusions: { coordinator.openSettings(project.id) })

        case .failed(.loadError):
            ReviewLoadFailedView(onRetry: { Task { await scan() } })

        case .failed(.accessLost):
            ReviewAccessLostView(onRecovered: { Task { await scan() } })
        }
    }
}
