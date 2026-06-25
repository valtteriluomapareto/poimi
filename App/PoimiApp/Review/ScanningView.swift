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
    @Environment(\.photoLibrary) private var library
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(SelectionStore.self) private var selection
    @State private var store: CandidateStore?
    /// Gates the scanning indicator behind a grace delay (below) so instant scans never flash it.
    @State private var indicatorVisible = false
    /// Pairs grid cells with the `.zoom` viewer (#36); the anchor restores scroll on return.
    @Namespace private var zoomNamespace
    @State private var scrollAnchorID: String?

    var body: some View {
        content
            .navigationTitle(project.title)
            .navigationBarTitleDisplayMode(.inline)
            // Keyed by project id so re-targeting (e.g. iPad detail column) reloads for the new
            // album rather than showing the previous one's candidates.
            .task(id: project.id) {
                // Hydrate the selection for this project (idempotent — activate() no-ops if it's
                // already active, so re-entry never clobbers unflushed picks).
                selection.activate(project)
                let resolved = store ?? CandidateStore(library: library)
                store = resolved
                if resolved.phase == .idle { await resolved.load(project) }
            }
    }

    @ViewBuilder
    private var content: some View {
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

        case .ready(let assets):
            // The grid sections by the same adaptive day-groups the overview/completion use. Grouped
            // here (not in the store) so the store's `.ready` stays a plain `[AssetRef]` for tests;
            // this runs once per ready render — selection toggles re-render the grid, not this view.
            ReviewGridView(
                groups: DayGrouping.groups(for: assets),
                openAsset: { coordinator.openPhoto($0) },
                zoomNamespace: zoomNamespace,
                scrollAnchorID: $scrollAnchorID)

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
