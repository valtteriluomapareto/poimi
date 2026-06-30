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
    @State private var store: CandidateStore?
    /// The album the current `store` loaded — so a reused view instance reloads for a NEW album
    /// rather than republishing the previous one's candidates (the iPad detail-column retarget, #42).
    @State private var loadedProjectID: UUID?
    /// Gates the scanning indicator behind a grace delay (below) so instant scans never flash it.
    @State private var indicatorVisible = false

    var body: some View {
        content()
            .navigationTitle(project.title)
            // Inline, not large: a collapsing large title fought the pinned `.safeAreaInset` tally
            // header and the section headers in the same top zone (the "glitch between the title and
            // the first group" seen on device) and drove the Liquid Glass nav backdrop into an
            // observation feedback loop. The ReviewHeader below carries the album context prominently.
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { reviewChrome }
            // Keyed by project id so re-targeting (e.g. iPad detail column) reloads for the new
            // album rather than showing the previous one's candidates.
            .task(id: project.id) {
                // Hydrate the selection for this project (idempotent — activate() no-ops if it's
                // already active, so re-entry never clobbers unflushed picks).
                selection.activate(project)
                // Reload when the album actually changed (or first load); reuse only survives a
                // benign re-appear of the SAME album, so returning from the viewer doesn't re-scan.
                // Gating on project identity (not `.idle`) stops a reused view instance from serving
                // the previous album's candidates + day map to the viewer (#42).
                if store == nil || loadedProjectID != project.id {
                    let fresh = CandidateStore(library: library)
                    store = fresh
                    loadedProjectID = project.id
                    await fresh.load(project)
                }
                // Publish the candidate list + per-photo day map so the photo viewer can page
                // through it and label each photo's day (#36).
                if case .ready(let groups) = store?.phase {
                    coordinator.reviewOrderedIDs = groups.flatMap(\.assetIDs)
                    coordinator.reviewDayByID = store?.dayByID ?? [:]
                }
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
    private func headerSubtitle(_ groups: [DayGroup]) -> String {
        let total = groups.reduce(0) { $0 + $1.count }
        return "\(total.formatted()) photos · \(periodLabel)"
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

        case .ready(let groups):
            // The store already grouped the candidates into adaptive day-groups, ONCE, when the pass
            // settled (Finding 1). The grid renders them directly and never recomputes the grouping.
            ReviewGridView(
                groups: groups,
                subtitle: headerSubtitle(groups),
                openAsset: { coordinator.openPhoto($0) },
                scrollToDay: scrollToDay)

        case .empty:
            ContentUnavailableView {
                Label("No photos in range", systemImage: "photo.on.rectangle")
            } description: {
                Text("Nothing matched this album's date range and filters.")
            }

        case .failed:
            ContentUnavailableView {
                Label("Couldn't load your photos", systemImage: "exclamationmark.triangle")
            } description: {
                Text("Something went wrong while scanning your library. Try again.")
            } actions: {
                Button("Try again") { Task { await store?.load(project) } }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}
