# Preprocessing & derived-data caching (incl. location grouping, v1.1)

**Status:** forward-looking plan / not yet built. Frames *what Poimi caches and why*, and lays out
the **location-preprocessing subsystem** (v1.1, D4) as the first place a persisted derived-data
cache becomes load-bearing. Nothing here changes v1 behavior; it records the intended shape so the
v1.1 work doesn't have to re-derive it.

> **One-line thesis:** *the expensive part is geocoding; everything else stays live and pure. Don't
> persist what's cheap to recompute, and only cache the things that don't drift when the library
> changes.*

**Reading order context:** sits under [architecture.md](architecture.md) (§2 fetch tier, §3 async
pass, §7 location, §9 persistence, §13 grouping) and the [decisions log](plan-review-decisions.md)
(D4, D7, D8, D13, D17, D18, D19, D20, D29, D31, D33). Read those for the authoritative "why"; this
plan composes them into a concrete subsystem. **It has been reviewed by a Swift Architect, a
Pragmatic Developer, and an Algorithms expert; their corrections are folded in** (provenance §14).

---

## 1. The principle: persist *state*, never loaded data — with one keyed exception

- **Photos are sacrosanct (D8/D31).** Only `localIdentifier`s persist; never bytes.
- **We persist project *state*, not the materialized working set.** `CurationProject` holds config +
  progress (debounced picked-id snapshot D15, done-days, resume pointer). The **candidate set is
  fetched live every open** (`CandidateStore.load`) and held only in memory; thumbnails are cached
  **in memory only** (`PHCachingImageManager` + the bounded `ThumbnailMemoryCache`).
- **The lazy direction (D17/D29).** The grid's data source is a *windowed* `AssetRef` snapshot served
  from the actor by index range, with an access-counting guard (D29) that fails if the whole fetch
  result is materialized. (Today `SystemPhotoLibrary.fetchAssets` still materializes a flat array —
  the windowing is the unbuilt #47; this plan leans on that future substrate and says so.)
- **The one deliberate persisted derived-data cache (D18):** the resource-size cache, keyed by
  `localIdentifier` **+ modification date**, because re-reading recorded original sizes is
  iCloud-touching and expensive.

**The rule, generalized from D18:** persist a derived-data cache **only when the derivation is
expensive enough that re-running it interactively is unacceptable** (network/iCloud/heavy compute),
**and** it must carry an **explicit invalidation key**, **and** it must cache only things that don't
silently drift when the library changes. Cheap, pure, deterministic derivations stay live —
*preprocessed once per session, not persisted across sessions*.

Date day-grouping is cheap+pure → stays live (already runs once at `.ready`, never in a `body`).
**The only thing in the location feature that clears the D18 bar is geocoding.** Clustering is cheap
and pure, so — by this plan's own rule — it is **not** persisted; only the network-bound *names* and
the user-authored *named locations* are.

---

## 2. Why location needs preprocessing at all

- **Naming is network-bound.** Coordinate → human label ("Italy", "Summer cabin") means reverse
  geocoding via `CLGeocoder` — rate-limited, serial, failure-prone. Never per-scroll/per-open.
- **The product loop is human-in-the-loop (D4/§7).** Clusters are *suggestions a human confirms +
  names*; a confirmed `NamedLocation` is durable authored state, not a recomputed artifact. (This
  keeps faith with the product truth: *you choose every photo — and every place name — not an
  algorithm.*)
- The raw input is free: `AssetRef.coordinate` (EXIF lat/lon, **D7** — no CoreLocation permission) is
  fetched today and unused. *Caveat:* `Coordinate` carries no accuracy or fix-timestamp field, so
  noise handling (§5.4) is heuristic, not metadata-driven.

---

## 3. What is already scaffolded (do not re-decide)

- **`AssetRef.coordinate: Coordinate?`** — `Sendable` lat/lon (D13, never `CLLocation`).
- **`NamedLocation` `@Model`** named in architecture §9 (v1.1): center, radius, name.
- **Pure location distance/geometry lives in `Curation`** (D21/§1) — *but the metric must be named*
  (§5.1); "distance check" alone invites a `CLLocation` leak.
- **D33 — location is *additive*, not a rework.** v1 sections stay date-only adaptive day-groups
  (§13); trips are an *overlay over the same day-groups*, with the day-group as the no-GPS fallback.
- **Always a "no location" bucket** (§7).

---

## 4. Boundary placement (D14/D21, CI-guarded)

| Concern | Layer | Notes |
| --- | --- | --- |
| `CLGeocoder`, `CLLocation` reconstruction, MapKit pin/radius UI | **App tier** | `Curation` must not import CoreLocation/MapKit. |
| The orchestrating `LocationPreprocessor` (geocode + persist) | **App tier**, its **own actor** | A *new* actor — **not** folded into `SystemPhotoLibrary` (keep that scoped to PhotoKit fetch/auth), mirroring how `SystemThumbnailProvider` is its own actor. |
| The `PlaceNaming` seam (real `CLGeocoder` + fake) | **App tier** | Mirrors **`ThumbnailProviding`** (app-tier, UIKit-touching) — **not** `PhotoLibraryProviding` (which lives in `Curation` because it traffics only in pure values). |
| Distance metric, clustering, trip-run composition, bucket assignment | **`Curation`** (pure) | `Sendable`, headless-testable. Mandate the metric (§5.1). |
| `NamedLocation` `@Model`, the persisted name/binding caches | **App tier (SwiftData)** | Write via `PersistentIdentifier` re-fetch — never hold/write `@Model`s from the preprocessor actor (architecture §9 SIGTRAP trap). |

---

## 5. The pure geometry (`Curation`) — name it, don't hand-wave it

**5.1 Distance metric (the missing keystone).** Raw lat/lon Euclidean is wrong — at ~60°N (Helsinki,
the likely primary user) a degree of longitude is ~half a degree of latitude in meters, so a
degree-radius "home vs trip" threshold is off by ~2×. Mandate, pure in `Curation`:
- **Equirectangular approximation about the cluster's mean latitude** (accurate to <0.5% at
  city/trip scale, cheap) — or full **haversine** if simpler to reason about. Pin the reference
  latitude for determinism.
