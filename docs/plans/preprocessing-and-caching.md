# Preprocessing & derived-data caching (incl. location grouping, v1.1)

**Status:** forward-looking plan / not yet built. Frames *what Poimi caches and why*, and lays out
the **location-preprocessing subsystem** (v1.1, D4) as the first place a persisted derived-data
cache becomes load-bearing. Nothing here changes v1 behavior; it records the intended shape so the
v1.1 work doesn't have to re-derive it.

**Reading order context:** sits under [architecture.md](architecture.md) (§2 fetch tier, §3 async
pass, §7 location bucketing, §9 persistence, §13 grouping) and the
[decisions log](plan-review-decisions.md) (D4, D7, D8, D13, D17, D18, D29, D31, D33). Read those for
the authoritative "why"; this plan composes them into a concrete subsystem.

---

## 1. The principle: we persist *state*, never loaded data — with one keyed exception

Poimi's caching posture today is deliberate and worth stating plainly, because the location work
must extend it without violating it:

- **Photos are sacrosanct (D8/D31).** We persist only `localIdentifier`s, never photo bytes. The
  user's library and originals are never copied, mutated, or cached as pixels.
- **We persist project *state*, not the materialized working set.** `CurationProject` (SwiftData)
  holds config (range, target, filters, export-album id) + progress (the debounced picked-id
  snapshot D15, done-days, resume pointer). The **candidate set is fetched live on every open**
  (`CandidateStore.load` → `fetchAssets` → `Filtering` → `DayGrouping`) and held only in memory for
  that session. Thumbnails are cached **in memory only** (PhotoKit's `PHCachingImageManager` window
  + the bounded, self-evicting `ThumbnailMemoryCache`); nothing image-shaped touches disk.
- **The lazy direction (D17/D29).** The grid's data source is meant to be a *windowed* `AssetRef`
  snapshot served from the actor by index range, with an access-counting guard (D29) that fails if
  the whole fetch result is materialized. So the default stance is *not* "cache the working set" —
  it's "stay lazy and re-derive cheaply."
- **The one deliberate persisted derived-data cache (D18):** the **resource-size cache**, keyed by
  `localIdentifier` + modification date, because re-reading recorded original sizes for a year of
  photos is iCloud-touching and expensive — caching it *is* the point.

**The rule this plan generalizes from D18:** a persisted derived-data cache is justified **only when
the derivation is expensive enough that re-running it interactively is unacceptable** (network,
iCloud, heavy compute), and it must always carry an **explicit invalidation key** so a stale entry
can never be silently trusted. Cheap, pure, deterministic derivations (e.g. date day-grouping) stay
live — they are *preprocessed once per session* (already true after the smoothness fix: grouping runs
once at `.ready`, never in a view body), but not *persisted across sessions*.

Location grouping is the first derivation that clears the D18 bar by a wide margin.

---

## 2. Why location is the case that needs preprocessing + a persisted cache

Date grouping is a pure O(n log n) function of capture dates — cheap, so it stays live. Location is
categorically different on three axes, and each one pushes the work to "preprocess once, persist":

