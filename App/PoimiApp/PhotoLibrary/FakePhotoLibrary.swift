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
    private var status: LibraryAuthorization

    init(
        assets: [AssetRef] = FakePhotoLibrary.yearMixedSeed(),
        albums: [AlbumRef] = FakePhotoLibrary.defaultAlbums,
        status: LibraryAuthorization = .authorized
    ) {
        self.seededAssets = assets
        self.seededAlbums = albums
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
}

extension FakePhotoLibrary {
    static let defaultAlbums: [AlbumRef] = [
        // `count: nil` to match SystemPhotoLibrary, which doesn't populate counts yet — so
        // designs/screenshots validated against the fake match the real app (no phantom counts).
        AlbumRef(id: "album/screenshots", title: "Screenshots", count: nil),
        AlbumRef(id: "album/whatsapp", title: "WhatsApp", count: nil)
    ]

    // MARK: - Canonical named seeds (D25)

    /// The default year-shaped, authorized library.
    static func yearMixed() -> FakePhotoLibrary {
        FakePhotoLibrary(assets: yearMixedSeed(), albums: defaultAlbums, status: .authorized)
    }

    /// An authorized but empty library (drives the empty states).
    static func empty() -> FakePhotoLibrary {
        FakePhotoLibrary(assets: [], albums: [], status: .authorized)
    }

    /// Limited-access state (drives the limited recovery flow).
    static func limited() -> FakePhotoLibrary {
        FakePhotoLibrary(assets: yearMixedSeed(), albums: defaultAlbums, status: .limited)
    }

    /// A scale seed: `count` dated assets spread across the year — for the D29 scale check.
    /// (`AllICloudOptimized` and progressive-delivery seeds arrive with the image-loading
    /// surface in a later Phase-2 issue, D25.)
    static func scale(_ count: Int = 10_000) -> FakePhotoLibrary {
        FakePhotoLibrary(assets: scaleSeed(count), albums: defaultAlbums, status: .authorized)
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
