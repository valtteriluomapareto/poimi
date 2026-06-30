//
//  DoneStore.swift
//  PoimiApp — in-memory mark-as-done state + debounced durability (#38 / #20; idea ③ collapse).
//
//  "Section done" is a derived view over the stable per-day truth (`Curation.Completion`): a
//  day-group is done iff every calendar day it spans is in `doneDays`, so the done-ness survives the
//  day-groups recomputing when the library changes (architecture §13). Like `SelectionStore`, the
//  live state is an in-memory `Set<DayKey>` mutated instantly; durability is a **debounced** write to
//  the active project's `doneDays` ([String] of `DayKey` descriptions), flushed before a project
//  switch. One project hydrated at a time, keyed by `PersistentIdentifier` so a stale debounce can't
//  write one project's done-days onto another (the multi-project trap, §12).
//

import Foundation
import SwiftData
import Curation

@MainActor
@Observable
final class DoneStore {
    /// Held so `context` stays valid — a `ModelContext` does not retain its container.
    private let container: ModelContainer
    private let context: ModelContext
    private let debounce: Duration

    /// The live done-days for the active project — mutated on every mark/unmark.
    private(set) var doneDays: Set<DayKey> = []
    /// The active project's persistent id (the debounce key), or `nil` when none is hydrated.
    private(set) var activeProjectID: PersistentIdentifier?

    private var activeProject: CurationProject?
    private var flushTask: Task<Void, Never>?

    var isActive: Bool { activeProject != nil }

    init(container: ModelContainer, debounce: Duration = .seconds(2)) {
        self.container = container
        self.context = container.mainContext
        self.debounce = debounce
    }

    /// Make `project` the single hydrated project — flush the outgoing one first, then decode this
    /// one's persisted `doneDays`.
    func activate(_ project: CurationProject) {
        if activeProjectID == project.persistentModelID { return }
        flushNow()
        activeProject = project
        activeProjectID = project.persistentModelID
        doneDays = Set(project.doneDays.compactMap(DayKey.init))
    }

    func deactivate() {
        flushNow()
        activeProject = nil
        activeProjectID = nil
        doneDays = []
    }

    /// Whether `group` renders done — every calendar day it spans is done (Completion §20).
    func isDone(_ group: DayGroup) -> Bool { Completion.isDone(group, doneDays: doneDays) }

    /// Toggle a day-group's done state (the section's ✓ circle). Schedules a debounced flush.
    func toggle(_ group: DayGroup) {
        guard activeProject != nil else { return }
        doneDays = isDone(group)
            ? Completion.markingUndone(group, in: doneDays)
            : Completion.markingDone(group, in: doneDays)
        scheduleFlush()
    }

    /// Reconcile the active project's done-days against a freshly-loaded candidate set (call once,
    /// after a load settles). A done day that **gained** an id since the last load re-opens, so a
    /// newly-added photo is never silently hidden inside a collapsed peek (D32(d)/D34 — the decided
    /// rider of mark-as-done). Always records the load as the new baseline. The FIRST load for a
    /// project has no baseline, so it reopens nothing — only records the snapshot. `currentIDsByDay`
    /// is built by the caller from `CandidateStore.dayByID` (invert id→day to day→ids).
    func reconcile(currentIDsByDay current: [DayKey: Set<String>]) {
        guard let project = activeProject, project.persistentModelID == activeProjectID else { return }
        if let data = project.reviewedIDsByDay, let previous = Self.decodeIDsByDay(data) {
            // Have a baseline → reopen days that grew. (An empty/absent baseline is a first load:
            // skip, or reopening would treat every id as new and re-open everything — see Completion.)
            doneDays = Completion.reopening(doneDays: doneDays,
                                            previousIDsByDay: previous,
                                            currentIDsByDay: current)
            project.doneDays = doneDays.map(\.description).sorted()
        }
        project.reviewedIDsByDay = Self.encodeIDsByDay(current)
        do {
            try context.save()
        } catch {
            Log.persistence.error("done reconcile save failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Persist synchronously + cancel any pending debounce (scenePhase→background, project switch).
    func flushNow() {
        flushTask?.cancel()
        flushTask = nil
        write(to: activeProject)
    }

    /// Await the in-flight debounced flush — lets tests assert persistence without a fixed sleep.
    func awaitPendingFlush() async { await flushTask?.value }

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
        // Only the active project is written — a stale debounce from a previous project is a no-op
        // (the multi-project trap, §12). The guard makes the live `doneDays` safe to encode here.
        guard let project, project.persistentModelID == activeProjectID else { return }
        project.doneDays = doneDays.map(\.description).sorted()
        do {
            try context.save()
        } catch {
            Log.persistence.error("done flush failed: \(String(describing: error), privacy: .public)")
        }
    }

    // The reconcile baseline persists as `[DayKey string: sorted ids]` JSON — the same string
    // round-trip `doneDays` uses (DayKey ⇄ its description), so `.undated` survives too.
    private static func encodeIDsByDay(_ map: [DayKey: Set<String>]) -> Data? {
        let dict = Dictionary(uniqueKeysWithValues: map.map { ($0.key.description, $0.value.sorted()) })
        return try? JSONEncoder().encode(dict)
    }

    private static func decodeIDsByDay(_ data: Data) -> [DayKey: Set<String>]? {
        guard let dict = try? JSONDecoder().decode([String: [String]].self, from: data) else { return nil }
        var out: [DayKey: Set<String>] = [:]
        for (key, ids) in dict {
            if let day = DayKey(key) { out[day] = Set(ids) }
        }
        return out
    }
}
