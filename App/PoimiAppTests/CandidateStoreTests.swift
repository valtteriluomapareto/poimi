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

    private static let yearStart = Date(timeIntervalSince1970: 1_735_689_600)   // 2025-01-01Z
    private static let yearEnd = Date(timeIntervalSince1970: 1_767_225_600)     // 2026-01-01Z

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
        rangeStart: Date = yearStart,
        rangeEnd: Date = yearEnd
    ) -> CurationProject {
        store.create(
            title: "Best of 2025",
            rangeStart: rangeStart, rangeEnd: rangeEnd,
            targetCount: 100,
            excludeScreenshots: excludeScreenshots,
            excludedAlbumIDs: excludedAlbumIDs)
    }

    /// Unwrap `.ready`'s candidates, or fail loudly with the actual phase.
    private func readyAssets(_ store: CandidateStore, _ comment: Comment) -> [AssetRef] {
        guard case .ready(let assets) = store.phase else {
            Issue.record("expected .ready, got \(store.phase) — \(comment)")
            return []
        }
        return assets
    }

    @Test("both filters resolve: screenshots + WhatsApp members dropped, chronological order kept")
    func bothFilters() async throws {
        let project = makeProject(excludeScreenshots: true, excludedAlbumIDs: ["album/whatsapp"])
        let store = CandidateStore(library: FakePhotoLibrary())
        await store.load(project)

        let ids = readyAssets(store, "both filters").map(\.id)
        // 16 dated − 1 screenshot − 2 WhatsApp members = 13, oldest → newest (March before July).
        #expect(ids == ["fake/quiet/16", "fake/quiet/17", "fake/quiet/18"]
            + (2...11).map { "fake/busy/\($0)" })
        #expect(!ids.contains("fake/shot"))
        #expect(!ids.contains("fake/busy/0") && !ids.contains("fake/busy/1"))
        #expect(!ids.contains("fake/undated"))   // undated never returned by a range fetch
    }

    @Test("no filters: every dated in-range asset survives (screenshot included, undated excluded)")
    func noFilters() async throws {
        let project = makeProject(excludeScreenshots: false, excludedAlbumIDs: [])
        let store = CandidateStore(library: FakePhotoLibrary())
        await store.load(project)

        let ids = Set(readyAssets(store, "no filters").map(\.id))
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

        let ids = Set(readyAssets(store, "screenshots only").map(\.id))
        #expect(ids.count == 15)
        #expect(!ids.contains("fake/shot"))
        #expect(ids.contains("fake/busy/0"))
    }

    @Test("album-exclusion-only filter drops just the WhatsApp members, keeps the screenshot")
    func albumExclusionOnly() async throws {
        let project = makeProject(excludeScreenshots: false, excludedAlbumIDs: ["album/whatsapp"])
        let store = CandidateStore(library: FakePhotoLibrary())
        await store.load(project)

        let ids = Set(readyAssets(store, "album exclusion only").map(\.id))
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
        #expect(Set(readyAssets(store, "zero-member album").map(\.id)).count == 15)
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
        let zero = makeProject(rangeStart: Self.yearStart, rangeEnd: Self.yearStart)
        let zeroStore = CandidateStore(library: FakePhotoLibrary())
        await zeroStore.load(zero)
        #expect(zeroStore.phase == .empty)

        // Inverted (end before start) — would trap `DateInterval(start:end:)` if not guarded.
        let inverted = makeProject(rangeStart: Self.yearEnd, rangeEnd: Self.yearStart)
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
