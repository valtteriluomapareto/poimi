//
//  AlbumPickerView.swift
//  PoimiApp — pick album(s) to exclude or a target album (issue #33; architecture §8).
//
//  Enumerates the user's albums through the `\.photoLibrary` seam and lets the setup form select
//  them. One reusable view: `allowsMultiple` = true for the exclude-from-source picker, false for
//  the single export-target picker (tapping replaces the selection).
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
                            if selection.contains(album.id) {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                                    .fontWeight(.semibold)
                                    .accessibilityLabel("Selected")
                            }
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
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
