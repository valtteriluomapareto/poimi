//
//  ControlRuntime.swift
//  PoimiApp — one control launch: seed the fixture, apply the route, then keep the state files current
//  (#296, docs/plans/control-plane.md §4 slice A). DEBUG-only (D30).
//
//  Free of process-global effects (those are `ControlEnvironment`'s), so the integration tests build
//  one over an `AppGraph` + an in-memory sink and drive it directly.
//
#if DEBUG

import Foundation
import SwiftUI
import UIKit
import Curation

@MainActor
final class ControlRuntime {
    /// The debounce for picks and done-days under control: long enough that it never fires on its own
    /// during a run, so persistence happens only on an explicit flush (scene phase / project switch).
    static let debounce: Duration = .seconds(24 * 3600)

    let graph: AppGraph
    /// Why the launch was refused (malformed flags) — shown in place of the UI. `nil` when valid.
    let refusal: String?
    let fixture: ControlFixture
    let assetAliases: ControlAssetAliases
    let albumAliases = ControlAlbumAliases()
    private(set) lazy var writer = ControlStateWriter(run: run, delay: writeDelay, sink: sink) { [unowned self] in
        inputs
    }

    private let run: String
    private let writeDelay: Duration
    private let sink: any ControlStateSink
    private let launch: ControlLaunch?
    private(set) var launchError: String?
    /// The launch has finished: authorization read, route applied, viewer opened (or failed). Nothing
    /// is written before this, so a run's first `state.json` already shows the applied route.
    private(set) var bootstrapped = false

    /// Seeds the fixture (a refused launch seeds nothing) — no I/O, no global effects.
    init(parsed: ControlLaunch.Parsed, graph: AppGraph, sink: any ControlStateSink,
         run: String = "r-" + String(UInt32.random(in: 0...UInt32.max), radix: 16),
         writeDelay: Duration = .milliseconds(100)) {
        self.graph = graph
        self.run = run
        self.writeDelay = writeDelay
        self.sink = sink
        switch parsed {
        case .on(let launch):
            self.launch = launch
            refusal = nil
        case .invalid(let message):
            launch = nil
            refusal = message
        case .off:
            launch = nil
            refusal = "control runtime started without a control flag"
        }
        fixture = launch?.fixture ?? .fresh
        launchError = refusal
        assetAliases = ControlAssetAliases(assets: fixture.assets)
        if launch != nil {
            let seeded = fixture.seed(projects: graph.projectStore, selection: graph.selectionStore,
                                      done: graph.doneStore)
            for project in seeded { albumAliases.assign(project.id) }
        }
        if let refusal {
            Log.app.fault("control: launch refused — \(refusal, privacy: .public)")
        } else {
            let fixtureName = fixture.rawValue
            Log.app.notice("control: fixture \(fixtureName, privacy: .public), run \(run, privacy: .public)")
        }
    }

    /// Run the bootstrap in the background (the app's launch path).
    @discardableResult
    func start() -> Task<Void, Never> {
        Task { await bootstrap() }
    }

    /// Read authorization, apply the route and viewer, then write the first snapshot and start
    /// observing. A problem is recorded as `app.launchError` (the UI stays up, so you can still look).
    func bootstrap() async {
        await graph.coordinator.refreshAuthorization()
        if refusal == nil, let launch {
            do throws(ControlLaunchError) {
                let applier = ControlRouteApplier(graph: graph, fixture: fixture,
                                                  albums: albumAliases, assets: assetAliases)
                if let route = launch.route { try applier.apply(route) }
                if let viewer = launch.viewer { try await applier.openViewer(viewer) }
            } catch {
                launchError = error.message
                Log.app.error("control: \(error.message, privacy: .public)")
            }
        }
        bootstrapped = true
        writer.start()
    }

    var inputs: ControlSnapshotInputs {
        ControlSnapshotInputs(
            fixture: fixture, coordinator: graph.coordinator, projects: graph.projectStore,
            selection: graph.selectionStore, done: graph.doneStore,
            assetAliases: assetAliases, albumAliases: albumAliases,
            launchError: launchError, bootstrapped: bootstrapped,
            idiom: UIDevice.current.userInterfaceIdiom == .pad ? "pad" : "phone",
            timeZone: Self.timeZoneName(Calendar.current.timeZone))
    }

    /// Foundation names UTC "GMT"; report the zone the plan pins (`UTC`) when that's what it is.
    static func timeZoneName(_ zone: TimeZone) -> String {
        ["GMT", "UTC"].contains(zone.identifier) ? "UTC" : zone.identifier
    }
}

/// Applies a launch route the way the UI would, through the coordinator's own methods.
@MainActor
struct ControlRouteApplier {
    let graph: AppGraph
    let fixture: ControlFixture
    let albums: ControlAlbumAliases
    let assets: ControlAssetAliases

    /// Open the album (bump + overview, like the album list's tap), then push the destination. A route
    /// needs the albums phase: on `fresh`/`denied` it can't apply, and says so.
    func apply(_ route: ControlRoute) throws(ControlLaunchError) {
        let coordinator = graph.coordinator
        guard coordinator.rootPhase == .albums else {
            throw ControlLaunchError("route needs photo access, but fixture '\(fixture.rawValue)' starts at "
                + "\(coordinator.rootPhase == .onboarding ? "onboarding" : "recovery")")
        }
        guard let alias = route.album else {
            coordinator.openAppSettings()
            return
        }
        guard let id = albums.projectID(for: alias),
              let project = graph.projectStore.projects.first(where: { $0.id == id }) else {
            throw ControlLaunchError("route album '\(alias)' is not in fixture '\(fixture.rawValue)'")
        }
        graph.projectStore.open(project)
        coordinator.openProject(id)
        switch route {
        case .review(_, let day): coordinator.openReview(id, day: day)
        case .export: coordinator.openExport(id)
        case .settings: coordinator.openSettings(id)
        case .overview, .appSettings: break
        }
    }

    /// Open the photo viewer on `alias` once the review grid has published it (its `.task` runs the
    /// scan after the route lands). Bounded by a real deadline, polled — never a fixed sleep.
    func openViewer(_ alias: String, timeout: Duration = .seconds(30)) async throws(ControlLaunchError) {
        guard let assetID = assets.assetID(for: alias) else {
            throw ControlLaunchError("viewer photo '\(alias)' is not in fixture '\(fixture.rawValue)'")
        }
        let coordinator = graph.coordinator
        let deadline = ContinuousClock.now + timeout
        while !coordinator.reviewOrderedIDs.contains(assetID) {
            switch coordinator.candidateStore?.phase {
            case .empty?, .failed?:
                throw ControlLaunchError("viewer: the review has no photos to open '\(alias)' on")
            case .ready? where !coordinator.reviewOrderedIDs.isEmpty:
                throw ControlLaunchError("viewer photo '\(alias)' is not in the open review")
            default:
                break   // not scanned yet, scanning, or ready but not yet published by the grid
            }
            guard ContinuousClock.now < deadline else {
                throw ControlLaunchError("viewer: the review scan did not settle within \(timeout)")
            }
            try? await Task.sleep(for: .milliseconds(50))   // poll with a real deadline
        }
        coordinator.openPhoto(assetID)
    }
}

/// Shown instead of the UI when a control launch is refused (malformed flags). Dev-facing, so
/// `Text(verbatim:)` — nothing here belongs in the String Catalog.
struct ControlRefusedView: View {
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
            Text(verbatim: "Control launch refused")
                .font(.headline)
            Text(verbatim: message)
                .font(.footnote.monospaced())
                .multilineTextAlignment(.center)
        }
        .padding()
    }
}

#endif