1. **Naming is network-bound.** Turning a coordinate cluster into a human label ("Italy", "Summer
   cabin") means reverse geocoding via `CLGeocoder` — rate-limited, async, failure-prone. This can
   **never** run per-scroll or per-open; it is a one-time pass whose output must be stored.
2. **Clustering is heavier than a sort.** Grouping thousands of coordinates into spatial clusters
   (grid/greedy, §7) is more than the date bucketer does, and it interacts with the date groups
   rather than replacing them (D33).
3. **The product loop is human-in-the-loop (D4/§7).** Clusters are *suggestions a human confirms +
   names*; a `NamedLocation` the user created is durable, authored state — exactly the kind of thing
   that belongs in SwiftData, not recomputed. This also keeps faith with the product truth: *you
   choose every photo (and here, every place name), not an algorithm.*

The raw input already exists and is free: `AssetRef.coordinate` (EXIF lat/lon, **D7** — no
CoreLocation permission, covered by the photo grant) is fetched today and currently unused. So the
data path is ready; only the processing + storage is missing.

---

## 3. What is already scaffolded (do not re-decide)

- **`AssetRef.coordinate: Coordinate?`** — `Sendable` value lat/lon (D13, never `CLLocation`).
  Populated by `SystemPhotoLibrary` from `PHAsset.location` today.
- **`NamedLocation` `@Model`** — named in the architecture's data model (§9, v1.1): center
  coordinate, radius, name.
- **Pure location distance math lives in `Curation`** (D21/§1: "location distance math … no separate
  `LocationKit` package"). Bucketing-by-distance is a pure check.
- **D33 — location is *additive*, not a rework.** v1 sections stay date-only adaptive day-groups
  (§13). The by-location overview and trip names are an *additive view over the same day-groups*;
  the day-group remains the fallback when an asset has no GPS. The plan below must preserve this — it
  enriches groups, it does not replace the grouping engine.
- **Always a "no location" bucket** (§7) — screenshots and many saved images carry no EXIF GPS.

---

## 4. The boundary constraint (where each piece is allowed to live)

The domain boundary (D14/D21, CI-guarded) dictates the architecture of the pass:

| Concern | Layer | Why |
| --- | --- | --- |
| `CLGeocoder` reverse geocoding, `CLLocation` reconstruction, MapKit pin/radius UI | **App tier** | `Curation` must not import `CoreLocation`/MapKit/UIKit. |
| Spatial clustering driver (calls geocoder, orchestrates the pass) | **App tier** (behind a `Sendable` seam, like `PhotoLibraryProviding`) | Touches CL + persistence. |
| Pure distance math, cluster geometry on `Coordinate`, bucket assignment | **`Curation`** | Pure, `Sendable`, unit-testable headless. |
| `NamedLocation` `@Model`, the derived place-assignment cache | **App tier (SwiftData)** | Persistence is app-tier. |

So the pass is: **app tier orchestrates (geocode + persist) → produces enriched `Sendable` values →
`Curation` does the pure bucketing/geometry.** Same seam shape as the rest of the app: heavy/impure
work behind an actor or a protocol, pure values crossing into the domain.

---

## 5. The preprocessing pass (at project start / on demand)

A staged pass, run once when a project's location view is first needed (e.g. opening the location
overview, or as a background task after the initial scan completes), with progress reported on the
same error-carrying channel as the scan (§3/D19 — it is partially-failing by nature):

1. **Collect coordinates** — from the already-fetched candidate `AssetRef`s (no new fetch). Partition
   into *located* and *no-location* (the latter is the always-present bucket, §7).
2. **Cluster (pure, `Curation`)** — grid/greedy clustering on `Coordinate`s → candidate clusters
   (centroid + member ids + bounding radius). Deterministic, unit-testable with synthetic coords.
3. **Reconcile with existing `NamedLocation`s (pure)** — assets within a user's named location's
   radius bind to it directly (no geocode needed). Only *unnamed* residual clusters proceed.
4. **Suggest names (app tier, async, network)** — reverse-geocode each residual cluster centroid via
   `CLGeocoder` → a *suggested* label. Rate-limited, batched, cancellable; failures degrade to "no
   suggestion" (the cluster still exists, just unnamed). **Suggestions only** — the user confirms or
   edits before a `NamedLocation` is created (D4/§7, human-in-the-loop).
5. **Persist the derived assignment cache** (see §6) so re-opens skip steps 1–4.
6. **Enrich, don't replace (D33)** — the location overview is an additive grouping over the same
   date day-groups: consecutive busy days at one place collapse into a named trip; ungrouped/no-GPS
   assets fall back to their day-groups unchanged.

Steps 1–3 are pure and fast; step 4 is the expensive, network-bound one and is the entire reason for
persistence.

---

## 6. The persisted derived-data cache (the D18 pattern, applied)

Two distinct persisted things, with different lifetimes:

- **`NamedLocation` (`@Model`) — authored state, durable.** Center, radius, user-confirmed name.
  Created/edited by the user; survives library changes; never auto-invalidated. This is *state*, not
  a cache.
- **A place-assignment cache — derived, invalidatable.** Maps `localIdentifier` → resolved place
  (a `NamedLocation` id, or an unnamed-cluster handle + its suggested label), so re-opening a project
  is instant. This is the D18-style cache and **must carry an explicit invalidation key.**

**Invalidation key.** Unlike the resource-size cache (keyed by id + modification date), a place
assignment depends on (a) the asset's coordinate (immutable for a given id — EXIF doesn't change),
and (b) the *set of `NamedLocation`s and clustering parameters* in effect. So the cache key/version
is **`NamedLocation`-set revision + clustering-params version**. Editing/adding/removing a named
location, or changing the cluster radius, bumps the revision and invalidates affected entries; the
asset coordinate itself needs no per-entry date key. Library mutations are handled by the existing
reconcile-on-resume path (§13/D20): assets that vanished are pruned; newly-added in-range assets are
unassigned until the next pass.

