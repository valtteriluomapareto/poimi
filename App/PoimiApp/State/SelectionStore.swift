//
//  SelectionStore.swift
//  PoimiApp — the in-memory selection + debounced durability (issue #29, D15; architecture §4/§12).
//
//  Selection is an in-memory `Set<String>` — the **source of truth, mutated instantly on every
//  tap**, never a per-tap SwiftData write (the riskiest persistence trap, D15). Durability is a
//  **debounced** snapshot to the active project's `selectionSnapshot`, flushed on
//  scenePhase→background and **before any project switch**.
//
//  v1 invariant: **exactly one project hydrated.** `activate` flushes the outgoing project to
//  its own snapshot first, then loads the incoming one. The debounce is keyed by the project's
//  `PersistentIdentifier` and cancelled/validated on switch, so a stale timer can never write
//  one project's picks onto another (the multi-project trap, §12).
//

import Foundation
import SwiftData
import Curation

@MainActor
@Observable
final class SelectionStore {
    /// Held so `context` stays valid — a `ModelContext` does not retain its container.
    private let container: ModelContainer
    private let context: ModelContext
    private let debounce: Duration

    /// The live selection for the active project — mutated on every tap.
    private(set) var selected: Set<String> = []
    /// The active project's target count, for the running total.
    private(set) var target: Int = 0
    /// The active project's persistent id (the debounce key), or `nil` when none is hydrated.
    private(set) var activeProjectID: PersistentIdentifier?

    private var activeProject: CurationProject?
    private var flushTask: Task<Void, Never>?

    /// Running total against the target (D15 / `Curation.TargetProgress`).
    var progress: TargetProgress { TargetProgress(picked: selected.count, target: target) }
    var isActive: Bool { activeProject != nil }

    /// `debounce` is injectable so tests can choose a long window (to prove no per-tap write) or
    /// drive the flush explicitly. The app uses the default.
    init(container: ModelContainer, debounce: Duration = .seconds(2)) {
        self.container = container
        self.context = container.mainContext
        self.debounce = debounce
    }

    /// Make `project` the single hydrated project. Flushes the outgoing project to its OWN
    /// snapshot first (picks never leak across projects), then loads this one's snapshot.
    func activate(_ project: CurationProject) {
        if activeProjectID == project.persistentModelID { return }
        flushNow()
        activeProject = project
        activeProjectID = project.persistentModelID
        target = project.targetCount
        selected = SelectionSnapshot.decode(project.selectionSnapshot).assetIDs
        let pickCount = selected.count, targetCount = target   // hoist out of the log autoclosure
        Log.selection.notice("activated project: \(pickCount) picks, target \(targetCount)")
    }

    /// Flush and clear the active project (e.g. returning to the library with nothing open).
    func deactivate() {
        flushNow()
        activeProject = nil
        activeProjectID = nil
        selected = []
        target = 0
    }

    func contains(_ id: String) -> Bool { selected.contains(id) }

    /// Toggle an asset's membership; returns whether it is now selected. Schedules a debounced
    /// flush — no synchronous write.
    @discardableResult
    func toggle(_ id: String) -> Bool {
        guard activeProject != nil else { return false }
        let nowSelected: Bool
        if selected.contains(id) {
            selected.remove(id)
            nowSelected = false
        } else {
            selected.insert(id)
            nowSelected = true
        }
        scheduleFlush()
        return nowSelected
    }

    /// Persist the current selection synchronously and cancel any pending debounce. Call on
    /// scenePhase→background and before switching projects (§12).
    func flushNow() {
        flushTask?.cancel()
        flushTask = nil
        write(to: activeProject)
    }

    private func scheduleFlush() {
        flushTask?.cancel()
        let project = activeProject
        let window = debounce
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: window)
            guard !Task.isCancelled else { return }
            self?.write(to: project)
        }
    }

    private func write(to project: CurationProject?) {
        guard let project else { return }
        // Only the active project is ever written — a stale debounce captured from a previous
        // project is a no-op (the multi-project trap, §12).
        guard project.persistentModelID == activeProjectID else { return }
        do {
            project.selectionSnapshot = try SelectionSnapshot(assetIDs: selected).encoded()
            try context.save()
        } catch {
            Log.selection.error("flush failed: \(String(describing: error), privacy: .public)")
        }
    }
}
