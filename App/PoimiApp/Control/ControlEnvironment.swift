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
    /// `relaunchRequested`: `-PoimiRelaunch` was passed — even if the launch is refused, the run it names
    /// is never wiped.
    static func boot(_ parsed: ControlLaunch.Parsed, relaunchRequested: Bool) -> ControlRuntime {
        let paths = ControlPaths.standard()
        NSTimeZone.default = TimeZone(identifier: "UTC")!   // before anything reads `.current`
        let runtime = makeRuntime(parsed, relaunchRequested: relaunchRequested, paths: paths,
                                  defaults: isolatedDefaults(suiteName: defaultsSuite),
                                  sink: ControlFileSink(paths: paths), mailbox: true)
        current = runtime
        runtime.start()
        return runtime
    }

    /// One control run over `paths` — the launch's whole wiring; the integration tests build theirs through
    /// it too (`ControlHarness`), so test and launch can't be wired differently:
    /// - a **fixture launch** wipes both control directories, then seeds the fixture into a fresh store;
    /// - a **relaunch** (#300) keeps `Application Support/control/` — the store, the fake library's state
    ///   (added photos, exported albums), the run record (fixture + album aliases) and the timeline cache —
    ///   clears only this run's state files and mailbox, and seeds nothing. Asked for (`relaunchRequested`)
    ///   but refused, it still never wipes the run; and a run it can't read (a store this build can't open,
    ///   an unreadable library file) is refused (`app.launchError`), never replaced by a fresh one.
    /// The store is a file there (a fixture launch might be relaunched), never the app's real one; the
    /// in-process tests may keep it in memory (`inMemoryStore`) and bring their own `library`.
    static func makeRuntime(_ parsed: ControlLaunch.Parsed, relaunchRequested: Bool = false, paths: ControlPaths,
                            defaults: UserDefaults, sink: any ControlStateSink, run: String? = nil,
                            writeDelay: Duration = .milliseconds(100), mailbox: Bool = false,
                            listAlwaysShown: Bool? = nil, inMemoryStore: Bool = false,
                            library: ((FakeExportGate) -> any PhotoLibraryProviding)? = nil) -> ControlRuntime {
        var parsed = parsed
        let relaunch = relaunchRequested || parsed.launch?.relaunch == true
        if relaunch { paths.resetOutput() } else { paths.reset() }
        // A refused launch runs on `fresh`, unseeded, touching none of the run's files.
        var restored: FakeLibraryState?
        var container: ModelContainer?
        if parsed.launch != nil {
            if relaunch {
                switch FakeLibraryState.load(from: paths.library) {
                case .loaded(let state): restored = state
                case .missing: break
                case .unreadable(let problem): parsed = .invalid("-PoimiRelaunch: \(problem)")
                }
            }
            if parsed.launch != nil, !inMemoryStore {
                do {
                    container = try storeContainer(at: paths.store)
                } catch {
                    parsed = .invalid("control store can't be opened (\(error.localizedDescription)) — "
                        + "launch a fixture to start over")
                }
            }
        }
        let refused = parsed.launch == nil
        let fixture = parsed.launch?.fixture ?? .fresh
        let gate = FakeExportGate(albumsCreated: restored?.exportSeq ?? 0)
        let loads = ThumbnailLoadCounter()
        let graph = makeGraph(fixture: fixture, timelineCacheDirectory: paths.timelineCache, defaults: defaults,
                              thumbnailLoads: loads,
                              library: library?(gate) ?? fixture.makeLibrary(
                                exportGate: gate, restoring: restored, persistence: refused ? nil : paths.library),
                              store: container)
        return ControlRuntime(parsed: parsed, graph: graph, sink: sink,
                              run: run ?? "r-" + String(UInt32.random(in: 0...UInt32.max), radix: 16),
                              writeDelay: writeDelay, thumbnailLoads: loads,
                              mailbox: mailbox ? paths.output : nil, listAlwaysShown: listAlwaysShown,
                              exportGate: gate, record: refused ? nil : paths.record,
                              addedAssets: restored?.added ?? [])
    }

    /// The control run's file store (DEBUG-only: the shipping app's persistence is unchanged).
    static func storeContainer(at url: URL) throws -> ModelContainer {
        let configuration = ModelConfiguration(schema: AppModelContainer.schema, url: url)
        return try ModelContainer(for: AppModelContainer.schema, configurations: configuration)
    }

    /// A normal (non-control) DEBUG launch ends any control run: its state files and mailbox, and what a
    /// relaunch would continue (store, fake library, run record) — so a reader can never mistake them for
    /// this process's, and a later `-PoimiRelaunch` is refused ("no run on record").
    static func clearForNormalLaunch(paths: ControlPaths = .standard()) {
        try? FileManager.default.removeItem(at: paths.output)
        try? FileManager.default.removeItem(at: paths.support)
    }

    /// The graph a control launch runs on — `AppGraph.make` with the fixture's fake library, fake
    /// thumbnails + naming, the control store (`store`; in memory when `nil`), the long debounce and UTC.
    static func makeGraph(fixture: ControlFixture, timelineCacheDirectory: URL,
                          defaults: UserDefaults, thumbnailLoads: ThumbnailLoadCounter? = nil,
                          library: any PhotoLibraryProviding, store: ModelContainer? = nil) -> AppGraph {
        let container: ModelContainer
        do {
            container = try store ?? AppModelContainer.make(inMemory: true)
        } catch {
            fatalError("control: could not build the in-memory store: \(error)")
        }
        return AppGraph.make(
            container: container,
            library: library,
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
    /// The only shape this build reads; anything else is unreadable (a relaunch refuses it).
    static let currentVersion = 1

    var version = ControlRunRecord.currentVersion
    var fixture: String
    /// Project id (UUID string) → album alias.
    var albums: [String: String]
    /// The next album alias number.
    var nextAlbum: Int

    /// The record at `url`: missing, loaded, or unreadable (corrupt, or another version).
    static func load(from url: URL) -> PersistedLoad<ControlRunRecord> {
        PersistedLoad(url: url, version: currentVersion, versionAt: \.version)
    }

    /// What `-PoimiRelaunch` continues, as `ControlLaunch.parse` takes it: the fixture on record, nothing
    /// (`nil`), or why the record can't be used.
    static func recordedRun(at url: URL) -> Result<ControlFixture, ControlLaunchError>? {
        switch load(from: url) {
        case .missing: return nil
        case .unreadable(let problem): return .failure(ControlLaunchError(problem))
        case .loaded(let record):
            guard let fixture = ControlFixture(rawValue: record.fixture) else {
                return .failure(ControlLaunchError("run.json names an unknown fixture '\(record.fixture)'"))
            }
            return .success(fixture)
        }
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
