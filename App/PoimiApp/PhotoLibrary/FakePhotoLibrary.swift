//
//  FakePhotoLibrary.swift
//  PoimiApp — deterministic test double for the photo library (issue #21).
//
//  A deterministic, in-memory `PhotoLibraryProviding` for SwiftUI previews, debug runs
//  (swapped in via the `-PoimiUseFakeLibrary` launch arg — see `PhotoLibraryProvider`), and
//  the Phase-2 integration tier. It **never ships**: the whole file is `#if DEBUG`, so it is
//  absent from release builds (D30, enforced by Scripts/check-fake-release-isolation.sh).
//
//  Phase-1 surface is minimal — one `.authorized` seed. The harder capabilities the test
//  tier will need (mutate-and-notify, deterministic progressive image delivery, the other
//  permission states, access-counting, 10k-scale seeds) grow in Phase 2 alongside the
//  features that consume them, each landing with a test (D25).
//
#if DEBUG

import Foundation
import Curation

/// In-memory fake. An `actor`, like `SystemPhotoLibrary`, so it honors the same isolation
/// the real implementation does (D25) and is trivially `Sendable`.
actor FakePhotoLibrary: PhotoLibraryProviding {
    private let seededAssets: [AssetRef]
    private let seededAlbums: [AlbumRef]
    /// Album id → the asset ids it contains, so the exclude-album filter can be exercised (D25).
    private let membership: [String: Set<String>]
    private var status: LibraryAuthorization
    /// Albums created by `export` (in-memory) — id → (name, member ids). Models the create-or-find +
    /// dupe-guard so the export flow is deterministic for tests + screenshots (#39).
    private var exportedAlbums: [String: (name: String, ids: Set<String>)] = [:]
    private var exportSeq = 0

    init(
        assets: [AssetRef] = FakePhotoLibrary.yearMixedSeed(),
        albums: [AlbumRef] = FakePhotoLibrary.defaultAlbums,
        membership: [String: Set<String>] = FakePhotoLibrary.defaultMembership,
        status: LibraryAuthorization = .authorized
    ) {
        self.seededAssets = assets
        self.seededAlbums = albums
        self.membership = membership
        self.status = status
    }

    func authorizationStatus() async -> LibraryAuthorization { status }

    func requestAuthorization() async -> LibraryAuthorization { status }

    /// Change the reported authorization mid-test — to exercise a transition (e.g. the user
    /// granting access at the system prompt: `.notDetermined` → `.authorized`).
    func setAuthorization(_ newStatus: LibraryAuthorization) {
        status = newStatus
    }

    func fetchAssets(in interval: DateInterval) async throws -> [AssetRef] {
        // SHARED CONTRACT with SystemPhotoLibrary (the conformance invariant, D24): a bounded
        // interval fetch returns only **dated** assets in `[start, end)`, oldest → newest.
        // A nil-`creationDate` (undated) asset is NOT matched by PhotoKit's range predicate,
        // so it isn't returned here either — undated assets reach the "Undated" section via a
        // separate path in Phase 2, never through a range fetch.
        seededAssets
            .filter { asset in
                guard let date = asset.captureDate else { return false }
                return date >= interval.start && date < interval.end
            }
            .sorted { ($0.captureDate ?? .distantPast) < ($1.captureDate ?? .distantPast) }
    }

    func albums() async throws -> [AlbumRef] { seededAlbums }

    func assetIDs(inAlbums albumIDs: [String]) async throws -> Set<String> {
        albumIDs.reduce(into: Set<String>()) { $0.formUnion(membership[$1] ?? []) }
    }

    func export(assetIDs: Set<String>, toAlbumNamed name: String,
                existingAlbumID: String?) async throws -> ExportResult {
        // Match SystemPhotoLibrary: creating/modifying an album needs FULL access (`.limited` can't).
        guard status == .authorized else { throw ExportError.notAuthorized }
        // Resolve against the seed (mirrors SystemPhotoLibrary fetching live PHAssets by id).
        let resolved = assetIDs.intersection(Set(seededAssets.map(\.id)))
        guard !resolved.isEmpty else { throw ExportError.noAssetsResolved }

        let albumID: String
        if let existing = existingAlbumID {
            // A valid target is one we exported before OR a pre-existing album the user chose at setup
            // (a seeded album, with its current membership). Only a truly unknown id is `.albumMissing`.
            if exportedAlbums[existing] == nil {
                guard seededAlbums.contains(where: { $0.id == existing }) else {
                    throw ExportError.albumMissing
                }
                exportedAlbums[existing] = (name, membership[existing] ?? [])
            }
            albumID = existing
        } else {
            exportSeq += 1
            albumID = "album/exported/\(exportSeq)"
            exportedAlbums[albumID] = (name, [])
        }
        let added = resolved.subtracting(exportedAlbums[albumID]!.ids)   // dupe guard
        exportedAlbums[albumID]!.ids.formUnion(added)
        return ExportResult(albumID: albumID, added: added.count, total: exportedAlbums[albumID]!.ids.count)
    }

    /// Test/debug peek at a created album's membership (the export write isn't observable otherwise).
    func exportedAssetIDs(inAlbum albumID: String) -> Set<String> {
        exportedAlbums[albumID]?.ids ?? []
    }
}

