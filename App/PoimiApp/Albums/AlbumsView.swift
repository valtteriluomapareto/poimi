//
//  AlbumsView.swift
//  PoimiApp — the album library / home (issue #32, D31; architecture §12).
//
//  The navigation root: the list of `CurationProject`s (the user-facing "albums"), most-recently-
//  opened first, each row showing its derived status + progress. Tap opens an album (the
//  coordinator pushes its overview); the row's context menu duplicates / resets / deletes.
//  Delete removes the project record only — never the Photos album (D31).
//

import SwiftUI
import Curation

struct AlbumsView: View {
    @Environment(ProjectStore.self) private var store
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(SelectionStore.self) private var selection
    @Environment(DoneStore.self) private var doneStore
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var showingSetup = false
    @State private var albumToDelete: CurationProject?
    @State private var albumToReset: CurationProject?

    var body: some View {
        Group {
            if store.projects.isEmpty {
                ContentUnavailableView {
                    Label("No albums yet", systemImage: "photo.stack")
                } description: {
                    Text("Create an album to hand-pick photos into.")
                } actions: {
                    Button("New album", systemImage: "plus") { showingSetup = true }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("newAlbumButton")
                }
            } else {
                // A `Button` per row (NOT `List(selection:)`): a plain list's selection binding doesn't
                // fire on a single tap in the compact `NavigationStack`, so that would break iPhone
                // tap-to-open. The Button navigates in both containers; the iPad sidebar highlight is
                // hand-rolled below via `listRowBackground` (regular width only), keyed on the open album.
                List {
                    ForEach(store.projects) { project in
                        Button { open(project) } label: {
                            AlbumRow(project: project)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(rowBackground(for: project))
                        .contextMenu {
                            Button("Duplicate", systemImage: "plus.square.on.square") {
                                store.duplicate(project)
                            }
                            // Reset + Delete are destructive (hand-curated picks are lost) → confirm
                            // first; "no destructive surprises" (design-language).
                            Button("Reset picks", systemImage: "arrow.counterclockwise", role: .destructive) {
                                albumToReset = project
                            }
                            Button("Delete album", systemImage: "trash", role: .destructive) {
                                albumToDelete = project
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                albumToDelete = project
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Albums")
        .toolbar {
            // The cog = APP-level settings (Photos access, About). The per-album settings screen uses a
            // sliders "adjustments" icon on the Overview instead, so the two never look alike.
            ToolbarItem(placement: .topBarLeading) {
                Button("Settings", systemImage: "gearshape") { coordinator.openAppSettings() }
            }
            ToolbarItem(placement: .primaryAction) {
                Button("New album", systemImage: "plus") { showingSetup = true }
                    .accessibilityIdentifier("newAlbumButton")
            }
        }
        .sheet(isPresented: $showingSetup) {
            NewAlbumSetupView(draft: .priorCalendarYear(now: Date(), calendar: .current))
        }
        .confirmationDialog("Delete this album?", isPresented: deleteConfirmation,
                            titleVisibility: .visible, presenting: albumToDelete) { project in
            Button("Delete “\(project.title)”", role: .destructive) {
                deleteAlbum(project)
                albumToDelete = nil
            }
            Button("Cancel", role: .cancel) { albumToDelete = nil }
        } message: { project in
            Text("""
                Removes the album and its ^[\(project.persistedPickedCount) pick](inflect: true). \
                Your Photos library isn’t touched.
                """)
        }
        .confirmationDialog("Reset picks?", isPresented: resetConfirmation,
                            titleVisibility: .visible, presenting: albumToReset) { project in
            Button("Reset “\(project.title)”", role: .destructive) {
                resetAlbum(project)
                albumToReset = nil
            }
            Button("Cancel", role: .cancel) { albumToReset = nil }
        } message: { _ in
            Text("Clears all picks and progress. The album’s settings are kept.")
        }
    }

    /// Open an album: bump it to the top of the library (most-recently-opened, §12) and navigate
    /// to its overview.
    private func open(_ project: CurationProject) {
        store.open(project)
        coordinator.openProject(project.id)
    }

    /// Delete from the library list. Deactivate the live stores first if this is the active album
    /// (reachable on iPad, where the sidebar shows while an album is active) — otherwise a store left
    /// holding the deleted model could flush a debounced write to it (#59). Mirrors `AlbumSettingsView`.
    private func deleteAlbum(_ project: CurationProject) {
        selection.deactivateIfActive(project)
        doneStore.deactivateIfActive(project)
        store.delete(project)
    }

    /// Reset from the library list. If it's the active album, deactivate (flush + clear) BEFORE zeroing so
    /// a late debounce can't resurrect the just-cleared picks, then re-activate to reload the emptied state
    /// (the `AlbumSettingsView.resetPicks` ordering). A no-op deactivate for any non-active album.
    private func resetAlbum(_ project: CurationProject) {
        let wasActive = selection.activeProjectID == project.persistentModelID
        selection.deactivateIfActive(project)
        doneStore.deactivateIfActive(project)
        store.reset(project)
        if wasActive {
            selection.activate(project)
            doneStore.activate(project)
        }
    }

    /// The iPad sidebar's selection highlight (#42): tint the open album's row — regular width only, since
    /// in the compact stack the list is covered after a push, so a lingering highlight would be noise.
    /// `nil` → the default row background. Keyed on the open album, so it follows the row if it reorders.
    private func rowBackground(for project: CurationProject) -> Color? {
        (sizeClass != .compact && project.id == coordinator.activeAlbumID) ? Color(.systemGray5) : nil
    }

    // Drive the confirmation dialogs off the pending-project optionals (cleared on dismiss).
    private var deleteConfirmation: Binding<Bool> {
        Binding(get: { albumToDelete != nil }, set: { if !$0 { albumToDelete = nil } })
    }
    private var resetConfirmation: Binding<Bool> {
        Binding(get: { albumToReset != nil }, set: { if !$0 { albumToReset = nil } })
    }
}

/// One album row: a cover placeholder, the title, and the derived status + progress.
struct AlbumRow: View {
    let project: CurationProject

    var body: some View {
        // Decode the selection snapshot ONCE per render and derive status + summary from that count,
        // rather than re-decoding via `project.status` / `AlbumSummary(project:)` (the "no heavy work
        // in a body" convention; the snapshot is a JSON blob).
        let picked = project.persistedPickedCount
        let status = project.status(forPickedCount: picked)
        let summary = AlbumSummary(status: status, picked: picked, target: project.targetCount)
        return HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(.systemGray6))
                .frame(width: 56, height: 56)
                // Real cover thumbnail arrives with image loading; placeholder until then.
                .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(project.title)
                    .font(.headline)
                HStack(spacing: 6) {
                    Image(systemName: statusSymbol(status))
                        .foregroundStyle(statusTint(status))
                        .font(.subheadline)        // scales with Dynamic Type alongside the text
                        .imageScale(.small)
                    Text("\(summary.statusText) · \(summary.progressText)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(project.title), \(summary.statusText), \(summary.progressText)")
    }

    // Status colour roles (styleguide §1): done = green (the "finish"), in-progress = gold
    // (progress), not-started = neutral.
    private func statusSymbol(_ status: ProjectStatus) -> String {
        switch status {
        case .empty: "circle.dashed"
        case .inProgress: "circle.bottomhalf.filled"
        case .done: "checkmark.circle.fill"
        }
    }

    private func statusTint(_ status: ProjectStatus) -> Color {
        switch status {
        case .empty: .secondary
        case .inProgress: .accentColor
        case .done: .brandGreen
        }
    }
}

/// Pure, testable display copy for an album row — the status label + the picked/target progress.
/// Kept out of the view so the derivation is unit-tested without rendering.
struct AlbumSummary: Equatable {
    let statusText: String
    let progressText: String

    init(status: ProjectStatus, picked: Int, target: Int) {
        switch status {
        case .empty: statusText = String(localized: "Not started", comment: "Album status: no picks")
        case .inProgress: statusText = String(localized: "In progress", comment: "Album status: in progress")
        case .done: statusText = String(localized: "Done", comment: "Album status: finalized")
        }
        progressText = "\(picked) / \(target)"
    }

    init(project: CurationProject) {
        self.init(status: project.status, picked: project.persistedPickedCount, target: project.targetCount)
    }
}
