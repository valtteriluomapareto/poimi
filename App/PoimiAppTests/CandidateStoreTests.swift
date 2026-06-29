//
//  CandidateStoreTests.swift
//  PoimiAppTests — the review-fetch pipeline: fetch → resolve exclusions → filter (#34).
//
//  Integration tests against `FakePhotoLibrary` (the `yearMixedSeed`: 12 busy on 2025-07-05,
//  3 quiet 2025-03-16…18, 1 screenshot 2025-04-01, 1 undated; WhatsApp ⊇ {busy/0, busy/1}).
//  These pin the two exact filters resolving end-to-end + the phase the scanning surface binds to.
//

import Testing
import Foundation
import Curation
@testable import PoimiApp

@MainActor
@Suite("CandidateStore fetch + exact filters (#34)")
struct CandidateStoreTests {

    // Date anchors + UTC calendar live in TestSupport.swift (`TestDates`, `utcCalendar()`).

    /// Held for the whole test (one fresh in-memory store per `@Test` instance): the store retains
    /// the `ModelContainer`, so projects it creates stay valid through `load`. (A locally-scoped
    /// store would deallocate, reset its context, and destroy the returned model.)
    private let store: ProjectStore

    init() throws {
        store = try ProjectStore(container: AppModelContainer.make(inMemory: true))
    }

    /// A project built through the in-memory store, so its persisted config is realistic.
    private func makeProject(
        excludeScreenshots: Bool = true,
        excludedAlbumIDs: [String] = [],
        rangeStart: Date = TestDates.year2025Start,
        rangeEnd: Date = TestDates.year2025End
    ) -> CurationProject {
        store.create(
            title: "Best of 2025",
            rangeStart: rangeStart, rangeEnd: rangeEnd,
            targetCount: 100,
            excludeScreenshots: excludeScreenshots,
            excludedAlbumIDs: excludedAlbumIDs)
    }

    /// Unwrap `.ready`'s day-groups, or fail loudly with the actual phase.
    private func readyGroups(_ store: CandidateStore, _ comment: Comment) -> [DayGroup] {
        guard case .ready(let groups) = store.phase else {
            Issue.record("expected .ready, got \(store.phase) — \(comment)")
            return []
        }
        return groups
    }

    /// The candidate ids in chronological order — concatenating the groups reproduces the flat
    /// slice the filter tier produced (a partition of the candidates, order-stable).
    private func readyIDs(_ store: CandidateStore, _ comment: Comment) -> [String] {
        readyGroups(store, comment).flatMap(\.assetIDs)
    }

