//
//  ControlEnvironment.swift
//  PoimiApp — the process-global side of a control launch (#296, docs/plans/control-plane.md §4 A).
//  DEBUG-only (D30).
//
//  Everything with process-wide effects lives here, apart from the testable runtime:
//    - the process time zone pinned to UTC (the fixtures' day keys are UTC; `poimi.sh` also sets
//      `SIMCTL_CHILD_TZ=UTC`), so cluster shapes don't depend on the Mac's zone;
//    - `Application Support/control/` (the store, the fake library's state, the timeline cache) and
//      `Documents/control/` (the state files, the mailbox) wiped at every fixture launch, so a fixture is
//      always its exact start state — a relaunch (#300) keeps the first and clears only the second;
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
        let runtime = makeRuntime(parsed, paths: paths, defaults: isolatedDefaults(suiteName: defaultsSuite),
                                  sink: ControlFileSink(paths: paths), mailbox: true)
        current = runtime
        runtime.start()
        return runtime
    }

    /// One control run over `paths` — the launch's whole wiring, which the relaunch tests drive too:
    /// - a **fixture launch** wipes both control directories, then seeds the fixture into a fresh store;
    /// - a **relaunch** (#300) keeps `Application Support/control/` — the store, the fake library's state
    ///   (added photos, exported albums, authorization), the run record (fixture + album aliases) and the
    ///   timeline cache — clears only this run's state files and mailbox, and seeds nothing.
    /// The store is always a file there (a fixture launch might be relaunched), never the app's real one.
    static func makeRuntime(_ parsed: ControlLaunch.Parsed, paths: ControlPaths, defaults: UserDefaults,
                            sink: any ControlStateSink, run: String? = nil, writeDelay: Duration = .milliseconds(100),
                            mailbox: Bool = false, listAlwaysShown: Bool? = nil) -> ControlRuntime {
        let relaunch = parsed.launch?.relaunch ?? false
        if relaunch { paths.resetOutput() } else { paths.reset() }
        let fixture = parsed.launch?.fixture ?? .fresh      // a refused launch runs on `fresh`, unseeded
        let restored = relaunch ? FakeLibraryState.load(from: paths.library) : nil
        let gate = FakeExportGate(created: restored?.exportSeq ?? 0)
        let loads = ThumbnailLoadCounter()
        let graph = makeGraph(fixture: fixture,
                              timelineCacheDirectory: paths.timelineCache,
                              defaults: defaults,
                              thumbnailLoads: loads,
                              library: fixture.makeLibrary(exportGate: gate, restoring: restored,
                                                           persistence: paths.library),
                              store: paths.store)
        return ControlRuntime(parsed: parsed, graph: graph, sink: sink,
                              run: run ?? "r-" + String(UInt32.random(in: 0...UInt32.max), radix: 16),
                              writeDelay: writeDelay, thumbnailLoads: loads,
                              mailbox: mailbox ? paths.output : nil, listAlwaysShown: listAlwaysShown,
                              exportGate: gate, record: paths.record, addedAssets: restored?.added ?? [])
    }

    /// A normal (non-control) DEBUG launch: remove any control state left by an earlier control run,
    /// so a reader can never mistake it for this process's state.
    static func clearForNormalLaunch() {
        try? FileManager.default.removeItem(at: ControlPaths.standard().output)
    }

    /// The graph a control launch runs on — `AppGraph.make` with the fixture's fake library, fake
    /// thumbnails + naming, the control store (`store`'s file; in memory when `nil`), the long debounce and
    /// UTC. The integration tests build theirs through this too, so test and launch can't be wired
    /// differently.
    static func makeGraph(fixture: ControlFixture, timelineCacheDirectory: URL,
                          defaults: UserDefaults, thumbnailLoads: ThumbnailLoadCounter? = nil,
                          library: (any PhotoLibraryProviding)? = nil, store: URL? = nil) -> AppGraph {
        let container: ModelContainer
        do {
            container = try store.map(AppModelContainer.make(url:)) ?? AppModelContainer.make(inMemory: true)
        } catch {
            fatalError("control: could not build the control store: \(error)")
        }
        return AppGraph.make(
            container: container,
            library: library ?? fixture.makeLibrary(),   // the tests may wrap the fixture's (e.g. gated)
            thumbnails: FakeThumbnailProvider(loads: thumbnailLoads),
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
    /// `Application Support/control/` — what a relaunch finds again (#300): the store, the fake library's
    /// state, the run record, the timeline cache. Wiped by every fixture launch, kept by a relaunch.
    let support: URL
    /// `Documents/control/` — what the agent reads (`simctl get_app_container … data`), and the mailbox
    /// (`req-<n>.json` in, `res-<n>.json` out, #298). Per run: wiped by every launch, relaunch included.
    let output: URL

    var timelineCache: URL { support.appendingPathComponent("TimelineCache", isDirectory: true) }
    /// The control run's SwiftData store (never the app's real one).
    var store: URL { support.appendingPathComponent("control.store") }
    /// The fake library's `FakeLibraryState`.
    var library: URL { support.appendingPathComponent("library.json") }
    /// The `ControlRunRecord`: the fixture and the album aliases, for a relaunch.
    var record: URL { support.appendingPathComponent("run.json") }
    var state: URL { output.appendingPathComponent("state.json") }
    var detail: URL { output.appendingPathComponent("state-detail.json") }

    static func standard(fileManager: FileManager = .default) -> ControlPaths {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return ControlPaths(support: support.appendingPathComponent("control", isDirectory: true),
                            output: documents.appendingPathComponent("control", isDirectory: true))
    }

    /// Wipe and recreate both directories (a fixture launch).
    func reset(fileManager: FileManager = .default) {
        for directory in [support, output] {
            try? fileManager.removeItem(at: directory)
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    /// Wipe and recreate only the per-run directory (a relaunch: the last run's state files and mailbox
    /// go, what it persisted stays).
    func resetOutput(fileManager: FileManager = .default) {
        try? fileManager.removeItem(at: output)
        try? fileManager.createDirectory(at: output, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: support, withIntermediateDirectories: true)
    }
}

/// What a relaunch needs to know about the run it continues (#300): the fixture (its asset aliases and
/// albums' starting shape) and the album aliases handed out so far — so `album-2` names the same album
/// after a relaunch, and a new album still never gets a used number. Rewritten whenever an alias is assigned.
struct ControlRunRecord: Codable, Equatable {
    var fixture: String
    /// Project id (UUID string) → album alias.
    var albums: [String: String]
    /// The next album alias number.
    var nextAlbum: Int

    static func load(from url: URL) -> ControlRunRecord? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ControlRunRecord.self, from: data)
    }

    func save(to url: URL) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            try encoder.encode(self).write(to: url, options: .atomic)
        } catch {
            Log.app.error("control: couldn't save the run record: \(String(describing: error), privacy: .public)")
        }
    }
}

#endif
