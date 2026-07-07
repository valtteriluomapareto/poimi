//
//  TimelineCache.swift
//  PoimiApp — the per-album review-timeline cache (issue #130; preprocessing §6, the "recalculate
//  only if the photos change" requirement).
//
//  Clustering an album (DBSCAN over its located set + the trip overlay) is the dominant cost of an
//  album-open — a few seconds on a large year. Its output is a pure function of the candidate set +
//  the clustering options, so once computed it can be REUSED verbatim until the photos actually change.
//  This caches the assembled `[ReviewCluster]` per album, keyed by a fingerprint of that exact input,
//  so a repeat open (or a relaunch) skips clustering entirely and just re-reads the result.
//
//  It caches regenerable, CPU-derived data (not the network-bound geocoded names — those stay in the
//  SwiftData `NameCacheStore`, §9), so it lives in the Caches directory: OS-purgeable and excluded from
//  backup. A purge, a decode failure, or a fingerprint mismatch is a benign miss → recompute, never data
//  loss. Its own `actor` so the file read + JSON decode of a large timeline never janks the open; only
//  values cross the boundary (`[ReviewCluster]` is `Sendable`).
//

import CryptoKit
import Foundation
import Curation

actor TimelineCache {
    /// Bump when the stored shape changes (a `ReviewCluster` field add/rename) so stale files miss and
    /// recompute rather than decode into the wrong thing. Folded into the fingerprint, so a bump
    /// invalidates every entry. (Clustering-parameter changes are covered directly — see `fingerprint`.)
    static let formatVersion = 1

    private let directory: URL
    private let fileManager: FileManager

    /// The on-disk envelope: the fingerprint the clusters were computed for, and the clusters. A stored
    /// fingerprint that no longer matches the current input ⇒ the photos changed ⇒ recompute.
    private struct Entry: Codable {
        let fingerprint: String
        let clusters: [ReviewCluster]
    }

    /// - Parameter directory: overridable for tests (a temp dir); production uses `Caches/TimelineCache`.
    init(directory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        if let directory {
            self.directory = directory
        } else {
            let caches = (try? fileManager.url(for: .cachesDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true))
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.directory = caches.appendingPathComponent("TimelineCache", isDirectory: true)
        }
    }

    private func fileURL(for projectID: UUID) -> URL {
        directory.appendingPathComponent("\(projectID.uuidString).json", isDirectory: false)
    }

    /// The cached clusters IFF a file exists for `projectID` AND its stored fingerprint matches the
    /// current one — otherwise `nil` (a miss: no file, a stale fingerprint, or an unreadable/old-format
    /// file, all of which just mean "recompute").
    func lookup(projectID: UUID, fingerprint: String) -> [ReviewCluster]? {
        guard let data = try? Data(contentsOf: fileURL(for: projectID)),
              let entry = try? JSONDecoder().decode(Entry.self, from: data),
              entry.fingerprint == fingerprint else { return nil }
        return entry.clusters
    }

    /// Persist `clusters` for `projectID` under `fingerprint` (one file per album, overwritten atomically).
    /// Best-effort: a write failure is logged, never fatal — the next open just recomputes.
    func store(projectID: UUID, fingerprint: String, clusters: [ReviewCluster]) {
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(Entry(fingerprint: fingerprint, clusters: clusters))
            try data.write(to: fileURL(for: projectID), options: .atomic)
        } catch {
            Log.location.error("Timeline-cache write failed: \(String(describing: error))")
        }
    }

    /// Drop a project's cached timeline (on album delete). Best-effort; a missing file is not an error.
    func remove(projectID: UUID) {
        try? fileManager.removeItem(at: fileURL(for: projectID))
    }

    // MARK: - Fingerprint

    /// A stable (cross-launch) fingerprint of everything `ReviewTimeline.clusters` depends on: each
    /// candidate's (id, capture instant, coordinate), the location toggle, the clustering parameters
    /// (eps / gap tolerance) and calendar timezone, and the format version. It changes iff the computed
    /// timeline would change — so a match proves the cached clusters are still valid, and a range or
    /// exclusion edit (which changes the candidate SET) or a re-geotag naturally misses.
    ///
    /// SHA-256, NOT `Hasher` — `Hasher` is per-process seeded, so it would differ every launch and never
    /// hit across relaunches. Candidates are sorted by id first, so PhotoKit's fetch order can't perturb
    /// the fingerprint.
    static func fingerprint(candidates: [AssetRef], locationEnabled: Bool, calendar: Calendar) -> String {
        var hasher = SHA256()
        let header = "v\(formatVersion)|loc:\(locationEnabled ? 1 : 0)"
            + "|eps:\(PlaceClustering.defaultEps)|gap:\(ReviewTimeline.defaultTripGapToleranceDays)"
            + "|tz:\(calendar.timeZone.identifier)|cal:\(calendar.identifier)\n"
        hasher.update(data: Data(header.utf8))
        for asset in candidates.sorted(by: { $0.id < $1.id }) {
            let epoch = asset.captureDate.map { String($0.timeIntervalSince1970) } ?? ""
            let lat = asset.coordinate.map { String($0.latitude) } ?? ""
            let lon = asset.coordinate.map { String($0.longitude) } ?? ""
            hasher.update(data: Data("\(asset.id)\t\(epoch)\t\(lat)\t\(lon)\n".utf8))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