    @Test("both filters resolve: screenshots + WhatsApp members dropped, chronological order kept")
    func bothFilters() async throws {
        let project = makeProject(excludeScreenshots: true, excludedAlbumIDs: ["album/whatsapp"])
        let store = CandidateStore(library: FakePhotoLibrary())
        await store.load(project)

        let ids = readyIDs(store, "both filters")
        // 16 dated − 1 screenshot − 2 WhatsApp members = 13, oldest → newest (March before July).
        #expect(ids == ["fake/quiet/16", "fake/quiet/17", "fake/quiet/18"]
            + (2...11).map { "fake/busy/\($0)" })
        #expect(!ids.contains("fake/shot"))
        #expect(!ids.contains("fake/busy/0") && !ids.contains("fake/busy/1"))
        #expect(!ids.contains("fake/undated"))   // undated never returned by a range fetch
    }

    // MARK: Grouping happens once, in the store (Finding 1)

    @Test("`.ready` carries adaptive day-groups partitioning the filtered candidates")
    func groupsAtReady() async throws {
        let project = makeProject(excludeScreenshots: true, excludedAlbumIDs: ["album/whatsapp"])
        let store = CandidateStore(library: FakePhotoLibrary(), calendar: utcCalendar())
        await store.load(project)

        let groups = readyGroups(store, "grouped at ready")
        // The March 16–18 run is quiet (< 10/day → one merged group); July 5 keeps 10 after the
        // WhatsApp exclusion (≥ 10 → its own busy group). Two groups, oldest → newest.
        #expect(groups.count == 2)
        #expect(groups.first?.isBusyDay == false)
        #expect(groups.first?.assetIDs == ["fake/quiet/16", "fake/quiet/17", "fake/quiet/18"])
        #expect(groups.last?.isBusyDay == true)
        #expect(groups.last?.assetIDs == (2...11).map { "fake/busy/\($0)" })
        // Concatenation reproduces the flat chronological slice — no loss, no duplication.
        #expect(readyIDs(store, "partition") == ["fake/quiet/16", "fake/quiet/17", "fake/quiet/18"]
            + (2...11).map { "fake/busy/\($0)" })
    }

    @Test("the per-photo day map is published for the viewer's label (#36)")
    func dayMapPublished() async throws {
        let project = makeProject(excludeScreenshots: true, excludedAlbumIDs: ["album/whatsapp"])
        let store = CandidateStore(library: FakePhotoLibrary(), calendar: utcCalendar())
        await store.load(project)

        // Each candidate maps to its *own* calendar day (unlike a merged group, which spans days):
        // the quiet run resolves per day, and every busy photo lands on July 5.
        #expect(store.dayByID["fake/quiet/16"] == .day(year: 2025, month: 3, day: 16))
        #expect(store.dayByID["fake/quiet/18"] == .day(year: 2025, month: 3, day: 18))
        #expect(store.dayByID["fake/busy/2"] == .day(year: 2025, month: 7, day: 5))
        // The map covers exactly the ready candidates — every one has a day, and filtered-out
        // assets (the screenshot, the WhatsApp members) are absent.
        let ids = readyIDs(store, "day map")
        #expect(ids.allSatisfy { store.dayByID[$0] != nil })
        #expect(store.dayByID.count == ids.count)
        #expect(store.dayByID["fake/shot"] == nil)
    }

    @Test("a reload that finds nothing clears the day map — no stale labels on the next album (#36)")
    func dayMapResetsOnReload() async throws {
        // The reset at the top of load() is behavior, not housekeeping: switching albums (or a retry)
        // must not leave the previous map behind to mislabel the viewer. Drive populated → empty on
        // ONE store — the only path that actually exercises the reset line.
        let store = CandidateStore(library: FakePhotoLibrary(), calendar: utcCalendar())
        await store.load(makeProject(excludeScreenshots: true, excludedAlbumIDs: ["album/whatsapp"]))
        #expect(!store.dayByID.isEmpty)
        // An inverted range degrades to .empty via the guard (before any fetch) — the map must clear.
        await store.load(makeProject(rangeStart: TestDates.year2025End, rangeEnd: TestDates.year2025Start))
        #expect(store.dayByID.isEmpty)
    }

    @Test("the store groups by its injected calendar (timezone shifts day bucketing)")
    func respectsInjectedCalendar() async throws {
        // Two assets straddling UTC midnight: 23:00Z on 2025-06-25 and 01:00Z on 2025-06-26.
        let a = AssetRef(id: "edge/a", captureDate: Date(timeIntervalSince1970: 1_750_892_400))
        let b = AssetRef(id: "edge/b", captureDate: Date(timeIntervalSince1970: 1_750_899_600))
        let library = FakePhotoLibrary(assets: [a, b], albums: [], membership: [:])
        let project = makeProject(excludeScreenshots: false)

        // UTC: the two land on different calendar days (Jun 25 and Jun 26).
        let utcStore = CandidateStore(library: library, calendar: utcCalendar())
        await utcStore.load(project)
        #expect(Set(readyGroups(utcStore, "utc").flatMap(\.days)).count == 2)
        // The per-photo day map keys on the SAME injected calendar as grouping — a regression that
        // built it with `.current` would still pass the grouping assertion above but fail here.
        #expect(utcStore.dayByID["edge/a"] == .day(year: 2025, month: 6, day: 25))
        #expect(utcStore.dayByID["edge/b"] == .day(year: 2025, month: 6, day: 26))

        // UTC−3: both shift back into the same calendar day (Jun 25) — only the calendar changed.
        var minus3 = Calendar(identifier: .gregorian)
        minus3.timeZone = TimeZone(secondsFromGMT: -3 * 3600)!
        let shiftedStore = CandidateStore(library: library, calendar: minus3)
        await shiftedStore.load(project)
        #expect(Set(readyGroups(shiftedStore, "utc-3").flatMap(\.days)).count == 1)
        // The map shifts in lockstep: edge/b's 01:00Z slides back to Jun 25 under UTC−3.
        #expect(shiftedStore.dayByID["edge/a"] == .day(year: 2025, month: 6, day: 25))
        #expect(shiftedStore.dayByID["edge/b"] == .day(year: 2025, month: 6, day: 25))
    }

    @Test("no filters: every dated in-range asset survives (screenshot included, undated excluded)")
    func noFilters() async throws {
        let project = makeProject(excludeScreenshots: false, excludedAlbumIDs: [])
        let store = CandidateStore(library: FakePhotoLibrary())
        await store.load(project)

        let ids = Set(readyIDs(store, "no filters"))
        #expect(ids.count == 16)
        #expect(ids.contains("fake/shot"))           // not filtered when the toggle is off
        #expect(ids.contains("fake/busy/0"))         // not excluded when no album is excluded
        #expect(!ids.contains("fake/undated"))
    }

    @Test("screenshots-only filter drops just the screenshot")
    func screenshotsOnly() async throws {
        let project = makeProject(excludeScreenshots: true, excludedAlbumIDs: [])
        let store = CandidateStore(library: FakePhotoLibrary())
        await store.load(project)

        let ids = Set(readyIDs(store, "screenshots only"))
        #expect(ids.count == 15)
        #expect(!ids.contains("fake/shot"))
        #expect(ids.contains("fake/busy/0"))
    }

    @Test("album-exclusion-only filter drops just the WhatsApp members, keeps the screenshot")
    func albumExclusionOnly() async throws {
        let project = makeProject(excludeScreenshots: false, excludedAlbumIDs: ["album/whatsapp"])
        let store = CandidateStore(library: FakePhotoLibrary())
        await store.load(project)

        let ids = Set(readyIDs(store, "album exclusion only"))
        #expect(ids.count == 14)
        #expect(!ids.contains("fake/busy/0") && !ids.contains("fake/busy/1"))
        #expect(ids.contains("fake/shot"))           // screenshot kept (its toggle is off)
    }

    @Test("excluding a real but empty album leaves the candidates unchanged")
    func zeroMemberExcludedAlbum() async throws {
        // album/downloads exists in the seed but has no members — excluding it must be a no-op,
        // distinct from excluding an unknown id, and must NOT drop anything.
        let project = makeProject(excludeScreenshots: true, excludedAlbumIDs: ["album/downloads"])
        let store = CandidateStore(library: FakePhotoLibrary())
        await store.load(project)
        // Same as the screenshots-only case: 16 dated − 1 screenshot = 15.
        #expect(Set(readyIDs(store, "zero-member album")).count == 15)
    }

    @Test("filters removing every in-range asset settle on .empty (not .ready([]))")
    func emptyAfterFiltering() async throws {
        // The only in-range asset is a screenshot; excluding screenshots empties the candidates.
        // This is the product-meaningful empty ("you filtered them all out"), distinct from
        // "no photos in that period".
        let onlyAScreenshot = AssetRef(
            id: "only/shot",
            captureDate: Date(timeIntervalSince1970: 1_745_000_000),   // 2025-04-18Z
            isScreenshot: true)
        let library = FakePhotoLibrary(assets: [onlyAScreenshot], albums: [], membership: [:])
        let project = makeProject(excludeScreenshots: true)
        let store = CandidateStore(library: library)
        await store.load(project)
        #expect(store.phase == .empty)
    }

    @Test("a range matching nothing settles on .empty (not an error)")
    func emptyOutOfRange() async throws {
        let start = Date(timeIntervalSince1970: 1_893_456_000)   // 2030-01-01Z
        let end = Date(timeIntervalSince1970: 1_925_000_000)
        let project = makeProject(rangeStart: start, rangeEnd: end)
        let store = CandidateStore(library: FakePhotoLibrary())
        await store.load(project)
        #expect(store.phase == .empty)
    }

    @Test("a zero-length or inverted range degrades to .empty without trapping DateInterval")
    func emptyDegenerateRange() async throws {
        // Equal bounds (zero length).
        let zero = makeProject(rangeStart: TestDates.year2025Start, rangeEnd: TestDates.year2025Start)
        let zeroStore = CandidateStore(library: FakePhotoLibrary())
        await zeroStore.load(zero)
        #expect(zeroStore.phase == .empty)

        // Inverted (end before start) — would trap `DateInterval(start:end:)` if not guarded.
        let inverted = makeProject(rangeStart: TestDates.year2025End, rangeEnd: TestDates.year2025Start)
        let invertedStore = CandidateStore(library: FakePhotoLibrary())
        await invertedStore.load(inverted)
        #expect(invertedStore.phase == .empty)
    }

    @Test("a fetch failure surfaces as .failed")
    func failure() async throws {
        let project = makeProject()
        let store = CandidateStore(library: FailingLibrary())
        await store.load(project)
        #expect(store.phase == .failed)
        #expect(store.dayByID.isEmpty)   // a failed pass leaves no (stale) day map behind
    }

    @Test("a failure while resolving excluded albums also surfaces as .failed")
    func failureResolvingExclusions() async throws {
        // The fetch succeeds but the second await (assetIDs) throws — a real PhotoKit error can
        // surface there too, and it must still become .failed (not a half-applied .ready).
        let project = makeProject(excludedAlbumIDs: ["album/whatsapp"])
        let store = CandidateStore(library: FailingMembershipLibrary())
        await store.load(project)
        #expect(store.phase == .failed)
    }

    @Test("re-loading after .failed restarts the pass and reaches .ready (the documented retry)")
    func retryAfterFailure() async throws {
        // load() is documented as callable again after .failed ("Try again"); prove the same store
        // re-enters .scanning and settles to .ready once the library recovers.
        let project = makeProject()
        let store = CandidateStore(library: RecoveringLibrary())
        await store.load(project)
        #expect(store.phase == .failed)          // first attempt throws
        await store.load(project)                // retry
        if case .ready = store.phase {} else {
            Issue.record("expected .ready after retry, got \(store.phase)")
        }
    }
}

