//
//  ControlPlaneTests.swift
//  PoimiAppTests — the control plane's slice A (#296, docs/plans/control-plane.md): fixture shape +
//  determinism, alias stability, launch-flag / route parsing, snapshot redaction, and the state.json
//  shape. In-process through the real stores + `FakePhotoLibrary`; every async step awaits the real
//  work (no fixed sleeps).
//

import Testing
import Foundation
import SwiftData
import Curation
@testable import PoimiApp

/// One fixture wired the way a control launch wires it — the real stores over an in-memory container.
@MainActor
private struct ControlHarness {
    let fixture: ControlFixture
    let container: ModelContainer
    let library: FakePhotoLibrary
    let projects: ProjectStore
    let selection: SelectionStore
    let done: DoneStore
    let coordinator: AppCoordinator
    let albums: ControlAlbumAliases
    let assets: ControlAssetAliases
    let created: [CurationProject]

    init(_ fixture: ControlFixture) throws {
        self.fixture = fixture
        container = try AppModelContainer.make(inMemory: true)
        library = fixture.makeLibrary()
        projects = ProjectStore(container: container, now: monotonicClock())
        selection = SelectionStore(container: container, debounce: .seconds(60))
        done = DoneStore(container: container, debounce: .seconds(60))
        coordinator = AppCoordinator(library: library)
        albums = ControlAlbumAliases(fileURL: nil)
        assets = ControlAssetAliases(assets: fixture.assets)
        created = fixture.seed(projects: projects, selection: selection, done: done)
        for project in created { albums.alias(for: project.id) }
    }

    func inputs(bootstrapped: Bool = true) -> ControlSnapshotInputs {
        ControlSnapshotInputs(fixture: fixture, coordinator: coordinator, projects: projects,
                              selection: selection, done: done, assetAliases: assets, albumAliases: albums,
                              launchError: nil, bootstrapped: bootstrapped, idiom: "phone", timeZone: "UTC")
    }

    /// Route to `album-1`'s review and run its scan the way `ScanningView`'s `.task` does.
    func openReview() async throws {
        let project = try #require(created.first)
        coordinator.openProject(project.id)
        coordinator.openReview(project.id)
        selection.activate(project)
        done.activate(project)
        let store = coordinator.candidateStore(for: project) {
            CandidateStore(library: library, calendar: utcCalendar(), naming: FakePlaceNaming(),
                           nameCache: NameCacheStore(modelContainer: container))
        }
        await store.load(project)
        await store.awaitPendingNames()
    }

