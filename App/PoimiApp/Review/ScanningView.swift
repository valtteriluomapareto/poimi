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
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(AlbumSession.self) private var session
    /// The album's scanned store — shared via the album session with the Overview, so drilling in reuses
    /// its clusters instead of re-fetching + re-clustering. Held here so `body` reads its phase.
    @State private var store: CandidateStore?
    /// Gates the scanning indicator behind a grace delay (below) so instant scans never flash it.
    @State private var indicatorVisible = false

    var body: some View {
        // The album can be deleted while this screen is still on its way out (the iPad sidebar's Delete
        // pops the detail in the same turn the model goes): a deleted model's attributes trap, so the
        // outgoing screen draws nothing rather than reading it (#298 review).
        if project.isGone {
            Color.clear
        } else {
            screen
        }
    }

    private var screen: some View {
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
            // Keyed by the SAME `CandidateStoreKey` the session uses for scan-vs-reuse (album + range +
            // location + the source filters), so re-targeting (iPad detail column) / any Settings edit
            // re-runs against the right candidate set — one key type, so this can't drift from the session.
            .task(id: AlbumSession.CandidateStoreKey(project)) {
                // The album session (#297) does the whole entry: hydrate selection + done, reuse the store
                // the Overview scanned (or scan it — iPad-direct / debug host — with the shared timeline
                // cache), reconcile done-state (the grid reconciles; the Overview doesn't, #289) and publish
                // the review context the viewer pages through — and picks the grid's entry cluster (the
                // drill day's, else the first unreviewed one) once per visit. Held first so `body` shows
                // the scan phase.
                store = session.candidateStore(for: project)
                await session.appear(.review(scrollToDay), project)
            }
    }

    /// Re-run the fetch pass (a "Try again" / access recovered) through the session, which reconciles and
    /// republishes the review context as on entry.
    private func rescan() async {
        await session.rescanReview(project)
    }

    private var isReady: Bool {
        if case .ready = store?.phase { return true }
        return false
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
                openAsset: { coordinator.openPhoto($0) })   // its entry page is the session's (#299)

        case .empty(let reason):
            ReviewEmptyView(
                reason: reason, rangeStart: project.rangeStart, rangeEnd: project.rangeEnd,
                onChangeRange: { coordinator.openSettings(project.id) },
                onReviewExclusions: { coordinator.openSettings(project.id) },
                // Fix the lens in place — no settings round-trip for a one-switch problem (#273).
                // The scan re-runs because `CandidateStoreKey` tracks the media filter.
                onIncludePhotos: { project.media = .photosAndVideos })

        case .failed(.loadError):
            ReviewLoadFailedView(onRetry: { Task { await rescan() } })

        case .failed(.accessLost):
            ReviewAccessLostView(onRecovered: { Task { await rescan() } })
        }
    }
}
