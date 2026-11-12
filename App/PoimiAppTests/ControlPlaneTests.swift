//
//  ControlPlaneTests.swift
//  PoimiAppTests — the control plane's slice A (#296, docs/plans/control-plane.md): fixture shape +
//  determinism, alias stability, launch-flag / route parsing, snapshot redaction, and the state.json
//  shape. In-process through the real stores + `FakePhotoLibrary`; every async step awaits the real
//  work (no fixed sleeps). The runtime/writer loop is ControlRuntimeTests.
//

import Testing
import Foundation
import SwiftData
import Curation
@testable import PoimiApp

/// Collects the state writes in memory, in order.
@MainActor
final class MemorySink: ControlStateSink {
    private(set) var writes: [(file: ControlStateFile, json: ControlJSON)] = []

    func write(_ json: ControlJSON, to file: ControlStateFile) { writes.append((file, json)) }

    var lastState: ControlJSON? { writes.last { $0.file == .state }?.json }
    var lastDetail: ControlJSON? { writes.last { $0.file == .detail }?.json }
}

/// One control launch, wired exactly as `ControlEnvironment.boot` wires it — the same graph factory
/// and the same `ControlRuntime` — minus the process-global effects, with an in-memory sink.
@MainActor
struct ControlHarness {
    let fixture: ControlFixture
    let runtime: ControlRuntime
    let sink = MemorySink()
    let thumbnailLoads = ThumbnailLoadCounter()

    init(_ fixture: ControlFixture, route: ControlRoute? = nil, viewer: String? = nil, headless: Bool = false,
         library: (any PhotoLibraryProviding)? = nil, iPad: Bool = false) {
        self.init(fixture, parsed: .on(ControlLaunch(fixture: fixture, route: route, viewer: viewer,
                                                     headless: headless)),
                  library: library, iPad: iPad)
    }

    /// `library` replaces the fixture's own (a test wraps it, e.g. to gate exports); the fixture still
    /// decides the albums and aliases.
    /// `iPad` = the split view's layout: the album list (sidebar) is always on screen.
    init(_ fixture: ControlFixture, parsed: ControlLaunch.Parsed, library: (any PhotoLibraryProviding)? = nil,
         iPad: Bool = false) {
        self.fixture = fixture
        // The fixture's own library carries the export gate, as a launch's does (#300).
        let gate = library == nil ? FakeExportGate() : nil
        let graph = ControlEnvironment.makeGraph(
            fixture: fixture,
            timelineCacheDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("control-tests-\(UUID().uuidString)", isDirectory: true),
            defaults: ControlEnvironment.isolatedDefaults(suiteName: "control.test.\(UUID().uuidString)"),
            thumbnailLoads: thumbnailLoads, library: library ?? fixture.makeLibrary(exportGate: gate))
        runtime = ControlRuntime(parsed: parsed, graph: graph, sink: sink, run: "r-test",
                                 writeDelay: .milliseconds(10), thumbnailLoads: thumbnailLoads,
                                 listAlwaysShown: iPad, exportGate: gate)
    }

    /// A launch over `paths`, exactly as `ControlEnvironment.boot` makes one (`makeRuntime`): a fixture
    /// launch wipes `paths` and seeds; `relaunch` continues whatever the last run over `paths` left (#300).
    init(_ fixture: ControlFixture, paths: ControlPaths, relaunch: Bool = false, headless: Bool = false,
         iPad: Bool = false) {
        self.fixture = fixture
        let recorded = ControlRunRecord.load(from: paths.record).flatMap { ControlFixture(rawValue: $0.fixture) }
        let arguments = ["-PoimiControl"] + (relaunch ? ["-PoimiRelaunch"] : ["-PoimiFixture", fixture.rawValue])
            + (headless ? ["-PoimiHeadless"] : [])
        runtime = ControlEnvironment.makeRuntime(
            ControlLaunch.parse(arguments, recorded: recorded), paths: paths,
            defaults: ControlEnvironment.isolatedDefaults(suiteName: "control.test.\(UUID().uuidString)"),
            sink: sink, run: "r-test-\(relaunch ? "relaunch" : "launch")", writeDelay: .milliseconds(10),
            listAlwaysShown: iPad)
    }

