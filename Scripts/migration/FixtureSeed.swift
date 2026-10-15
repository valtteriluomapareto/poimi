// Appended to the historical test target by generate-migration-fixture.py.
// Production models, schema and application sources are never patched.
import Testing
import SwiftData
import Curation
import CryptoKit
@testable import PoimiApp

@MainActor
@Suite("Historical migration fixture generator")
struct MigrationFixtureSeed {
    @Test func seed() throws {
        let files = FileManager.default
        let root = files.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MigrationFixture", isDirectory: true)
        let storeDirectory = root.appendingPathComponent("Store", isDirectory: true)
        try files.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        let configuration = ModelConfiguration(schema: AppModelContainer.schema,
                                               url: storeDirectory.appendingPathComponent("default.store"))
        let container = try ModelContainer(for: AppModelContainer.schema, configurations: configuration)
        container.mainContext.autosaveEnabled = false
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let start = Date(timeIntervalSince1970: 1_735_689_600)
        let end = Date(timeIntervalSince1970: 1_767_225_600)
        let stamp = Date(timeIntervalSince1970: 1_750_000_000)
        // Above the external-storage threshold on the recorded runtime. The export script verifies
        // actual external files by hash; a threshold change must fail generation, not shrink coverage.
        let padding = (0..<20_000).map {
            String(format: "fixture-photo-%05d-", $0) + String(repeating: "x", count: 64)
        }
        var expected: [[String: Any]] = []
        for (index, videos) in [false, true].enumerated() {
            let picks: Set<String> = videos ? ["photo-1", "video-1"] : ["photo-1", "photo-next"]
            let snapshot = try SelectionSnapshot(assetIDs: picks).encoded()
            let reviewed = padding + (videos ? ["photo-1", "video-1"] : ["photo-1"])
            let baseline = try encoder.encode([
                "2025-07-05": reviewed, "2025-07-06": ["photo-next"], "undated": ["undated-photo"]
            ])
            let project = CurationProject(
                id: UUID(uuidString: "00000000-0000-4000-8000-00000000000\(index + 1)")!,
                title: videos ? "Historical photos and videos" : "Historical photos",
                rangeStart: start, rangeEnd: end, targetCount: 50 + index,
                excludeScreenshots: !videos, excludedAlbumIDs: ["excluded-\(index)"],
                locationEnabled: videos, includeVideos: videos, targetAlbumID: "exported-album-\(index)",
                selectionSnapshot: snapshot, doneDays: ["2025-07-05", "2025-07-06", "undated"],
                reviewedIDsByDay: baseline, resumeDayKey: "2025-07-06", lastViewedAssetID: "photo-next",
                markedDoneAt: stamp, exportedSelectionSnapshot: snapshot, exportedPhotoCount: picks.count,
                lastExportedAt: stamp.addingTimeInterval(60), createdAt: start, lastOpenedAt: stamp)
            container.mainContext.insert(project)
            expected.append([
                "id": project.id.uuidString, "title": project.title,
                "rangeStart": start.timeIntervalSince1970, "rangeEnd": end.timeIntervalSince1970,
                "targetCount": project.targetCount, "excludeScreenshots": project.excludeScreenshots,
                "excludedAlbumIDs": project.excludedAlbumIDs, "locationEnabled": videos,
                "includeVideos": videos, "targetAlbumID": project.targetAlbumID!,
                "selectionSnapshot": snapshot.base64EncodedString(), "picks": picks.sorted(),
                "doneDays": project.doneDays, "resumeDayKey": project.resumeDayKey!,
                "lastViewedAssetID": project.lastViewedAssetID!, "markedDoneAt": stamp.timeIntervalSince1970,
                "exportedSelectionSnapshot": snapshot.base64EncodedString(), "exportedPhotoCount": picks.count,
                "lastExportedAt": stamp.addingTimeInterval(60).timeIntervalSince1970,
                "createdAt": start.timeIntervalSince1970, "lastOpenedAt": stamp.timeIntervalSince1970,
                "baselineSHA256": SHA256.hash(data: baseline).map { String(format: "%02x", $0) }.joined(),
                "baselineIDCount": reviewed.count + 2
            ])
        }
        let place = GeocodedPlaceName(cellKey: "60.170,24.940", name: "Fixture Helsinki", fetchedAt: stamp)
        container.mainContext.insert(place)
        try container.mainContext.save()
        let manifest: [String: Any] = [
            "albums": expected,
            "places": [["cellKey": place.cellKey, "name": place.name, "fetchedAt": stamp.timeIntervalSince1970]],
            "baselineRecipe": ["paddingCount": padding.count, "paddingSuffixLength": 64,
                               "day": "2025-07-05", "otherDays": ["2025-07-06", "undated"]]
        ]
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("manifest.json"))
        #expect(try container.mainContext.fetchCount(FetchDescriptor<CurationProject>()) == 2)
    }
}
