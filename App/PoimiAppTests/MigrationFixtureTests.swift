import Foundation
import CryptoKit
import SwiftData
import Testing
import Curation
@testable import PoimiApp

@MainActor
@Suite("Historical store upgrade (#290)")
struct MigrationFixtureTests {
    @Test("1.0.2 albums survive automatic migration with their stored defaults and data intact")
    func preservation() throws {
        let fixture = try MigrationFixture()
        defer { fixture.remove() }
        try fixture.withContainer { container in
            try fixture.checkPreservation(in: container, legacy: true)
        }
        // The migrated columns and untouched blobs must survive a second, independent open too.
        try fixture.withContainer { container in
            try fixture.checkPreservation(in: container, legacy: true)
        }
    }

    @Test("activation immediately persists the historical lens, without reconciliation or a later flush",
          arguments: [false, true])
    func activationIsDurable(videos: Bool) throws {
        let fixture = try MigrationFixture()
        defer { fixture.remove() }
        try fixture.withContainer { container in
            let project = try fixture.album(in: container, videos: videos)
            let done = DoneStore(container: container)
            done.activate(project)
            let data = try #require(project.reviewedIDsByDay)
            let matchesHistoricalLens = ReviewBaseline.decodeKeyed(data) ==
                [project.media.rawValue: fixture.baseline(videos: videos)]
            #expect(matchesHistoricalLens,
                    "Activation must preserve and persist the baseline under its historical lens")
            // Intentionally no deactivate(), flushNow(), or context.save(): any of those could
            // conceal a missing save in activate(). Autosave is disabled by withContainer.
        }
        try fixture.withContainer { container in
            let project = try fixture.album(in: container, videos: videos)
            let data = try #require(project.reviewedIDsByDay)
            let matchesHistoricalLens = ReviewBaseline.decodeKeyed(data) ==
                [project.media.rawValue: fixture.baseline(videos: videos)]
            #expect(matchesHistoricalLens,
                    "Activation must preserve and persist the baseline under its historical lens")
            try fixture.checkPreservation(in: container, legacy: false)
        }
    }

    @Test("filter changes preserve upgraded done days before or after an unchanged first reconcile",
          arguments: [false, true], [false, true])
    func lensSwitch(videos: Bool, reconcileFirst: Bool) throws {
        let fixture = try MigrationFixture()
        defer { fixture.remove() }
        try fixture.withContainer { container in
            let project = try fixture.album(in: container, videos: videos)
            let originalLens = project.media
            let projects = ProjectStore(container: container)
            let done = DoneStore(container: container)
            done.activate(project)
            if reconcileFirst { done.reconcile(currentIDsByDay: fixture.baseline(videos: videos)) }
            project.media = videos ? .photosOnly : .photosAndVideos
            projects.saveEdits(to: project) // Leaving Settings persists its bound media edit.
            done.reconcile(currentIDsByDay: fixture.baseline(videos: !videos))
            #expect(done.doneDays == fixture.doneDays)
            project.media = originalLens
            projects.saveEdits(to: project)
            done.reconcile(currentIDsByDay: fixture.baseline(videos: videos))
            #expect(done.doneDays == fixture.doneDays)
            #expect(project.selectionSnapshot == fixture.expected(videos: videos).selectionSnapshot)
        }
        try fixture.withContainer { container in
            try fixture.checkPreservation(in: container, legacy: false)
            let project = try fixture.album(in: container, videos: videos)
            let data = try #require(project.reviewedIDsByDay)
            let keyed = try #require(ReviewBaseline.decodeKeyed(data))
            let matchesBothLenses = keyed == ["photosOnly": fixture.baseline(videos: false),
                                             "photosAndVideos": fixture.baseline(videos: true)]
            #expect(matchesBothLenses, "Each lens must retain its own complete baseline")
        }
    }

    @Test("a genuinely new candidate still reopens only its day after upgrade", arguments: [false, true])
    func newCandidate(videos: Bool) throws {
        let fixture = try MigrationFixture()
        defer { fixture.remove() }
        let day = DayKey.day(year: 2025, month: 7, day: 5)
        try fixture.withContainer { container in
            let project = try fixture.album(in: container, videos: videos)
            let done = DoneStore(container: container)
            done.activate(project)
            var current = fixture.baseline(videos: videos)
            current[day, default: []].insert("genuinely-new-photo")
            done.reconcile(currentIDsByDay: current)
            #expect(done.doneDays == fixture.doneDays.subtracting([day]))
        }
        try fixture.withContainer { container in
            let project = try fixture.album(in: container, videos: videos)
            #expect(Set(project.doneDays.compactMap(DayKey.init)) == fixture.doneDays.subtracting([day]))
            #expect(project.selectionSnapshot == fixture.expected(videos: videos).selectionSnapshot)
            #expect(project.status == .exported)
            let data = try #require(project.reviewedIDsByDay)
            let keyed = try #require(ReviewBaseline.decodeKeyed(data))
            #expect(keyed[project.media.rawValue]?[day]?.contains("genuinely-new-photo") == true)
        }
    }
}