- A **wrap-aware longitude delta** `Δlon = ((a − b + 540) mod 360) − 180` so the anti-meridian
  (±180°, Pacific/date-line travel) doesn't put nearby points 360° apart. (Centroid arithmetic has
  the same wrap hazard — another reason to prefer the medoid, §5.3.)

**5.2 Clustering algorithm — recommend DBSCAN, not "grid/greedy".** A single global radius cannot
separate a dense "home" (every café/park) from sparse trip cities. **DBSCAN** (or HDBSCAN for
density-adaptivity) handles variable cluster size at one density threshold, models **GPS
noise/outliers as unclustered** (which maps directly onto the no-location bucket, §5.4), is
O(n log n) with a **grid spatial index** (so the 10k smoke isn't quadratic), and is **deterministic
given a pinned input sort** (sort coordinates by `(lat, lon, id)` before the pass — the same
defensive-sort discipline `DayGrouping.chronological` uses). If grid/greedy is chosen instead, the
plan must *justify* it and pin the input order (greedy "leader" assignment is order-dependent → not
deterministic otherwise).

**5.3 Representative point = medoid, not centroid.** The geocoding query point and cluster identity
should be the **medoid** (the actual member coordinate minimizing summed distance): it is always a
real photographed place (never mid-bay/mid-border), is anti-meridian-safe, and is deterministic.
**Cluster identity = medoid asset id**, not an ordinal index, so cached handles survive re-clustering.

**5.4 GPS noise / no-location.** Route `(0,0)` null-island sentinels and DBSCAN-noise points to the
**no-location bucket**. Decide explicitly: a dated-but-no-GPS asset still belongs to its date
day-group; a no-GPS *and* undated asset already lands in `DayGrouping`'s trailing `.undated` group —
specify whether "no location" and "Undated" are the same bucket, nested, or orthogonal axes.

**5.5 Parameters need a spike.** DBSCAN `eps`/`minPts` (or `clusterRadius`) and the trip
`gapToleranceDays` have no confirmed defaults; §5.2's density argument means there is no single
obviously-right radius. Treat these like `DayGrouping.defaultThreshold` — spike-confirmed before
"settled."

---

## 6. The D33 composition: trips as a *time-contiguous overlay*, never a re-partition

This was the biggest gap in the first draft ("collapse into a trip" was one sentence). Specify it as
a pipeline **over the existing `DayGroup` output**, so D33's "additive, not a rework" holds and the
done-day atom (§13, `section.days ⊆ doneDays`) is never broken:

> **v1.1 decision (ratified) — label by the dominant cluster (P5).** A time-run gets **exactly one**
> trip label = the cluster holding the **plurality** of its located assets; the majority simply wins,
> with no abstain and no multi-tag. Crucially this is **label-by-dominant, not merge-into-dominant**:
> the spatial **clusters stay distinct**, so every place keeps its own browsable bucket and a photo's
> place membership is always its *own* cluster — only the run's *name* goes to the winner. (We chose
> this over the earlier "abstain below a fraction threshold / allow multiple tags" idea because it's
> simpler, deterministic, no more expensive to compute, and **lossless** — nothing becomes
> unreachable. The "ignore a handful of stray points" instinct is already handled upstream by
> DBSCAN's `minPts`: trivially sparse points become noise → the no-location bucket, §5.4, so no
> separate merge rule is needed.)

