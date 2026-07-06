# Location-clustering spike — pre-registration template (#129 / #133)

**Status:** template to freeze *before* the interactive probe run. Overfitting guard for the
location-bucketing spike (#129): fiddling `eps`/`minPts` until your known trips appear is overfitting
to a sample of one. So **fill in the "Frozen expectations" section below and commit it before you
touch a slider.** The reported result is a **stable plateau** — a *range* of parameters that all
surface your trips with ~0 junk — never a single lucky value.

This serves the interactive probe built in #133 (`DebugScreen.locationspike`,
`App/PoimiApp/Support/LocationSpikeProbe.swift`), which drives the merged pure core (#132):
`PlaceClustering` + `TripOverlay` in `Curation`. Read `preprocessing-and-caching.md` §5–§8 first.

---

## How to run the spike session

1. **Freeze expectations** (next section) and commit — before tuning.
2. Launch the app to the probe on your device against your **real** library:
   `-PoimiScreen locationspike` (no `-PoimiUseFakeLibrary` → real `\.photoLibrary` + real `CLGeocoder`;
   grant Photos access when asked — EXIF coordinates only, no CoreLocation permission, D7).
   - For a deterministic dry run / screenshot, add `-PoimiUseFakeLibrary` → the planted
     `FakePhotoLibrary.locationSpikeSeed` + a placeholder geocoder (`Scripts/screenshots.sh locationspike`).
3. Read the **k-distance elbow** for an objective `eps` starting point (the knee ≈ a good radius).
4. Tune `eps` / `minPts` (adaptive vs manual) / `gapToleranceDays` / home-exclusion. Watch the trip
   cards appear / merge / fragment. Note the **range** over which each expected trip stays correct.
5. **Judge by seeing the photos** in the cluster/trip cards — not coordinate rows.
6. **Export findings** (share button) at each candidate plateau — params + counts + cluster/trip
   tables land in Markdown. Pair with a screenshot.
7. Fill in "Observed results" and make the go/no-go call.

---

## Frozen expectations (fill BEFORE tuning)

### Expected trips (ground truth)
List the trips you *know* are in the frozen date range, with rough dates. A detected result is only
"good" if it recovers these with ~0 spurious extras.

| # | trip (place) | dates | notes |
| - | ------------ | ----- | ----- |
| 1 |              |       |       |
| 2 |              |       |       |

### GPS-coverage floor
- Minimum global GPS coverage for the spike to be meaningful at all: **____%**
  (if real coverage is far below this, location bucketing may not be worth shipping — a go/no-go input).

### Precision / junk bar
- Max tolerated **spurious trips** (trips surfaced that aren't real): **____**
- Max tolerated **fragmentation** (one real trip split into N): **____**
- Home must be detected as home (not surfaced as a trip): **yes / no**

### Plateau requirement
- A result counts as "settled" only if the expected trips survive across an **`eps` range of at least
  ____ km** and **both** `minPts` modes (adaptive + a nearby manual value), not a single value.

---

## Observed results (fill DURING/AFTER)

### Candidate plateau
- `eps`: ____ km – ____ km   ·   `minPts`: ____ (adaptive computed = ____)   ·
  `gapToleranceDays`: ____   ·   home exclusion: on/off
- Global GPS coverage: ____%   ·   clusters: ____   ·   trips: ____   ·   no-location: ____

### Trip recovery vs expectations
| expected trip | detected? | label quality | GPS coverage | notes |
| ------------- | --------- | ------------- | ------------ | ----- |

### Junk / failures
- Spurious trips: ____   ·   fragmentation: ____   ·   home mis-detected: ____
- `CLGeocoder` name quality / latency: ____

---

## Go / no-go

- [ ] Expected trips recovered within the junk bar, across a real plateau (not a lucky point)
- [ ] GPS coverage clears the floor
- [ ] Geocoded names are good enough to be useful suggestions

**Decision:** ▢ go (ship location bucketing to v1.1) ▢ no-go ▢ needs another spike — because: ______

---

## Reproducible anchor (not a substitute for the real run)

The planted synthetic field (`FakePhotoLibrary.locationSpikeSeed`, ported from
`CurationTests/PlantedSeed`) is the deterministic CI/screenshot anchor. Its ground truth:

- **Home:** Helsinki (dense, across most of the year).
- **Trips:** Stockholm (2d), Italy = Rome→Florence→Venice (6d, one contiguous trip / three clusters),
  Paris (3d), London (3d) — Paris and London separated by one fly-home day, Fiji (3d, antimeridian),
  Barcelona (3d, concurrent with home days).
- **No-location:** eight `(0,0)` null-island + five dated-no-GPS assets.

The real-library run, actual coverage, the "yes, that's my Italy trip" judgment, real geocode
quality, and the go/no-go are **irreducibly human** — this template only makes them honest.