This keeps the invariant from §1: **no stale derived entry is ever silently trusted** — a revision
mismatch forces re-derivation (cheap steps 1–3; step 4 only for genuinely new clusters).

---

## 7. Concurrency & performance

- The orchestrating clusterer is an **actor** (or sits behind the existing `PhotoLibrary` actor's
  seam), so `CLGeocoder` calls and SwiftData writes never block the main actor. Pure values
  (`Coordinate`, cluster structs, assignment maps) cross back — never `CLLocation`/`PHAsset` (D13).
- **Geocoding is the bottleneck, not the compute.** Batch + throttle to respect `CLGeocoder` rate
  limits; cache aggressively (§6); make the whole step cancellable (leaving the screen cancels it,
  like the scan). A cluster with no successful geocode is simply unnamed — never a blocked UI.
- Reuse the **windowed/lazy posture (D17/D29)**: the location overview renders from the persisted
  assignment cache + the same windowed `AssetRef` snapshot; it does not materialize a second full
  copy of the year.
- The **access-counting guard (D29)** should be extended to cover the location pass so "don't
  materialize the whole set" can't regress when location lands.

---

## 8. Testing (matches the tiers in development-guidelines)

- **Pure unit/property tests (`Curation`, headless):** clustering determinism, distance-bucket
  membership, "no-location" partition, reconcile-with-`NamedLocation`-radius, and the additive-over-
  day-groups composition (D33). Property tests over synthetic coordinate fields — the same approach
  that pins `DayGrouping`.
- **Integration tier (`PoimiAppTests`, fake-backed):** the orchestration pass against a fake that
  vends seeded coordinates + a **fake geocoder** (deterministic, offline — no real `CLGeocoder` in
  CI), the persisted assignment cache + its revision-based invalidation, and cancellation.
- **Cache-correctness tests:** bumping the `NamedLocation` revision invalidates; an unchanged
  revision is a hit; a pruned asset drops cleanly.
- **Scale:** extend the 10k-asset perf smoke (`FakePhotoLibrary.scale`) + the D29 access-counting
  guard to the location pass.

---

## 9. Phased rollout (proposed)

1. **Coordinate plumbing audit** — confirm `AssetRef.coordinate` is populated end-to-end; add the
   pure clustering + distance math to `Curation` with property tests. *(No UI, no persistence — safe
   to land early.)*
2. **`NamedLocation` `@Model` + SwiftData migration** — the v1.1 migration approach (project-phases
   Phase 4 note) lands here; CRUD for named locations.
3. **The geocoder seam + fake** — a `Sendable` `PlaceNaming` protocol (real `CLGeocoder` impl +
   deterministic fake), mirroring `PhotoLibraryProviding`/`ThumbnailProviding`.
4. **The orchestrated pass + persisted assignment cache** — steps §5.1–§5.5, with invalidation §6.
5. **The additive location overview UI** — buckets + "no location", MapKit pin/radius editor, the
   human-confirm/name flow; trip-name collapse over day-groups (D33).

Steps 1–3 are independently testable and carry no UI risk; the value (instant re-opens, named trips)
appears at 4–5.

---

## 10. Open decisions (to ratify into the decisions log when this is scheduled)

These are *proposals*, not yet ratified D-numbers — flagged so the v1.1 kickoff can adopt or revise:

- **P1 — Persist a place-assignment cache keyed by `NamedLocation`-set revision + cluster-params
  version** (the D18 pattern), so re-opens skip geocoding. *Alternative: recompute clusters live but
  cache only geocoded names by cluster centroid — simpler, but re-clusters every open.*
- **P2 — Geocoding is suggestion-only and human-confirmed before a `NamedLocation` is created**
  (reinforces D4/§7 and the product truth). No silent auto-naming.
- **P3 — Run the pass lazily (first time the location view is opened), not eagerly at scan**, to keep
  the v1 scan fast and avoid geocoding projects the user never views by place. *Alternative: a
  low-priority background task kicked off after the scan settles.*
- **P4 — Extend the D29 access-counting guard to the location pass** so the lazy invariant holds
  across both groupings.

---

## 11. Relationship to v1 (what this does *not* change)

- v1 stays **date-only** (D33). No location code ships in v1; this plan is the v1.1 blueprint.
- The v1 candidate set stays **live-fetched, not persisted** (§1) — this plan does not introduce a
  candidate-set cache; it introduces a *location-assignment* cache, which is a different, smaller,
  derived artifact.
- The "no heavy work in a `body`" convention and the windowed/lazy posture (D17/D29) are *preserved
  and extended*, not relaxed.
