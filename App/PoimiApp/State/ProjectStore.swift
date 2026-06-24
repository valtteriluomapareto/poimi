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

    /// The library, most-recently-opened first (the album-list order, §12).
    private(set) var projects: [CurationProject] = []

    init(container: ModelContainer, now: @escaping () -> Date = Date.init) {
        self.container = container
        self.context = container.mainContext
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
        excludedAlbumIDs: [String] = []
    ) -> CurationProject {
        let timestamp = now()
        let project = CurationProject(
            title: title,
            rangeStart: rangeStart,
            rangeEnd: rangeEnd,
            targetCount: targetCount,
            excludeScreenshots: excludeScreenshots,
            excludedAlbumIDs: excludedAlbumIDs,
            selectionSnapshot: Self.emptySnapshot,
            createdAt: timestamp,
            lastOpenedAt: timestamp)
        context.insert(project)
        save("create")
        refresh()
        return project
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
            targetAlbumID: nil,
            selectionSnapshot: Self.emptySnapshot,
            createdAt: timestamp,
            lastOpenedAt: timestamp)
        context.insert(copy)
        save("duplicate")
        refresh()
        return copy
    }

    /// Clear all progress on a project — selection, done-days, resume pointer, finalized flag —
    /// while keeping its configuration. (Does not delete or alter any Photos album.)
    func reset(_ project: CurationProject) {
        project.selectionSnapshot = Self.emptySnapshot
        project.doneDays = []
        project.resumeDayKey = nil
        project.lastViewedAssetID = nil
        project.markedDoneAt = nil
        save("reset")
        refresh()
    }

    /// Delete the project record. NEVER deletes the exported Photos album (D31, §12).
    /// NOTE (#30): when the navigation coordinator can have a project *active* in `SelectionStore`,
    /// deleting or resetting the active project must `deactivate()` it first — otherwise the
    /// selection store holds a stale/dangling project. Harmless today (nothing activates yet).
    func delete(_ project: CurationProject) {
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