1. **Assign** each *located* asset a cluster id (§5.2, pure). This membership *is* the place bucket —
   it never changes based on what else shares a day.
2. **Form trips = `place ∩ contiguous-time-run`.** A trip is a maximal run of consecutive `DayKey`s
   (reuse `DayGrouping.dayGap` with its own `gapToleranceDays`), labeled by the **dominant cluster**
   of its located assets (plurality wins; ties broken deterministically, e.g. by the lower medoid
   id). This is the step that turns a *place* (spatial) into a *trip* (spatio-temporal).
3. **Overlay, don't re-cut.** The trip is a single *annotation* (one `tripID?` per `DayGroup` /
   `DayKey`), never a re-partition of `assetIDs` and never a rewrite of any asset's cluster
   membership. The day-group stays the unit of done-tracking; the place buckets stay the unit of
   by-location browsing.

This resolves the hard cases explicitly:
- **Home in Jan vs June** = same cluster, two different time-runs → two trips (correct).
- **Shared / concurrent-location library** (the family case: partner A in Italy, partner B in Finland
  on the *same* days) → both place buckets exist and stay browsable; the mixed week is *named* by
  whichever has the plurality (e.g. "Italy"), and the minority photos remain in their own bucket +
  the timeline. The label is a convenience, not a claim about every photo in the run.
- **Two trips the same day** → resolved to one day-granularity label = the day's dominant cluster;
  sub-day place splits are **out of scope** (they'd break the done-day atom). Known v1.1 limitation.
- **A trip spanning a quiet run + busy days** → the overlay can span multiple `DayGroup`s (including a
  merged quiet run) *without splitting them*; an in-run "home → travel → abroad" day stays in its
  day-group and is simply labeled by that run's dominant cluster.
- **Determinism** inherits from §5.2's pinned sort + `dayGap`, plus the explicit tie-break above.

§10's property tests now have a concrete spec to pin (incl. the dominant-label tie-break and the
concurrent-location case).

---

## 7. The pass + the `CLGeocoder` reality

Run once, lazily, when the location view is first opened (P3); progress on an error-carrying channel
(D19) — it is partially-failing by nature:

1. Collect coordinates from the already-fetched candidates (no new fetch); partition located /
   no-location (§5.4).
2. Cluster (pure, §5.2) → clusters with **medoid** (§5.3).
3. Reconcile with existing `NamedLocation`s: assets within a named location's radius bind to it (no
   geocode). Only *unnamed residual* clusters proceed.
