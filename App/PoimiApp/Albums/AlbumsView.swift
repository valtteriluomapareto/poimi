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

    var body: some View {
        Group {
            if store.projects.isEmpty {
                ContentUnavailableView {
                    Label("No albums yet", systemImage: "photo.stack")
                } description: {
                    Text("Create an album to hand-pick a year of photos into.")
                } actions: {
                    Button("New album", systemImage: "plus", action: newAlbum)
                        .buttonStyle(.borderedProminent)
                }
            } else {
                List {
                    ForEach(store.projects) { project in
                        Button { open(project) } label: {
                            AlbumRow(project: project)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Duplicate", systemImage: "plus.square.on.square") {
                                store.duplicate(project)
                            }
                            Button("Reset picks", systemImage: "arrow.counterclockwise") {
                                store.reset(project)
                            }
                            Button("Delete album", systemImage: "trash", role: .destructive) {
                                store.delete(project)
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                store.delete(project)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Albums")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("New album", systemImage: "plus", action: newAlbum)
            }
        }
    }

    /// Open an album: bump it to the top of the library (most-recently-opened, §12) and navigate
    /// to its overview.
    private func open(_ project: CurationProject) {
        store.open(project)
        coordinator.openProject(project.id)
    }

    private func newAlbum() {
        // #33 replaces this with the range/target setup flow. For now, create a default album
        // (the prior calendar year) and open it, so the library is usable end-to-end.
        let calendar = Calendar.current
        let now = Date()
        let start = calendar.date(byAdding: .year, value: -1, to: now) ?? now
        let project = store.create(title: "New Album", rangeStart: start, rangeEnd: now, targetCount: 100)
        coordinator.openProject(project.id)
    }
}

/// One album row: a cover placeholder, the title, and the derived status + progress.
struct AlbumRow: View {
    let project: CurationProject

    private var summary: AlbumSummary { AlbumSummary(project: project) }

    var body: some View {
        HStack(spacing: 12) {
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
                    Image(systemName: statusSymbol)
                        .foregroundStyle(statusTint)
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
    private var statusSymbol: String {
        switch project.status {
        case .empty: "circle.dashed"
        case .inProgress: "circle.bottomhalf.filled"
        case .done: "checkmark.circle.fill"
        }
    }

    private var statusTint: Color {
        switch project.status {
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
        case .empty: statusText = "Not started"
        case .inProgress: statusText = "In progress"
        case .done: statusText = "Done"
        }
        progressText = "\(picked) / \(target)"
    }

    init(project: CurationProject) {
        self.init(status: project.status, picked: project.persistedPickedCount, target: project.targetCount)
    }
}
