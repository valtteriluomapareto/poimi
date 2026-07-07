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

public extension Sequence where Element == AlbumRef {
    /// Albums ordered for display: by title, **localized + case-insensitive + natural-numeric**
    /// (`localizedStandardCompare`, so "Album 2" precedes "Album 10" and case doesn't split the list),
    /// tie-broken by `id` so duplicate titles keep a **stable** order across reloads (#124). The photo
    /// library returns albums in an arbitrary order; the picker sorts through this so both its modes
    /// (exclude + export target) agree.
    ///
    /// This is a **display** sort: the title comparison follows the user's current locale by design, so the
    /// exact order is locale-sensitive — not a canonical/invariant ordering. The `id` tie-break is a
    /// deterministic ordinal `String` compare (ids are opaque `localIdentifier`s, never user-facing — do
    /// NOT "fix" it to a localized compare or ties become locale-unstable). Unit-testable with an ASCII
    /// fixture, whose order is locale-invariant.
    func sortedByTitle() -> [AlbumRef] {
        sorted { lhs, rhs in
            switch lhs.title.localizedStandardCompare(rhs.title) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: return lhs.id < rhs.id
            }
        }
    }
}
