//
//  AlbumRef.swift
//  Curation — a value descriptor for a Photos album (issue #18).
//
//  Used by the exclude-album picker and the export-album selection step (architecture
//  §8). Carries the album's stable identifier + display info as plain `Sendable` data;
//  the live `PHAssetCollection` never crosses into the domain.
//

import Foundation

/// A value snapshot of a Photos album.
public struct AlbumRef: Sendable, Identifiable, Equatable, Hashable, Codable {
    /// `PHAssetCollection.localIdentifier` — the stable key we persist (a project's
    /// excluded-album ids and its target-album id are these).
    public let id: String

    /// Display title ("Screenshots", "WhatsApp", …).
    public let title: String

    /// Asset count, for the picker's secondary line. `nil` when not cheaply known.
    public let count: Int?

    public init(id: String, title: String, count: Int? = nil) {
        self.id = id
        self.title = title
        self.count = count
    }
}