private final class MigrationFixtureBundle: NSObject {}

private struct MigrationManifest: Decodable {
    struct Album: Decodable {
        let id: UUID
        let title: String
        let rangeStart: Double
        let rangeEnd: Double
        let targetCount: Int
        let excludeScreenshots: Bool
        let excludedAlbumIDs: [String]
        let locationEnabled: Bool
        let includeVideos: Bool
        let targetAlbumID: String
        let selectionSnapshot: Data
        let picks: Set<String>
        let doneDays: [String]
        let resumeDayKey: String
        let lastViewedAssetID: String
        let markedDoneAt: Double
        let exportedSelectionSnapshot: Data
        let exportedPhotoCount: Int
        let lastExportedAt: Double
        let createdAt: Double
        let lastOpenedAt: Double
        let baselineSHA256: String
        let baselineIDCount: Int
        let externalBaselineFile: String
    }
    struct Place: Decodable {
        let cellKey: String
        let name: String
        let fetchedAt: Double
    }
    let albums: [Album]
    let places: [Place]
    let filesSHA256: [String: String]
}

@MainActor
private final class MigrationFixture {

    let manifest: MigrationManifest
    private let root: URL
    let doneDays: Set<DayKey> = [.day(year: 2025, month: 7, day: 5),
                                .day(year: 2025, month: 7, day: 6), .undated]

