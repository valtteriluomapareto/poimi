//
//  AlbumPickerView.swift
//  PoimiApp — pick album(s) to exclude or a target album (issue #33; architecture §8).
//
//  Enumerates the user's albums through the `\.photoLibrary` seam and lets the setup form select
//  them. One reusable view: `allowsMultiple` = true for the exclude-from-source picker, false for
//  the single export-target picker (tapping replaces the selection).
//
//  Deferred (v1.1): album cover thumbnails (needs image loading) and "suggested-to-skip"
//  highlighting/sorting of common excludes (WhatsApp, Downloads — design-inventory item 5).
//

import SwiftUI
import Curation

struct AlbumPickerView: View {
    @Binding var selection: Set<String>
    let allowsMultiple: Bool

    @Environment(\.photoLibrary) private var library
    @State private var albums: [AlbumRef] = []
    @State private var loaded = false

    var body: some View {
        List {
            if loaded && albums.isEmpty {
                ContentUnavailableView("No albums", systemImage: "rectangle.stack",
                                       description: Text("You have no albums to choose from."))
            } else {
                ForEach(albums) { album in
                    let isSelected = selection.contains(album.id)
                    Button { toggle(album.id) } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(album.title)
                                if let count = album.count {
                                    Text("^[\(count) photo](inflect: true)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            // A quiet `circle` on every unselected row makes selection
                            // discoverable; the filled check carries the chosen state.
                            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                                .accessibilityHidden(true)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    // One VoiceOver element with the selected *state* as a trait (not a detached
                    // "Selected" label), so selected vs unselected is announced.
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
        }
        .overlay { if !loaded { ProgressView() } }
        .navigationTitle(allowsMultiple ? "Exclude albums" : "Save to album")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            albums = (try? await library.albums()) ?? []
            loaded = true
        }
    }

    private func toggle(_ id: String) {
        if allowsMultiple {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        } else {
            // Single-select: tapping the chosen one clears it, otherwise replaces the selection.
            selection = selection.contains(id) ? [] : [id]
        }
    }
}
