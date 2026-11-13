//
//  HappyPathSmokeTests.swift
//  PoimiAppTests — the ONE end-to-end happy-path smoke (#43, D23): a tripwire that drives the whole
//  curation loop through the REAL production graph (stores, coordinator, album session) + FakePhotoLibrary —
//  authorize → create album → scan → select → mark done → export → completion — and asserts the album holds
//  the picks. Headless (no UI automation, per the chosen approach): deterministic + fast, so it's a
//  reliable tripwire rather than a flaky one. It uses a `localIdentifier`-CHURN seed (ids differ every
//  run) so nothing in the pipeline may depend on a specific id string — the smoke selects/exports by
//  whatever the scan returns. The happy-path CONTROLS also carry accessibility identifiers now, so a
//  future XCUITest can drive the same flow through the UI.
//

import Testing
import Foundation
import Curation
@testable import PoimiApp

@MainActor
@Suite("E2E happy-path smoke (#43)")
struct HappyPathSmokeTests {

    @Test("curation loop end to end: authorize → create → scan → select → mark done → export → done")
    func happyPath() async throws {
        // Real composition: the app's own `AppGraph` wiring (stores, coordinator, album session, façade)
        // over an authorized fake library + in-memory SwiftData; a long debounce so durability is driven
        // explicitly (never by a timer — no fixed-sleep flakiness). No view is mounted: since #297 the
        // album session runs the scan / reconcile / publish / export the screens used to run.
        let library = FakePhotoLibrary(assets: Self.churnSeed())
        let graph = AppGraph.make(
            container: try AppModelContainer.make(inMemory: true),
            library: library, thumbnails: FakeThumbnailProvider(), naming: FakePlaceNaming(),
            timelineCache: TimelineCache(directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("smoke-\(UUID().uuidString)", isDirectory: true)),
            debounce: .seconds(60), now: monotonicClock(), calendar: utcCalendar())
        let coordinator = graph.coordinator
        let session = graph.session
        let selection = graph.selectionStore
        let done = graph.doneStore

        // 1 — authorize: onboarding resolves to the albums library (D6).
        await coordinator.refreshAuthorization()
        #expect(coordinator.rootPhase == .albums)

        // 2 — create an album over the seeded year and open it (the setup sheet's Create).
        var draft = NewAlbumDraft.priorCalendarYear(now: TestDates.year2025End, calendar: utcCalendar())
        draft.title = "Best of 2025"
        draft.targetCount = 100
        let project = try #require(graph.actions.create(validated: draft))
        #expect(coordinator.activeAlbumID == project.id)

        // 3 — scan: the Overview opens the album session (no reconcile, #289); the real fetch → filter →
        // adaptive-group pipeline settles with candidates.
        let candidates = await session.openOverview(project)
        guard case .ready(let groups) = candidates.phase else {
            Issue.record("scan did not reach .ready: \(candidates.phase)")
            return
        }
        let scannedIDs = groups.flatMap(\.assetIDs)
        #expect(!scannedIDs.isEmpty)
        // The churn seed is a busy day + a quiet 3-day run → two adaptive clusters; assert that shape so
        // a grouping regression (or an empty scan) surfaces here and the mark-done step has a real
        // cluster to act on. Ids are unique (nonce + index), so the count comparisons below are clean.
        #expect(groups.count >= 2)

        // 3b — drill into the grid: it REUSES the Overview's scan, reconciles, and the review context the
        // viewer pages through is published.
        coordinator.openReview(project.id)
        let gridStore = await session.openReview(project)
        #expect(gridStore === candidates)
        #expect(session.reviewOrderedIDs == scannedIDs)

        // 4 — select every candidate. (In the grid, "Pick all" picks one cluster; here we select the
        // whole scan at the store — the same SelectionStore path the UI drives.)
        selection.select(scannedIDs)
        #expect(selection.progress.picked == scannedIDs.count)
        #expect(selection.hasPendingFlush)

        // 5 — mark the first cluster done, and prove it PERSISTED to the model (not just in-memory) —
        // otherwise this step is a no-op no downstream assertion would catch regressing.
        let firstGroup = try #require(groups.first)
        done.toggle(firstGroup)
        #expect(done.isDone(firstGroup))
        done.flushNow()
        #expect(firstGroup.days.allSatisfy { project.doneDays.contains($0.description) })

        // 5b — mark EVERY cluster done and prove the album now reads as fully reviewed (#187). This is the
        // state the forward-path affordances key on; without it the smoke bypassed the navigation, so a
        // regressed dead-end (advance() silently holding, no route out of review) would stay green.
        for group in groups where !done.isDone(group) { done.toggle(group) }
        #expect(isReviewComplete(clusters: groups, isDone: { done.isDone($0) }))

        // 5c — the forward path: from the review grid (where the fully-reviewed affordance lives), the ONE
        // coordinator transition the UI fires routes to export. Assert the whole path — review is no longer
        // a dead-end — before running the export below.
        coordinator.finishToExport()
        #expect(coordinator.path == [.albumOverview(project.id), .review(project.id, nil), .export(project.id)])

        // 6 — export: the export screen starts the session's export (create-or-find the Photos album and
        // copy the picks in, one-way, D31) — once.
        selection.flushNow()
        #expect(!selection.hasPendingFlush)
        #expect(session.export.phase == .idle)
        await session.startExport(project)
        guard case .done(let result, let wasReExport) = session.export.phase else {
            Issue.record("export did not reach .done: \(session.export.phase)")
            return
        }
        #expect(!wasReExport)                         // first export
        #expect(result.added == scannedIDs.count)     // every pick landed (churned ids resolve fine)
        #expect(result.title == "Best of 2025")       // #193: create path returns the requested name
        #expect(project.targetAlbumID != nil)         // finalized …
        #expect(project.markedDoneAt != nil)          // … and stamped done
        #expect(project.exportedSelectionSnapshot != nil)   // … with the #191 drift baseline
        #expect(project.status == .exported)          // exported + in sync
        // The completion stats read the published review context: every candidate is on a done day.
        let stats = CompletionStats(dayByID: session.reviewDayByID, doneDays: done.doneDays,
                                    selection: selection.selected)
        #expect(stats.markedDone == scannedIDs.count)

        // 7 — the album really holds exactly the picks (peek the fake's exported album).
        let inAlbum = await library.exportedAssetIDs(inAlbum: result.albumID)
        #expect(inAlbum == selection.selected)

        // 8 — additions-only drift (#191): de-selecting a pick does NOT count as drift (add-only export
        // never removes it from the Photos album), so the album stays "Exported" end-to-end. (The
        // add → editedSinceExport case is covered in ProjectStoreTests.postExportDrift.)
        if let anyPick = selection.selected.first {
            selection.toggle(anyPick)
            selection.flushNow()
            #expect(project.status == .exported)
        }

        // 9 — "Back to albums": the album closes, and the session lets go of its scan + export.
        coordinator.popToRoot()
        #expect(session.candidateStore == nil)
        #expect(session.export.phase == .idle)

        selection.deactivate()
        done.deactivate()
    }

    /// A `localIdentifier`-CHURN seed: ~13 photos across a busy day + a quiet 3-day run in 2025, with
    /// ids carrying a fresh per-run nonce so they differ every run. Nothing in the pipeline may hard-code
    /// an id — the smoke selects/exports by whatever the scan returns, so churned ids must flow through
    /// fetch → filter → group → select → export cleanly.
    private static func churnSeed() -> [AssetRef] {
        let nonce = UUID().uuidString.prefix(8)
        let day: TimeInterval = 86_400
        let busy = (0..<10).map { i in
            AssetRef(id: "\(nonce)/busy/\(i)",
                     captureDate: TestDates.year2025Start.addingTimeInterval(120 * day + Double(i)))
        }
        let quiet = (0..<3).map { i in
            AssetRef(id: "\(nonce)/quiet/\(i)",
                     captureDate: TestDates.year2025Start.addingTimeInterval(200 * day + Double(i) * day))
        }
        return busy + quiet
    }
}
