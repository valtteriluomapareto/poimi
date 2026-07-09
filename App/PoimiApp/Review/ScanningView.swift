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
    /// The album's scanned store — shared via the coordinator with the Overview, so drilling in reuses
    /// its clusters instead of re-fetching + re-clustering. Held here so `body` reads its phase.
    @State private var store: CandidateStore?
    /// Gates the scanning indicator behind a grace delay (below) so instant scans never flash it.
    @State private var indicatorVisible = false

    var body: some View {
        content()
            // Blanked once the grid is up — the pinned ReviewTopBar carries the current cluster's
            // identity there, so a nav title too would be a double title. Other phases (scanning /
            // empty / failed) keep it as their only label.
            .navigationTitle(isReady ? "" : project.title)
            // Inline, not large: a collapsing large title fought the pinned `.safeAreaInset` top bar
            // and the section headers in the same top zone (the "glitch between the title and the
            // first group" seen on device) and drove the Liquid Glass nav backdrop into an observation
            // feedback loop. The ReviewTopBar below carries the cluster context prominently.
            .navigationBarTitleDisplayMode(.inline)
            // No grid-level toolbar actions: Export now lives on the Overview (its own toolbar) and the
            // grid top is purely picking (design 4AB). The nav bar keeps only the system back button.
            // Hide the system nav backdrop so the ReviewTopBar's own glass (extended to the top edge) is
            // the single continuous glass surface up there — the back button floats on it, with no bright
            // photo band between the nav bar and the bar. We supply a STATIC glass (not the system
            // backdrop reacting to a collapsing title), which removes the observation feedback loop
            // — verified on device (no scroll flicker); re-check if the top-title layout changes.
            .toolbarBackground(.hidden, for: .navigationBar)
            // Keyed by the SAME `CandidateStoreKey` the coordinator uses for scan-vs-reuse (album + range +
            // location + the source filters), so re-targeting (iPad detail column) / any Settings edit
            // re-runs against the right candidate set — one key type, so this can't drift from the coordinator.
            .task(id: AppCoordinator.CandidateStoreKey(project)) {
                // Hydrate the selection + done-state for this project (idempotent — activate() no-ops
                // if already active, so re-entry never clobbers unflushed picks/done-days).
                selection.activate(project)
                doneStore.activate(project)
                // Reuse the album's shared store: the Overview scanned it on the way in, so drilling here
                // doesn't re-fetch + re-cluster. Scan only if WE are the first (iPad-direct / debug host);
                // otherwise just reconcile done-state + publish the viewer's paging list.
                let store = coordinator.candidateStore(for: project) {
                    CandidateStore(library: library, locationEnabled: project.locationEnabled,
                                   naming: placeNaming,
                                   nameCache: NameCacheStore(modelContainer: modelContext.container))
                }
                self.store = store
                if store.phase == .idle {
                    await scan()
                } else if case .ready = store.phase {
                    doneStore.reconcile(currentIDsByDay: Self.idsByDay(store.dayByID))
                    publishForViewer()
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
            coordinator.reviewAssetsByID = store?.assetsByID ?? [:]   // viewer info panel (#127)
            coordinator.reviewClusters = clusters   // viewer auto-done (#128) + grid page-restore (#126)
        }
    }

    private var isReady: Bool {
        if case .ready = store?.phase { return true }
        return false
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
