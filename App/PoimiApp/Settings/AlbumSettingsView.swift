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
#if DEBUG
import UIKit   // UIPasteboard for the DEBUG "Copy scan diagnostics" tool
#endif

struct AlbumSettingsView: View {
    @Environment(ProjectStore.self) private var store
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(SelectionStore.self) private var selection
    @Environment(DoneStore.self) private var doneStore
    @Environment(\.scenePhase) private var scenePhase

    /// The album being edited. `@Bindable` so Form controls bind straight to the persisted model —
    /// it's `@Observable`, so a bound edit updates it (and any live view) immediately.
    @Bindable var project: CurationProject
    /// Injectable so the end-exclusive ↔ inclusive-day date arithmetic is testable with a fixed
    /// calendar (matches `NewAlbumSetupView`).
    private let calendar: Calendar

    @State private var confirmingReset = false
    @State private var confirmingDelete = false
    /// Set just before a delete pops the screen, so the teardown save doesn't touch a project that's
    /// already been removed from the context.
    @State private var isDeleting = false
    /// The title as it was when the screen opened — restored if the user leaves the name blank, so
    /// clearing the field is a no-op rather than a silent rename to a placeholder.
    @State private var titleOnOpen: String
    #if DEBUG
    @State private var showLocationSpike = false
    #endif

    init(project: CurationProject, calendar: Calendar = .current) {
        _project = Bindable(wrappedValue: project)
        _titleOnOpen = State(initialValue: project.title)
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
                Text("""
                    Changing the range re-scans which photos you pick from next time you review. \
                    Picks outside the new range are kept — you chose them.
                    """)
            }

            Section {
                NavigationLink {
                    AlbumPickerView(selection: targetSelection, allowsMultiple: false)
                } label: {
                    LabeledContent("Photos album", value: project.targetAlbumID == nil
                        ? String(localized: "New album", comment: "Destination: a new album created on export")
                        : String(localized: "Existing album", comment: "Destination: an existing Photos album"))
                }
                Stepper("Aim for ^[\(project.targetCount) photo](inflect: true)",
                        value: $project.targetCount, in: 1...10_000, step: 10)
            } header: {
                Text("Saves to")
            } footer: {
                Text("Picks are copied to this Photos album — your library and originals aren't changed.")
            }

            // Source exclusions grouped together (matching setup) — both levers the "all excluded"
            // empty state points at, so "Review exclusions" lands somewhere it can actually fix.
            Section {
                Toggle("Exclude screenshots", isOn: $project.excludeScreenshots)
                NavigationLink {
                    AlbumPickerView(selection: excludedSelection, allowsMultiple: true)
                } label: {
                    LabeledContent("Excluded albums", value: excludedValue)
                }
            } header: {
                Text("Exclude from source")
            } footer: {
                Text("Screenshots and photos in these albums won't appear while you pick.")
            }

            Section {
                Toggle("Group by trips & places", isOn: $project.locationEnabled)
            } footer: {
                Text("""
                    Groups a stretch away from home into one trip (“Week in Salo”) with its place name. \
                    Turn off to review strictly by date.
                    """)
            }

            Section {
                Button("Reset picks", role: .destructive) { confirmingReset = true }
                Button("Delete album", role: .destructive) { confirmingDelete = true }
            } footer: {
                Text("""
                    Reset clears your picks and progress but keeps the album's settings. Delete removes \
                    this album from Poimi — the Photos album it created and your originals are never touched.
                    """)
            }

            #if DEBUG
            // DEBUG-only dev tool (release-isolated, D30): run the location-clustering spike over THIS
            // album's range (not the whole library), so it clusters a small set without downsampling. The
            // probe brings its own NavigationStack → hosted as a sheet (swipe down to dismiss).
            Section {
                Button { showLocationSpike = true } label: {
                    Label { Text(verbatim: "Location clustering") } icon: { Image(systemName: "map") }
                }
                .tint(.primary)
                Button {
                    UIPasteboard.general.string = coordinator.candidateStore?.scanReport?.text
                        ?? "No scan yet — open this album's overview first."
                } label: {
                    Label { Text(verbatim: "Copy scan diagnostics") } icon: { Image(systemName: "stopwatch") }
                }
                .tint(.primary)
            } header: {
                Text(verbatim: "Developer")
            } footer: {
                Text(verbatim: "Clusters this album live (tune eps / minPts). Scan diagnostics = where an "
                    + "album-open's time goes (fetch / cluster / naming), copied for sharing.")
            }
            #endif
        }
        // "Album settings", not just "Settings" — distinguishes it from the app-level `AppSettingsView`
        // (also reached by a gear-like icon), and matches this screen's entry `accessibilityLabel`.
        .navigationTitle("Album settings")
        .navigationBarTitleDisplayMode(.inline)
        #if DEBUG
        .sheet(isPresented: $showLocationSpike) {
            DebugAlbumLocationSpikeHostView(project: project)
        }
        #endif
        // Apply-on-leave AND on backgrounding: `onDisappear` alone isn't a reliable durable-save point
        // (it doesn't fire if the app is backgrounded — then force-quit — while this screen is up), which
        // would silently fall back to the deferred autosave we're avoiding. So persist on both.
        .onDisappear { persistEdits() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { persistEdits() } }
        // Keep the tally correct the instant the stepper moves (the target is cached in SelectionStore).
        .onChange(of: project.targetCount) { selection.retarget(project) }
        .confirmationDialog("Reset picks?", isPresented: $confirmingReset, titleVisibility: .visible) {
            Button("Reset “\(project.title)”", role: .destructive) { resetPicks() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("""
                Clears all picks and marked-done days. The album's settings are kept, \
                and your Photos library isn't touched.
                """)
        }
        .confirmationDialog("Delete this album?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete “\(project.title)”", role: .destructive) { deleteAlbum() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes the album from Poimi. The Photos album it created and your originals are never touched.")
        }
    }

    // MARK: - Persistence

    /// Force a durable save of the in-place edits (title / range / exclusions / destination) and re-sync
    /// the live tally's target for the Overview behind. A blank name restores the title the screen opened
    /// with (clearing the field is a no-op, not a silent rename). Skipped mid-delete — the project is gone.
    private func persistEdits() {
        guard !isDeleting else { return }
        if project.title.trimmingCharacters(in: .whitespaces).isEmpty {
            project.title = titleOnOpen.trimmingCharacters(in: .whitespaces).isEmpty
                ? String(localized: "Untitled album", comment: "Fallback album name when the user clears the name field")
                : titleOnOpen
        }
        store.saveEdits(to: project)
        selection.retarget(project)
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
        store.delete(project)   // also drops the album's cached timeline (ProjectStore.delete, #130)
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
        let count = project.excludedAlbumIDs.count
        switch count {
        case 0: return String(localized: "None", comment: "Excluded albums: none selected")
        case 1: return String(localized: "1 album", comment: "Excluded albums count, singular")
        default: return String(localized: "\(count) albums", comment: "Excluded albums count, 2 or more")
        }
    }
}