    /// Fresh control directories for one test (both under the temporary directory).
    static func temporaryPaths() -> ControlPaths {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("control-\(UUID().uuidString)")
        return ControlPaths(support: root.appendingPathComponent("support"), output: root.appendingPathComponent("output"))
    }

    var graph: AppGraph { runtime.graph }
    var coordinator: AppCoordinator { graph.coordinator }
    var selection: SelectionStore { graph.selectionStore }
    var done: DoneStore { graph.doneStore }

    /// The seeded albums in alias (= seed) order.
    var created: [CurationProject] {
        (1...max(1, graph.projectStore.projects.count)).compactMap { number in
            runtime.albumAliases.projectID(for: "album-\(number)").flatMap { id in
                graph.projectStore.projects.first { $0.id == id }
            }
        }
    }

    /// Navigate to `album-1`'s review the way the album list + route do, then scan as the grid does.
    func openReview() async throws {
        let project = try #require(created.first)
        graph.actions.open(project)
        coordinator.openReview(project.id)
        try await scanAsGrid()
    }

    /// What `ScanningView`'s `.task` does for the open album — the album session's `open` with
    /// reconcile (#297) — then wait for its trip names, so the snapshot is settled.
    func scanAsGrid() async throws {
        let id = try #require(coordinator.activeAlbumID)
        let project = try #require(graph.projectStore.projects.first { $0.id == id })
        let store = await graph.session.openReview(project)
        await store.awaitPendingNames()
    }

    /// The current snapshot pair (content, detail), unstamped.
    func snapshot() -> (content: ControlJSON, detail: ControlJSON) {
        let inputs = runtime.inputs
        return (ControlSnapshot.content(inputs), ControlSnapshot.detail(inputs, cache: ControlDetailCache()))
    }

    /// Both snapshot files, serialized exactly as the runtime writes them.
    func serializedSnapshots() -> [String] {
        let (content, detail) = snapshot()
        return [content, detail].map {
            String(bytes: ControlSnapshot.stamped($0, run: "r-test", rev: 1).serialized(), encoding: .utf8) ?? ""
        }
    }
}

/// A comparable projection of a seeded album (everything a fixture decides).
private struct SeededAlbum: Equatable {
    let title: String
    let target: Int
    let picks: [String]
    let doneDays: [String]
    let status: ProjectStatus
    let exportedCount: Int?
    let targetAlbumID: String?

    init(_ project: CurationProject) {
        title = project.title
        target = project.targetCount
        picks = project.persistedPicks.sorted()
        doneDays = project.doneDays.sorted()
        status = project.status
        exportedCount = project.exportedPhotoCount
        targetAlbumID = project.targetAlbumID
    }
}

@MainActor
@Suite("Control plane: fixtures (#296)")
struct ControlFixtureTests {

    @Test("every fixture seeds the same albums and the same snapshot twice", arguments: ControlFixture.allCases)
    func deterministic(_ fixture: ControlFixture) async throws {
        let first = ControlHarness(fixture)
        let second = ControlHarness(fixture)
        #expect(first.created.map(SeededAlbum.init) == second.created.map(SeededAlbum.init))
        for harness in [first, second] {
            await harness.runtime.bootstrap()
            if !harness.created.isEmpty, fixture.authorization == .authorized { try await harness.openReview() }
        }
        // The whole serialized snapshot (aliases, clusters, per-day detail) is identical.
        #expect(first.serializedSnapshots() == second.serializedSnapshots())
    }

