//
//  ControlRuntimeTests.swift
//  PoimiAppTests — the control runtime + state writer (#296): bootstrap ordering, refused launches,
//  route application + the viewer, and the observe → coalesce → revise → write loop, against an
//  in-memory sink. Waits are on the writer's real scheduled-flush task — never a fixed sleep.
//

import Testing
import Foundation
import Curation
@testable import PoimiApp

extension ControlHarness {
    /// Drain the writer: let `onChange` hops run, and await each flush they schedule, until a few
    /// main-actor turns pass with nothing scheduled.
    func settle() async {
        var quietTurns = 0
        while quietTurns < 5 {
            await Task.yield()
            if runtime.writer.isFlushScheduled {
                await runtime.writer.awaitScheduledFlush()
                quietTurns = 0
            } else {
                quietTurns += 1
            }
        }
    }

    func state(_ path: String...) -> ControlJSON? {
        path.reduce(sink.lastState) { json, key in json?[key] }
    }
}

@MainActor
@Suite("Control plane: runtime + state writer (#296)")
struct ControlRuntimeTests {

    // MARK: - Bootstrap

    @Test("nothing is written before the bootstrap; the first write already shows the applied route")
    func firstWriteAfterBootstrap() async throws {
        let harness = ControlHarness(.oneAlbum, route: .settings(album: "album-1"))
        #expect(harness.sink.writes.isEmpty)   // seeded, but not bootstrapped
        await harness.runtime.bootstrap()
        #expect(harness.sink.writes.map(\.file) == [.detail, .state])
        #expect(harness.state("nav", "screen") == .string("settings"))
        #expect(harness.state("app", "launchError") == .null)
        #expect(harness.state("idle") == .bool(true))
        #expect(harness.state("rev") == .int(1))
        #expect(harness.state("run") == .string("r-test"))
    }

    @Test("a refused launch runs isolated, seeds nothing, and writes its launchError")
    func refusedLaunch() async {
        let harness = ControlHarness(.fresh, parsed: .invalid("-PoimiControl refuses -PoimiScreen"))
        await harness.runtime.bootstrap()
        #expect(harness.runtime.refusal == "-PoimiControl refuses -PoimiScreen")
        #expect(harness.state("app", "launchError") == .string("-PoimiControl refuses -PoimiScreen"))
        #expect(harness.state("albums") == .object(pairs: []))
    }

    // MARK: - Routes

    @Test("routes apply through the coordinator: overview, review + day, export, settings, appsettings")
    func routesApply() async throws {
        let day = DayKey.day(year: 2025, month: 7, day: 5)
        let cases: [(ControlRoute, (UUID) -> [Route])] = [
            (.overview(album: "album-1"), { [.albumOverview($0)] }),
            (.review(album: "album-1", day: day), { [.albumOverview($0), .review($0, day)] }),
            (.export(album: "album-1"), { [.albumOverview($0), .export($0)] }),
            (.settings(album: "album-1"), { [.albumOverview($0), .settings($0)] }),
            (.appSettings, { _ in [.appSettings] })
        ]
        for (route, expected) in cases {
            let harness = ControlHarness(.midReview, route: route)
            await harness.runtime.bootstrap()
            let id = try #require(harness.created.first?.id)
            #expect(harness.coordinator.path == expected(id), "\(route)")
            #expect(harness.runtime.launchError == nil, "\(route)")
        }
    }

    @Test("an export route is not idle until the export settles — and then reports it (#297)")
    func exportIdleObservable() async throws {
        let harness = ControlHarness(.exported, route: .export(album: "album-1"))
        await harness.runtime.bootstrap()
        #expect(harness.state("nav", "screen") == .string("export"))
        #expect(harness.state("active", "export", "phase") == .string("idle"))
        #expect(harness.state("idle") == .bool(false))   // the screen's export hasn't run yet
        // Play the export screen's part: its `.task` starts the session's export.
        let project = try #require(harness.created.first)
        await harness.graph.session.startExport(project)
        await harness.settle()
        #expect(harness.state("active", "export", "phase") == .string("done"))
        #expect(harness.state("active", "export", "wasReExport") == .bool(true))
        #expect(harness.state("pending", "export") == .bool(false))
        #expect(harness.state("idle") == .bool(true))
    }

    @Test("a route that can't apply says so", arguments: [
        (ControlFixture.fresh, ControlRoute.appSettings),
        (.denied, .overview(album: "album-1")),
        (.oneAlbum, .review(album: "album-9", day: nil))
    ])
    func routeCannotApply(_ fixture: ControlFixture, _ route: ControlRoute) async {
        let harness = ControlHarness(fixture, route: route)
        await harness.runtime.bootstrap()
        guard case .string(let error)? = harness.state("app", "launchError") else {
            Issue.record("expected a launchError for \(route) on \(fixture)")
            return
        }
        #expect(!error.isEmpty)
        #expect(harness.coordinator.path.isEmpty)
    }

