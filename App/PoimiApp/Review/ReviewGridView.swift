//
//  ReviewGridView.swift
//  PoimiApp — the review grid (issue #35; promoted from the spike's AssetGridView).
//
//  THE make-or-break screen: a `LazyVGrid` in a `ScrollView`, split into Curation's adaptive
//  day-groups with **pinned section headers** (the headline Phase-0 finding — a flat year-grid is
//  harder to curate than grouped). The grid still scrolls as one chronological flow. It keeps:
//    • badge-select (resolved by the spike): tap a cell opens it; tap the ≥44pt badge selects,
//    • pinch-to-adjust column density (default 3 on iPhone),
//    • a scroll-driven prefetch window (visible range ± a row margin) feeding the thumbnail seam,
//    • `.scrollPosition` restore to the source cell after a zoom dismiss (#36).
//
//  Selection is the shared `SelectionStore` (the in-memory `Set` source of truth, D15); reading
//  `contains` here ties the grid to it via Observation, so a toggle re-renders just the affected
//  cells. The tally + export chrome and the select-mode toolbar land in #35 part 3.
//

import SwiftUI
import UIKit
import Curation

struct ReviewGridView: View {
    /// The candidates split into adaptive day-groups (oldest → newest). Concatenating the groups'
    /// `assetIDs` reproduces the full chronological slice — the sections are headered runs of it.
    let groups: [DayGroup]
    /// Open a cell full-screen (the parent pushes the viewer, #36).
    let openAsset: (String) -> Void
    /// Namespace pairing the cell with the `.zoom` viewer destination (#36).
    let zoomNamespace: Namespace.ID
    /// The cell to restore scroll position to (updated on tap / by the viewer on swipe).
    @Binding var scrollAnchorID: String?

    @Environment(\.thumbnailProvider) private var thumbnails
    @Environment(SelectionStore.self) private var selection

    @State private var columnCount = 3
    @State private var pinchBaseline = 3
    @State private var visibleIDs: Set<String> = []
    @State private var window = PrefetchWindow(orderedIDs: [])
    @State private var recomputeScheduled = false

    private let spacing: CGFloat = 2
    private let minColumns = 2
    private let maxColumns = 8
    private let windowRowMargin = 2
    /// Oversized vs the on-screen point size on purpose (Retina + density headroom).
    private let thumbnailTarget = CGSize(width: 400, height: 400)

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: spacing), count: columnCount)
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: spacing, pinnedViews: [.sectionHeaders]) {
                ForEach(groups) { group in
                    Section {
                        ForEach(group.assetIDs, id: \.self) { id in
                            cell(for: id).id(id)
                        }
                    } header: {
                        sectionHeader(group)
                    }
                }
            }
            .scrollTargetLayout()
        }
        .scrollPosition(id: $scrollAnchorID, anchor: .center)
        .animation(.snappy, value: columnCount)
        .gesture(
            MagnifyGesture()
                .onChanged { value in
                    let proposed = Double(pinchBaseline) / value.magnification
                    columnCount = min(maxColumns, max(minColumns, Int(proposed.rounded())))
                }
                .onEnded { _ in pinchBaseline = columnCount }
        )
        .onAppear {
            rebuildWindow()
            scheduleRecomputeWindow()
        }
        .onChange(of: visibleIDs) { scheduleRecomputeWindow() }
        .onChange(of: columnCount) { scheduleRecomputeWindow() }
        .onChange(of: groupIdentity) {
            rebuildWindow()
            visibleIDs = []
            scheduleRecomputeWindow()
        }
        .onDisappear { Task { await thumbnails.resetCache() } }
    }

    // MARK: Section header (adaptive day-group label)

    private func sectionHeader(_ group: DayGroup) -> some View {
        HStack(spacing: 6) {
            if group.isBusyDay {
                Circle().fill(.tint).frame(width: 6, height: 6)
            }
            Text(DayGroupHeader.title(for: group))
                .font(.subheadline.weight(.semibold))
            Text("· \(group.count)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        // A heading + a per-section selected/total summary so VoiceOver can navigate a huge grid.
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isHeader)
        .accessibilityLabel(sectionAccessibilityLabel(group))
    }

    private func sectionAccessibilityLabel(_ group: DayGroup) -> String {
        let selectedCount = group.assetIDs.reduce(0) { $0 + (selection.contains($1) ? 1 : 0) }
        return "\(DayGroupHeader.title(for: group)). \(group.count) photos, \(selectedCount) selected."
    }

    // MARK: Cell

    private func cell(for id: String) -> some View {
        let isSelected = selection.contains(id)
        return ReviewGridCell(id: id, isSelected: isSelected, load: load)
            .matchedTransitionSource(id: id, in: zoomNamespace)
            .onTapGesture {
                scrollAnchorID = id
                openAsset(id)
            }
            // The ≥44pt badge zone wins over the whole-cell tap and toggles selection (D9).
            .overlay(alignment: .bottomTrailing) {
                Color.clear
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                    .onTapGesture { selection.toggle(id) }
            }
            .onAppear { visibleIDs.insert(id) }
            .onDisappear { visibleIDs.remove(id) }
            // VoiceOver: one element per cell, its selected state, and a named toggle action so a
            // photo can be selected without hunting for the badge.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Photo")
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityHint("Opens full screen. Use the actions to select.")
            .accessibilityAction(named: isSelected ? "Deselect" : "Select") { selection.toggle(id) }
    }

    private func load(_ id: String) async -> UIImage? {
        await thumbnails.thumbnail(for: id, targetSize: thumbnailTarget)
    }

    // MARK: Prefetch window

    private var groupIdentity: String {
        "\(groups.first?.id ?? "∅")#\(groups.reduce(0) { $0 + $1.assetIDs.count })"
    }

    private func rebuildWindow() {
        window = PrefetchWindow(orderedIDs: groups.flatMap(\.assetIDs))
    }

    private func scheduleRecomputeWindow() {
        guard !recomputeScheduled else { return }
        recomputeScheduled = true
        Task { @MainActor in
            recomputeScheduled = false
            let slice = window.slice(visibleIDs: visibleIDs, columnCount: columnCount, rowMargin: windowRowMargin)
            await thumbnails.updateCachingWindow(to: slice)
        }
    }
}