extension FakePhotoLibrary {
    static let defaultAlbums: [AlbumRef] = [
        // Regular user albums only — SystemPhotoLibrary enumerates `.albumRegular`, so smart
        // albums (Screenshots, Recents) don't appear; the fake matches that. `count: nil` too,
        // since the real impl doesn't populate counts yet (no fake-vs-real drift).
        AlbumRef(id: "album/whatsapp", title: "WhatsApp", count: nil),
        AlbumRef(id: "album/downloads", title: "Downloads", count: nil)
    ]

    /// Two busy-day assets also live in the WhatsApp album, so excluding it drops exactly them —
    /// enough to exercise the exclude-album set-difference (D25).
    static let defaultMembership: [String: Set<String>] = [
        "album/whatsapp": ["fake/busy/0", "fake/busy/1"]
    ]

    // MARK: - Canonical named seeds (D25)

    /// The default year-shaped, authorized library.
    static func yearMixed() -> FakePhotoLibrary {
        FakePhotoLibrary(assets: yearMixedSeed(), albums: defaultAlbums,
                         membership: defaultMembership, status: .authorized)
    }

    /// An authorized but empty library (drives the empty states).
    static func empty() -> FakePhotoLibrary {
        // Explicitly membership-free: no albums means no membership (the default would otherwise
        // reference a WhatsApp album this library doesn't vend).
        FakePhotoLibrary(assets: [], albums: [], membership: [:], status: .authorized)
    }

    /// Limited-access state (drives the limited recovery flow).
    static func limited() -> FakePhotoLibrary {
        FakePhotoLibrary(assets: yearMixedSeed(), albums: defaultAlbums,
                         membership: defaultMembership, status: .limited)
    }

    /// A scale seed: `count` dated assets spread across the year — for the D29 scale check.
    /// (`AllICloudOptimized` and progressive-delivery seeds arrive with the image-loading
    /// surface in a later Phase-2 issue, D25.)
    static func scale(_ count: Int = 10_000) -> FakePhotoLibrary {
        // No membership: the scale seed's ids don't intersect the canonical WhatsApp members.
        FakePhotoLibrary(assets: scaleSeed(count), albums: defaultAlbums,
                         membership: [:], status: .authorized)
    }

