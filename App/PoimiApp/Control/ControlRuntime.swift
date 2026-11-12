//
//  ControlRuntime.swift
//  PoimiApp — the control launch: isolation, launch route, and the `state.json` writer
//  (#296, docs/plans/control-plane.md §4 slice A). DEBUG-only (D30).
//
//  `-PoimiControl -PoimiFixture <name>` builds an ISOLATED graph and seeds it:
//    - the fake library, thumbnails and place naming (never PhotoKit / CLGeocoder);
//    - an in-memory SwiftData store, plus `Application Support/control/` for the album-alias table
//      and the timeline cache — wiped at every control launch, so a fixture is always the start state;
//    - a separate `UserDefaults` suite, with What's New and the App Store review prompt pre-marked as
//      done for this version, so neither can cover a control run;
//    - the process time zone pinned to UTC (the fixtures' day keys are UTC; `poimi.sh` also sets
//      `SIMCTL_CHILD_TZ=UTC`), so cluster shapes don't depend on the Mac's zone;
//    - a day-long debounce, so a flush happens only when the app flushes explicitly (scene phase).
//  It then reads authorization, applies `-PoimiRoute` / `-PoimiViewer` through the coordinator's
//  own methods, and keeps `Documents/control/state.json` (+ `state-detail.json`) current.
//
#if DEBUG

import Foundation
import Observation
import SwiftData
import SwiftUI
import UIKit
import Curation

@MainActor
final class ControlRuntime {
    /// The one runtime of a control launch (kept alive here; `nil` on a normal launch).
    private(set) static var shared: ControlRuntime?

    let graph: AppGraph
    /// Why the launch was refused (malformed flags) — shown in place of the UI. `nil` when valid.
    let refusal: String?

    private let launch: ControlLaunch?
    private let fixture: ControlFixture
    private let paths: ControlPaths
    private let assetAliases: ControlAssetAliases
    private let albumAliases: ControlAlbumAliases
    private let run = "r-" + String(UInt32.random(in: 0...UInt32.max), radix: 16)
    /// Ordered, off-main file writes (one consumer, so a later snapshot can never land first).
    private let writes: AsyncStream<ControlFileWrite>.Continuation

    private var launchError: String?
    private var bootstrapped = false
    private var revision = ControlRevision()
    private var latest: ControlJSON?
    private var lastDetail: ControlJSON?
    private var writeScheduled = false

    /// The debounce for picks and done-days under control: long enough that it never fires on its
    /// own during a run, so persistence happens only on an explicit flush (scene phase / switch).
    static let debounce: Duration = .seconds(24 * 3600)
    static let defaultsSuite = "com.valtteriluoma.poimi.control"

    // MARK: - Boot

    /// Build the isolated graph for `parsed`, seed its fixture, and start the runtime.
    static func boot(_ parsed: ControlLaunch.Parsed) -> ControlRuntime {
        let runtime = ControlRuntime(parsed)
        shared = runtime
        runtime.start()
        return runtime
    }

    private init(_ parsed: ControlLaunch.Parsed) {
        switch parsed {
        case .on(let launch):
            self.launch = launch
            refusal = nil
        case .invalid(let message):
            launch = nil
            refusal = message
        case .off:
            launch = nil
            refusal = "control runtime booted without a control flag"
        }
        // A refused launch still runs isolated — on the `fresh` fixture's (unseeded) library.
        fixture = launch?.fixture ?? .fresh
        launchError = refusal

        // UTC before anything reads `Calendar.current` / `TimeZone.current`.
        NSTimeZone.default = TimeZone(identifier: "UTC")!
        paths = ControlPaths.standard()
        paths.reset()
        let (stream, continuation) = AsyncStream.makeStream(of: ControlFileWrite.self)
        writes = continuation
        Task.detached(priority: .utility) {
            for await write in stream { write.perform() }
        }

        graph = Self.isolatedGraph(fixture: fixture, paths: paths)
        assetAliases = ControlAssetAliases(assets: fixture.assets)
        albumAliases = ControlAlbumAliases(fileURL: paths.albumAliases)
        if launch != nil {
            let seeded = fixture.seed(projects: graph.projectStore, selection: graph.selectionStore,
                                      done: graph.doneStore)
            for project in seeded { albumAliases.alias(for: project.id) }
        }
        if let refusal {
            Log.app.fault("control: launch refused — \(refusal, privacy: .public)")
        } else {
            let fixtureName = fixture.rawValue, runID = run
            Log.app.notice("control: fixture \(fixtureName, privacy: .public), run \(runID, privacy: .public)")
        }
    }

