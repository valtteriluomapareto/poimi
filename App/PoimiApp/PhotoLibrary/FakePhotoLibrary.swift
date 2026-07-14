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
    /// When set, `fetchAssets` throws it — so the scan-failure path (`CandidateStore.failed`) is
    /// reachable in tests/harness. Combined with a non-`.authorized` `status` it models access
    /// revoked mid-session (the `.accessLost` reason); with `.authorized`, a transient load error.
    private let fetchError: (any Error)?
    /// Albums created by `export` (in-memory) — id → (name, member ids). Models the create-or-find +
    /// dupe-guard so the export flow is deterministic for tests + screenshots (#39).
    private var exportedAlbums: [String: (name: String, ids: Set<String>)] = [:]
    private var exportSeq = 0

    init(
        assets: [AssetRef] = FakePhotoLibrary.yearMixedSeed(),
        albums: [AlbumRef] = FakePhotoLibrary.defaultAlbums,
        membership: [String: Set<String>] = FakePhotoLibrary.defaultMembership,
        status: LibraryAuthorization = .authorized,
        fetchError: (any Error)? = nil
    ) {
        self.seededAssets = assets
        self.seededAlbums = albums
        self.membership = membership
        self.status = status
        self.fetchError = fetchError
    }

    /// A generic fetch failure the fake can be seeded to throw (transient load error / lost access).
    enum FakeError: Error { case fetchFailed }

    func authorizationStatus() async -> LibraryAuthorization { status }

    func requestAuthorization() async -> LibraryAuthorization { status }

    /// Change the reported authorization mid-test — to exercise a transition (e.g. the user
    /// granting access at the system prompt: `.notDetermined` → `.authorized`).
    func setAuthorization(_ newStatus: LibraryAuthorization) {
        status = newStatus
    }

    func fetchAssets(in interval: DateInterval) async throws -> [AssetRef] {
        if let fetchError { throw fetchError }   // seeded failure → exercises the scan-error path
        // SHARED CONTRACT with SystemPhotoLibrary (the conformance invariant, D24): a bounded
        // interval fetch returns only **dated** assets in `[start, end)`, oldest → newest.
        // A nil-`creationDate` (undated) asset is NOT matched by PhotoKit's range predicate,
        // so it isn't returned here either — undated assets reach the "Undated" section via a
        // separate path in Phase 2, never through a range fetch.
        return seededAssets
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
                guard let seeded = seededAlbums.first(where: { $0.id == existing }) else {
                    throw ExportError.albumMissing
                }
                // Seeded album's OWN title, not `name` (the project title) — mirrors the real impl's
                // `collection.localizedTitle`, so the #193 divergence is real in the double (#193).
                exportedAlbums[existing] = (seeded.title, membership[existing] ?? [])
            }
            albumID = existing
        } else {
            exportSeq += 1
            albumID = "album/exported/\(exportSeq)"
            exportedAlbums[albumID] = (name, [])   // created with `name` → that's its title
        }
        let added = resolved.subtracting(exportedAlbums[albumID]!.ids)   // dupe guard
        exportedAlbums[albumID]!.ids.formUnion(added)
        return ExportResult(albumID: albumID, added: added.count,
                            total: exportedAlbums[albumID]!.ids.count, title: exportedAlbums[albumID]!.name)
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

    /// The year-shaped library plus two videos — the authorized fixture for the include-videos path (#125).
    static func videoMixed() -> FakePhotoLibrary {
        FakePhotoLibrary(assets: videoMixedSeed(), albums: defaultAlbums,
                         membership: defaultMembership, status: .authorized)
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

    /// `yearMixedSeed` plus videos (dated, in range) — the fixture for the include-videos path (#125).
    /// Kept SEPARATE from `yearMixedSeed()` on purpose: the many exact-count/id assertions against that
    /// seed must not churn. Durations are literal constants (no clock / randomness, D25). A video ⇒
    /// non-nil positive duration, a still ⇒ nil duration (the media-type conformance contract).
    static func videoMixedSeed() -> [AssetRef] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
            calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
        }
        var assets = yearMixedSeed()
        assets.append(AssetRef(id: "fake/video/1", captureDate: date(2025, 7, 5, 13),
                               pixelSize: PixelSize(width: 1920, height: 1080), isVideo: true, duration: 14))
        assets.append(AssetRef(id: "fake/video/2", captureDate: date(2025, 7, 6),
                               pixelSize: PixelSize(width: 1280, height: 720), isVideo: true, duration: 9))
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

    /// A synthetic **located** year with *planted trips*, for the interactive location-clustering
    /// probe (issue #133 / spike #129). It is the app-tier port of `CurationTests/PlantedSeed`: a dense
    /// **home base** (Helsinki) across most of the year, a **multi-city foreign trip** (Rome / Florence /
    /// Venice — three place clusters, one contiguous trip), a **weekend city trip** (Stockholm),
    /// **fly-home-between-two-trips** (Paris → one home day → London), an **antimeridian** cluster (Fiji,
    /// straddling ±180°), the **concurrent-location** family case (Barcelona on home days), plus
    /// **null-island `(0,0)`** and **dated-but-no-GPS** edge assets that must route to no-location. All
    /// jitter is a deterministic SplitMix64 (`SpikeSeedRNG`) so the field — and therefore the probe's
    /// clusters, trips, and screenshot — is byte-stable run-to-run (never `Date.now`/`arc4random`).
    ///
    /// Ground truth (the pre-registration anchor, `docs/plans/location-spike-preregistration.md`): the
    /// six planted trips above + Helsinki home. Undated assets are omitted here because a range fetch
    /// (the probe's load path, mirroring PhotoKit) never returns them; the no-location bucket the probe
    /// shows is therefore the null-island + dated-no-GPS assets, which a range fetch *does* return.
    static func locationSpikeSeed() -> [AssetRef] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let base = calendar.date(from: DateComponents(year: 2025, month: 1, day: 1, hour: 12))!
        func date(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: base)! }

        var rng = SpikeSeedRNG(seed: 0x50A1)
        func jitter(_ span: Double) -> Double { Double.random(in: -span...span, using: &rng) }

        // `perDay` jittered located photos on each day offset, within ~±`span`° of `centre`.
        func place(_ prefix: String, _ lat: Double, _ lon: Double,
                   offsets: [Int], perDay: Int, span: Double = 0.02) -> [AssetRef] {
            var out: [AssetRef] = []
            for offset in offsets {
                for shot in 0..<perDay {
                    out.append(AssetRef(
                        id: "fake/spike/\(prefix)-\(offset)-\(shot)",
                        captureDate: date(offset),
                        coordinate: Coordinate(latitude: lat + jitter(span), longitude: lon + jitter(span)),
                        pixelSize: PixelSize(width: 4032, height: 3024)))
                }
            }
            return out
        }

        // Trip day windows (offsets from Jan 1). Barcelona's even offsets deliberately coincide with
        // home days (the concurrent case); day 123 is a HOME day wedged between Paris (120–122) and
        // London (124–126) so the run breaks into two trips.
        let stockholm = [60, 61]
        let italy = [90, 91, 92, 93, 94, 95]            // Rome 90–92, Florence 93–94, Venice 95
        let paris = [120, 121, 122]
        let london = [124, 125, 126]
        let fiji = [150, 151, 152]
        let barcelona = [180, 182, 184]
        let flyHome = 123

        let tripWindow = Set(stockholm + italy + paris + london + fiji)
        var homeDays = stride(from: 0, through: 300, by: 2).filter { !tripWindow.contains($0) }
        homeDays.append(flyHome)

        var assets: [AssetRef] = []
        assets += place("home", 60.17, 24.94, offsets: homeDays, perDay: 3, span: 0.03)   // Helsinki
        assets += place("sto", 59.33, 18.07, offsets: stockholm, perDay: 8)               // Stockholm
        // Keep each Italian city above the adaptive minPts (~4 here) so all three cluster; Venice (6)
        // is the thinnest margin.
        assets += place("rom", 41.90, 12.50, offsets: [90, 91, 92], perDay: 7)            // Rome
        assets += place("flo", 43.77, 11.26, offsets: [93, 94], perDay: 6)               // Florence
        assets += place("ven", 45.44, 12.33, offsets: [95], perDay: 6)                   // Venice
        assets += place("par", 48.86, 2.35, offsets: paris, perDay: 7)                   // Paris
        assets += place("lon", 51.51, -0.13, offsets: london, perDay: 7)                 // London
        assets += place("bcn", 41.39, 2.17, offsets: barcelona, perDay: 8)              // Barcelona

        // Antimeridian: Fiji photos split half at +179.9x and half at −179.9x — genuinely across ±180°.
        for offset in fiji {
            for shot in 0..<6 {
                let lon = (shot % 2 == 0 ? 179.93 : -179.93) + jitter(0.02)
                assets.append(AssetRef(
                    id: "fake/spike/fij-\(offset)-\(shot)",
                    captureDate: date(offset),
                    coordinate: Coordinate(latitude: -17.0 + jitter(0.02), longitude: lon),
                    pixelSize: PixelSize(width: 4032, height: 3024)))
            }
        }

        // No-location edge assets (dated, so a range fetch returns them → they count as no-location).
        for i in 0..<8 {                                 // null-island (0,0) sentinels
            assets.append(AssetRef(id: "fake/spike/null-\(i)", captureDate: date(40 + i % 2),
                                   coordinate: Coordinate(latitude: 0, longitude: 0)))
        }
        for i in 0..<5 {                                 // dated but no GPS
            assets.append(AssetRef(id: "fake/spike/nogps-\(i)", captureDate: date(45 + i % 2)))
        }
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

/// A tiny seedable PRNG (SplitMix64) so `locationSpikeSeed`'s jitter is reproducible per seed —
/// the app-tier mirror of `CurationTests.SeededRNG` (no `Date.now`/`arc4random`, so the seeded
/// field is byte-stable across runs). Local to this DEBUG file, not a shipped utility.
struct SpikeSeedRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }
}

#endif
