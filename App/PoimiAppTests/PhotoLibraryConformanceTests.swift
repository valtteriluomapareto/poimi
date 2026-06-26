//
//  PhotoLibraryConformanceTests.swift
//  PoimiAppTests — the conformance suite (#28, D24).
//
//  The contract every `PhotoLibraryProviding` must satisfy, asserted *generically* so the
//  same checks run against the deterministic `FakePhotoLibrary` (here, in CI) and — on a
//  real device — against `SystemPhotoLibrary`. This is the guard against fake-vs-real drift
//  the #27 review flagged: both sides must agree on the fetch contract.
//

import Testing
import Foundation
import Curation
@testable import PoimiApp

// `DateInterval.year2025` / `.everything` live in TestSupport.swift.

/// The fetch-contract invariants — content-agnostic, so they hold for any implementation.
func assertFetchContract(_ library: any PhotoLibraryProviding, in interval: DateInterval) async throws {
    let assets = try await library.fetchAssets(in: interval)

    // 1. A bounded fetch returns only dated assets, all within [start, end).
    for asset in assets {
        let date = try #require(asset.captureDate, "a range fetch must not return undated assets")
        #expect(date >= interval.start && date < interval.end)
    }
    // 2. Oldest → newest.
    let dates = assets.compactMap(\.captureDate)
    #expect(dates == dates.sorted())
    // 3. No duplicate ids.
    #expect(Set(assets.map(\.id)).count == assets.count)
}

/// The album-membership contract for `assetIDs(inAlbums:)` — content-agnostic, so it holds for
/// any implementation (the new seam, #34). The fake/real *content* equivalence is the on-device
/// run (#46); these are the invariants both sides must agree on regardless of seed.
func assertAlbumMembershipContract(_ library: any PhotoLibraryProviding) async throws {
    // Empty input enumerates nothing.
    #expect(try await library.assetIDs(inAlbums: []).isEmpty)
    // An unknown album id contributes nothing — no crash, no spurious ids.
    #expect(try await library.assetIDs(inAlbums: ["bogus/nonexistent-album"]).isEmpty)
}

@Suite("PhotoLibrary conformance (#28)")
struct PhotoLibraryConformanceTests {

    @Test("FakePhotoLibrary satisfies the fetch + album-membership contracts")
    func fakeFetchContract() async throws {
        try await assertFetchContract(FakePhotoLibrary.yearMixed(), in: .year2025)
        try await assertAlbumMembershipContract(FakePhotoLibrary.yearMixed())
    }

    @Test("empty FakePhotoLibrary satisfies the contract")
    func emptyFetchContract() async throws {
        let library = FakePhotoLibrary.empty()
        try await assertFetchContract(library, in: .year2025)
        let assets = try await library.fetchAssets(in: .year2025)
        #expect(assets.isEmpty)
    }

    @Test("SystemPhotoLibrary: unauthorized simulator returns empty, contract still holds")
    func systemUnauthorizedContract() async throws {
        // CI precondition: a fresh simulator is unauthorized, so the real fetch returns [] and
        // the invariants hold (the predicate/sort path runs, but over an empty set). We ASSERT
        // that precondition so this can't silently become content-bearing — a seeded sim would
        // fail these and force a conscious update. The real fake↔real *content* equivalence is
        // the on-device conformance run (#46, D24).
        let library = SystemPhotoLibrary()
        let status = await library.authorizationStatus()
        #expect(status != .authorized)
        let assets = try await library.fetchAssets(in: .year2025)
        #expect(assets.isEmpty)
        try await assertFetchContract(library, in: .year2025)
        // The new membership seam must hold the same contract on the real impl: an unauthorized /
        // empty library resolves any album id to nothing (and never traps).
        try await assertAlbumMembershipContract(library)
    }
}