    @Test("fixture shapes: authorization, album count, statuses")
    func shapes() async throws {
        for fixture in [ControlFixture.fresh, .denied] {
            let harness = ControlHarness(fixture)
            #expect(harness.created.isEmpty)
            await harness.runtime.bootstrap()
            #expect(harness.coordinator.rootPhase == (fixture == .fresh ? .onboarding : .recovery))
        }
        // Each harness is held in a local: it owns the container, and a model outliving it traps.
        #expect(ControlFixture.emptyLibrary.assets.isEmpty)
        let empty = ControlHarness(.emptyLibrary)
        #expect(empty.created.count == 1)
        let one = ControlHarness(.oneAlbum)
        #expect(one.created.map(\.status) == [.empty])

        let four = ControlHarness(.fourStatuses)
        #expect(four.created.map(\.status) == [.exported, .editedSinceExport(toAdd: 3), .inProgress, .empty])
        // The stores are handed back released, like a cold launch.
        #expect(!four.selection.isActive)
        #expect(!four.done.isActive)

        let midHarness = ControlHarness(.midReview)
        let mid = try #require(midHarness.created.first)
        #expect(mid.persistedPickedCount == 34)
        #expect(mid.doneDays == ControlFixture.yearDays.prefix(4).map(\.description))
        #expect(mid.status == .inProgress)

        let exportedHarness = ControlHarness(.exported)
        let exported = try #require(exportedHarness.created.first)
        #expect(exported.status == .exported)
        #expect(exported.doneDays.count == ControlFixture.yearDays.count)
        #expect(exported.targetAlbumID == ControlFixture.exportedPhotosAlbum.id)

        #expect(ControlFixture.scale.assets.count == 10_000)
        let scale = ControlHarness(.scale)
        #expect(scale.created.first?.persistedPickedCount == 200)

        #expect(ControlFixture.located.assets.contains { $0.coordinate != nil })
    }

    @Test("the exported fixture re-exports into its Photos album with nothing to add")
    func exportedReExports() async throws {
        let harness = ControlHarness(.exported)
        let project = try #require(harness.created.first)
        let result = try await harness.graph.photoLibrary.export(
            assetIDs: project.persistedPicks, toAlbumNamed: project.title, existingAlbumID: project.targetAlbumID)
        #expect(result.added == 0)
        #expect(result.total == ControlFixture.exportedPicks.count)
    }
}

@MainActor
@Suite("Control plane: aliases (#296)")
struct ControlAliasTests {

    @Test("asset aliases: capture date, then seed index, undated last; stable across builds")
    func assetAliases() {
        let base = Date(timeIntervalSince1970: 1_750_000_000)
        let assets = [
            AssetRef(id: "x/undated", captureDate: nil),
            AssetRef(id: "x/late", captureDate: base.addingTimeInterval(60)),
            AssetRef(id: "x/tie-first", captureDate: base),
            AssetRef(id: "x/tie-second", captureDate: base)
        ]
        let aliases = ControlAssetAliases(assets: assets)
        #expect(aliases.alias(for: "x/tie-first") == "a-0001")
        #expect(aliases.alias(for: "x/tie-second") == "a-0002")
        #expect(aliases.alias(for: "x/late") == "a-0003")
        #expect(aliases.alias(for: "x/undated") == "a-0004")
        #expect(aliases.assetID(for: "a-0003") == "x/late")
        #expect(aliases.aliases(for: ["x/undated", "x/tie-first", "not/seeded"]) == ["a-0001", "a-0004"])
        #expect(ControlAssetAliases(assets: assets) == aliases)
        // The scale library widens the number so aliases still sort as strings.
        #expect(ControlAssetAliases(assets: ControlFixture.scaleAssets).alias(for: "fake/scale/0") == "a-00001")
    }

    @Test("album aliases match across two builds of the same fixture")
    func albumAliasesStable() {
        func titles(_ harness: ControlHarness) -> [String: String] {
            Dictionary(uniqueKeysWithValues: harness.created.compactMap { project in
                harness.runtime.albumAliases.alias(for: project.id).map { ($0, project.title) }
            })
        }
        let first = ControlHarness(.fourStatuses)
        let second = ControlHarness(.fourStatuses)
        #expect(titles(first) == titles(second))
        #expect(Set(titles(first).keys) == ["album-1", "album-2", "album-3", "album-4"])
    }

    @Test("album aliases are monotonic and never reused; lookup never assigns")
    func albumAliasesMonotonic() {
        let first = UUID(), second = UUID(), third = UUID()
        let registry = ControlAlbumAliases()
        #expect(registry.alias(for: first) == nil)       // a pure lookup
        #expect(registry.assign(first) == "album-1")
        #expect(registry.assign(second) == "album-2")
        #expect(registry.assign(first) == "album-1")
        // `second` may since be deleted — its number is still never handed out again.
        #expect(registry.projectID(for: "album-2") == second)
        #expect(registry.assign(third) == "album-3")
    }
}

