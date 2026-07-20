//
//  TimelineCacheTests.swift
//  PoimiAppTests — the per-album review-timeline cache (#130).
//
//  Unit tests for the fingerprint (does it change iff the clustering input changes?) and the file
//  store (does a matching fingerprint round-trip the clusters, and a stale one miss?). The end-to-end
//  "a repeat open skips clustering" path is covered through `CandidateStore` in CandidateStoreTests.
//

import Testing
import Foundation
import Curation
@testable import PoimiApp

@Suite("TimelineCache — fingerprint + on-disk store (#130)")
struct TimelineCacheTests {
    private let cal = utcCalendar()

    private func asset(_ id: String, day: Int, lat: Double? = 60.17, lon: Double? = 24.94) -> AssetRef {
        let coord = (lat != nil && lon != nil) ? Coordinate(latitude: lat!, longitude: lon!) : nil
        return AssetRef(id: id,
                        captureDate: cal.date(from: DateComponents(year: 2025, month: 3, day: day))!,
                        coordinate: coord)
    }

    private func dayKey(_ day: Int) -> DayKey {
        DayKey(date: cal.date(from: DateComponents(year: 2025, month: 3, day: day))!, calendar: cal)
    }

    private func sampleClusters() -> [ReviewCluster] {
        // A trivial but real timeline shape: two date day-groups. (Trip round-trip fidelity is pinned in
        // Curation's ReviewTimelineTests; here we only need a non-empty, encodable value.)
        [.day(DayGroup(id: "2025-03-01", assetIDs: ["a", "b"], days: [dayKey(1)], isBusyDay: false)),
         .day(DayGroup(id: "2025-03-02", assetIDs: ["c"], days: [dayKey(2)], isBusyDay: false))]
    }

    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    // MARK: fingerprint

    @Test("identical inputs → identical fingerprint; fetch order doesn't matter (sorted by id)")
    func fingerprintStableAndOrderIndependent() {
        let a = [asset("x", day: 1), asset("y", day: 2), asset("z", day: 3)]
        let shuffled = [a[2], a[0], a[1]]
        let fpA = TimelineCache.fingerprint(candidates: a, locationEnabled: true, calendar: cal)
        let fpShuffled = TimelineCache.fingerprint(candidates: shuffled, locationEnabled: true, calendar: cal)
        #expect(fpA == fpShuffled)
        // Deterministic across calls (SHA-256, not a per-process-seeded Hasher).
        #expect(fpA == TimelineCache.fingerprint(candidates: a, locationEnabled: true, calendar: cal))
    }

    @Test("any input change flips the fingerprint: membership, date, coordinate, or the location toggle")
    func fingerprintChangesWithInput() {
        let base = [asset("x", day: 1), asset("y", day: 2)]
        let fp = TimelineCache.fingerprint(candidates: base, locationEnabled: true, calendar: cal)

        let added = base + [asset("z", day: 3)]
        #expect(TimelineCache.fingerprint(candidates: added, locationEnabled: true, calendar: cal) != fp)

        let reDated = [asset("x", day: 9), base[1]]
        #expect(TimelineCache.fingerprint(candidates: reDated, locationEnabled: true, calendar: cal) != fp)

        let reLocated = [asset("x", day: 1, lat: 41.9, lon: 12.5), base[1]]
        #expect(TimelineCache.fingerprint(candidates: reLocated, locationEnabled: true, calendar: cal) != fp)

        #expect(TimelineCache.fingerprint(candidates: base, locationEnabled: false, calendar: cal) != fp)
    }

    // MARK: store / lookup

    @Test("store then lookup with the matching fingerprint returns the clusters + locality verbatim")
    func storeThenLookupHit() async {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = TimelineCache(directory: dir)
        let id = UUID()
        let clusters = sampleClusters()
        let locality: [String: Locality] = [clusters[0].id: .mostlyHome]
        await cache.store(projectID: id, fingerprint: "fp-1", clusters: clusters, localityByCluster: locality)
        let hit = await cache.lookup(projectID: id, fingerprint: "fp-1")
        #expect(hit?.clusters == clusters)
        #expect(hit?.localityByCluster == locality)   // #201: the locality map round-trips too
    }

    @Test("a stale fingerprint, a missing file, and a removed entry all miss (→ recompute)")
    func lookupMisses() async {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = TimelineCache(directory: dir)
        let id = UUID()
        #expect(await cache.lookup(projectID: id, fingerprint: "fp-1") == nil)   // nothing stored yet
        await cache.store(projectID: id, fingerprint: "fp-1", clusters: sampleClusters(), localityByCluster: [:])
        #expect(await cache.lookup(projectID: id, fingerprint: "fp-2") == nil)   // fingerprint changed
        #expect(await cache.lookup(projectID: UUID(), fingerprint: "fp-1") == nil) // different album
        await cache.remove(projectID: id)
        #expect(await cache.lookup(projectID: id, fingerprint: "fp-1") == nil)   // removed
    }

    @Test("a real pre-#201 (v1) file — no localityByCluster key — misses gracefully, never crash-decodes")
    func v1FileMisses() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = TimelineCache(directory: dir)
        let id = UUID()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // The exact old on-disk envelope after an app update: fingerprint + clusters, no locality map.
        let v1 = #"{"fingerprint":"fp","clusters":[]}"#
        try Data(v1.utf8).write(to: dir.appendingPathComponent("\(id.uuidString).json"))
        #expect(await cache.lookup(projectID: id, fingerprint: "fp") == nil)   // decode fails → benign miss
    }

    @Test("a corrupt or wrong-shape cache file misses gracefully — recompute, never a crash")
    func corruptFileMisses() async throws {
        // The file doc-comment promises a decode failure is a benign miss. A future refactor that
        // switched the `try?`s to a trapping decode would crash on album-open with a stale file after a
        // formatVersion bump; this pins the contract.
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = TimelineCache(directory: dir)
        let id = UUID()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("\(id.uuidString).json")
        try Data("not json at all".utf8).write(to: file)                 // garbage bytes
        #expect(await cache.lookup(projectID: id, fingerprint: "fp") == nil)
        try Data(#"{"unexpected":"shape"}"#.utf8).write(to: file)         // valid JSON, wrong shape
        #expect(await cache.lookup(projectID: id, fingerprint: "fp") == nil)
    }

    @Test("the fingerprint is a well-formed SHA-256 digest (the format version is folded into its input)")
    func fingerprintIsSHA256Digest() {
        // The version participates by being hashed into the header (see `fingerprint`), so it can't be
        // asserted literally in the digest — instead pin the digest shape (a change to the header format
        // that dropped the version would still produce a 64-hex digest, but the round-trip + change tests
        // above guard the semantics). This guards against an accidental non-hash return.
        let fp = TimelineCache.fingerprint(candidates: [asset("x", day: 1)], locationEnabled: true, calendar: cal)
        #expect(fp.count == 64)                                  // 32 bytes → 64 lowercase hex chars
        #expect(fp.allSatisfy { $0.isHexDigit })
    }
}