    /// Both snapshot files, serialized exactly as the runtime writes them.
    func serializedSnapshots() -> [String] {
        let state = ControlSnapshot.stamped(ControlSnapshot.content(inputs()), run: "r-test", rev: 1)
        let detail = ControlSnapshot.stamped(ControlSnapshot.detail(inputs()), run: "r-test", rev: 1)
        return [state, detail].map { String(bytes: $0.serialized(), encoding: .utf8) ?? "" }
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

    @Test("every fixture seeds the same albums and library twice", arguments: ControlFixture.allCases)
    func deterministic(_ fixture: ControlFixture) throws {
        let first = try ControlHarness(fixture)
        let second = try ControlHarness(fixture)
        #expect(first.created.map(SeededAlbum.init) == second.created.map(SeededAlbum.init))
        #expect(fixture.assets == fixture.assets)
        #expect(first.assets == second.assets)
        // The stores are handed back released, like a cold launch.
        #expect(!first.selection.isActive)
        #expect(!first.done.isActive)
    }

    @Test("fixture shapes: authorization, album count, statuses")
    func shapes() async throws {
        for fixture in [ControlFixture.fresh, .denied] {
            let harness = try ControlHarness(fixture)
            #expect(harness.created.isEmpty)
            await harness.coordinator.refreshAuthorization()
            #expect(harness.coordinator.rootPhase == (fixture == .fresh ? .onboarding : .recovery))
        }
        // Each harness is held in a local: it owns the container, and a model outliving it traps.
        #expect(ControlFixture.emptyLibrary.assets.isEmpty)
        let empty = try ControlHarness(.emptyLibrary)
        #expect(empty.created.count == 1)
        let one = try ControlHarness(.oneAlbum)
        #expect(one.created.map(\.status) == [.empty])

        let four = try ControlHarness(.fourStatuses)
        #expect(four.created.map(\.status) == [.exported, .editedSinceExport(toAdd: 3), .inProgress, .empty])

        let midHarness = try ControlHarness(.midReview)
        let mid = try #require(midHarness.created.first)
        #expect(mid.persistedPickedCount == 34)
        #expect(mid.doneDays == ControlFixture.yearDays.prefix(4).map(\.description))
        #expect(mid.status == .inProgress)

        let exportedHarness = try ControlHarness(.exported)
        let exported = try #require(exportedHarness.created.first)
        #expect(exported.status == .exported)
        #expect(exported.doneDays.count == ControlFixture.yearDays.count)
        #expect(exported.targetAlbumID == ControlFixture.exportedPhotosAlbum.id)

        #expect(ControlFixture.scale.assets.count == 10_000)
        let scale = try ControlHarness(.scale)
        #expect(scale.created.first?.persistedPickedCount == 200)
    }

    @Test("the exported fixture re-exports into its Photos album with nothing to add")
    func exportedReExports() async throws {
        let harness = try ControlHarness(.exported)
        let project = try #require(harness.created.first)
        let result = try await harness.library.export(
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
    func albumAliasesStable() throws {
        func titles(_ harness: ControlHarness) -> [String: String] {
            Dictionary(uniqueKeysWithValues: harness.created.map { (harness.albums.alias(for: $0.id), $0.title) })
        }
        let first = try ControlHarness(.fourStatuses)
        let second = try ControlHarness(.fourStatuses)
        #expect(titles(first) == titles(second))
        #expect(Set(titles(first).keys) == ["album-1", "album-2", "album-3", "album-4"])
    }

    @Test("album aliases are monotonic, never reused, and persist across a reload")
    func albumAliasesMonotonic() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("control-aliases-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let first = UUID(), second = UUID(), third = UUID()
        let registry = ControlAlbumAliases(fileURL: file)
        #expect(registry.alias(for: first) == "album-1")
        #expect(registry.alias(for: second) == "album-2")
        #expect(registry.alias(for: first) == "album-1")
        // A reload (the next launch) keeps the table and the counter — `second` may be deleted, but
        // its number is never handed out again.
        let reloaded = ControlAlbumAliases(fileURL: file)
        #expect(reloaded.projectID(for: "album-2") == second)
        #expect(reloaded.alias(for: third) == "album-3")
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

    @Test("no localIdentifier, title, place name or project id in any fixture's snapshot",
          arguments: ControlFixture.allCases)
    func redaction(_ fixture: ControlFixture) async throws {
        let harness = try ControlHarness(fixture)
        await harness.coordinator.refreshAuthorization()
        if !harness.created.isEmpty, fixture.authorization == .authorized {
            try await harness.openReview()
        }
        let strings = try harness.serializedSnapshots().flatMap(Self.allStrings)
        let assetIDs = Set(fixture.assets.map(\.id))
        let titles = harness.created.map(\.title) + fixture.photosAlbums.map(\.title)
        let projectIDs = Set(harness.created.map(\.id.uuidString))
        // Every place name the fake geocoder can produce.
        let places = ["Testby", "Fakenäs", "Mockala", "Dummeberg", "Sampleton", "Placeholmen",
                      "Nowheresund", "Faketon"]
        for string in strings {
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
        let harness = try ControlHarness(.midReview)
        await harness.coordinator.refreshAuthorization()
        try await harness.openReview()
        let state = try #require(try Self.parse(harness.serializedSnapshots()[0]) as? [String: Any])
        #expect(Set(state.keys) == ["snapshotVersion", "run", "rev", "app", "nav", "albums", "active",
                                    "pending", "idle"])
        #expect(state["snapshotVersion"] as? Int == 1)
        #expect(state["idle"] as? Bool == true)

        let app = try #require(state["app"] as? [String: Any])
        #expect(app["rootPhase"] as? String == "albums")
        #expect(app["fixture"] as? String == "mid-review")
        #expect(app["launchError"] is NSNull)

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
        #expect(pending["selectionFlush"] is NSNull)   // unobservable until slice B — null, not a guess

        // The detail file: the active album's days, aliases only, picks as a subset of the day's photos.
        let detail = try #require(try Self.parse(harness.serializedSnapshots()[1]) as? [String: Any])
        let days = try #require(detail["days"] as? [String: [String: Any]])
        #expect(days.count == ControlFixture.yearDays.count)
        let first = try #require(days[ControlFixture.yearDays[0].description])
        #expect(first["done"] as? Bool == true)
        let photos = try #require(first["photos"] as? [String])
        let picked = try #require(first["picked"] as? [String])
        #expect(Set(picked).isSubset(of: photos))
        #expect(photos.first == "a-0001")
    }

    @Test("idle waits for the bootstrap and for the review scan the route needs")
    func idle() async throws {
        let harness = try ControlHarness(.oneAlbum)
        await harness.coordinator.refreshAuthorization()
        #expect(ControlSnapshot.content(harness.inputs(bootstrapped: false))["idle"] == .bool(false))
        #expect(ControlSnapshot.content(harness.inputs())["idle"] == .bool(true))   // the album list
        let project = try #require(harness.created.first)
        harness.coordinator.openProject(project.id)
        harness.coordinator.openReview(project.id)
        // The route landed but the grid hasn't started its scan yet → not idle.
        #expect(ControlSnapshot.content(harness.inputs())["idle"] == .bool(false))
        try await harness.openReview()
        #expect(ControlSnapshot.content(harness.inputs())["idle"] == .bool(true))
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

    private static func parse(_ text: String) throws -> Any {
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