@Suite("Control plane: launch flags + routes (#296)")
struct ControlLaunchParsingTests {

    @Test("valid routes")
    func validRoutes() throws {
        #expect(try ControlRoute.parse("overview:album-1") == .overview(album: "album-1"))
        #expect(try ControlRoute.parse("review:album-2") == .review(album: "album-2", day: nil))
        #expect(try ControlRoute.parse("review:album-1:2025-07-05")
                == .review(album: "album-1", day: .day(year: 2025, month: 7, day: 5)))
        #expect(try ControlRoute.parse("review:album-1:undated") == .review(album: "album-1", day: .undated))
        #expect(try ControlRoute.parse("export:album-12") == .export(album: "album-12"))
        #expect(try ControlRoute.parse("settings:album-1") == .settings(album: "album-1"))
        #expect(try ControlRoute.parse("appsettings") == .appSettings)
    }

    @Test("invalid routes are rejected", arguments: [
        "", "albums", "overview", "overview:", "overview:1", "overview:album-0", "overview:album-x",
        "overview:album-1:2025-07-05", "review:album-1:2025-7-5", "review:album-1:tomorrow",
        "review:album-1:2025-07-05:extra", "appsettings:album-1", "Review:album-1"
    ])
    func invalidRoutes(_ raw: String) {
        #expect(throws: ControlLaunchError.self) { try ControlRoute.parse(raw) }
    }

    @Test("launch flags")
    func launchFlags() {
        #expect(ControlLaunch.parse(["Poimi"]) == .off)
        #expect(ControlLaunch.parse(["Poimi", "-PoimiUseFakeLibrary", "-PoimiScreen", "shell"]) == .off)
        #expect(ControlLaunch.parse(["Poimi", "-PoimiControl", "-PoimiFixture", "mid-review",
                                     "-PoimiRoute", "review:album-1", "-PoimiViewer", "a-0012"])
                == .on(ControlLaunch(fixture: .midReview, route: .review(album: "album-1", day: nil),
                                     viewer: "a-0012")))
        #expect(ControlLaunch.parse(["Poimi", "-PoimiControl", "-PoimiFixture", "fresh"])
                == .on(ControlLaunch(fixture: .fresh, route: nil, viewer: nil)))
    }

    @Test("malformed control launches are refused, never run as normal launches", arguments: [
        ["-PoimiFixture", "fresh"],                                                  // no -PoimiControl
        ["-PoimiControl"],                                                           // no fixture
        ["-PoimiControl", "-PoimiFixture"],                                          // fixture without value
        ["-PoimiControl", "-PoimiFixture", "-PoimiRoute", "appsettings"],            // value is a flag
        ["-PoimiControl", "-PoimiFixture", "nope"],                                  // unknown fixture
        ["-PoimiControl", "-PoimiFixture", "fresh", "-PoimiScreen", "shell"],        // two hosts
        ["-PoimiControl", "-PoimiFixture", "fresh", "-PoimiRoute", "review:1"],      // bad route
        ["-PoimiControl", "-PoimiFixture", "one-album", "-PoimiViewer", "a-0001"],   // viewer w/o review
        ["-PoimiControl", "-PoimiFixture", "one-album", "-PoimiRoute", "review:album-1",
         "-PoimiViewer", "ctl/3"]                                                    // viewer not an alias
    ])
    func refused(_ arguments: [String]) {
        guard case .invalid(let message) = ControlLaunch.parse(["Poimi"] + arguments) else {
            Issue.record("expected a refusal for \(arguments)")
            return
        }
        #expect(!message.isEmpty)
    }
}

@MainActor
@Suite("Control plane: state snapshot (#296)")
struct ControlSnapshotTests {

    /// Every place name the fake geocoder can produce.
    private static let fakePlaceNames = ["Testby", "Fakenäs", "Mockala", "Dummeberg", "Sampleton",
                                         "Placeholmen", "Nowheresund", "Faketon"]

