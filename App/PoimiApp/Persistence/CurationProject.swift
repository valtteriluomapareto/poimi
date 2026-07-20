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

    /// Overlay trip/visit clusters in the review timeline (#130). Per-album so location relevance can
    /// differ album to album; the Settings "Trips & places" toggle flips it. Additive attribute with a
    /// default → SwiftData AUTOMATIC lightweight migration (no stage, a shared model class — the
    /// AppSchema policy note). `false` → the byte-identical date-only timeline (the v1 screen).
    var locationEnabled: Bool = true

    /// Include video assets in the candidate set (#125). **Opt-in** — defaults `false`, so an album is
    /// images-only unless the user turns videos on (product truth: the human curates; videos add noise
    /// for most). Additive attribute with a default → SwiftData AUTOMATIC lightweight migration (no stage,
    /// a shared model class — the AppSchema policy note; same pattern as `locationEnabled`). Toggling it
    /// re-runs the scan (it feeds `Filtering.included(includeVideos:)`), so the candidate set changes.
    var includeVideos: Bool = false

    /// The exported Photos album's id — `nil` until first export creates-or-finds it (D19).
    var targetAlbumID: String?

    /// Versioned `Codable` `Set<String>` of picked asset ids, debounced (D15) — never per-tap.
    var selectionSnapshot: Data

    /// Sorted, unique `DayKey` strings (yyyy-MM-dd), treated as a set (D32(d), §13).
    var doneDays: [String]
    /// Snapshot of the candidate ids present at the last review load, grouped by day
    /// (`DayKey` string → ids), encoded JSON. The baseline for the "done but changed" reconcile
    /// (D32(d)/D34): on the next load a done day that *gained* an id re-opens, so a newly-added
    /// photo is never silently hidden by the collapse. `nil` until the first load records it.
    /// `.externalStorage` so this ~100s-of-KB blob faults in lazily and never loads with a plain
    /// project fetch (the albums list, status checks) that has no use for it.
    @Attribute(.externalStorage) var reviewedIDsByDay: Data?
    /// Cache of the derived resume day (§13).
    var resumeDayKey: String?
    /// Scroll anchor only — not the done-state authority (§13).
    var lastViewedAssetID: String?
    /// Set at the FIRST export (finalize) → status `.exported`. A later re-export leaves it unchanged — it
    /// records *when finalized*, not the last export time (that's `lastExportedAt`). Kept named
    /// `markedDoneAt` deliberately: renaming a stored property would be the first non-additive schema
    /// change (a staged migration) — only the derived status was renamed `.done` → `.exported` (#191).
    var markedDoneAt: Date?

    /// The picked-asset id set captured at the LAST export — the additions-only drift baseline (#191).
    /// A versioned `SelectionSnapshot` blob (same shape as `selectionSnapshot`) of the user's PICKS at
    /// export time (not the live-resolved subset export writes, so an unresolvable pick never shows
    /// permanent drift). `nil` until the first export; stamped on EVERY export (unlike `markedDoneAt`,
    /// first-only) so drift clears after a re-export. Additive optional → SwiftData AUTOMATIC lightweight
    /// migration (the `locationEnabled` pattern).
    var exportedSelectionSnapshot: Data?

    /// When the album was LAST exported — display-only ("last exported …"), distinct from `markedDoneAt`
    /// (first finalized). Additive optional → lightweight migration. Stamped every export, cleared on reset.
    var lastExportedAt: Date?

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
        locationEnabled: Bool = true,
        includeVideos: Bool = false,
        targetAlbumID: String? = nil,
        selectionSnapshot: Data,
        doneDays: [String] = [],
        reviewedIDsByDay: Data? = nil,
        resumeDayKey: String? = nil,
        lastViewedAssetID: String? = nil,
        markedDoneAt: Date? = nil,
        exportedSelectionSnapshot: Data? = nil,
        lastExportedAt: Date? = nil,
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
        self.locationEnabled = locationEnabled
        self.includeVideos = includeVideos
        self.targetAlbumID = targetAlbumID
        self.selectionSnapshot = selectionSnapshot
        self.doneDays = doneDays
        self.reviewedIDsByDay = reviewedIDsByDay
        self.resumeDayKey = resumeDayKey
        self.lastViewedAssetID = lastViewedAssetID
        self.markedDoneAt = markedDoneAt
        self.exportedSelectionSnapshot = exportedSelectionSnapshot
        self.lastExportedAt = lastExportedAt
        self.createdAt = createdAt
        self.lastOpenedAt = lastOpenedAt
    }
}

/// The project's lifecycle status, derived from persisted state (never stored — single source
/// of truth). `ProjectStore` and the album-library UI render from this.
enum ProjectStatus: Sendable, Equatable {
    case empty          // no picks, no days marked done
    case inProgress     // has picks and/or marked days, not yet exported
    case exported       // exported ≥1× and in sync with that export (#191; add-only → removals stay in sync)
    case editedSinceExport(toAdd: Int)   // exported, then N new picks added, not yet in Photos (#191)
}

extension CurationProject {
    /// The picked-asset id SET from the *persisted* snapshot. For the active project the live set lives
    /// in `SelectionStore`; this is the durable value the library list reads. Decodes the blob on each
    /// access — the album row calls it once per render (deriving status), so it's a single decode per row;
    /// fine at v1 scale.
    var persistedPicks: Set<String> {
        SelectionSnapshot.decode(selectionSnapshot).assetIDs
    }

    /// The picked count from the persisted snapshot (`persistedPicks.count`).
    var persistedPickedCount: Int { persistedPicks.count }

    /// The picks captured at the last export — the additions-only drift baseline (#191); `nil` if never
    /// exported, or a pre-#191 export that predates the baseline.
    var exportedPicks: Set<String>? {
        exportedSelectionSnapshot.map { SelectionSnapshot.decode($0).assetIDs }
    }

    /// Derived lifecycle status (§12) from the current picks + the export baseline. `markedDoneAt` is the
    /// "exported at least once" truth (kept for its stored name); the additions-only drift (#191) then
    /// splits exported into in-sync vs edited-since-export. A pre-#191 exported album (no baseline
    /// snapshot) reads as plain `.exported` — no baseline ⇒ don't cry drift (mirrors the DoneStore
    /// reconcile's "no baseline reopens nothing").
    func status(currentPicks: Set<String>) -> ProjectStatus {
        if markedDoneAt != nil {
            guard let exported = exportedPicks else { return .exported }
            let toAdd = ExportSync.pendingAdditions(picks: currentPicks, exported: exported)
            return toAdd > 0 ? .editedSinceExport(toAdd: toAdd) : .exported
        }
        if !currentPicks.isEmpty || !doneDays.isEmpty { return .inProgress }
        return .empty
    }

    /// Derived lifecycle status (§12). Decodes the snapshot once via `persistedPicks`.
    var status: ProjectStatus { status(currentPicks: persistedPicks) }
}