    /// A tiny year-shaped seed: a busy day (12 photos), a 3-day quiet run, a screenshot, and
    /// one undated asset — enough to exercise grouping, the screenshot filter, and the
    /// undated bucket. The full `YearMixed2025` / scale seeds arrive in Phase 2 (D25).
    static func yearMixedSeed() -> [AssetRef] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
            calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
        }

        var assets: [AssetRef] = []
        for index in 0..<12 {                       // busy day: 12 photos on 2025-07-05
            assets.append(AssetRef(
                id: "fake/busy/\(index)",
                captureDate: date(2025, 7, 5, index),
                pixelSize: PixelSize(width: 4032, height: 3024)))
        }
        for day in 16...18 {                        // quiet run: one each, 2025-03-16…18
            assets.append(AssetRef(id: "fake/quiet/\(day)", captureDate: date(2025, 3, day)))
        }
        assets.append(AssetRef(id: "fake/shot", captureDate: date(2025, 4, 1), isScreenshot: true))
        assets.append(AssetRef(id: "fake/undated", captureDate: nil))
        return assets
    }

    /// A spread-out year of clusters (Feb → Nov, varying sizes) for eyeballing the cluster-index
    /// Overview (#37, design 3BL): enough day-clusters across enough months that the bar chart reads
    /// as a real year skyline and the month sections stack. Ids are `fake/ov/<month>-<day>-<i>` so the
    /// screenshot host can pick / mark-done specific clusters to show all three states.
    static func overviewSeed() -> [AssetRef] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        // Midday, so a UTC-anchored seed rendered under the viewer's `.current` calendar never rolls a
        // photo across midnight into the next day (which would split one cluster into two).
        func date(_ month: Int, _ day: Int) -> Date {
            calendar.date(from: DateComponents(year: 2025, month: month, day: day, hour: 12))!
        }
        var assets: [AssetRef] = []
        func cluster(_ month: Int, _ day: Int, _ count: Int) {
            for index in 0..<count {
                assets.append(AssetRef(id: "fake/ov/\(month)-\(day)-\(index)",
                                       captureDate: date(month, day),
                                       pixelSize: PixelSize(width: 4032, height: 3024)))
            }
        }
        // Every month populated (a realistic full year), so the coverage chart is 12 even bars.
        cluster(1, 15, 20)   // Jan
        cluster(2, 1, 47)    // Feb 1  (done)
        cluster(2, 8, 31)    // Feb 8  (done)
        cluster(2, 14, 62)   // Feb 14 (in-progress)
        cluster(3, 1, 24)    // Mar
        cluster(3, 9, 18)    // Mar
        cluster(4, 12, 15)   // Apr
        cluster(5, 10, 40)   // May    (in-progress)
        cluster(6, 8, 28)    // Jun
        cluster(7, 4, 55)    // Jul
        cluster(7, 5, 44)    // Jul
        cluster(8, 22, 33)   // Aug
        cluster(9, 20, 22)   // Sep
        cluster(10, 5, 19)   // Oct
        cluster(11, 3, 16)   // Nov
        cluster(12, 20, 26)  // Dec
        return assets
    }

    /// A SHORT album (~5 weeks, one summer) for eyeballing the coverage chart's minimum-bucket floor:
    /// the calendar unit (weekly) would give only ~5 bars, so the chart falls back to 8 equal day-slices.
    /// Ids are `fake/kesa/<month>-<day>-<i>`.
    static func overviewShortSeed() -> [AssetRef] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        func date(_ month: Int, _ day: Int) -> Date {
            calendar.date(from: DateComponents(year: 2025, month: month, day: day, hour: 12))!
        }
        var assets: [AssetRef] = []
        func cluster(_ month: Int, _ day: Int, _ count: Int) {
            for index in 0..<count {
                assets.append(AssetRef(id: "fake/kesa/\(month)-\(day)-\(index)",
                                       captureDate: date(month, day),
                                       pixelSize: PixelSize(width: 4032, height: 3024)))
            }
        }
        cluster(6, 1, 30)     // Jun 1
        cluster(6, 4, 12)     // Jun 4
        cluster(6, 11, 20)    // Jun 11
        cluster(6, 18, 41)    // Jun 18
        cluster(6, 25, 25)    // Jun 25
        cluster(7, 2, 18)     // Jul 2  → span ~31 days → weekly ≈ 5 bars → floors to 8
        return assets
    }

    /// `count` dated assets spread evenly across 2025, oldest → newest (all within the year,
    /// so a year-range fetch returns the whole set).
    static func scaleSeed(_ count: Int) -> [AssetRef] {
        let start = Date(timeIntervalSince1970: 1_735_689_600)   // 2025-01-01T00:00:00Z
        let secondsInYear: TimeInterval = 365 * 24 * 3600
        let spacing = count > 1 ? secondsInYear / Double(count) : 0
        return (0..<count).map { index in
            AssetRef(
                id: "fake/scale/\(index)",
                captureDate: start.addingTimeInterval(Double(index) * spacing),
                pixelSize: PixelSize(width: 4032, height: 3024))
        }
    }
}

#endif
