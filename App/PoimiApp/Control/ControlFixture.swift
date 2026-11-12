//
//  ControlFixture.swift
//  PoimiApp — named, deterministic starting states (#296, docs/plans/control-plane.md §4 slice A).
//
//  One enum shared by three callers: the control launch (`-PoimiFixture <name>`), the `DebugScreen`
//  hosts (`DebugShellView`'s four-album library), and the integration tests. Each fixture is a fake
//  library (assets + Photos albums + authorization) plus albums seeded through the public store APIs
//  — `ProjectStore.create`/`saveEdits`, `SelectionStore.select`, `DoneStore.toggle` — never by
//  writing SwiftData behind the stores' backs, so a fixture is a state the app itself can reach.
//
//  Deterministic by construction: fixed UTC dates, fixed ids, no clock or randomness in the seed.
//  DEBUG-only (D30).
//
#if DEBUG

import Foundation
import Curation

enum ControlFixture: String, CaseIterable, Sendable {
    /// First run: photo access not yet asked (`.notDetermined`) → onboarding. No albums.
    case fresh
    /// Photo access denied → the recovery screen. No albums.
    case denied
    /// Authorized, but the photo library is empty; one album, so its empty scan state is reachable.
    case emptyLibrary = "empty-library"
    /// Authorized, the year library, one untouched album.
    case oneAlbum = "one-album"
    /// The four album statuses side by side: exported (in sync), edited since export, in progress,
    /// not started. (The `shell` screenshot's library.)
    case fourStatuses = "four-statuses"
    /// One album part-way through review: 34 picks of a target of 80, the first four days done.
    case midReview = "mid-review"
    /// One album fully reviewed and exported, in sync with its Photos album.
    case exported
    /// One album over a 10,000-photo library (the D29 scale shape), 200 picks.
    case scale
    /// One album over a LOCATED library (the location-spike seed: a home base plus planted trips), so
    /// trips form and get (fake) place names — the redaction test's place-name half needs real names.
    case located
    /// An album carried over from before the per-lens done baseline (#273): the first four days done,
    /// their baseline in the old flat shape (photos only), and a video on the first done day — the
    /// #289 shape, where switching the media lens must not un-mark a done day that holds a video.
    case legacyBaseline = "legacy-baseline"

    /// The known names, for error messages.
    static var names: String { allCases.map(\.rawValue).joined(separator: ", ") }

    // MARK: - The library

    var authorization: LibraryAuthorization {
        switch self {
        case .fresh: .notDetermined
        case .denied: .denied
        default: .authorized
        }
    }

    /// The whole seeded library, in seed order (the asset-alias table is built from this).
    var assets: [AssetRef] {
        switch self {
        case .emptyLibrary: []
        case .scale: Self.scaleAssets
        case .located: Self.locatedAssets
        case .legacyBaseline: Self.yearAssets + [Self.legacyVideo]
        default: Self.yearAssets
        }
    }

    /// The user's Photos albums the fake vends (the exclude-picker / export destinations).
    var photosAlbums: [AlbumRef] {
        switch self {
        case .emptyLibrary: []
        case .exported: FakePhotoLibrary.defaultAlbums + [Self.exportedPhotosAlbum]
        default: FakePhotoLibrary.defaultAlbums
        }
    }

    private var membership: [String: Set<String>] {
        switch self {
        case .exported: [Self.exportedPhotosAlbum.id: Set(Self.exportedPicks)]
        default: [:]
        }
    }

    /// A fresh fake library for this fixture.
    func makeLibrary() -> FakePhotoLibrary {
        FakePhotoLibrary(assets: assets, albums: photosAlbums, membership: membership, status: authorization)
    }

    // MARK: - Seeding

