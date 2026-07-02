//
//  AlbumSettingsView.swift
//  PoimiApp — per-album settings (issue #41, D31; Paper artboard "Album settings" 2F1).
//
//  A grouped form to edit one album's configuration in place — name, period, target, exclusions,
//  export destination — plus the destructive Reset / Delete. This screen is PER-ALBUM only:
//  app-level settings (Photos access, About) belong on a separate app-settings screen reached from
//  the album library, not inside one album — the 2F1 design's "App" section lives there, not here.
//  Pushed from the album Overview (the gear). Edits apply immediately (iOS-Settings style, no Save
//  button): controls bind straight to the `@Observable` `CurationProject`, and leaving the screen
//  forces a durable save via `ProjectStore` (rather than leaning on the mainContext's deferred
//  autosave) and re-syncs the live tally's target.
//
//  Reset / Delete route through `ProjectStore` (never touching the exported Photos album or the
//  user's originals, D31) and reconcile the live `SelectionStore` / `DoneStore` so the Overview
//  behind reflects the change the moment this screen pops.
//

import SwiftUI

struct AlbumSettingsView: View {
    @Environment(ProjectStore.self) private var store
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(SelectionStore.self) private var selection
    @Environment(DoneStore.self) private var doneStore

    /// The album being edited. `@Bindable` so Form controls bind straight to the persisted model —
    /// it's `@Observable`, so a bound edit updates it (and any live view) immediately.
    @Bindable var project: CurationProject
    /// Injectable so the end-exclusive ↔ inclusive-day date arithmetic is testable with a fixed
    /// calendar (matches `NewAlbumSetupView`).
    private let calendar: Calendar

    @State private var confirmingReset = false
    @State private var confirmingDelete = false
    /// Set just before a delete pops the screen, so the teardown `onDisappear` doesn't try to save a
    /// project that's already been removed from the context.
    @State private var isDeleting = false

    init(project: CurationProject, calendar: Calendar = .current) {
        _project = Bindable(wrappedValue: project)
        self.calendar = calendar
    }

    var body: some View {
        Form {
            Section("Name") {
                TextField("Album name", text: $project.title)
            }

            Section {
                // Mutually bounded so an inverted/zero range is unreachable (same as setup): From ≤ the
                // inclusive To, and To ≥ From.
                DatePicker("From", selection: $project.rangeStart, in: ...inclusiveEndDate,
                           displayedComponents: .date)
                DatePicker("To", selection: inclusiveEnd, in: project.rangeStart...,
                           displayedComponents: .date)
            } header: {
                Text("Period")
            } footer: {
                Text("Changing the range re-scans which photos you pick from next time you review. "
                    + "Picks outside the new range are kept — you chose them.")
            }

            Section {
                NavigationLink {
                    AlbumPickerView(selection: targetSelection, allowsMultiple: false)
                } label: {
                    LabeledContent("Photos album", value: project.targetAlbumID == nil ? "New album" : "Existing album")
                }
                NavigationLink {
                    AlbumPickerView(selection: excludedSelection, allowsMultiple: true)
                } label: {
                    LabeledContent("Excluded albums", value: excludedValue)
                }
                Stepper("Aim for ^[\(project.targetCount) photo](inflect: true)",
                        value: $project.targetCount, in: 1...10_000, step: 10)
            } header: {
                Text("Saves to")
            } footer: {
                Text("Picks are copied to this Photos album — your library and originals aren't changed.")
            }

            Section {
                Button("Reset picks", role: .destructive) { confirmingReset = true }
                Button("Delete album", role: .destructive) { confirmingDelete = true }
            } footer: {
                Text("Reset clears your picks and progress but keeps the album's settings. Delete removes "
                    + "this album from Poimi — the Photos album it created and your originals are never touched.")
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        // Apply-on-leave: force a durable save (title/range/exclusions/destination) and re-sync the
        // live tally's target for the Overview behind. Skipped when we're mid-delete (the project is gone).
        .onDisappear {
            guard !isDeleting else { return }
            if project.title.trimmingCharacters(in: .whitespaces).isEmpty { project.title = "Untitled album" }
            store.saveEdits(to: project)
            selection.retarget(project)
        }
        // Keep the tally correct the instant the stepper moves (the target is cached in SelectionStore).
        .onChange(of: project.targetCount) { selection.retarget(project) }
        .confirmationDialog("Reset picks?", isPresented: $confirmingReset, titleVisibility: .visible) {
            Button("Reset “\(project.title)”", role: .destructive) { resetPicks() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Clears all picks and marked-done days. The album's settings are kept, "
                + "and your Photos library isn't touched.")
        }
        .confirmationDialog("Delete this album?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete “\(project.title)”", role: .destructive) { deleteAlbum() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes the album from Poimi. The Photos album it created and your originals are never touched.")
        }
    }

    // MARK: - Destructive actions

    /// Clear all progress, reconciling the live stores. Order matters: `deactivate()` flushes and
    /// clears each store's in-memory state, THEN `reset` zeroes the model, THEN we re-activate to reload
    /// the now-empty state — otherwise a later debounced flush would write stale picks back over the
    /// reset. The interim flush is redundant but harmless; Reset is a rare, explicit action.
    private func resetPicks() {
        selection.deactivate()
        doneStore.deactivate()
        store.reset(project)
        selection.activate(project)
        doneStore.activate(project)
    }

    /// Delete the project record and return to the album library. Deactivates the live stores first
    /// (so nothing holds the dangling project) and flags `isDeleting` so teardown doesn't re-save it.
    /// NEVER deletes the exported Photos album (D31).
    private func deleteAlbum() {
        isDeleting = true
        selection.deactivate()
        doneStore.deactivate()
        store.delete(project)
        coordinator.popToRoot()
    }

    // MARK: - Derived display

    /// The inclusive last day of the period, for display and as the "From" picker's upper bound. The
    /// draft stores `rangeEnd` end-exclusive (the fetch contract), so the picker reads/writes one day
    /// off through `inclusiveEnd` — the same off-by-one bridge `NewAlbumSetupView` uses.
    private var inclusiveEndDate: Date {
        NewAlbumDraft.inclusiveEndDay(forExclusiveEnd: project.rangeEnd, calendar: calendar)
    }

    private var inclusiveEnd: Binding<Date> {
        Binding(
            get: { NewAlbumDraft.inclusiveEndDay(forExclusiveEnd: project.rangeEnd, calendar: calendar) },
            set: { project.rangeEnd = NewAlbumDraft.exclusiveEnd(forInclusiveDay: $0, calendar: calendar) })
    }

    /// Bridges the single export target (`String?`) to the picker's `Set<String>` selection.
    private var targetSelection: Binding<Set<String>> {
        Binding(
            get: { project.targetAlbumID.map { [$0] } ?? [] },
            set: { project.targetAlbumID = $0.first })
    }

    /// Bridges the persisted excluded-album list (`[String]`) to the picker's `Set<String>` selection.
    private var excludedSelection: Binding<Set<String>> {
        Binding(
            get: { Set(project.excludedAlbumIDs) },
            set: { project.excludedAlbumIDs = Array($0) })
    }

    private var excludedValue: String {
        project.excludedAlbumIDs.isEmpty ? "None" : "\(project.excludedAlbumIDs.count)"
    }
}