    @Test("the viewer opens once the grid has scanned and published the photo")
    func viewerOpensAfterScan() async throws {
        let harness = ControlHarness(.midReview, route: .review(album: "album-1", day: nil), viewer: "a-0210")
        let bootstrap = harness.runtime.start()
        // Play the grid's part: its `.task` scans after the route lands, then publishes.
        while harness.coordinator.activeAlbumID == nil { await Task.yield() }
        try await harness.scanAsGrid()
        await bootstrap.value
        let assetID = try #require(harness.runtime.assetAliases.assetID(for: "a-0210"))
        #expect(harness.coordinator.presentedPhotoID == assetID)
        #expect(harness.state("nav", "sheet") == .string("viewer"))
        #expect(harness.state("nav", "viewerPhoto") == .string("a-0210"))
        #expect(harness.state("app", "launchError") == .null)
    }

    @Test("a viewer photo outside the fixture is a launchError")
    func viewerUnknownPhoto() async {
        let harness = ControlHarness(.midReview, route: .review(album: "album-1", day: nil), viewer: "a-9999")
        await harness.runtime.bootstrap()
        guard case .string(let error)? = harness.state("app", "launchError") else {
            Issue.record("expected a launchError")
            return
        }
        #expect(error.contains("a-9999"))
        #expect(harness.coordinator.presentedPhotoID == nil)
    }

    // MARK: - The write loop

    /// A bootstrapped, scanned `mid-review` with the writer drained — the baseline for write counting.
    private func scannedMidReview() async throws -> ControlHarness {
        let harness = ControlHarness(.midReview, route: .review(album: "album-1", day: nil))
        await harness.runtime.bootstrap()
        try await harness.scanAsGrid()
        await harness.settle()
        return harness
    }

    @Test("one toggle → one write pair, one rev")
    func oneToggleOneWrite() async throws {
        let harness = try await scannedMidReview()
        let writes = harness.sink.writes.count, rev = harness.runtime.writer.rev
        let unpicked = try #require(ControlFixture.yearDatedIDs.first { !harness.selection.contains($0) })
        harness.selection.toggle(unpicked)
        await harness.settle()
        #expect(harness.sink.writes.count == writes + 2)
        #expect(harness.runtime.writer.rev == rev + 1)
        #expect(harness.state("active", "selection", "count") == .int(35))
    }

    @Test("a burst of changes coalesces into one write pair")
    func burstCoalesces() async throws {
        let harness = try await scannedMidReview()
        let writes = harness.sink.writes.count, rev = harness.runtime.writer.rev
        let unpicked = ControlFixture.yearDatedIDs.filter { !harness.selection.contains($0) }.prefix(5)
        for id in unpicked { harness.selection.toggle(id) }
        await harness.settle()
        #expect(harness.sink.writes.count == writes + 2)
        #expect(harness.runtime.writer.rev == rev + 1)
        #expect(harness.state("active", "selection", "count") == .int(39))
    }

    @Test("every revision writes detail before state, both stamped with the same rev")
    func detailBeforeState() async throws {
        let harness = try await scannedMidReview()
        let writes = harness.sink.writes
        #expect(writes.count.isMultiple(of: 2))
        for pair in stride(from: 0, to: writes.count, by: 2) {
            #expect(writes[pair].file == .detail)
            #expect(writes[pair + 1].file == .state)
            #expect(writes[pair].json["rev"] == writes[pair + 1].json["rev"])
        }
    }

    @Test("a change only state-detail.json shows (swapping one pick) still bumps rev")
    func detailOnlyChangeBumpsRev() async throws {
        let harness = try await scannedMidReview()
        let rev = harness.runtime.writer.rev
        let picked = try #require(harness.selection.selected.min())
        let unpicked = try #require(ControlFixture.yearDatedIDs.first { !harness.selection.contains($0) })
        let countBefore = harness.state("active", "selection", "count")
        harness.selection.toggle(picked)
        harness.selection.toggle(unpicked)
        await harness.settle()
        #expect(harness.state("active", "selection", "count") == countBefore)   // state content unchanged
        #expect(harness.runtime.writer.rev == rev + 1)
        #expect(harness.sink.lastDetail?["rev"] == .int(rev + 1))
    }

    @Test("an album created after launch gets the next alias")
    func newAlbumGetsNextAlias() async throws {
        let harness = ControlHarness(.oneAlbum)
        await harness.runtime.bootstrap()
        harness.graph.projectStore.create(title: "New", rangeStart: ControlFixture.rangeStart,
                                          rangeEnd: ControlFixture.rangeEnd, targetCount: 10)
        await harness.settle()
        #expect(harness.state("albums", "album-2", "target") == .int(10))
    }
}
