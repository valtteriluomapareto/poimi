//
//  ScanningView.swift
//  PoimiApp — the long-scan surface for the review-fetch pass (issue #34, D12; architecture §3).
//
//  Drives a `CandidateStore` for the opened project and renders its phase. This is the *minimal*
//  scan surface: a labeled progress indicator while the fetch+filter pass runs (never a bare
//  blocking spinner), then the candidate summary, an empty state, or a recoverable failure. The
//  full cancelable curate-*while*-scanning surface (D12) lands in Phase 4 with the async quality
//  filter; the `.ready` summary here is replaced by the actual review grid in #35.
//

import SwiftUI
import Curation

struct ScanningView: View {
    let project: CurationProject
    @Environment(\.photoLibrary) private var library
    @State private var store: CandidateStore?

    var body: some View {
        content
            .navigationTitle(project.title)
            .navigationBarTitleDisplayMode(.inline)
            .task {
                // Reuse an existing store across view rebuilds; only the first appearance loads.
                let resolved = store ?? CandidateStore(library: library)
                store = resolved
                if resolved.phase == .idle { await resolved.load(project) }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch store?.phase ?? .idle {
        case .idle, .scanning:
            // Labeled, centered — context, not a bare spinner (design language). The pass is one
            // actor round-trip, so it's indeterminate here; the determinate count is the Phase-4
            // D12 surface.
            VStack(spacing: 16) {
                ProgressView()
                    .controlSize(.large)
                    .tint(.brandGreen)
                Text("Scanning your photos…")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

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
                Text("Something went wrong while scanning. Check your connection and try again.")
            } actions: {
                Button("Try again") { Task { await store?.load(project) } }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

/// The `.ready` stand-in until #35 builds the grid: the candidate count and the day-group
/// partition the review grid will section by — enough to verify the fetch+filter+group pipeline
/// in a screenshot.
private struct ReadySummaryView: View {
    let assets: [AssetRef]

    var body: some View {
        let groups = DayGrouping.groups(for: assets)
        ContentUnavailableView {
            Label("\(assets.count) photos ready", systemImage: "checkmark.circle")
                .foregroundStyle(.brandGreen)
        } description: {
            Text("Across ^[\(groups.count) day-group](inflect: true) to review. The grid lands in #35.")
        }
    }
}
