//
//  NewAlbumSetupView.swift
//  PoimiApp — configure a new album (issue #33, D2; architecture §8).
//
//  Presented as a sheet from the albums home (#32). Gathers a `NewAlbumDraft` — name, period,
//  target, exclusions, export target — and on Create persists it via `ProjectStore` and opens it.
//

import SwiftUI

struct NewAlbumSetupView: View {
    @Environment(ProjectStore.self) private var store
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss

    @State private var draft: NewAlbumDraft
    private let calendar: Calendar

    init(draft: NewAlbumDraft, calendar: Calendar = .current) {
        _draft = State(initialValue: draft)
        self.calendar = calendar
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Album name", text: $draft.title)
                }

                Section {
                    // "From" is unbounded; "To" stays ≥ "From". Moving "From" to or past "To" collapses
                    // "To" to a single day at the new start (`rangeStartBinding` → `nonInvertedEnd`) instead
                    // of greying out later dates — so a range past the default is reachable without
                    // reordering taps, and the interval is never inverted (Create can't be silently
                    // disabled). Same behaviour in AlbumSettingsView (#259). Row label on `LabeledContent`,
                    // not the picker (`labelsHidden`), so the date button keeps its natural width (no
                    // truncation at larger text sizes) + stacks at AX sizes (#173).
                    LabeledContent("From") {
                        DatePicker("From", selection: rangeStartBinding, displayedComponents: .date)
                            .labelsHidden()
                    }
                    LabeledContent("To") {
                        DatePicker("To", selection: inclusiveEnd, in: draft.rangeStart...,
                                   displayedComponents: .date)
                            .labelsHidden()
                    }
                } header: {
                    Text("Period")
                } footer: {
                    Text("Photos captured in this date range are the candidates to pick from.")
                }

                Section {
                    TargetCountField(count: $draft.targetCount)
                } header: {
                    Text("Target")
                } footer: {
                    Text("A goal, not a limit — you can pick past it.")
                }

                // The 3-way media lens (#273, design 604-0 variant A). Segmented so all three options
                // are visible at once — it reads as a lens you switch, not a setting you edit. Bound to
                // `draft.media`, never to the two bools, so "neither" can't be selected.
                Section {
                    Picker("Media", selection: $draft.media) {
                        ForEach(MediaSelection.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("setup.media")
                } header: {
                    Text("Media")
                } footer: {
                    Text("Sets what you review — not what’s already in the album. Switching keeps every pick and day mark.")
                }

                Section {
                    // Inert under the videos-only lens: a screenshot is a still, so it is already
                    // dropped by the media filter whatever this says (#273, design 61N-0).
                    Toggle("Exclude screenshots", isOn: $draft.excludeScreenshots)
                        .disabled(draft.media == .videosOnly)
                    NavigationLink {
                        AlbumPickerView(selection: $draft.excludedAlbumIDs, allowsMultiple: true)
                    } label: {
                        LabeledContent("Excluded albums", value: excludedValue)
                    }
                } header: {
                    Text("Exclude from source")
                } footer: {
                    if draft.media == .videosOnly {
                        Text("Screenshots are stills, so that switch has no effect while you’re reviewing videos only.")
                    } else {
                        Text("Screenshots and photos in these albums won’t appear while you pick.")
                    }
                }

                Section {
                    NavigationLink {
                        AlbumPickerView(selection: targetSelection, allowsMultiple: false)
                    } label: {
                        LabeledContent("Photos album", value: draft.targetAlbumID == nil
                            ? String(localized: "New Photos album",
                                     comment: "Destination: a new album created in Photos on finish")
                            : String(localized: "Existing Photos album",
                                     comment: "Destination: an existing album in the Photos app"))
                    }
                } header: {
                    Text("Destination")
                } footer: {
                    // The up-front expectation (#185): a newcomer expects the album they're naming to appear
                    // in Photos now — say plainly it's created when they finish, and that "album" here means
                    // a Photos-app album. Also carries the new-vs-existing choice this section controls.
                    Text("""
                        Your picks become an album in the Photos app when you finish — a new album, \
                        created then, or an existing Photos album you add to.
                        """)
                }
            }
            // Reliable number-pad dismissal (it has no return key): swipe the form to dismiss (#123).
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("New album")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create", action: create)
                        .disabled(!isValid)
                        .accessibilityIdentifier("createAlbumButton")
                }
            }
        }
    }

    private func create() {
        let project = store.create(from: draft)
        dismiss()
        coordinator.openProject(project.id)
    }

    /// A non-empty name and a non-inverted interval are required to create.
    private var isValid: Bool {
        !draft.title.trimmingCharacters(in: .whitespaces).isEmpty && draft.rangeEnd > draft.rangeStart
    }

    /// The excluded-albums count as a label — matches Settings' `excludedValue` form ("None" / "1 album" /
    /// "N albums") so Setup and Settings read identically (#190, item 3), not a bare "3" vs "3 albums".
    private var excludedValue: String {
        switch draft.excludedAlbumIDs.count {
        case 0: return String(localized: "None", comment: "Excluded albums: none selected")
        case 1: return String(localized: "1 album", comment: "Excluded albums count, singular")
        default: return String(localized: "\(draft.excludedAlbumIDs.count) albums",
                               comment: "Excluded albums count, 2 or more")
        }
    }

    /// "From" writes through here so moving the start past the end never leaves an inverted or greyed-out
    /// range: set the new start, then let `nonInvertedEnd` collapse "To" to a single day at that start if
    /// the start has reached/passed it (the user then extends "To"). No hard upper bound on "From" (#259).
    private var rangeStartBinding: Binding<Date> {
        Binding(
            get: { draft.rangeStart },
            set: {
                draft.rangeStart = $0
                draft.rangeEnd = NewAlbumDraft.nonInvertedEnd(start: $0, end: draft.rangeEnd, calendar: calendar)
            })
    }

    /// The "To" picker shows an **inclusive** end day, while the draft stores `rangeEnd`
    /// end-exclusive (the fetch contract) — so the picker reads/writes one day off, using the
    /// view's injected `calendar` (matching the calendar the draft was built with).
    private var inclusiveEnd: Binding<Date> {
        Binding(
            get: { NewAlbumDraft.inclusiveEndDay(forExclusiveEnd: draft.rangeEnd, calendar: calendar) },
            set: { draft.rangeEnd = NewAlbumDraft.exclusiveEnd(forInclusiveDay: $0, calendar: calendar) })
    }

    /// Bridges the single export-target (`String?`) to the picker's `Set<String>` selection.
    private var targetSelection: Binding<Set<String>> {
        Binding(
            get: { draft.targetAlbumID.map { [$0] } ?? [] },
            set: { draft.targetAlbumID = $0.first })
    }
}