    /// The app graph a control launch runs on: the fixture's fake library, fake thumbnails + naming, an
    /// in-memory store, the timeline cache under `control/`, the long debounce and isolated defaults.
    private static func isolatedGraph(fixture: ControlFixture, paths: ControlPaths) -> AppGraph {
        let container: ModelContainer
        do {
            container = try AppModelContainer.make(inMemory: true)
        } catch {
            fatalError("control: could not build the in-memory store: \(error)")
        }
        let library = fixture.makeLibrary()
        let timelineCache = TimelineCache(directory: paths.timelineCache)
        let defaults = isolatedDefaults()
        return AppGraph(
            photoLibrary: library,
            thumbnailProvider: FakeThumbnailProvider(),
            placeNaming: FakePlaceNaming(),
            modelContainer: container,
            projectStore: ProjectStore(container: container, timelineCache: timelineCache),
            selectionStore: SelectionStore(container: container, debounce: debounce),
            doneStore: DoneStore(container: container, debounce: debounce),
            coordinator: AppCoordinator(library: library, timelineCache: timelineCache),
            whatsNewState: WhatsNewState(userDefaults: defaults),
            appReviewPrompt: AppReviewPrompt(userDefaults: defaults))
    }

    /// A wiped `UserDefaults` suite with What's New and the review prompt already "done" for this
    /// version, so neither presents over a control run (and the real defaults are never touched).
    private static func isolatedDefaults() -> UserDefaults {
        guard let defaults = UserDefaults(suiteName: defaultsSuite) else {
            fatalError("control: could not open the \(defaultsSuite) defaults suite")
        }
        defaults.removePersistentDomain(forName: defaultsSuite)
        let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
        defaults.set(version, forKey: WhatsNewState.lastSeenVersionKey)
        defaults.set(version, forKey: AppReviewPrompt.lastPromptedVersionKey)
        return defaults
    }

    /// Nothing is written until the bootstrap finishes, so the first `state.json` of a run already
    /// reflects the applied route (or its `launchError`) — `poimi.sh launch` returns on that file.
    private func start() {
        Task { await bootstrap() }
    }

    // MARK: - Launch route

    /// Read authorization, then apply the route and viewer. A problem is recorded as
    /// `app.launchError` (the UI stays up, so you can still look).
    private func bootstrap() async {
        await graph.coordinator.refreshAuthorization()
        if refusal == nil, let launch {
            do throws(ControlLaunchError) {
                if let route = launch.route { try apply(route) }
                if let viewer = launch.viewer { try await openViewer(viewer) }
            } catch {
                launchError = error.message
                Log.app.error("control: \(error.message, privacy: .public)")
            }
        }
        bootstrapped = true
        arm()          // from here on, every observed change re-arms and schedules a write
        flushState()   // the run's first state.json
    }

