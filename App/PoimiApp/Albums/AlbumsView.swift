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
    // The New album sheet and the Delete / Reset confirmations are the coordinator's `modal` (#299), not
    // view state, so they can be read and set as data; this view binds to them.

    var body: some View {
        Group {
            if store.projects.isEmpty {
                ContentUnavailableView {
                    Label("No albums yet", systemImage: "photo.stack")
                } description: {
                    Text("Create an album to hand-pick photos into.")
                } actions: {
                    Button("New album", systemImage: "plus") { coordinator.present(.newAlbum) }
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
                                    ask(.reset, project)
                                }
                                Button("Delete album", systemImage: "trash", role: .destructive) {
                                    ask(.delete, project)
                                }
                            }
                            .disabled(session.isExporting(project))
                        }
                        .swipeActions(edge: .trailing) {
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                ask(.delete, project)
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
                Button("New album", systemImage: "plus") { coordinator.present(.newAlbum) }
                    .accessibilityIdentifier("newAlbumButton")
            }
        }
        .sheet(isPresented: coordinator.presenting(.newAlbum)) {
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
        // The confirm buttons go through `AlbumActions.confirm` — the one path from a confirm tap to the
        // store, shared with album settings and the control plane (#299). Cancel and a dismissal clear the
        // coordinator's modal through the binding.
        .confirmationDialog("Delete this album?", isPresented: pendingBinding(.delete),
                            titleVisibility: .visible, presenting: pending(.delete)) { pending in
            Button("Delete “\(pending.project.title)”", role: .destructive) {
                actions.confirm(pending.confirmation)
            }
            Button("Cancel", role: .cancel) {}
        } message: { pending in
            let project = pending.project
            Text("""
                Removes the album and its ^[\(project.persistedPickedCount) pick](inflect: true). \
                Your Photos library isn’t touched.
                """)
        }
        // Same wording as Album settings (#285): this is the SAME operation, and it is the more
        // mis-tappable route (a row context menu, with no album context on screen). The confirm button
        // counts what it discards rather than saying a bare "Reset".
        .confirmationDialog("Reset all progress?", isPresented: pendingBinding(.reset),
                            titleVisibility: .visible, presenting: pending(.reset)) { pending in
            Button(role: .destructive) {
                actions.confirm(pending.confirmation)
            } label: {
                Text(ResetConfirmTitle.text(picks: pending.project.persistedPickedCount))
            }
            Button("Cancel", role: .cancel) {}
        } message: { pending in
            let project = pending.project
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

    /// Ask to delete / reset `project` from its row: the coordinator presents the list's confirmation. The
    /// confirm then runs through the one ordering every delete / reset shares (`AlbumActions`): the live
    /// stores let go of it first (#59); on iPad, deleting the album on screen returns the detail to the
    /// library root; a non-active album's reset never touches the live stores.
    private func ask(_ kind: AlbumConfirmation.Kind, _ project: CurationProject) {
        coordinator.present(.confirm(AlbumConfirmation(kind: kind, album: project.id, origin: .albumList)))
    }

    /// The list's pending confirmation of `kind`, with its album (`nil` when none is up, or its album is
    /// gone). A lookup over the album list — small, and read only while a dialog is up or appearing.
    private struct Pending {
        let confirmation: AlbumConfirmation
        let project: CurationProject
    }

    private func pending(_ kind: AlbumConfirmation.Kind) -> Pending? {
        guard case .confirm(let confirmation)? = coordinator.modal, confirmation.kind == kind,
              confirmation.origin == .albumList,
              let project = store.projects.first(where: { $0.id == confirmation.album }), !project.isGone
        else { return nil }
        return Pending(confirmation: confirmation, project: project)
    }

    /// The iPad sidebar's selection highlight (#42): tint the open album's row — regular width only, since
    /// in the compact stack the list is covered after a push, so a lingering highlight would be noise.
    /// `nil` → the default row background. Keyed on the open album, so it follows the row if it reorders.
    private func rowBackground(for project: CurationProject) -> Color? {
        (sizeClass != .compact && project.id == coordinator.activeAlbumID) ? Color(.systemGray5) : nil
    }

    /// A dialog is up while the list's confirmation of `kind` is the coordinator's modal; Cancel or a
    /// dismissal clears it (only that one — never a modal presented since).
    private func pendingBinding(_ kind: AlbumConfirmation.Kind) -> Binding<Bool> {
        Binding(get: { pending(kind) != nil },
                set: { if !$0, let pending = pending(kind) { coordinator.dismiss(.confirm(pending.confirmation)) } })
    }
}

/// The Reset confirmation's destructive button title, shared by the album list and album settings: it
/// counts what it discards ("Discard 34 picks"), or says "Reset everything" with nothing to name.
/// `AttributedString(localized:)`, not `String(localized:)`: only the attributed form applies the
/// `^[…](inflect: true)` grammar agreement — the plain string showed the markup verbatim.
enum ResetConfirmTitle {
    static func text(picks: Int) -> AttributedString {
        picks == 0
            ? AttributedString(localized: "Reset everything",
                               comment: "Destructive confirm when there are no picks to name")
            : AttributedString(localized: "Discard ^[\(picks) pick](inflect: true)",
                               comment: "Destructive confirm button: names the pick count it discards")
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
