//
//  CurationProject.swift
//  PoimiApp — the persisted "album" (issue #29, D31; architecture §9/§12 + data model).
//
//  A `CurationProject` is the user-facing album: a date range, a target count, the chosen
//  filters, the exported Photos-album id (once it exists), the debounced selection snapshot
//  (D15), and the done-day set + resume pointer (§13). It persists *our* state only — never
//  photo bytes. The schema is versioned from v1 (`AppSchema`) and the selection blob carries
//  its own version envelope (`SelectionSnapshot`), so both can evolve without a silent wipe.
//

import Foundation
import SwiftData
import Curation

@Model
final class CurationProject {
    /// Stable external identity (distinct from SwiftData's `PersistentIdentifier`). Unique by
    /// construction (a fresh `UUID` per project) — no `.unique` DB constraint (it's unnecessary
    /// and trips a SwiftData SIGTRAP on insert).
    var id: UUID

    var title: String
    var rangeStart: Date
    var rangeEnd: Date
    var targetCount: Int

    // Exclusion settings (§8 / filtering tier).
    var excludeScreenshots: Bool
    var excludedAlbumIDs: [String]          // PHAssetCollection localIdentifiers

    /// The exported Photos album's id — `nil` until first export creates-or-finds it (D19).
    var targetAlbumID: String?

    /// Versioned `Codable` `Set<String>` of picked asset ids, debounced (D15) — never per-tap.
    var selectionSnapshot: Data

    /// Sorted, unique `DayKey` strings (yyyy-MM-dd), treated as a set (D32(d), §13).
    var doneDays: [String]
    /// Cache of the derived resume day (§13).
    var resumeDayKey: String?
    /// Scroll anchor only — not the done-state authority (§13).
    var lastViewedAssetID: String?
    /// Set when the user finalizes the album → status `.done`.
    var markedDoneAt: Date?

    var createdAt: Date
    var lastOpenedAt: Date

    init(
        id: UUID = UUID(),
        title: String,
        rangeStart: Date,
        rangeEnd: Date,
        targetCount: Int,
        excludeScreenshots: Bool = true,
        excludedAlbumIDs: [String] = [],
        targetAlbumID: String? = nil,
        selectionSnapshot: Data,
        doneDays: [String] = [],
        resumeDayKey: String? = nil,
        lastViewedAssetID: String? = nil,
        markedDoneAt: Date? = nil,
        createdAt: Date,
        lastOpenedAt: Date
    ) {
        self.id = id
        self.title = title
        self.rangeStart = rangeStart
        self.rangeEnd = rangeEnd
        self.targetCount = targetCount
        self.excludeScreenshots = excludeScreenshots
        self.excludedAlbumIDs = excludedAlbumIDs
        self.targetAlbumID = targetAlbumID
        self.selectionSnapshot = selectionSnapshot
        self.doneDays = doneDays
        self.resumeDayKey = resumeDayKey
        self.lastViewedAssetID = lastViewedAssetID
        self.markedDoneAt = markedDoneAt
        self.createdAt = createdAt
        self.lastOpenedAt = lastOpenedAt
    }
}

/// The project's lifecycle status, derived from persisted state (never stored — single source
/// of truth). `ProjectStore` and the album-library UI render from this.
enum ProjectStatus: Sendable, Equatable {
    case empty          // no picks, no days marked done
    case inProgress     // has picks and/or marked days, not finalized
    case done           // user finalized (markedDoneAt set)
}

extension CurationProject {
    /// The picked-asset count from the *persisted* snapshot. For the active project the live
    /// count lives in `SelectionStore`; this is the durable value the library list reads.
    /// Decodes the blob on each access — fine at v1 scale (a handful of projects, read once per
    /// library render). If the album-list cell ever decodes large snapshots every frame, cache
    /// this (or store a cheap `pickedCount: Int` column alongside the blob).
    var persistedPickedCount: Int {
        SelectionSnapshot.decode(selectionSnapshot).assetIDs.count
    }

    /// Derived lifecycle status from an **already-decoded** picked count — lets a caller that
    /// already has the count (the album row decodes the snapshot once per render) avoid decoding
    /// the blob a second time. `markedDoneAt` wins; otherwise any picks or done-days mean in-progress.
    func status(forPickedCount picked: Int) -> ProjectStatus {
        if markedDoneAt != nil { return .done }
        if picked > 0 || !doneDays.isEmpty { return .inProgress }
        return .empty
    }

    /// Derived lifecycle status (§12). Decodes the snapshot once via `persistedPickedCount`.
    var status: ProjectStatus { status(forPickedCount: persistedPickedCount) }
}
