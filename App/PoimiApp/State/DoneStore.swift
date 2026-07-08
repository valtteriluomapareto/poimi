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

    /// Deactivate ONLY if `project` is the currently-hydrated one — so deleting/resetting a project (from
    /// any call site) never leaves this store holding a dangling/stale model (#59). A no-op otherwise.
    func deactivateIfActive(_ project: CurationProject) {
        if activeProjectID == project.persistentModelID { deactivate() }
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

    /// Whether a review cluster renders done — every day it spans is done. A trip is done iff ALL its
    /// constituent day-groups are (the done atom stays the day, D33 — a trip only groups them).
    func isDone(_ cluster: ReviewCluster) -> Bool {
        cluster.dayGroups.allSatisfy { Completion.isDone($0, doneDays: doneDays) }
    }

    /// Toggle a whole cluster's done state — "Mark trip done" marks EVERY constituent day done (undo
    /// unmarks them all); a date cluster is the single-group case. Schedules a debounced flush.
    func toggle(_ cluster: ReviewCluster) {
        guard activeProject != nil else { return }
        let markDone = !isDone(cluster)
        for group in cluster.dayGroups {
            doneDays = markDone ? Completion.markingDone(group, in: doneDays)
                                : Completion.markingUndone(group, in: doneDays)
        }
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
        let previous = project.reviewedIDsByDay.flatMap(Self.decodeIDsByDay)
        var dirty = false
        // Reopen only against a REAL baseline. An absent (first load) OR an empty-dict baseline must
        // reopen NOTHING: an empty `previous` makes every current id look "new" and would un-mark the
        // user's whole year (the exact catastrophe Completion.reopening's caller contract warns about).
        // A corrupt blob decodes to nil → also treated as no baseline (falls back to first-load).
        if let previous, !previous.isEmpty {
            let reconciled = Completion.reopening(doneDays: doneDays,
                                                  previousIDsByDay: previous,
                                                  currentIDsByDay: current)
            if reconciled != doneDays {
                doneDays = reconciled
                project.doneDays = encodedDoneDays
                dirty = true
            }
        }
        // Record this load as the new baseline — but skip the rewrite when the candidate set is
        // unchanged (a benign re-open of the same album) so we don't re-encode the same blob each time.
        if previous != current {
            project.reviewedIDsByDay = Self.encodeIDsByDay(current)
            dirty = true
        }
        // A once-per-load reconcile saves DIRECTLY (not via the debounce) so the reopen is durable at
        // once; a later debounced flush re-reads the live `doneDays`, so this direct save can't be lost.
        if dirty {
            do {
                try context.save()
            } catch {
                Log.persistence.error("done reconcile save failed: \(String(describing: error), privacy: .public)")
            }
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
        project.doneDays = encodedDoneDays
        do {
            try context.save()
        } catch {
            Log.persistence.error("done flush failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// The live done-days in the persisted `[String]` form — sorted `DayKey` descriptions. Shared by
    /// `write` and `reconcile` so the two persistence paths can't drift.
    private var encodedDoneDays: [String] { doneDays.map(\.description).sorted() }

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
