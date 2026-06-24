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

extension DateInterval {
    /// All representable time — for "fetch everything" assertions.
    static let everything = DateInterval(start: .distantPast, end: .distantFuture)
    /// Calendar year 2025 (UTC), end-exclusive.
    static let year2025 = DateInterval(
        start: Date(timeIntervalSince1970: 1_735_689_600),   // 2025-01-01T00:00:00Z
        end: Date(timeIntervalSince1970: 1_767_225_600))     // 2026-01-01T00:00:00Z
}

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

@Suite("PhotoLibrary conformance (#28)")
struct PhotoLibraryConformanceTests {

    @Test("FakePhotoLibrary satisfies the fetch contract")
    func fakeFetchContract() async throws {
        try await assertFetchContract(FakePhotoLibrary.yearMixed(), in: .year2025)
    }

    @Test("empty FakePhotoLibrary satisfies the contract")
    func emptyFetchContract() async throws {
        let library = FakePhotoLibrary.empty()
        try await assertFetchContract(library, in: .year2025)
        let assets = try await library.fetchAssets(in: .year2025)
        #expect(assets.isEmpty)
    }

    @Test("SystemPhotoLibrary satisfies the contract shape (content-agnostic)")
    func systemFetchContractShape() async throws {
        // In CI/simulator with no authorized library this returns []; the invariants must
        // still hold. The content-bearing conformance run against the real library is
        // on-device (D24) — this proves the real impl honors the same contract shape.
        try await assertFetchContract(SystemPhotoLibrary(), in: .year2025)
    }
}
