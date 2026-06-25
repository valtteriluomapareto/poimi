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
    @State private var store: CandidateStore?
    /// Gates the scanning indicator behind a grace delay (below) so instant scans never flash it.
    @State private var indicatorVisible = false

    var body: some View {
        content
            .navigationTitle(project.title)
            .navigationBarTitleDisplayMode(.inline)
            // Keyed by project id so re-targeting (e.g. iPad detail column) reloads for the new
            // album rather than showing the previous one's candidates.
            .task(id: project.id) {
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
            // Placeholder for the #35 review grid: proves the whole pipeline end-to-end by
            // summarizing the filtered candidates and how the grouping function partitions them.
            ReadySummaryView(assets: assets)

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

/// The `.ready` stand-in until #35 builds the grid: the candidate count and the day-group
/// partition the review grid will section by — enough to verify the fetch+filter+group pipeline
/// in a screenshot. A plain summary (not `ContentUnavailableView`, whose "unavailable" semantics
/// would misframe a positive result for VoiceOver).
private struct ReadySummaryView: View {
    let assets: [AssetRef]

    var body: some View {
        let groups = DayGrouping.groups(for: assets)
        VStack(spacing: 12) {
            // Green reads as success here — the same status-green the album list uses for "done".
            Image(systemName: "checkmark.circle")
                .font(.largeTitle)
                .foregroundStyle(.brandGreen)
            Text("\(assets.count) photos ready")
                .font(.title2.bold())
            Text("Across ^[\(groups.count) day-group](inflect: true) to review. The grid lands in #35.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
