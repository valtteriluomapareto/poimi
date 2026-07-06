//
//  GeocodedPlaceName.swift
//  PoimiApp — the D18 geocoded-name cache entry (issue #130, preprocessing §8; schema v2).
//
//  The ONE persisted derived-data cache the location feature needs: the reverse-geocoded label for a
//  *place*. Clustering + trips are cheap+pure and stay live (recomputed every open, §1); only the
//  network-bound *name* is worth persisting, per the D18 rule (persist a derivation only when re-running
//  it interactively is unacceptable, with an explicit invalidation key).
//
//  Keyed by a rounded coordinate **cell** (`GeocodeCell`), not an exact medoid or an asset id:
//    • a place name is a function of *where*, not of a specific photo — so the key is geographic;
//    • small membership churn (a medoid shifting a few metres when a photo is added) stays in the same
//      cell → cache hit, no re-geocode (the churn hazard the plan-review flagged against exact-medoid
//      keys); and
//    • an EXIF edit that MOVES an asset lands it in a *different* cell → correctly re-geocoded — so
//      cell-keying subsumes the D18 per-asset modification-date key for this per-place cache.
//
//  It caches *suggestions* (P2): a user-confirmed `NamedLocation` (Phase 3) supersedes a cached name,
//  and staleness of an unconfirmed suggestion is acceptable (§7 — the real geocoder is non-deterministic
//  across runs; the cache deliberately stabilises the unconfirmed ones). App-wide (not per-project):
//  the same place seen from two albums resolves once.
//

import Foundation
import SwiftData

@Model
final class GeocodedPlaceName {
    /// The rounded-cell identity (`GeocodeCell.key`, e.g. `"60.170,24.940"`) — a place, not an asset.
    /// No `.unique` DB constraint (it trips a SwiftData SIGTRAP on insert); uniqueness is kept by
    /// fetch-or-create in `NameCacheStore.store`.
    var cellKey: String

    /// The reverse-geocoded label — a *suggestion* until a user confirms it (P2).
    var name: String

    /// When it was fetched — for diagnostics / a future expiry policy; NOT part of the cache key.
    var fetchedAt: Date

    init(cellKey: String, name: String, fetchedAt: Date) {
        self.cellKey = cellKey
        self.name = name
        self.fetchedAt = fetchedAt
    }
}