    init() throws {
        let bundle = Bundle(for: MigrationFixtureBundle.self)
        let fixtures = try #require(bundle.url(forResource: "Fixtures", withExtension: nil))
        let source = fixtures.appendingPathComponent("1.0.2", isDirectory: true)
        manifest = try JSONDecoder().decode(MigrationManifest.self, from: Data(contentsOf:
            source.appendingPathComponent("manifest.json")))
        // Check the actual bundled files, including hidden external-storage directories. This fails
        // if Xcode packaging or a copy drops a blob, before SwiftData has any chance to hide the loss.
        for (path, digest) in manifest.filesSHA256 {
            #expect(Self.sha256(try Data(contentsOf: source.appendingPathComponent(path))) == digest)
        }
        for album in manifest.albums {
            #expect(manifest.filesSHA256[album.externalBaselineFile] == album.baselineSHA256)
        }
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.copyItem(at: source, to: root)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    func withContainer(_ body: (ModelContainer) throws -> Void) throws {
        try autoreleasepool {
            let configuration = ModelConfiguration(schema: AppModelContainer.schema,
                                                   url: root.appendingPathComponent("Store/default.store"))
            let container = try ModelContainer(for: AppModelContainer.schema, configurations: configuration)
            container.mainContext.autosaveEnabled = false
            try body(container)
        }
    }

    func expected(videos: Bool) -> MigrationManifest.Album {
        // Both fixture rows are required by checkPreservation; generation produces exactly this pair.
        manifest.albums.first { $0.includeVideos == videos }!
    }

    func album(in container: ModelContainer, videos: Bool) throws -> CurationProject {
        let id = expected(videos: videos).id
        let projects = try container.mainContext.fetch(FetchDescriptor<CurationProject>())
        return try #require(projects.first { $0.id == id })
    }

    func baseline(videos: Bool) -> ReviewBaseline.Days {
        // Independent recipe pins the historical blob contents, not just what the current decoder
        // happens to return. Matches the documented synthetic seed, including a real external blob.
        let padding = (0..<20_000).map {
            String(format: "fixture-photo-%05d-", $0) + String(repeating: "x", count: 64)
        }
        return [.day(year: 2025, month: 7, day: 5): Set(padding + (videos ? ["photo-1", "video-1"] : ["photo-1"])),
                .day(year: 2025, month: 7, day: 6): ["photo-next"], .undated: ["undated-photo"]]
    }

    func checkPreservation(in container: ModelContainer, legacy: Bool) throws {
        let projects = try container.mainContext.fetch(FetchDescriptor<CurationProject>())
        #expect(projects.count == 2)
        #expect(manifest.albums.count == 2)
        #expect(Set(manifest.albums.map(\.includeVideos)) == [false, true])
        #expect(Set(projects.map(\.id)) == Set(manifest.albums.map(\.id)))
        for expected in manifest.albums {
            let project = try #require(projects.first { $0.id == expected.id })
            #expect(project.title == expected.title)
            #expect(project.rangeStart.timeIntervalSince1970 == expected.rangeStart)
            #expect(project.rangeEnd.timeIntervalSince1970 == expected.rangeEnd)
            #expect(project.targetCount == expected.targetCount)
            #expect(project.excludeScreenshots == expected.excludeScreenshots)
            #expect(project.excludedAlbumIDs == expected.excludedAlbumIDs)
            #expect(project.locationEnabled == expected.locationEnabled)
            // Must assert the stored bool, not only media: (false, false) also decodes as photosOnly.
            #expect(project.includePhotos == true)
            #expect(project.includeVideos == expected.includeVideos)
            #expect(project.media == (expected.includeVideos ? .photosAndVideos : .photosOnly))
            #expect(project.targetAlbumID == expected.targetAlbumID)
            #expect(project.selectionSnapshot == expected.selectionSnapshot)
            #expect(project.persistedPicks == expected.picks)
            #expect(Set(project.doneDays) == Set(expected.doneDays))
            #expect(project.resumeDayKey == expected.resumeDayKey)
            #expect(project.lastViewedAssetID == expected.lastViewedAssetID)
            #expect(project.markedDoneAt?.timeIntervalSince1970 == expected.markedDoneAt)
            #expect(project.exportedSelectionSnapshot == expected.exportedSelectionSnapshot)
            #expect(project.exportedPicks == expected.picks)
            #expect(project.exportedPhotoCount == expected.exportedPhotoCount)
            #expect(project.lastExportedAt?.timeIntervalSince1970 == expected.lastExportedAt)
            #expect(project.createdAt.timeIntervalSince1970 == expected.createdAt)
            #expect(project.lastOpenedAt.timeIntervalSince1970 == expected.lastOpenedAt)
            #expect(project.status == .exported)
            if legacy {
                let data = try #require(project.reviewedIDsByDay)
                #expect(Self.sha256(data) == expected.baselineSHA256)
                let flat = try JSONDecoder().decode([String: Set<String>].self, from: data)
                #expect(flat.values.reduce(0) { $0 + $1.count } == expected.baselineIDCount)
                let recipe = baseline(videos: expected.includeVideos)
                let matchesRecipe = flat == Dictionary(uniqueKeysWithValues:
                    recipe.map { ($0.key.description, $0.value) })
                #expect(matchesRecipe, "The external legacy blob must contain every seeded candidate")
            }
        }
        let places = try container.mainContext.fetch(FetchDescriptor<GeocodedPlaceName>())
        #expect(places.count == manifest.places.count)
        for expected in manifest.places {
            let place = try #require(places.first { $0.cellKey == expected.cellKey })
            #expect(place.name == expected.name)
            #expect(place.fetchedAt.timeIntervalSince1970 == expected.fetchedAt)
        }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
