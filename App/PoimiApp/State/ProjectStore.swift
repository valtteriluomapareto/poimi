//
//  ProjectStore.swift
//  PoimiApp — the album-library store (issue #29; architecture §12, D31).
//
//  `@MainActor @Observable` CRUD over `CurationProject`s, backed by a SwiftData `ModelContext`.
//  The album-library UI binds to `projects`; the rest of the app opens / duplicates / resets /
//  deletes through here. Delete removes the project record ONLY — it never touches the exported
//  Photos album (D31): the user's library is sacrosanct.
//

import Foundation
import SwiftData
import Curation

@MainActor
@Observable
final class ProjectStore {
    /// Held so the `ModelContext` below stays valid: a context does not retain its container, so
    /// if the store kept only the context the container could deallocate and invalidate it.
    private let container: ModelContainer
    private let context: ModelContext
    /// Injected clock — `Date.init` in the app, a fixed value in tests, so created/opened
    /// ordering is deterministic.
    private let now: () -> Date
    /// The per-album timeline cache (#130), so `delete` drops the album's cached file — the single
    /// choke point every delete path (albums-list swipe + album-settings) already funnels through, so
    /// the cleanup can't be forgotten at a call site. `nil` in tests (no file is written there anyway).
    private let timelineCache: TimelineCache?

    /// The library, most-recently-opened first (the album-list order, §12).
    private(set) var projects: [CurationProject] = []

    init(container: ModelContainer, timelineCache: TimelineCache? = nil, now: @escaping () -> Date = Date.init) {
        self.container = container
        self.context = container.mainContext
        self.timelineCache = timelineCache
        self.now = now
        refresh()
    }

    /// Re-read the library from the store.
    func refresh() {
        let descriptor = FetchDescriptor<CurationProject>(
            sortBy: [SortDescriptor(\.lastOpenedAt, order: .reverse)])
        do {
            projects = try context.fetch(descriptor)
        } catch {
            Log.persistence.error("ProjectStore.refresh failed: \(String(describing: error), privacy: .public)")
            projects = []
        }
    }

    /// Create a new album.
    @discardableResult
    func create(
        title: String,
        rangeStart: Date,
        rangeEnd: Date,
        targetCount: Int,
        excludeScreenshots: Bool = true,
        excludedAlbumIDs: [String] = [],
        includeVideos: Bool = false,
        targetAlbumID: String? = nil
    ) -> CurationProject {
        let timestamp = now()
        let project = CurationProject(
            title: title,
            rangeStart: rangeStart,
            rangeEnd: rangeEnd,
            targetCount: targetCount,
            excludeScreenshots: excludeScreenshots,
            excludedAlbumIDs: excludedAlbumIDs,
            includeVideos: includeVideos,
            targetAlbumID: targetAlbumID,
            selectionSnapshot: Self.emptySnapshot,
            createdAt: timestamp,
            lastOpenedAt: timestamp)
        context.insert(project)
        save("create")
        refresh()
        return project
    }

    /// Create a new album from a setup draft (#33). `excludedAlbumIDs` is sorted for a stable
    /// persisted order.
    @discardableResult
    func create(from draft: NewAlbumDraft) -> CurationProject {
        create(
            title: draft.title,
            rangeStart: draft.rangeStart,
            rangeEnd: draft.rangeEnd,
            targetCount: draft.targetCount,
            excludeScreenshots: draft.excludeScreenshots,
            excludedAlbumIDs: draft.excludedAlbumIDs.sorted(),
            includeVideos: draft.includeVideos,
            targetAlbumID: draft.targetAlbumID)
    }

    /// Mark a project as the most recently opened (bumps it to the top of the library).
    func open(_ project: CurationProject) {
        project.lastOpenedAt = now()
        save("open")
        refresh()
    }

    /// Duplicate an album's *configuration* — range, target, filters — but none of its progress:
    /// a fresh copy starts unexported (`targetAlbumID == nil`, D19), unselected, and not done.
    @discardableResult
    func duplicate(_ project: CurationProject) -> CurationProject {
        let timestamp = now()
        let copy = CurationProject(
            title: "\(project.title) copy",
            rangeStart: project.rangeStart,
            rangeEnd: project.rangeEnd,
            targetCount: project.targetCount,
            excludeScreenshots: project.excludeScreenshots,
            excludedAlbumIDs: project.excludedAlbumIDs,
            locationEnabled: project.locationEnabled,
            includeVideos: project.includeVideos,
            targetAlbumID: nil,
            selectionSnapshot: Self.emptySnapshot,
            createdAt: timestamp,
            lastOpenedAt: timestamp)
        context.insert(copy)
        save("duplicate")
        refresh()
        return copy
    }

    /// Clear all progress on a project — selection, done-days, resume pointer, finalized flag, and the
    /// export drift baseline (#191) — while keeping its configuration. (Does not delete or alter any
    /// Photos album.)
    func reset(_ project: CurationProject) {
        project.selectionSnapshot = Self.emptySnapshot
        project.doneDays = []
        project.resumeDayKey = nil
        project.lastViewedAssetID = nil
        project.markedDoneAt = nil
        project.exportedSelectionSnapshot = nil   // drop the drift baseline so status returns to .empty
        project.lastExportedAt = nil
        save("reset")
        refresh()
    }

    /// Persist edits made to `project` in-place from the settings screen — title, period, target,
    /// exclusions, destination. The fields are mutated on the model directly (it's `@Observable`, so
    /// bound controls update it live); this forces an immediate durable save (rather than leaning on
    /// the mainContext's deferred autosave) and `refresh()`es so the library list reflects a renamed
    /// or re-targeted album. `excludedAlbumIDs` is sorted for a stable persisted order (matching
    /// `create(from:)`).
    func saveEdits(to project: CurationProject) {
        project.excludedAlbumIDs.sort()
        save("edit")
        refresh()
    }

    /// Delete the project record. NEVER deletes the exported Photos album (D31, §12).
    /// Callers MUST `SelectionStore`/`DoneStore.deactivateIfActive(project)` first if it could be the
    /// active one, so no live store is left holding the deleted model (a late debounce would then
    /// `write(to:)` a dead project). Both delete sites do — `AlbumSettingsView.deleteAlbum` and
    /// `AlbumsView.deleteAlbum` (#59).
    func delete(_ project: CurationProject) {
        // Drop the album's cached timeline too (best-effort, off-main). A regenerable cache, so a
        // leftover file would be harmless (the OS purges Caches), but a deleted album leaves nothing.
        if let timelineCache {
            let deletedID = project.id
            Task { await timelineCache.remove(projectID: deletedID) }
        }
        context.delete(project)
        save("delete")
        refresh()
    }

    private func save(_ op: String) {
        do {
            try context.save()
        } catch {
            let reason = String(describing: error)
            Log.persistence.error("ProjectStore.\(op, privacy: .public) save failed: \(reason, privacy: .public)")
        }
    }

    /// An encoded empty selection — the starting snapshot for a new/reset project.
    private static let emptySnapshot: Data =
        (try? SelectionSnapshot.empty.encoded()) ?? Data()
}