    @Test("no localIdentifier, title, place name or project id in any fixture's snapshot",
          arguments: ControlFixture.allCases)
    func redaction(_ fixture: ControlFixture) async throws {
        let harness = ControlHarness(fixture)
        await harness.runtime.bootstrap()
        if !harness.created.isEmpty, fixture.authorization == .authorized {
            try await harness.openReview()
        }
        let tripNames = Array((harness.graph.session.candidateStore?.tripNames ?? [:]).values)
        if fixture == .located {
            // The place-name half must be able to fail: trips formed AND got names the app holds.
            #expect(!tripNames.isEmpty)
            guard case .int(let trips)? = harness.snapshot().content["active"]?["scan"]?["trips"] else {
                Issue.record("no trip count in the located snapshot")
                return
            }
            #expect(trips > 0)
        }
        let strings = try harness.serializedSnapshots().flatMap(Self.allStrings)
        let assetIDs = Set(fixture.assets.map(\.id))
        let titles = harness.created.map(\.title) + fixture.photosAlbums.map(\.title)
        let places = Self.fakePlaceNames + tripNames
        let projectIDs = Set(harness.created.map(\.id.uuidString))
        // `app.timeZone` is the one legitimate `/`-shaped value (`Region/City` when, as in this test
        // host, the process isn't pinned to UTC).
        let timeZone = ControlRuntime.timeZoneName(Calendar.current.timeZone)
        for string in strings where string != timeZone {
            #expect(!assetIDs.contains(string), "asset id leaked: \(string)")
            #expect(!string.contains("/"), "id-shaped string leaked: \(string)")
            #expect(!projectIDs.contains(string), "project id leaked: \(string)")
            #expect(UUID(uuidString: string) == nil, "UUID leaked: \(string)")
            for title in titles { #expect(!string.contains(title), "title leaked: \(string)") }
            for place in places { #expect(!string.contains(place), "place name leaked: \(string)") }
        }
    }

    @Test("state.json shape: keys, types, explicit nulls")
    func shape() async throws {
        let harness = ControlHarness(.midReview)
        await harness.runtime.bootstrap()
        try await harness.openReview()
        let snapshots = harness.serializedSnapshots()
        let state = try #require(try Self.parse(snapshots[0]) as? [String: Any])
        #expect(Set(state.keys) == ["snapshotVersion", "run", "rev", "settledSeq", "lastSeq", "app", "nav",
                                    "albums", "active", "library", "pending", "idle"])
        #expect(state["settledSeq"] as? Int == state["lastSeq"] as? Int)
        #expect(state["snapshotVersion"] as? Int == 1)
        #expect(state["idle"] as? Bool == true)

        let app = try #require(state["app"] as? [String: Any])
        #expect(app["rootPhase"] as? String == "albums")
        #expect(app["fixture"] as? String == "mid-review")
        #expect(app["launchError"] is NSNull)
        #expect(app["host"] as? String == "ui")

        let nav = try #require(state["nav"] as? [String: Any])
        #expect(nav["screen"] as? String == "review")
        #expect(nav["sheet"] is NSNull)
        let path = try #require(nav["path"] as? [[String: Any]])
        #expect(path.map { $0["route"] as? String } == ["albumOverview", "review"])
        #expect(path[1]["day"] is NSNull)

        let album = try #require((state["albums"] as? [String: Any])?["album-1"] as? [String: Any])
        #expect(album["status"] as? String == "inProgress")
        #expect(album["picked"] as? Int == 34)
        #expect(album["titleLength"] as? Int == harness.created[0].title.count)

        let active = try #require(state["active"] as? [String: Any])
        #expect(active["album"] as? String == "album-1")
        let scan = try #require(active["scan"] as? [String: Any])
        #expect(scan["phase"] as? String == "ready")
        #expect(scan["candidates"] as? Int == ControlFixture.yearDatedIDs.count)
        let done = try #require(active["done"] as? [String: Any])
        #expect(done["days"] as? Int == 4)

        let pending = try #require(state["pending"] as? [String: Any])
        #expect(pending["scan"] as? Bool == false)
        #expect(pending["selectionFlush"] as? Bool == false)   // observable since slice B (#297)
        #expect(pending["doneFlush"] as? Bool == false)
        #expect(pending["naming"] as? Bool == false)
        #expect(pending["export"] as? Bool == false)
        #expect(pending["thumbnails"] as? Int == 0)   // the fake's loads in flight (#298)
        let export = try #require(active["export"] as? [String: Any])
        #expect(export["phase"] as? String == "idle")
        #expect(export["wasReExport"] is NSNull)

        // The detail file: the active album's days, aliases only, picks as a subset of the day's photos.
        let detail = try #require(try Self.parse(snapshots[1]) as? [String: Any])
        let days = try #require(detail["days"] as? [String: [String: Any]])
        #expect(days.count == ControlFixture.yearDays.count)
        let first = try #require(days[ControlFixture.yearDays[0].description])
        #expect(first["done"] as? Bool == true)
        let photos = try #require(first["photos"] as? [String])
        let picked = try #require(first["picked"] as? [String])
        #expect(Set(picked).isSubset(of: photos))
        #expect(photos.first == "a-0001")
    }

