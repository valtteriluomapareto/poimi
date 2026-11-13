//
//  AlbumSettingsView.swift
//  PoimiApp — per-album settings (issue #41, D31; Paper artboard "Album settings" 2F1).
//
//  A grouped form to edit one album's configuration in place — name, period, target, exclusions,
//  export destination — plus the destructive Reset / Delete. This screen is PER-ALBUM only:
//  app-level settings (Photos access, About) belong on a separate app-settings screen reached from
//  the album library, not inside one album — the 2F1 design's "App" section lives there, not here.
//  Pushed from the album Overview (the gear). Edits apply immediately (iOS-Settings style, no Save
//  button): every control writes through `AlbumActions.stage` (the edit rules, in one place), and
//  leaving the screen commits them through `AlbumActions.applyEdits` — a durable save (rather than leaning on the
//  mainContext's deferred autosave) + re-syncing the live tally's target.
//
//  Reset / Delete route through `AlbumActions` (never touching the exported Photos album or the
//  user's originals, D31), which reconciles the live `SelectionStore` / `DoneStore` so the Overview
//  behind reflects the change the moment this screen pops.
//

import SwiftUI
#if DEBUG
import UIKit   // UIPasteboard for the DEBUG "Copy scan diagnostics" tool
#endif

struct AlbumSettingsView: View {
    @Environment(AlbumActions.self) private var actions
    @Environment(AppCoordinator.self) private var coordinator   // the confirmations are its modal (#299)
    @Environment(AlbumSession.self) private var session
    @Environment(SelectionStore.self) private var selection
    @Environment(DoneStore.self) private var doneStore
    @Environment(\.scenePhase) private var scenePhase

