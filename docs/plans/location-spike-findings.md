# Location-clustering spike — findings (#129 / #133)

The real-data results of the location spike (the "after" to
[location-spike-preregistration.md](location-spike-preregistration.md)). Context in
[preprocessing-and-caching.md](preprocessing-and-caching.md) §5–§8 (the D18 subsystem). The pure core
is `PlaceClustering` + `TripOverlay` (`Curation`); the probe is `App/PoimiApp/Support/LocationSpikeProbe.swift`,
reached per-album from **Album settings ▸ Developer ▸ Location clustering**.

_Recorded 2026-07-06 from runs on a real ~14-year library (owner's device)._

## TL;DR

- **Place + home clustering: GO.** Correct, well-named, fast. Validated on a real library.
- **Trip layer: needs one more pass** — but *not* the filter first assumed (see "Recurrence, not
  distance" — the headline learning).
- **Performance fixed** — a library-wide O(n²) run (~a minute) became a per-album, full-resolution
  run in ~a second or two via a spatial grid index + per-album scoping.

## Runs

Two runs, same library:

| run | scope | located pts | coverage | clusters | trips | notes |
| --- | ----- | ----------: | -------: | -------: | ----: | ----- |
| A | whole library (all years) | 42 240 | 79% | 13 | 199 | eps 25 km; downsampled preview (2 500) — the O(n²) pain |
| B | one album = 2025 | 6 789 | 94% | 16 | 29 | eps 3.1 km, minPts 20; **full** set, grid index, fast |

## Performance — the grid spatial index

Run A exposed the scale wall: `PlaceClustering` neighbour discovery was O(n²), and the k-distance
elbow O(n² log n). On 42 k located points that is ~a minute, forcing a downsampled preview that
distorts *which* clusters form.

Fix (see `PlaceCluster.swift`):

- **Uniform grid index** for the DBSCAN neighbour search — each point scans a 3×3 block of eps-sized
  cells instead of the whole field, pruning cross-region pairs (home vs. a far trip). Byte-identical
  results (same haversine filter → same neighbour *sets*; this DBSCAN is order-independent), pinned by
  a grid-vs-brute equivalence property test. Brute O(n²) retained as the reference + the ±180°
  antimeridian fallback.
- **Per-album scoping** — an album is a bounded range, so the located set drops from ~42 k to a few
  thousand. This, not just the grid, is what makes a *full* (un-downsampled) run cheap.
- **Capped elbow** — the k-distance curve is a diagnostic and its k-NN isn't grid-accelerable, so it
  runs on a ≤2 000-point representative subsample. Clustering itself uses the full set.

Result: run B clustered all 6 789 points with no downsample, fast.

Residual cost: the **medoid** of a very large home cluster is still O(m²) (inherent — it minimises
summed intra-cluster distance). Fine at album scale (~1 s); only the whole-library launch path feels it.

## Place clustering — validated

- **Home detected correctly** (Tampere) in both runs — the most-days-spanning cluster.
- **Geocoded names are good** — real Finnish/Swedish place names, usable as suggestions (Tampere,
  Lempäälä, Nokia, Halikko, Naantali, Sastamala, Pori, Vårdö, Åkersberga/Ruotsi, …).
- **GPS coverage** 79% (whole library) / 94% (2025) — well clear of any "worth shipping" floor.
- **`eps` behaves as designed.** At the ~25 km default a metro stays one cluster; pulled down to
  3.1 km (below the k-distance knee), the metro fragments into sub-areas — which also means **the same
  town appears as several clusters with duplicate names** (Lempäälä ×3, Pori ×3). Design note for when
  places go user-facing: cluster at a coarser eps for "places," or merge same-name adjacent clusters,
  or disambiguate by neighbourhood.

## Recurrence, not distance — the headline learning

Run B surfaced ~13 "trips" to **Lempäälä**. The first instinct was over-segmentation → add a
*distance-from-home* filter to drop near-home visits. **That instinct is wrong.** Lempäälä is the
owner's **summer house ~30 km from home**, visited repeatedly across the season — those day trips are
*meaningful*, not noise. A distance filter would have hidden a place the user cares about.

The real discriminator is already in the data — **recurrence, not distance**:

- **Lempäälä** cluster spans **2025-04 → 2025-10** with many separate visits → a *seasonal recurring
  place* (a summer house's signature).
- **Åland/Sweden** (Vårdö + Åkersberga + Turku) is a single **Nov 8–9** event → a *one-off trip*.

So the location layer should classify clusters along a **recurrence** axis, using signals it already
computes (distinct visit count / day-span across the album):

- **Home** — the most-days-spanning recurring place (already detected).
- **Recurring places / "second homes"** — many separated visits over a long span (summer house,
  relatives' towns). A category of their own — never dropped, never lumped as one-off trips.
- **Trips** — a tight, one-off date span (Åland, Naantali, Halikko).

This is on-brand for Poimi: while curating a year, "your places" (home, summer house) vs. "your trips"
is exactly the orientation the location layer is meant to give.

## Go / no-go

- **Place clustering + home detection + geocoded names: GO** for the v1.1 D18 subsystem.
- **Trip overlay: revise before user-facing** — replace the naïve "every non-home visit is a trip"
  with the recurrence-based classification above (home / recurring place / one-off trip). This falls
  out of the existing cluster date-spans; no distance heuristic.
- **Not** built into the product flow yet — the probe stays a DEBUG tool until the classification lands.

## Next

1. `TripOverlay` (or a new classifier): tag each cluster home / recurring / one-off from visit
   recurrence + day-span; keep recurring places as first-class, not "trips."
2. Places UX: same-name/sub-area handling at small eps.
3. The geocoded-name cache (the only network-bound, persistence-worthy piece — D18) when this leaves
   the spike.