    /// Seed this fixture's albums through the public store APIs. Returns the created projects in seed
    /// order (the order album aliases are assigned in). The selection and done stores are left
    /// inactive afterwards, exactly like a cold launch.
    @MainActor
    @discardableResult
    func seed(projects: ProjectStore, selection: SelectionStore, done: DoneStore) -> [CurationProject] {
        let seeder = Seeder(projects: projects, selection: selection, done: done)
        let created: [CurationProject]
        switch self {
        case .fresh, .denied:
            created = []
        case .emptyLibrary, .oneAlbum:
            created = [seeder.album("Best of 2025", target: 80)]
        case .fourStatuses:
            created = seeder.fourStatuses()
        case .midReview:
            let album = seeder.album("Best of 2025", target: 80)
            seeder.pick(Self.midReviewPicks, in: album)
            seeder.markDone(days: Array(Self.yearDays.prefix(4)), in: album)
            created = [album]
        case .exported:
            let album = seeder.album("Best of 2025", target: 80)
            seeder.pick(Self.exportedPicks, in: album)
            seeder.markDone(days: Self.yearDays, in: album)
            seeder.markExported(album, exportedPicks: Self.exportedPicks, count: Self.exportedPicks.count,
                                to: Self.exportedPhotosAlbum.id)
            created = [album]
        case .scale:
            let album = seeder.album("Best of 2025", target: 200)
            seeder.pick(stride(from: 0, to: Self.scaleAssets.count, by: 50).map { Self.scaleAssets[$0].id },
                        in: album)
            created = [album]
        case .located:
            created = [seeder.album("Best of 2025", target: 60)]
        case .legacyBaseline:
            let album = seeder.album("Best of 2025", target: 80)
            seeder.pick(Self.midReviewPicks, in: album)
            let days = Array(Self.yearDays.prefix(4))
            seeder.markDone(days: days, in: album)
            seeder.legacyBaseline(album, days: days)
            created = [album]
        }
        projects.refresh()
        return created
    }

    /// Seeds albums over the 2025 range through the stores.
    @MainActor
    private struct Seeder {
        let projects: ProjectStore
        let selection: SelectionStore
        let done: DoneStore

        func album(_ englishTitle: String, target: Int) -> CurationProject {
            projects.create(title: debugSampleTitle(englishTitle),
                            rangeStart: ControlFixture.rangeStart, rangeEnd: ControlFixture.rangeEnd,
                            targetCount: target)
        }

        /// Pick `ids` via the selection store (D15's path), flushed and released.
        func pick(_ ids: [String], in project: CurationProject) {
            selection.activate(project)
            selection.select(ids)
            selection.deactivate()   // flushes the snapshot
        }

        /// Mark whole days done via the done store, flushed and released.
        func markDone(days: [DayKey], in project: CurationProject) {
            done.activate(project)
            for day in days where !done.doneDays.contains(day) {
                done.toggle(DayGroup(id: day.description, assetIDs: [], days: [day], isBusyDay: true))
            }
            done.deactivate()   // flushes `doneDays`
        }

        /// Record a completed export of `exportedPicks` — the fields `ExportView` stamps on success —
        /// persisted with `saveEdits`. `photosAlbumID == nil` leaves the destination unset (the
        /// four-statuses rows only need the status).
        func markExported(_ project: CurationProject, exportedPicks: [String], count: Int?,
                          to photosAlbumID: String?) {
            project.targetAlbumID = photosAlbumID
            project.markedDoneAt = ControlFixture.exportedAt
            project.exportedSelectionSnapshot = try? SelectionSnapshot(assetIDs: Set(exportedPicks)).encoded()
            project.exportedPhotoCount = count
            project.lastExportedAt = ControlFixture.exportedAt
            projects.saveEdits(to: project)
        }

        /// Record a pre-#273 review baseline: the flat `day → ids` blob (no lens key) an older build
        /// wrote after reviewing `days` under the photos-only lens — so it holds the days' photos, never
        /// a video. Persisted with `saveEdits`, like an upgraded store would hold it.
        func legacyBaseline(_ project: CurationProject, days: [DayKey]) {
            let photos = ControlFixture.yearAssets.filter { !$0.isScreenshot }
            var blob: [String: [String]] = [:]
            for day in days {
                blob[day.description] = photos
                    .filter { $0.captureDate.map { DayKey(date: $0, calendar: ControlFixture.utc) } == day }
                    .map(\.id)
            }
            project.reviewedIDsByDay = try? JSONEncoder().encode(blob)
            projects.saveEdits(to: project)
        }

        /// The four derived statuses (moved here from `DebugShellView.seedSampleAlbums`; titles,
        /// targets and counts unchanged so the `shell` screenshot is identical).
        func fourStatuses() -> [CurationProject] {
            let ids = ControlFixture.yearDatedIDs
            // Exported + in sync → "Exported · 200 in Photos".
            let exported = album("Best of 2024", target: 200)
            pick(Array(ids.prefix(200)), in: exported)
            markExported(exported, exportedPicks: Array(ids.prefix(200)), count: 200, to: nil)
            // Exported, then 3 more picks → "Edited since export · 3 to add".
            let edited = album("Italy 2024", target: 200)
            pick(Array(ids.prefix(203)), in: edited)
            markExported(edited, exportedPicks: Array(ids.prefix(200)), count: nil, to: nil)
            // In progress.
            let inProgress = album("Summer trip", target: 80)
            pick(Array(ids.prefix(34)), in: inProgress)
            // Not started.
            let notStarted = album("Best of 2025", target: 150)
            return [exported, edited, inProgress, notStarted]
        }
    }

