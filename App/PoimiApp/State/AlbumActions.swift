//
//  AlbumActions.swift
//  PoimiApp — the album-library flows, sequenced once (#297, control plane slice B;
//  docs/plans/control-plane.md §4 B).
//
//  Open / create / delete / reset / edit used to be sequenced in the views, and delete + reset had two
//  different deactivate → mutate → reactivate orderings (`AlbumsView` vs `AlbumSettingsView`). This
//  façade carries ONE ordering for each, and every caller — the album list, the album settings, the new
//  album sheet, and (slice C) the control plane — goes through it. It holds no state of its own; each
//  step is a call into the stores, the album session or the coordinator.
//
//  The orderings, and why:
//  - **delete / reset deactivate ONLY the hydrated album** (`deactivateIfActive`), and reset re-activates
//    only the stores that held it. A reset or delete of an album that isn't open must neither flush/clear
//    nor steal the live stores of the album that is — and the album being mutated must not keep a live
//    debounce that later writes into a deleted or just-zeroed model (#59).
//  - **delete pops to the library root iff the deleted album is the one on screen**, and closes the album
//    session if it holds that album, before the model is removed — so no route and no session is left
//    pointing at a deleted album.
//  - **delete / reset are refused while that album's export runs**: the run stamps its result into the
//    album when it lands, which must not hit a deleted or just-zeroed model. (Reachable only on iPad, from
//    the sidebar while the export screen shows; the album list disables the two actions meanwhile.)
//  - **reset leaves the export screen's state alone**: a completion screen on show keeps showing (the
//    session starts the next visit's export fresh anyway, when the export screen leaves the path).
//

import Foundation
import Observation

@MainActor
@Observable
final class AlbumActions {
    @ObservationIgnored private let projects: ProjectStore
    @ObservationIgnored private let selection: SelectionStore
    @ObservationIgnored private let done: DoneStore
    @ObservationIgnored private let session: AlbumSession
    @ObservationIgnored private let coordinator: AppCoordinator

    init(projects: ProjectStore, selection: SelectionStore, done: DoneStore,
         session: AlbumSession, coordinator: AppCoordinator) {
        self.projects = projects
        self.selection = selection
        self.done = done
        self.session = session
        self.coordinator = coordinator
    }

    /// Open an album from the library: bump it to the top (most recently opened) and show its overview.
    func open(_ project: CurationProject) {
        projects.open(project)
        coordinator.openProject(project.id)
    }

    /// Create an album from a setup draft and open it — or `nil` (nothing created) for an invalid draft.
    @discardableResult
    func create(validated draft: NewAlbumDraft) -> CurationProject? {
        guard draft.isValid else { return nil }
        let project = projects.create(from: draft)
        coordinator.openProject(project.id)
        return project
    }

    /// Delete an album (never its Photos album or the user's originals, D31). The live stores let go of
    /// it first (#59); if it's the album on screen, navigation returns to the library root, and the album
    /// session lets go of it, before the model goes. Refused (`false`) while its export runs.
    @discardableResult
    func delete(_ project: CurationProject) -> Bool {
        guard !session.isExporting(project) else { return false }
        selection.deactivateIfActive(project)
        done.deactivateIfActive(project)
        if coordinator.activeAlbumID == project.id { coordinator.popToRoot() }
        if session.projectID == project.id { session.close() }
        projects.delete(project)   // also drops the album's cached timeline (#130)
        return true
    }

    /// Clear an album's progress (picks, day marks, export history), keeping its settings. The stores
    /// holding it flush + let go first — or their next debounce would write the old state straight back
    /// over the reset — and re-hydrate it afterwards, so the screen behind shows the reset at once.
    /// Refused (`false`) while its export runs.
    @discardableResult
    func reset(_ project: CurationProject) -> Bool {
        guard !session.isExporting(project) else { return false }
        let selectionHeld = selection.activeProjectID == project.persistentModelID
        let doneHeld = done.activeProjectID == project.persistentModelID
        selection.deactivateIfActive(project)
        done.deactivateIfActive(project)
        projects.reset(project)
        if selectionHeld { selection.activate(project) }
        if doneHeld { done.activate(project) }
        return true
    }

    /// Clear only the day marks, keeping the picks (#285). The ordering lives in `DoneStore`.
    func markAllUnreviewed(_ project: CurationProject) {
        done.markAllUnreviewed(project, in: projects)
    }

    /// Commit the settings screen's in-place edits (its controls bind straight to the model): a blank
    /// name falls back to the name it had on open (or a placeholder), the edit is saved durably, and the
    /// live tally picks up a changed target.
    func applyEdits(to project: CurationProject, titleOnOpen: String) {
        if project.title.trimmingCharacters(in: .whitespaces).isEmpty {
            project.title = titleOnOpen.trimmingCharacters(in: .whitespaces).isEmpty
                ? String(localized: "Untitled album",
                         comment: "Fallback album name when the user clears the name field")
                : titleOnOpen
        }
        projects.saveEdits(to: project)
        selection.retarget(project)
    }
}
