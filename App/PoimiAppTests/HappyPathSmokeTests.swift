//
//  HappyPathSmokeTests.swift
//  PoimiAppTests — the ONE end-to-end happy-path smoke (#43, D23): a tripwire that drives the whole
//  curation loop through the REAL production stores + coordinator + FakePhotoLibrary — authorize →
//  create album → scan → select → mark done → export → completion — and asserts the album really holds
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
        // Real composition: an authorized fake library + in-memory SwiftData; a long debounce so
        // durability is driven explicitly (never by a timer — no fixed-sleep flakiness).
        let container = try AppModelContainer.make(inMemory: true)
        let library = FakePhotoLibrary(assets: Self.churnSeed())
        let coordinator = AppCoordinator(library: library)
        let projects = ProjectStore(container: container, now: monotonicClock())
        let selection = SelectionStore(container: container, debounce: .seconds(60))
        let done = DoneStore(container: container, debounce: .seconds(60))
        let export = ExportStore(library: library)

        // 1 — authorize: onboarding resolves to the albums library (D6).
        await coordinator.refreshAuthorization()
        #expect(coordinator.rootPhase == .albums)

        // 2 — create an album over the seeded year and open it.
        let project = projects.create(
            title: "Best of 2025",
            rangeStart: TestDates.year2025Start, rangeEnd: TestDates.year2025End, targetCount: 100)
        coordinator.openProject(project.id)
        #expect(coordinator.activeAlbumID == project.id)

        // 3 — scan: the real fetch → filter → adaptive-group pipeline settles with candidates.
        let candidates = CandidateStore(library: library, calendar: utcCalendar())
        await candidates.load(project)
        guard case .ready(let groups) = candidates.phase else {
            Issue.record("scan did not reach .ready: \(candidates.phase)")
            return
        }
        let scannedIDs = groups.flatMap(\.assetIDs)
        #expect(!scannedIDs.isEmpty)

        // 4 — select every candidate (the grid's "Select all", exercised at the store).
        selection.activate(project)
        selection.select(scannedIDs)
        #expect(selection.progress.picked == scannedIDs.count)

        // 5 — mark the first cluster done.
        done.activate(project)
        let firstGroup = try #require(groups.first)
        done.toggle(firstGroup)
        #expect(done.isDone(firstGroup))

        // 6 — export: create-or-find the Photos album and copy the picks in (one-way, D31).
        selection.flushNow()
        await export.run(project: project, picks: selection.selected)
        guard case .done(let result, let wasReExport) = export.phase else {
            Issue.record("export did not reach .done: \(export.phase)")
            return
        }
        #expect(!wasReExport)                         // first export
        #expect(result.added == scannedIDs.count)     // every pick landed (churned ids resolve fine)
        #expect(project.targetAlbumID != nil)         // finalized …
        #expect(project.markedDoneAt != nil)          // … and stamped done
        #expect(project.status == .done)

        // 7 — the album really holds exactly the picks (peek the fake's exported album).
        let inAlbum = await library.exportedAssetIDs(inAlbum: result.albumID)
        #expect(inAlbum == selection.selected)

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
