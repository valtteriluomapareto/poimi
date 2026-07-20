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
        // Decode each JSON blob ONCE per render (the "no heavy work in a body" convention): the current
        // picks, and — only for an exported album — the drift baseline. Both feed the status via the
        // pre-decoded overload so it doesn't re-decode. "N in Photos" reads the stored `exportedPhotoCount`
        // (the true membership); it's `nil` for a pre-#191 export → the row shows just "Exported", never
        // the live pick count (that overstated what's actually in Photos — bug #191).
        let picks = project.persistedPicks
        let exported = project.exportedPicks
        let status = project.status(currentPicks: picks, exported: exported)
        let summary = AlbumSummary(status: status, picked: picks.count, target: project.targetCount,
                                   exportedCount: project.exportedPhotoCount)
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
                    Text(summary.detailLine)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(project.title), \(summary.detailLine)")
    }

    // Status colour roles (styleguide §1): exported = green (the "finish"), in-progress = gold
    // (progress), edited-since-export = amber (the heads-up tone, distinct from both — #191),
    // not-started = neutral.
    private func statusSymbol(_ status: ProjectStatus) -> String {
        switch status {
        case .empty: "circle.dashed"
        case .inProgress: "circle.bottomhalf.filled"
        case .exported: "checkmark.circle.fill"
        case .editedSinceExport: "arrow.up.circle.fill"   // "new picks to add" — not the green "done" check
        }
    }

    private func statusTint(_ status: ProjectStatus) -> Color {
        switch status {
        case .empty: .secondary
        case .inProgress: .accentColor
        case .exported: .brandGreen
        case .editedSinceExport: .brandWarning   // amber heads-up, distinct from green-done + gold-progress
        }
    }
}

/// Pure, testable display copy for an album row — the status label + the progress detail.
/// Kept out of the view so the derivation is unit-tested without rendering.
struct AlbumSummary: Equatable {
    let statusText: String
    /// The trailing detail ("47 / 100", "200 in Photos", "3 to add"); **empty** for an exported album
    /// whose true membership we never recorded (a pre-#191 export) — we don't guess "in Photos" from the
    /// live pick count (that overstated what's actually in Photos — device bug #191).
    let progressText: String

    /// `exportedCount` is the TRUE post-export album membership when known (`ExportResult.total`), or `nil`
    /// for a pre-#191 export with no record — in which case an exported row shows just "Exported", no count.
    init(status: ProjectStatus, picked: Int, target: Int, exportedCount: Int?) {
        switch status {
        case .empty:
            statusText = String(localized: "Not started", comment: "Album status: no picks")
            progressText = "\(picked) / \(target)"
        case .inProgress:
            statusText = String(localized: "In progress", comment: "Album status: in progress")
            progressText = "\(picked) / \(target)"
        case .exported:
            // Past-tense fact, not a present-tense "in Photos" sync claim that goes false on the next edit
            // (#191). The count is the true membership recorded at export — never the live pick count.
            statusText = String(localized: "Exported", comment: "Album status: exported to Photos at least once")
            progressText = exportedCount.map {
                String(localized: "\($0) in Photos", comment: "Album progress: N photos in the Photos album")
            } ?? ""
        case .editedSinceExport(let toAdd):
            // Additions-only framing (#191(a)): N new picks a re-export would add. Distinct amber tone.
            statusText = String(localized: "Edited since export",
                                comment: "Album status: picks changed after the last export")
            progressText = String(localized: "\(toAdd) to add",
                                  comment: "Album progress: N new picks not yet in Photos")
        }
    }

    /// The row's single line: "<status> · <detail>", or just "<status>" when there's no detail.
    var detailLine: String { progressText.isEmpty ? statusText : "\(statusText) · \(progressText)" }
}
