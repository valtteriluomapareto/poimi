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
    /// The asset aliases — the fixture's library, plus any photos added mid-run (the host grows them).
    var assetAliases: ControlAssetAliases { host.assets }
    private let initialAssetAliases: ControlAssetAliases
    let albumAliases: ControlAlbumAliases
    /// The fake library's export gate (#300): `library.*` in the snapshot, the export levers. `nil` when
    /// the run's library has none (a test's own wrapper).
    let exportGate: FakeExportGate?
    /// The action bookkeeping behind `settledSeq` / `lastSeq` (#298).
    let progress = ControlProgress()
    /// The fake thumbnail loads in flight (`pending.thumbnails`), when the graph counts them.
    let thumbnailLoads: ThumbnailLoadCounter?
    private(set) lazy var writer = ControlStateWriter(run: run, delay: writeDelay, sink: sink) { [unowned self] in
        inputs
    }
    /// The one action handler (#298) — what the mailbox, and the in-process tests, talk to.
    private(set) lazy var host = ControlHost(
        graph: graph, run: run, fixture: fixture, assets: initialAssetAliases, albums: albumAliases,
        progress: progress, listAlwaysShown: listAlwaysShown, exportGate: exportGate,
        state: { [unowned self] in stateJSON() },
        rev: { [unowned self] in writer.rev },
        syncState: { [unowned self] in await syncState() })
    /// Whether the album list is always on screen (the iPad sidebar) — what library actions may assume.
    private let listAlwaysShown: Bool
    /// `Documents/control/` when this run serves the file mailbox; `nil` in-process.
    private let mailboxDirectory: URL?
    private var mailbox: ControlMailbox?

    /// This launch's id (`state.json`'s `run`; every request must name it).
    let run: String
    private let writeDelay: Duration
    private let sink: any ControlStateSink
    private let launch: ControlLaunch?
    private(set) var launchError: String?
    /// The launch has finished: authorization read, route applied, viewer opened (or failed). Nothing
    /// is written before this, so a run's first `state.json` already shows the applied route.
    private(set) var bootstrapped = false

    /// Seeds the fixture (a refused launch or a relaunch seeds nothing) — no global effects. With a
    /// `record` URL the album aliases are kept there for a relaunch, which restores them from it (#300);
    /// `addedAssets` are the photos an earlier run added to the library (a relaunch's alias table).
    init(parsed: ControlLaunch.Parsed, graph: AppGraph, sink: any ControlStateSink,
         run: String = "r-" + String(UInt32.random(in: 0...UInt32.max), radix: 16),
         writeDelay: Duration = .milliseconds(100),
         thumbnailLoads: ThumbnailLoadCounter? = nil, mailbox: URL? = nil, listAlwaysShown: Bool? = nil,
         exportGate: FakeExportGate? = nil, record: URL? = nil, addedAssets: [AssetRef] = []) {
        self.graph = graph
        self.exportGate = exportGate
        // The iPad's split view keeps the album list on screen; the tests can pick either layout.
        self.listAlwaysShown = listAlwaysShown ?? (UIDevice.current.userInterfaceIdiom == .pad)
        self.thumbnailLoads = thumbnailLoads
        mailboxDirectory = mailbox
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
        initialAssetAliases = ControlAssetAliases(assets: fixture.assets).appending(addedAssets)
        if let launch, launch.relaunch {
            // A relaunch continues the run on record: nothing is seeded, the aliases are its own.
            albumAliases = record.flatMap(ControlRunRecord.load(from:)).map(ControlAlbumAliases.init(restoring:))
                ?? ControlAlbumAliases()
        } else {
            albumAliases = ControlAlbumAliases()
            if launch != nil {
                let seeded = fixture.seed(projects: graph.projectStore, selection: graph.selectionStore,
                                          done: graph.doneStore)
                for project in seeded { albumAliases.assign(project.id) }
            }
        }
        if let record, refusal == nil {
            let aliases = albumAliases
            let fixture = fixture
            aliases.didAssign = { [unowned aliases] in aliases.record(fixture: fixture).save(to: record) }
            aliases.record(fixture: fixture).save(to: record)
        }
        if let refusal {
            Log.app.fault("control: launch refused — \(refusal, privacy: .public)")
        } else {
            let what = (launch?.relaunch == true ? "relaunch of " : "fixture ") + fixture.rawValue
            Log.app.notice("control: \(what, privacy: .public), run \(run, privacy: .public)")
        }
    }

    /// Run the bootstrap in the background (the app's launch path).
    @discardableResult
    func start() -> Task<Void, Never> {
        Task { await bootstrap() }
    }

    /// Whether this run has no UI (`-PoimiHeadless`).
    var isHeadless: Bool { launch?.headless ?? false }

    /// Start the graph (the launch authorization read), apply the route and viewer, then write the first
    /// snapshot, start observing and open the mailbox. The route's screen task (its scan / export) is
    /// started like any action's, so it runs headless too and `idle` waits for it. A problem is recorded
    /// as `app.launchError` (the UI stays up, so you can still look).
    func bootstrap() async {
        await graph.start()
        if refusal == nil, let launch {
            do throws(ControlLaunchError) {
                let applier = ControlRouteApplier(graph: graph, fixture: fixture,
                                                  albums: albumAliases, assets: assetAliases)
                if let route = launch.route {
                    try await applier.apply(route)
                    if let screenWork = host.screenTask() { _ = progress.begin(screenWork) }
                }
                if let viewer = launch.viewer { try await applier.openViewer(viewer) }
            } catch {
                launchError = error.message
                Log.app.error("control: \(error.message, privacy: .public)")
            }
        }
        bootstrapped = true
        writer.start()
        if let mailboxDirectory, refusal == nil {
            let mailbox = ControlMailbox(directory: mailboxDirectory, host: host)
            self.mailbox = mailbox
            mailbox.start()
        }
    }

    /// Write the current snapshot now (if it changed) and wait until it's on disk — before every reply,
    /// so `state.json` is never behind what a reply reported. Before the bootstrap, nothing is written.
    func syncState() async {
        guard bootstrapped else { return }
        writer.flush()
        await sink.drained()
    }

    /// The snapshot as `state.json` carries it now — `wait` and `snapshot` evaluate this, not the file.
    func stateJSON() -> ControlJSON {
        let inputs = inputs
        inputs.albumAliases.assignNew(inputs.projects.projects)   // as the writer does before each pass
        return ControlSnapshot.stamped(ControlSnapshot.content(inputs), run: run, rev: writer.rev)
    }

    var inputs: ControlSnapshotInputs {
        ControlSnapshotInputs(
            fixture: fixture, coordinator: graph.coordinator, session: graph.session, viewer: graph.viewer,
            projects: graph.projectStore,
            selection: graph.selectionStore, done: graph.doneStore,
            assetAliases: assetAliases, albumAliases: albumAliases,
            progress: progress, thumbnails: thumbnailLoads, exportGate: exportGate, headless: isHeadless,
            launchError: launchError, bootstrapped: bootstrapped,
            idiom: UIDevice.current.userInterfaceIdiom == .pad ? "pad" : "phone",
            timeZone: Self.timeZoneName(Calendar.current.timeZone))
    }

    /// Foundation names UTC "GMT"; report the zone the plan pins (`UTC`) when that's what it is.
    static func timeZoneName(_ zone: TimeZone) -> String {
        ["GMT", "UTC"].contains(zone.identifier) ? "UTC" : zone.identifier
    }
}