4. **Geocode the medoid** of each residual cluster via the serial `CLGeocoder` seam → a *suggested*
   name. **`CLGeocoder` has no batch API and rejects concurrency** — the actor owns a single instance
   and `await`s each request serially with pacing/throttle; failures degrade to "unnamed" (cluster
   still exists). **Persist each name as it resolves** (partial progress, §8) so a
   cancelled/throttled pass doesn't re-burn the budget. The real geocoder is **non-deterministic
   across runs** (Apple updates map data, locale-sensitive) — fine because names are suggestions
   until confirmed (P2), and the name cache (§8) stabilizes the unconfirmed ones.
5. **Suggest only; human confirms/edits** before a `NamedLocation` is created (D4/P2).
6. Enrich, don't replace (D33, §6).

**Types (D19):** add a `PlaceNamingError` (rate-limited / network / no-result) and a partial-result
shape (cluster present, name absent); the fake geocoder (§8) needs an error-injection path.

---

## 8. Caching — lead with the cheap, membership-stable MVP

By §1's rule, **clustering is recomputed live every open** (cheap, pure). Only two *small*,
membership-stable things are persisted:

- **`NamedLocation` (`@Model`) — authored state, durable.** Center, radius, user-confirmed name.
  Membership is a stable predicate (a point is in the radius or not), so a binding doesn't silently
  drift. Survives library changes; never auto-invalidated. *State, not a cache.*
- **A geocoded-name cache, keyed by query coordinate (medoid) + the asset's modification date**
  (the D18 precedent the first draft wrongly dropped). This caches *only the expensive step*. It is
  independent of clustering params, so a param tweak re-clusters (cheap) but reuses names for
  unchanged query points.

That is the v1.1 MVP: **`NamedLocation` CRUD + live re-clustering + a name cache.** No per-asset
assignment cache, no revision counter, no D29-guard extension on day one.

**Why the first draft's revision-keyed assignment cache is deferred (and was buggy):**
- Keying only on `NamedLocation`-set revision **silently omits newly-added in-range assets** (the
  view reads "complete" while missing photos — the exact failure D32(d) prevents in the date world),
  and **centroid/medoid drift** from an added neighbor changes a cluster's geocoded name while
  *nothing bumps the revision* → stale neighbor names.
- "EXIF doesn't change" is **false**: edits can strip/alter GPS and iOS can back-fill location, so a
  per-entry `modification-date` key (D18) is required, not optional.
- Recomputing clusters live sidesteps all of this, and by §1 it's cheap enough to not persist.