    /// Apply `route` exactly as the UI would: open the album (bump + overview, like the album list's
    /// tap), then push the destination with the coordinator's own method.
    private func apply(_ route: ControlRoute) throws(ControlLaunchError) {
        let coordinator = graph.coordinator
        guard let alias = route.album else {
            coordinator.openAppSettings()
            return
        }
        guard let id = albumAliases.projectID(for: alias),
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

    /// Open the photo viewer on `alias` once the review scan has published it (the grid's `.task`
    /// runs the scan after the route lands). Bounded wait — a real deadline, not a fixed sleep.
    private func openViewer(_ alias: String) async throws(ControlLaunchError) {
        guard let assetID = assetAliases.assetID(for: alias) else {
            throw ControlLaunchError("viewer photo '\(alias)' is not in fixture '\(fixture.rawValue)'")
        }
        let coordinator = graph.coordinator
        let deadline = ContinuousClock.now + .seconds(30)
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
                throw ControlLaunchError("viewer: the review scan did not settle within 30 s")
            }
            try? await Task.sleep(for: .milliseconds(50))   // poll with a real deadline
        }
        coordinator.openPhoto(assetID)
    }

    // MARK: - state.json

    private var inputs: ControlSnapshotInputs {
        ControlSnapshotInputs(
            fixture: fixture, coordinator: graph.coordinator, projects: graph.projectStore,
            selection: graph.selectionStore, done: graph.doneStore,
            assetAliases: assetAliases, albumAliases: albumAliases,
            launchError: launchError, bootstrapped: bootstrapped,
            idiom: UIDevice.current.userInterfaceIdiom == .pad ? "pad" : "phone",
            timeZone: Self.timeZoneName(TimeZone.current))
    }

    /// Foundation names UTC "GMT"; report the zone the plan pins (`UTC`) when that's what it is.
    static func timeZoneName(_ zone: TimeZone) -> String {
        ["GMT", "UTC"].contains(zone.identifier) ? "UTC" : zone.identifier
    }

    /// Build the snapshot while tracking what it reads. `onChange` fires BEFORE the change lands and
    /// only once, so each change re-arms on the next main-actor turn (when the new value is readable).
    private func arm() {
        latest = withObservationTracking {
            ControlSnapshot.content(inputs)
        } onChange: { [weak self] in
            Task { @MainActor in self?.changed() }
        }
    }

    private func changed() {
        arm()
        scheduleWrite()
    }

    /// Coalesce bursts: one write ~100 ms after the first change in a burst.
    private func scheduleWrite() {
        guard !writeScheduled else { return }
        writeScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard let self else { return }
            writeScheduled = false
            flushState()
        }
    }

    /// Write `state.json` (when its content changed — that's what bumps `rev`) and `state-detail.json`
    /// (when the per-day detail changed). Serialization + the atomic file write run off the main actor.
    private func flushState() {
        guard let latest else { return }
        let stateChanged = revision.record(latest)
        let detail = ControlSnapshot.detail(inputs)
        let detailChanged = detail != lastDetail
        guard stateChanged || detailChanged else { return }
        lastDetail = detail
        let state = stateChanged ? ControlSnapshot.stamped(latest, run: run, rev: revision.rev) : nil
        // Detail first: once `state.json`'s new rev is visible, its detail is already on disk.
        writes.yield(ControlFileWrite(json: ControlSnapshot.stamped(detail, run: run, rev: revision.rev),
                                      url: paths.detail))
        if let state { writes.yield(ControlFileWrite(json: state, url: paths.state)) }
    }
}

/// The control plane's on-disk locations.
struct ControlPaths: Sendable {
    /// `Application Support/control/` — the album-alias table + timeline cache beside the isolated store.
    let support: URL
    /// `Documents/control/` — what the agent reads (`simctl get_app_container … data`).
    let output: URL

    var albumAliases: URL { support.appendingPathComponent("album-aliases.json") }
    var timelineCache: URL { support.appendingPathComponent("TimelineCache", isDirectory: true) }
    var state: URL { output.appendingPathComponent("state.json") }
    var detail: URL { output.appendingPathComponent("state-detail.json") }

    static func standard(fileManager: FileManager = .default) -> ControlPaths {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return ControlPaths(support: support.appendingPathComponent("control", isDirectory: true),
                            output: documents.appendingPathComponent("control", isDirectory: true))
    }

    /// Wipe and recreate both directories — every control launch starts from its fixture, and a stale
    /// `state.json` from a previous launch never survives into this one.
    func reset(fileManager: FileManager = .default) {
        for directory in [support, output] {
            try? fileManager.removeItem(at: directory)
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }
}

/// One snapshot file write. Serialization + `.atomic` (a temporary file renamed over the target, so
/// a reader never sees a half-written file) both run on the writer task, off the main actor.
struct ControlFileWrite: Sendable {
    let json: ControlJSON
    let url: URL

    func perform() {
        do {
            try json.serialized().write(to: url, options: .atomic)
        } catch {
            Log.app.error("control: state write failed: \(String(describing: error), privacy: .public)")
        }
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