/// A library whose range fetch always throws — to exercise the `.failed` phase.
private actor FailingLibrary: PhotoLibraryProviding {
    func authorizationStatus() async -> LibraryAuthorization { .authorized }
    func requestAuthorization() async -> LibraryAuthorization { .authorized }
    func fetchAssets(in interval: DateInterval) async throws -> [AssetRef] {
        throw PhotoLibraryError.fetchFailed
    }
    func albums() async throws -> [AlbumRef] { [] }
    func assetIDs(inAlbums albumIDs: [String]) async throws -> Set<String> { [] }
}

/// A library that throws on the FIRST fetch, then succeeds — to exercise the retry-after-.failed
/// path on a single store.
private actor RecoveringLibrary: PhotoLibraryProviding {
    private var attempts = 0
    func authorizationStatus() async -> LibraryAuthorization { .authorized }
    func requestAuthorization() async -> LibraryAuthorization { .authorized }
    func fetchAssets(in interval: DateInterval) async throws -> [AssetRef] {
        attempts += 1
        if attempts == 1 { throw PhotoLibraryError.fetchFailed }
        return FakePhotoLibrary.yearMixedSeed().filter { $0.captureDate != nil }
    }
    func albums() async throws -> [AlbumRef] { [] }
    func assetIDs(inAlbums albumIDs: [String]) async throws -> Set<String> { [] }
}

/// A library whose range fetch succeeds but whose membership resolution throws — to prove the
/// pipeline's *second* await also maps to `.failed`.
private actor FailingMembershipLibrary: PhotoLibraryProviding {
    func authorizationStatus() async -> LibraryAuthorization { .authorized }
    func requestAuthorization() async -> LibraryAuthorization { .authorized }
    func fetchAssets(in interval: DateInterval) async throws -> [AssetRef] {
        FakePhotoLibrary.yearMixedSeed().filter { $0.captureDate != nil }
    }
    func albums() async throws -> [AlbumRef] { [] }
    func assetIDs(inAlbums albumIDs: [String]) async throws -> Set<String> {
        throw PhotoLibraryError.fetchFailed
    }
}