    // MARK: - Fixed data

    static let rangeStart = Date(timeIntervalSince1970: 1_735_689_600)   // 2025-01-01T00:00:00Z
    static let rangeEnd = Date(timeIntervalSince1970: 1_767_225_600)     // 2026-01-01T00:00:00Z
    static let exportedAt = Date(timeIntervalSince1970: 1_750_000_000)   // 2025-06-15

    /// The Photos album the `exported` fixture's album was exported to — vended by the fake, holding
    /// exactly the picks, so a re-export dupe-guards to "nothing to add" instead of `.albumMissing`.
    static let exportedPhotosAlbum = AlbumRef(id: "album/control/exported", title: "Best of 2025", count: nil)

    static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// The year library: 26 shooting days across 2025 (368 dated photos, 4–40 a day), a screenshot and
    /// one undated photo. Ids are `ctl/<n>` in seed order.
    static let yearAssets: [AssetRef] = {
        // [month, day, photo count] per shooting day.
        let days: [[Int]] = [
            [1, 6, 8], [1, 18, 14], [2, 2, 6], [2, 14, 22], [3, 8, 4], [3, 9, 5], [3, 22, 12],
            [4, 5, 9], [4, 19, 16], [5, 1, 7], [5, 17, 25], [6, 7, 11], [6, 14, 30], [6, 15, 18],
            [7, 4, 12], [7, 5, 40], [7, 6, 20], [8, 9, 10], [8, 23, 15], [9, 13, 8], [9, 27, 13],
            [10, 11, 6], [10, 31, 17], [11, 15, 9], [12, 24, 21], [12, 31, 10]
        ]
        var assets: [AssetRef] = []
        for entry in days {
            let morning = utc.date(from: DateComponents(year: 2025, month: entry[0], day: entry[1], hour: 8))!
            for index in 0..<entry[2] {
                assets.append(AssetRef(id: "ctl/\(assets.count)",
                                       captureDate: morning.addingTimeInterval(Double(index) * 13 * 60),
                                       pixelSize: PixelSize(width: 4032, height: 3024)))
            }
        }
        let screenshotDay = utc.date(from: DateComponents(year: 2025, month: 4, day: 1, hour: 12))!
        assets.append(AssetRef(id: "ctl/\(assets.count)", captureDate: screenshotDay,
                               pixelSize: PixelSize(width: 1206, height: 2622), isScreenshot: true))
        assets.append(AssetRef(id: "ctl/\(assets.count)", captureDate: nil))
        return assets
    }()

    /// `legacy-baseline`'s video: on the year's first shooting day (one of the done days), after its
    /// photos — invisible under the photos-only lens the legacy baseline was recorded with.
    static let legacyVideo = AssetRef(
        id: "ctl/video/0",
        captureDate: utc.date(from: DateComponents(year: 2025, month: 1, day: 6, hour: 18))!,
        pixelSize: PixelSize(width: 1920, height: 1080), isVideo: true, duration: 12)

    /// The year library's dated, non-screenshot photo ids, oldest first — the pickable set.
    static let yearDatedIDs: [String] = yearAssets
        .filter { $0.captureDate != nil && !$0.isScreenshot }
        .map(\.id)

    /// The year library's shooting days, oldest first.
    static let yearDays: [DayKey] = {
        var seen: Set<DayKey> = []
        return yearAssets
            .filter { !$0.isScreenshot }
            .compactMap { $0.captureDate.map { DayKey(date: $0, calendar: utc) } }
            .filter { seen.insert($0).inserted }
    }()

    /// `mid-review`'s 34 picks: every third photo from the start of the year.
    static let midReviewPicks: [String] = stride(from: 1, to: 102, by: 3).map { yearDatedIDs[$0] }

    /// `exported`'s picks: every fifth photo across the year.
    static let exportedPicks: [String] = stride(from: 0, to: yearDatedIDs.count, by: 5).map { yearDatedIDs[$0] }

    /// The scale library — the canonical 10k scale seed.
    static let scaleAssets: [AssetRef] = FakePhotoLibrary.scaleSeed(10_000)

    /// The located library — the deterministic location-spike seed (all of 2025, with coordinates).
    static let locatedAssets: [AssetRef] = FakePhotoLibrary.locationSpikeSeed()
}

#endif
