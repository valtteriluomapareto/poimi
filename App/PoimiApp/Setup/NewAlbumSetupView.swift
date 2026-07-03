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
                    // Mutually bounded so an inverted/zero range is unreachable (Create can't be
                    // silently disabled with no explanation): From ≤ the inclusive To, and vice-versa.
                    DatePicker("From", selection: $draft.rangeStart, in: ...inclusiveEndDate,
                               displayedComponents: .date)
                    DatePicker("To", selection: inclusiveEnd, in: draft.rangeStart...,
                               displayedComponents: .date)
                } header: {
                    Text("Period")
                } footer: {
                    Text("Photos captured in this date range are the candidates to pick from.")
                }

                Section("Target") {
                    Stepper("Target: ^[\(draft.targetCount) photo](inflect: true)",
                            value: $draft.targetCount, in: 1...10_000, step: 10)
                }

                Section("Exclude from source") {
                    Toggle("Exclude screenshots", isOn: $draft.excludeScreenshots)
                    NavigationLink {
                        AlbumPickerView(selection: $draft.excludedAlbumIDs, allowsMultiple: true)
                    } label: {
                        let excluded = draft.excludedAlbumIDs
                        LabeledContent("Exclude albums", value: excluded.isEmpty ? "None" : "\(excluded.count)")
                    }
                }

                Section {
                    NavigationLink {
                        AlbumPickerView(selection: targetSelection, allowsMultiple: false)
                    } label: {
                        LabeledContent("Save to", value: draft.targetAlbumID == nil ? "New album" : "Existing album")
                    }
                } header: {
                    Text("Destination")
                } footer: {
                    Text("Leave as a new album (created on export), or add picks to an existing album.")
                }
            }
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

    /// The inclusive end day as a value — the upper bound for the "From" picker (see above).
    private var inclusiveEndDate: Date {
        NewAlbumDraft.inclusiveEndDay(forExclusiveEnd: draft.rangeEnd, calendar: calendar)
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
