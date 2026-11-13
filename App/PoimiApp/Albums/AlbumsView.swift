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
    @Environment(AlbumActions.self) private var actions
    @Environment(AlbumSession.self) private var session
    @Environment(WhatsNewState.self) private var whatsNew
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
                                actions.duplicate(project)
                            }
                            // Reset + Delete are destructive (hand-curated picks are lost) → confirm
                            // first; "no destructive surprises" (design-language).
                            // Not while this album's export runs (iPad: the sidebar stays tappable over the
                            // export screen) — the run stamps its result into the album when it lands.
                            Group {
                                Button("Reset all progress", systemImage: "arrow.counterclockwise",
                                       role: .destructive) {
                                    albumToReset = project
                                }
                                Button("Delete album", systemImage: "trash", role: .destructive) {
                                    albumToDelete = project
                                }
                            }
                            .disabled(session.isExporting(project))
                        }
                        .swipeActions(edge: .trailing) {
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                albumToDelete = project
                            }
                            .disabled(session.isExporting(project))
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
        // What's New (#248): auto-presents once per new version at the albums root — structurally in the
        // `.albums` phase only (AlbumsView is the compact root / iPad sidebar, never shown during
        // onboarding). Routing Continue AND swipe-down through the binding's setter means an interactive
        // dismiss still persists (WhatsNewState.markAsSeen is idempotent).
        .sheet(isPresented: Binding(
            get: { whatsNew.shouldShow },
            set: { if !$0 { whatsNew.markAsSeen() } }
        )) {
            WhatsNewView(notes: whatsNew.notes) { whatsNew.markAsSeen() }
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
        // Same wording as Album settings (#285): this is the SAME operation, and it is the more
        // mis-tappable route (a row context menu, with no album context on screen). The confirm button
        // counts what it discards rather than saying a bare "Reset".
        .confirmationDialog("Reset all progress?", isPresented: resetConfirmation,
                            titleVisibility: .visible, presenting: albumToReset) { project in
            Button(project.persistedPickedCount == 0
                   ? String(localized: "Reset everything",
                            comment: "Destructive confirm when there are no picks to name")
                   : String(localized: "Discard ^[\(project.persistedPickedCount) pick](inflect: true)",
                            comment: "Destructive confirm button: names the pick count it discards"),
                   role: .destructive) {
                resetAlbum(project)
                albumToReset = nil
            }
            Button("Cancel", role: .cancel) { albumToReset = nil }
        } message: { project in
            Text("""
                Discards ^[\(project.persistedPickedCount) pick](inflect: true), every day mark and the \
                export history for “\(project.title)”. The Photos album it created is not touched.
                """)
        }
    }

    /// Open an album: bump it to the top of the library (most-recently-opened, §12) and navigate
    /// to its overview.
    private func open(_ project: CurationProject) {
        actions.open(project)
    }

    /// Delete from the library list — through the one ordering every delete shares (`AlbumActions`): the
    /// live stores let go of it first (#59), and on iPad, where the sidebar shows while an album is open,
    /// deleting the album on screen returns the detail to the library root.
    private func deleteAlbum(_ project: CurationProject) {
        actions.delete(project)
    }

    /// Reset from the library list — through the one ordering every reset shares (`AlbumActions`): the
    /// stores holding it flush + let go before the zeroing and re-hydrate after. A non-active album's
    /// reset never touches the live stores.
    private func resetAlbum(_ project: CurationProject) {
        actions.reset(project)
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
        // A row can be asked to render once more for an album just deleted (the list animates it out
        // after the stores' last flush wrote to it): a deleted model's attributes trap, so draw nothing.
        if project.isGone {
            EmptyView()
        } else {
            row
        }
    }

    private var row: some View {
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