/// Applies a launch route the way the UI would, through the coordinator's own methods. (The screen's own
/// work — the scan, the export — is the host's `screenTask`, started by the bootstrap after this.)
@MainActor
struct ControlRouteApplier {
    let graph: AppGraph
    let fixture: ControlFixture
    let albums: ControlAlbumAliases
    let assets: ControlAssetAliases

    /// Open the album (bump + overview, like the album list's tap), then push the destination. A route
    /// needs the albums phase: on `fresh`/`denied` it can't apply, and says so. The export route is the
    /// user's own path, as an agent would send it: open → the Overview's scan settles (its task) → Save to
    /// Photos (`finishToExport`, disabled with no picks) — so its completion stats match the real one.
    func apply(_ route: ControlRoute) async throws(ControlLaunchError) {
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
        graph.actions.open(project)   // bump + overview, exactly as the album list's tap
        switch route {
        case .review(_, let day): coordinator.openReview(id, day: day)
        case .export:
            await graph.session.appear(.overview, project)
            guard graph.selectionStore.progress.picked > 0 else {
                throw ControlLaunchError("export route: '\(alias)' has no picks (Save to Photos is disabled)")
            }
            coordinator.finishToExport()   // the one export entry point (the Overview's button, #298)
        case .settings: coordinator.openSettings(id)
        case .overview, .appSettings: break
        }
    }

    /// Open the photo viewer on `alias` once the review has published it (the route's screen task runs
    /// the scan after the route lands). Bounded by a real deadline, polled — never a fixed sleep.
    func openViewer(_ alias: String, timeout: Duration = .seconds(30)) async throws(ControlLaunchError) {
        guard let assetID = assets.assetID(for: alias) else {
            throw ControlLaunchError("viewer photo '\(alias)' is not in fixture '\(fixture.rawValue)'")
        }
        let session = graph.session
        let deadline = ContinuousClock.now + timeout
        while !session.reviewOrderedIDs.contains(assetID) {
            switch session.candidateStore?.phase {
            case .empty?, .failed?:
                throw ControlLaunchError("viewer: the review has no photos to open '\(alias)' on")
            case .ready? where !session.reviewOrderedIDs.isEmpty:
                throw ControlLaunchError("viewer photo '\(alias)' is not in the open review")
            default:
                break   // not scanned yet, scanning, or ready but not yet published by the grid
            }
            guard ContinuousClock.now < deadline else {
                throw ControlLaunchError("viewer: the review scan did not settle within \(timeout)")
            }
            try? await Task.sleep(for: .milliseconds(50))   // poll with a real deadline
        }
        graph.coordinator.openPhoto(assetID)
    }
}

/// Shown instead of `AppRootView` in a headless control run (`-PoimiHeadless`, #298): static on purpose —
/// it observes nothing, so the run does no UI work; everything goes through the mailbox and the stores.
/// Dev-facing, so `Text(verbatim:)`.
struct ControlHeadlessView: View {
    let run: String

    var body: some View {
        VStack(spacing: 8) {
            Text(verbatim: "Poimi control — headless")
                .font(.headline)
            Text(verbatim: "run \(run)")
                .font(.footnote.monospaced())
        }
        .padding()
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