    @Test("idle: false before bootstrap, while the route's scan is pending, and until the export settles")
    func idle() async throws {
        let harness = ControlHarness(.oneAlbum)
        #expect(harness.snapshot().content["idle"] == .bool(false))   // not bootstrapped yet
        await harness.runtime.bootstrap()
        #expect(harness.snapshot().content["idle"] == .bool(true))    // the album list
        let project = try #require(harness.created.first)
        harness.coordinator.openProject(project.id)
        harness.coordinator.openReview(project.id)
        // The route landed but the grid hasn't started its scan yet → not idle.
        #expect(harness.snapshot().content["idle"] == .bool(false))
        try await harness.scanAsGrid()
        #expect(harness.snapshot().content["idle"] == .bool(true))
        // The export screen, before its export ran: pending, not idle (since #297 it's observable —
        // slice A could only say `null`).
        harness.coordinator.finishToExport()
        #expect(harness.snapshot().content["idle"] == .bool(false))
        #expect(harness.snapshot().content["active"]?["export"]?["phase"] == .string("idle"))
        harness.selection.select(harness.graph.session.reviewOrderedIDs.prefix(2))
        await harness.graph.session.startExport(project)   // (an export flushes the picks it exports, #300)
        #expect(harness.snapshot().content["active"]?["export"]?["phase"] == .string("done"))
        harness.selection.toggle(harness.graph.session.reviewOrderedIDs[2])   // a debounce is pending …
        #expect(harness.snapshot().content["pending"]?["selectionFlush"] == .bool(true))
        // … and `idle` doesn't wait on it: under control the debounce is a day long (no flush action
        // until slice C), so the flush is reported under `pending` only.
        #expect(harness.snapshot().content["idle"] == .bool(true))
    }

    @Test("rev bumps only when the content changes")
    func revision() {
        var revision = ControlRevision()
        let one = ControlJSON.object(("a", .int(1)))
        // (Bound to locals first: `#expect` can't call a mutating method on its operand.)
        let first = revision.record(one)
        let repeated = revision.record(one)
        #expect(first)
        #expect(!repeated)
        #expect(revision.rev == 1)
        let changed = revision.record(.object(("a", .int(2))))
        #expect(changed)
        #expect(revision.rev == 2)
    }

    @Test("serialization escapes strings and keeps key order")
    func serialization() throws {
        let json = ControlJSON.object(("z", .string("quote \" slash \\ line\nend \u{01}")),
                                      ("a", .array([.int(1), .null, .bool(false)])),
                                      ("m", .object(pairs: [])))
        let text = String(bytes: json.serialized(), encoding: .utf8) ?? ""
        #expect(text.range(of: "\"z\"")!.lowerBound < text.range(of: "\"a\"")!.lowerBound)
        let parsed = try #require(try Self.parse(text) as? [String: Any])
        #expect(parsed["z"] as? String == "quote \" slash \\ line\nend \u{01}")
        #expect((parsed["a"] as? [Any])?.count == 3)
    }

    // MARK: - Helpers

    static func parse(_ text: String) throws -> Any {
        try JSONSerialization.jsonObject(with: Data(text.utf8))
    }

    /// Every key and string value in a serialized snapshot.
    private static func allStrings(_ text: String) throws -> [String] {
        var out: [String] = []
        func walk(_ value: Any) {
            switch value {
            case let string as String: out.append(string)
            case let array as [Any]: array.forEach(walk)
            case let object as [String: Any]:
                for (key, item) in object {
                    out.append(key)
                    walk(item)
                }
            default: break
            }
        }
        walk(try parse(text))
        return out
    }
}
