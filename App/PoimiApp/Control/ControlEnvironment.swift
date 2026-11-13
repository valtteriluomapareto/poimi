//
//  ControlEnvironment.swift
//  PoimiApp — the process-global side of a control launch (#296, docs/plans/control-plane.md §4 A).
//  DEBUG-only (D30).
//
//  Everything with process-wide effects lives here, apart from the testable runtime:
//    - the process time zone pinned to UTC (the fixtures' day keys are UTC; `poimi.sh` also sets
//      `SIMCTL_CHILD_TZ=UTC`), so cluster shapes don't depend on the Mac's zone;
//    - `Application Support/control/` (timeline cache) and `Documents/control/` (the state files)
//      wiped at every control launch, so a fixture is always its exact start state;
//    - a wiped `UserDefaults` suite with What's New and the review prompt pre-marked for this
//      version, so neither covers a control run and the real defaults are never touched;
//    - the one live `ControlRuntime`.
//  A NORMAL DEBUG launch deletes `Documents/control/`, so a state file can never outlive its run.
//
#if DEBUG

import Foundation
import SwiftData
import Curation

@MainActor
enum ControlEnvironment {
    /// The runtime of this control launch (`nil` on a normal launch).
    private(set) static var current: ControlRuntime?

    static let defaultsSuite = "com.valtteriluoma.poimi.control"

    /// Boot a control launch: process-global setup, the isolated graph, the runtime, the file sink.
    static func boot(_ parsed: ControlLaunch.Parsed) -> ControlRuntime {
        let paths = ControlPaths.standard()
        NSTimeZone.default = TimeZone(identifier: "UTC")!   // before anything reads `.current`
        paths.reset()
        let fixture = parsed.launch?.fixture ?? .fresh      // a refused launch runs on `fresh`, unseeded
        let graph = makeGraph(fixture: fixture,
                              timelineCacheDirectory: paths.timelineCache,
                              defaults: isolatedDefaults(suiteName: defaultsSuite))
        let runtime = ControlRuntime(parsed: parsed, graph: graph, sink: ControlFileSink(paths: paths))
        current = runtime
        runtime.start()
        return runtime
    }

    /// A normal (non-control) DEBUG launch: remove any control state left by an earlier control run,
    /// so a reader can never mistake it for this process's state.
    static func clearForNormalLaunch() {
        try? FileManager.default.removeItem(at: ControlPaths.standard().output)
    }

    /// The graph a control launch runs on — `AppGraph.make` with the fixture's fake library, fake
    /// thumbnails + naming, an in-memory store, the long debounce and UTC. The integration tests build
    /// theirs through this too, so test and launch can't be wired differently.
    static func makeGraph(fixture: ControlFixture, timelineCacheDirectory: URL,
                          defaults: UserDefaults) -> AppGraph {
        let container: ModelContainer
        do {
            container = try AppModelContainer.make(inMemory: true)
        } catch {
            fatalError("control: could not build the in-memory store: \(error)")
        }
        return AppGraph.make(
            container: container,
            library: fixture.makeLibrary(),
            thumbnails: FakeThumbnailProvider(),
            naming: FakePlaceNaming(),
            timelineCache: TimelineCache(directory: timelineCacheDirectory),
            debounce: ControlRuntime.debounce,
            defaults: defaults,
            calendar: ControlFixture.utc)
    }

    /// A wiped `UserDefaults` suite with What's New and the review prompt already "done" for this
    /// version, so neither presents over a control run.
    static func isolatedDefaults(suiteName: String) -> UserDefaults {
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("control: could not open the \(suiteName) defaults suite")
        }
        defaults.removePersistentDomain(forName: suiteName)
        let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
        defaults.set(version, forKey: WhatsNewState.lastSeenVersionKey)
        defaults.set(version, forKey: AppReviewPrompt.lastPromptedVersionKey)
        return defaults
    }
}

/// The control plane's on-disk locations.
struct ControlPaths: Sendable {
    /// `Application Support/control/` — the control run's timeline cache.
    let support: URL
    /// `Documents/control/` — what the agent reads (`simctl get_app_container … data`).
    let output: URL

    var timelineCache: URL { support.appendingPathComponent("TimelineCache", isDirectory: true) }
    var state: URL { output.appendingPathComponent("state.json") }
    var detail: URL { output.appendingPathComponent("state-detail.json") }

    static func standard(fileManager: FileManager = .default) -> ControlPaths {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return ControlPaths(support: support.appendingPathComponent("control", isDirectory: true),
                            output: documents.appendingPathComponent("control", isDirectory: true))
    }

    /// Wipe and recreate both directories.
    func reset(fileManager: FileManager = .default) {
        for directory in [support, output] {
            try? fileManager.removeItem(at: directory)
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }
}

#endif