    /// The album being edited. `@Bindable` so Form controls bind straight to the persisted model —
    /// it's `@Observable`, so a bound edit updates it (and any live view) immediately.
    @Bindable var project: CurationProject
    /// Injectable so the end-exclusive ↔ inclusive-day date arithmetic is testable with a fixed
    /// calendar (matches `NewAlbumSetupView`).
    private let calendar: Calendar

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
        // The album can be deleted while this screen is still on its way out (the iPad sidebar's Delete
        // pops the detail in the same turn the model goes): a deleted model's attributes trap, so the
        // outgoing screen draws nothing rather than reading it (#298 review).
        if project.isGone {
            Color.clear
        } else {
            screen
        }
    }

    private var screen: some View {
        Form {
            Section("Name") {
                TextField("Album name", text: staged(\.title) { AlbumEdits(title: $0) })
            }

            Section {
                // "From" is unbounded; "To" stays ≥ "From". Moving "From" to or past "To" collapses "To"
                // to a single day at the new start (`rangeStartBinding` → `nonInvertedEnd`) instead of
                // greying out later dates — so a range past the current one is reachable without reordering
                // taps, and the interval never inverts (same as setup, #259). The row label goes on
                // `LabeledContent`, not the picker (`labelsHidden`), so the compact date button keeps its
                // natural width and never truncates at larger text sizes; it also stacks at AX sizes (#173).
                LabeledContent("From") {
                    DatePicker("From", selection: rangeStartBinding, displayedComponents: .date)
                        .labelsHidden()
                }
                LabeledContent("To") {
                    DatePicker("To", selection: inclusiveEnd, in: project.rangeStart...,
                               displayedComponents: .date)
                        .labelsHidden()
                }
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
                        ? String(localized: "New Photos album",
                                 comment: "Destination: a new album created in Photos on finish")
                        : String(localized: "Existing Photos album",
                                 comment: "Destination: an existing album in the Photos app"))
                }
                TargetCountField(count: staged(\.targetCount) { AlbumEdits(targetCount: $0) })
            } header: {
                Text("Destination")
            } footer: {
                Text("Picks are copied to this Photos album — your library and originals aren’t changed.")
            }

            // Same 3-way lens as setup (#273, design 604-0 variant A) — bound to `project.media`, the
            // single writer of the two stored bools.
            Section {
                Picker("Media", selection: staged(\.media) { AlbumEdits(media: $0) }) {
                    ForEach(MediaSelection.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("settings.media")
            } header: {
                Text("Media")
            } footer: {
                Text("Sets what you review — not what’s already in the album. Switching keeps every pick and day mark.")
            }

            // Source exclusions grouped together (matching setup) — both levers the "all excluded"
            // empty state points at, so "Review exclusions" lands somewhere it can actually fix.
            Section {
                // Inert under the videos-only lens (see setup) — a screenshot is a still.
                Toggle("Exclude screenshots", isOn: staged(\.excludeScreenshots) { AlbumEdits(excludeScreenshots: $0) })
                    .disabled(project.media == .videosOnly)
                NavigationLink {
                    AlbumPickerView(selection: excludedSelection, allowsMultiple: true)
                } label: {
                    LabeledContent("Excluded albums", value: excludedValue)
                }
            } header: {
                Text("Exclude from source")
            } footer: {
                if project.media == .videosOnly {
                    Text("Screenshots are stills, so that switch has no effect while you’re reviewing videos only.")
                } else {
                    Text("Screenshots and photos in these albums won’t appear while you pick.")
                }
            }

            Section {
                Toggle("Group by trips & places", isOn: staged(\.locationEnabled) { AlbumEdits(locationEnabled: $0) })
            } footer: {
                Text("""
                    Groups a stretch away from home into one trip (“Week in Salo”) with its place name. \
                    Turn off to review strictly by date.
                    """)
            }

            // Review progress on its own, ABOVE the red block (#285, design 65Z-0). Not `.destructive`:
            // nothing the user chose is lost, and the accent tint is what separates "walk the album
            // again" from "throw things away" — three identical red rows is how someone loses a year of
            // picks to a mis-tap.
            Section {
                Button("Mark all days unreviewed") { coordinator.present(.confirm(confirmation(.markAllUnreviewed))) }
                    .disabled(doneStore.doneDays.isEmpty)
            } footer: {
                Text("Clears which days you’ve marked done so you can walk the album again. Your picks are kept.")
            }

            Section {
                // Relabelled (#285): this always cleared day marks, the resume point and the export
                // history too — "Reset picks" named a fraction of what it does.
                Button("Reset all progress", role: .destructive) { coordinator.present(.confirm(confirmation(.reset))) }
                Button("Delete album", role: .destructive) { coordinator.present(.confirm(confirmation(.delete))) }
            } footer: {
                Text("""
                    Reset clears your picks, your day marks and the export history — everything except the \
                    album’s settings. Delete removes this album from Poimi; the Photos album it created and \
                    your originals are never touched.
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
                    UIPasteboard.general.string = session.candidateStore?.scanReport?.text
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
        // Reliable number-pad dismissal for the target field (it has no return key): swipe to dismiss (#123).
        .scrollDismissesKeyboard(.interactively)
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
        // Not `.destructive`, and the button says what it does — never a bare "Reset" (#285). It sits
        // next to the red one, so reading alike is the failure mode.
        // The three dialogs are the coordinator's modal (#299); each confirm runs through
        // `AlbumActions.confirm`, the one path the album list's dialogs and the control plane use too.
        .confirmationDialog("Mark all days unreviewed?",
                            isPresented: coordinator.presenting(.confirm(confirmation(.markAllUnreviewed))),
                            titleVisibility: .visible) {
            Button("Mark all unreviewed") { actions.confirm(confirmation(.markAllUnreviewed)) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("""
                Clears the ^[\(doneStore.doneDays.count) day](inflect: true) you've marked done in \
                “\(project.title)”. Your picks are kept.
                """)
        }
        .confirmationDialog("Reset all progress?", isPresented: coordinator.presenting(.confirm(confirmation(.reset))),
                            titleVisibility: .visible) {
            // The confirm button counts what it destroys, so the cost is in the tap target rather than
            // only the prose above it.
            Button(role: .destructive) {
                actions.confirm(confirmation(.reset))
            } label: {
                Text(ResetConfirmTitle.text(picks: pickedCount))
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("""
                Discards ^[\(pickedCount) pick](inflect: true), every day mark and the export history \
                for “\(project.title)”. The Photos album it created is not touched.
                """)
        }
        .confirmationDialog("Delete this album?", isPresented: coordinator.presenting(.confirm(confirmation(.delete))),
                            titleVisibility: .visible) {
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
        actions.applyEdits(to: project, titleOnOpen: titleOnOpen)
    }

    // MARK: - Destructive actions

    /// This screen's confirmation of `kind` — the coordinator's modal while its dialog is up (#299). The
    /// confirms run through `AlbumActions.confirm` → `reset` / `markAllUnreviewed` / `delete`, the one
    /// ordering each shares: reset flushes + lets go of the live stores, zeroes, then re-hydrates (so a
    /// later debounced flush can't write stale picks back); mark-all-unreviewed's ordering lives in
    /// `DoneStore` and keeps every pick (#285).
    private func confirmation(_ kind: AlbumConfirmation.Kind) -> AlbumConfirmation {
        AlbumConfirmation(kind: kind, album: project.id, origin: .albumSettings)
    }

    /// The pick count to quote in the destructive dialogs. Prefers the LIVE count while this album is
    /// the hydrated one (so it reflects taps not yet flushed), and falls back to the persisted set
    /// otherwise — a dialog whose whole job is to state the cost honestly shouldn't depend on an
    /// invariant held by whoever pushed this screen.
    private var pickedCount: Int {
        selection.activeProjectID == project.persistentModelID
            ? selection.progress.picked
            : project.persistedPickedCount
    }

    /// Delete the project record and return to the album library (`AlbumActions.delete`: the live stores
    /// let go first, so nothing holds the dangling project). Flags `isDeleting` so teardown doesn't
    /// re-save it (a delete that didn't come from this button is caught by `applyEdits`' `isGone` guard).
    /// NEVER deletes the exported Photos album (D31).
    private func deleteAlbum() {
        // Only once it ran (it pops to the library, drops the model + cached timeline): a refused delete
        // (the album is exporting) leaves this screen up, and its edits must still be saved on leave.
        isDeleting = actions.confirm(confirmation(.delete))
    }

    // MARK: - Derived display

    /// "From" writes through here so moving the start past the end never leaves an inverted/greyed range:
    /// `AlbumActions.stage` sets the new start, then collapses "To" to a single day at that start if the
    /// start has reached/passed it (the user then extends "To"). Mirrors `NewAlbumSetupView` (#259). The
    /// rule lives in the façade so the control plane's `albums.update` applies the same one (#298).
    private var rangeStartBinding: Binding<Date> {
        Binding(
            get: { project.rangeStart },
            set: { actions.stage(AlbumEdits(rangeStart: $0), to: project, calendar: calendar) })
    }

    /// The "To" picker shows an inclusive end day, while the model stores `rangeEnd` end-exclusive (the
    /// fetch contract), so the picker reads/writes one day off — the same off-by-one bridge setup uses.
    private var inclusiveEnd: Binding<Date> {
        Binding(
            get: { NewAlbumDraft.inclusiveEndDay(forExclusiveEnd: project.rangeEnd, calendar: calendar) },
            set: {
                let end = NewAlbumDraft.exclusiveEnd(forInclusiveDay: $0, calendar: calendar)
                actions.stage(AlbumEdits(rangeEnd: end), to: project, calendar: calendar)
            })
    }

    /// Bridges the single export target (`String?`) to the picker's `Set<String>` selection.
    private var targetSelection: Binding<Set<String>> {
        Binding(
            get: { project.targetAlbumID.map { [$0] } ?? [] },
            set: { actions.stage(AlbumEdits(targetAlbumID: .some($0.first)), to: project, calendar: calendar) })
    }

    /// Bridges the persisted excluded-album list (`[String]`) to the picker's `Set<String>` selection.
    private var excludedSelection: Binding<Set<String>> {
        Binding(
            get: { Set(project.excludedAlbumIDs) },
            set: { actions.stage(AlbumEdits(excludedAlbumIDs: Array($0)), to: project, calendar: calendar) })
    }

    /// A control's binding: reads the model, and writes through `AlbumActions.stage` — the one place the
    /// settings edit rules live (the range clamp, the media lens's single writer, the live re-target), so
    /// the control plane's `albums.update` applies exactly what these controls do (#298).
    private func staged<Value>(_ field: KeyPath<CurationProject, Value>,
                               _ edit: @escaping (Value) -> AlbumEdits) -> Binding<Value> {
        Binding(get: { project[keyPath: field] },
                set: { actions.stage(edit($0), to: project, calendar: calendar) })
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