**Later, only if profiling shows live re-clustering janks at scale (#47-class data):** add a
persisted per-asset assignment cache — but then key it on a **content fingerprint of the located-id
set** (not just user params) and reconcile it on resume (D20/§13 must be *extended* to know about it;
it currently only handles selection-prune + day-group re-derive).

---

## 9. Concurrency, laziness, lifecycle

- The `LocationPreprocessor` **actor** owns the `PlaceNaming` seam; `CLGeocoder` calls and SwiftData
  writes stay off the main actor. Pure values cross back; the **persist step re-fetches `@Model`s by
  `PersistentIdentifier`** on the main actor / a `ModelActor` (never writes `@Model` from the
  preprocessor actor).
- **D17/D29 reconciliation:** clustering is inherently a whole-set operation — the pass legitimately
  reads *every* coordinate once. State this so the D29 access-counting guard treats the location pass
  as a sanctioned full coordinate read (one pass, off-main, not per-cell), rather than failing it.
- **Lifecycle (D20/§13):** reconcile-on-resume must additionally prune vanished assets from bindings
  and re-run the (cheap) clustering; the name cache self-heals via its mod-date key.

---

## 10. Testing (per development-guidelines tiers)

Follow the standing test-tier rules; the location-specific must-haves:
- **Pure (`Curation`, headless):** the distance metric (incl. anti-meridian + high-latitude), DBSCAN
  determinism under a pinned sort, noise/`(0,0)` → no-location, medoid stability, and the **§6 trip
  composition** (home-Jan-vs-June, trip-spanning-quiet-run, two-trips-one-day demotion) as property
  tests over synthetic coordinate fields.
- **Integration (`PoimiAppTests`, fake-backed):** the pass against a seeded fake + a **deterministic
  offline fake geocoder with error injection**; the name cache hit/miss + mod-date invalidation;
  binding reconcile; cancellation/partial-progress.
- **Scale:** extend the 10k perf smoke + (later) the D29 guard to the pass; assert the grid index
  keeps clustering sub-quadratic.

---

## 11. Phased rollout

1. **Pure geometry in `Curation`** — the named metric (§5.1) + DBSCAN + medoid + the §6 composition,
   with property tests. *No UI, no persistence, no boundary risk — land early.*
2. **`NamedLocation` `@Model` + the first real migration.** This is the schema bump that **first
   activates `AppMigrationPlan`** (whose `stages` are empty today and *trap if `migrationPlan:` is
   wired before a real stage exists*). It is **additive-only** → a lightweight migration, not custom.
3. **The `PlaceNaming` seam + offline fake** (mirrors `ThumbnailProviding`).
4. **The `LocationPreprocessor` pass + the name cache** (§7/§8 MVP — *not* the assignment cache).
5. **The additive location overview UI** — buckets + "no location", MapKit pin/radius editor, the
   human-confirm/name flow, trip-name overlay (D33).

Steps 1–3 are independently testable with no UI risk; value appears at 4–5.

---

## 12. Open decisions (to ratify into the decisions log at v1.1 kickoff)

Proposals, not yet ratified D-numbers:
- **P1 — MVP caches only `NamedLocation` bindings + geocoded names (by medoid coord + mod date);
  clusters recomputed live.** The revision-keyed per-asset assignment cache is deferred until
  profiling forces it (and then keyed on a located-id-set fingerprint, with reconcile-on-resume).
- **P2 — Geocoding is suggestion-only, human-confirmed** before a `NamedLocation` exists. No silent
  auto-naming.
- **P3 — Run the pass lazily on first location-view open**, not eagerly at scan.
- **P4 — Mandate the pure distance metric** (equirectangular-about-mean-latitude / haversine, wrap-
  aware) and **DBSCAN** clustering with a pinned input sort; geocode the **medoid**.
- **P5 — Trips are a time-contiguous overlay over day-groups (§6), never a re-partition;** sub-day
  place splits are out of scope for v1.1 (done-day atom). **Ratified detail:** each time-run takes a
  **single label = its dominant (plurality) cluster** — *label*-by-dominant, not *merge*-by-dominant,
  so clusters stay distinct and every place keeps a browsable bucket (no abstain, no multi-tag;
  `minPts` suppresses trivial specks upstream).

---

## 13. What this does *not* change

- v1 stays **date-only** (D33); no location code ships in v1.
- The v1 candidate set stays **live-fetched, not persisted** (§1); this introduces only a small
  *name* cache + authored `NamedLocation`s, not a candidate or assignment cache.
- "No heavy work in a `body`" and the windowed/lazy posture (D17/D29) are **preserved and extended**,
  not relaxed.

---

## 14. Review provenance

Revised after a three-persona review:
- **Swift Architect** — caught the cache-key correctness bug (newly-added assets silently omitted),
  re-anchored the seam to `ThumbnailProviding` (app tier), flagged the haversine/`CLLocation`-leak
  risk, the serial-`CLGeocoder` reality, the `PersistentIdentifier` persist-hop, the
  `AppMigrationPlan`-activation trap, and the missing `PlaceNamingError`/reconcile-on-resume contract.
- **Algorithms expert** — supplied the §5 geometry (metric, anti-meridian, DBSCAN-over-grid/greedy,
  medoid, noise) and the §6 trip-composition pipeline that the first draft only asserted; split the
  cache into membership-stable bindings + coordinate-keyed names; flagged centroid-drift staleness.
- **Pragmatic Developer** — identified the cache inversion (the first draft filed the right MVP under
  "alternative"), confirmed the doc is justified as constraint-capture, and trimmed the concurrency
  /testing prose to pointers.
