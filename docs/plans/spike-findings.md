# Spike findings (Phase 0) — IN PROGRESS

> **Status: in progress — Part B.** This is the **real Phase-0 output** (the spike
> code is disposable; this evidence is not — project-phases §"Phase 0 exit"). The
> harness (Part A, PR #13) is built and runnable; the on-device evaluation against a
> real year (Part B) fills in the numbers and the UX verdicts below. **It is what
> closes [#4](https://github.com/valtteriluomapareto/poimi/issues/4) / resolves the
> picking interaction ([#5★](https://github.com/valtteriluomapareto/poimi/issues/5)),
> not the merge of the harness PR.**
>
> Headings below are the questions the spike must answer. Entries marked _(seeded)_
> are the author's first on-device observations already recorded on PR #13; the rest
> are placeholders to fill in while running on a real library.

---

## Part B — on-device verdicts (session 2)

- ✅ **Scroll smoothness at scale: good** — freeze fix + windowed prefetch hold up on a real year.
- ✅ **Column density: good** — **3 columns** confirmed for iPhone.
- ✅ **Scroll-restore: good** — returning from full-screen lands on the right photo, cleanly.
- ✅ **Badge mis-fire: none** — the 44pt badge zone didn't mis-fire during triage.
- ⚠️ **iCloud progressive load: too slow** — iCloud-only photos **stay blurry quite long** before sharpening. **Now mitigated (session 3):** the pager prefetches full-res for the current ± 1 page, so a swipe lands on a sharper image sooner. **Some latency is inherent to the iCloud download** — Phase 2 adds the determinate long-scan surface (D12). → **re-feel on-device** (does the neighbour-prefetch take the edge off the blur on a real iCloud library?).
- 🐞 **Zoomed pan lags badly** — double-tap zoom works, but *panning* the zoomed image had huge lag (unusable). **Now fixed (session 3):** the zoom/pan is rewritten onto a `UIScrollView`-backed zoomable image (native pinch + pan + double-tap at 60/120fps), replacing the SwiftUI `MagnifyGesture` + `offset` approach that caused the lag. → **re-feel on-device** (is the pan smooth now? does pinch still page cleanly at the zoom boundary?).
- 🐞 **Pull-down dismiss animation feels weird** — **now reworked (session 3):** the dismiss is interactive — the photo tracks the finger downward and scales down, the backdrop fades with drag progress, and release past a threshold dismisses (else springs back). Coexists with the scroll-view zoom (only active at fit scale) and left/right paging. → **re-feel on-device.**
- 🔑 **Grouping is needed (key finding).** Going through a whole year on the flat chronological grid is *harder than Apple Photos* — curating needs the **adaptive day-grouping** (busy days stand alone, quiet days merge; see project-phases "Timeline grouping", #6). A flat date slice isn't enough. **Now implemented in the spike (session 3):** the grid renders as sectioned day-groups with pinned headers, computed by a pure `SpikeGrouping` function (the precursor to Curation's grouping). → **re-evaluate the feel: does grouping make a year manageable (vs the flat grid / Apple Photos)? Is N = 10/day and the gap rule right?**

---

## Part B — on-device re-test (the session-3 build: grouping + new pager)

- 🔑 **We need another zoom level above this grid (key navigation finding).** Day-grouping helps, but one grid level still isn't enough to scan a whole *year*: the author wants a **higher-level overview** above this grid (à la Apple Photos' Years / Months / Days), then **drill into this grid, where selection happens**. So this review grid is the *selection* level; a coarser *overview* level sits above it for navigating scale. Informs the navigation model (D20) and #6 — likely a pinch / level-switch between an overview and the selection grid.
- 🐞 **Super sluggish on device** after the session-3 build (sectioned grid + `UIScrollView` pager + neighbour prefetch). Console: `Gesture: System gesture gate timed out` (main-thread stall), `CMPhotoDecompressionSession err=-16990` (decode pressure), and a zoom-transition fallback (`matchedTransitionSource` source cell not in the hierarchy on dismiss, with the new sections). **Under root-cause review (4 perspectives incl. Codex); fix next.** The sluggishness currently *masks* the grouping feel — re-judge grouping once it's smooth.
- ⚠️ **Cells not square after grouping** — cosmetic, **deprioritized** for now ("don't care").

---

## Part B — on-device re-test (after the performance fix)

- ✅ **Perf fix worked — ran smoothly.** Bounding the pager decode (~2048pt vs `MaximumSize`) + dropping the neighbour-prefetch + moving fetch/grouping off-main cleared the sluggishness. **⚠️ But it "got stuck" again after a while** — an intermittent stall remains (suspect: decoded-image / memory growth over a long session, or a specific path). Needs a repro detail (what action preceded the freeze) to pin down.
- ✅ **Zoom / pan now works and "makes sense"** (the `UIScrollView` rewrite); **the interaction workflow is validated** ("works for now") — the two-tier picking loop holds.
- ⚠️ **Square cells would improve the grid** (non-square crept back with the sections) — minor; tidy when convenient.
- 🔑 **Overview zoom level — confirmed, designing now.** Above the selection grid, a high-level view of *"how many photos I have of this month / trip / summer"* so you can see where the volume is and aim the curation. Navigation: overview → drill into the day-group selection grid.

---

## Tap mapping

The make-or-break decision (D9/D10, ★ primary gate). The real question: which action
deserves the cheap whole-cell tap — *select* (the constant action, done hundreds of
times) or *inspect* (occasional)?

The harness now ships a **runtime A/B toggle** in the grid's top bar (segmented
control) so both mappings can be felt on the **same real year in one session**:

- **(A) Badge select** _[default]_ — tap the badge → select; tap the rest of the cell
  → open full-screen.
- **(B) Tap select** — whole-cell tap → select; **long-press → open** full-screen
  (inspect via long-press, since pinch is taken by column density).

- _(seeded — author, PR #13)_ The grid selection works as wired in (A): tapping the
  badge marked the photo selected; tapping the rest of the image opened it larger.
  **The mapping "reads well so far"** — badge = select, rest = open.
- **✅ RESOLVED (Part B, on-device) → (A) Badge select.** Author's verdict: *"the
  select with badge feels better."* Tap-the-badge → select, tap-the-rest → open is the
  chosen mapping. **The #5 primary gate is settled.** (Mapping (B) whole-cell-select +
  long-press-to-open was tried on the same library and lost.) The design already
  carries (A) as canonical (Paper Review grid + styleguide §6).
- **Session 3 cleanup:** the runtime A/B toggle has done its job and is **removed**;
  badge-select is now **hard-coded** (tap badge → select, tap cell → open). The grid's
  top "controls" bar is gone with it.

## Default column count

Plan default: **~3 columns on iPhone (~128pt)**, pinch-adjustable
(`AssetGridView` clamps to 2–8; iPad wants more). Question: can you make *most* calls
from the grid at this density, opening full-screen only for fine ones (sharpness,
burst disambiguation, eyes-open)? If you're constantly forced full-screen, the
density (or the whole model) is wrong.

- TODO (Part B): confirm 3 is the right iPhone default; note where you naturally
  settle the pinch; note the iPad default.

## Badge hit-target

≥44pt corner zone (`ThumbnailCell` renders a small glyph in a 44×44 target;
`AssetGridView` overlays a 44×44 high-priority tap zone so the badge wins over the
open-cell tap).

- _(seeded — author, PR #13)_ Hitting the badge selected; hitting elsewhere opened —
  i.e. the 44pt target and its priority over the cell tap behaved correctly.
- TODO (Part B): does it ever mis-fire during fast scroll-and-flick triage? Is the
  glyph legible against bright/dark photos?

## Cell shape (square vs aspect)

Spike question (project-phases item 7): **square** scans faster but crops framing;
Apple's Library tab uses justified aspect so you see the real shot.

The harness now ships a **runtime toggle** alongside the tap-mapping control (the
grid's top bar) to flip cells between:

- **Square** _[default]_ — fixed 1:1, fills the cell (crops framing) — scans fastest.
- **Aspect** — the asset's natural ratio (clamped to ~0.45–2.2 so panoramas don't blow
  out a row), fit whole so framing isn't cropped.

- **✅ RESOLVED (Part B, on-device) → Square.** Author's verdict: *"square is good."*
  Square is the chosen cell shape. ⚠️ The **Aspect toggle didn't work** on-device (a
  harness bug — aspect path didn't take); not pursued since square is the decision.
- **Session 3 cleanup:** the cell-shape toggle **and the dead/broken aspect path are
  removed**; cells are now **hard-coded square**.

## Scroll-restore feel

`AssetGridView` uses `.scrollPosition(id:)`; the pager writes the current page back to
`scrollAnchorID` so dismissing returns the grid to whichever photo you swiped to
(D22 — "which photo we land back on"). Paired with `.matchedTransitionSource` +
`.navigationTransition(.zoom)`.

- TODO (Part B): on return, do you land on the photo you ended on, centered and with
  the zoom transition reading cleanly? Any jump/flicker with recycled cells?

## Smoothness at scale (scroll-driven prefetch window)

Explicit Phase-0 exit criterion: does it stay smooth over **thousands** of assets, and
do recycled cells behave? The harness now drives the `PHCachingImageManager` prefetch
window from the grid's **visible range** (`AssetGridView` tracks visible cell ids via
per-cell `onAppear`/`onDisappear` and passes a windowed slice — visible ± 2 rows —
to `ThumbnailImageManager.updateCachingWindow` as you scroll). Previously the whole
slice was primed once, so the windowing was never exercised under scroll; now it is.

- TODO (Part B): scroll a full year fast — does it stay at 60/120fps, or do cells show
  placeholders that never fill (window too tight) or memory balloon (window too wide)?
  Is ±2 rows the right margin? Do recycled cells flash the previous photo before the
  new one loads? This is the "tech holds up at scale" half of the gate.
- Note: the prefetch window now indexes over the **flattened chronological order**
  across the day-group sections, so windowing still spans section boundaries as you
  scroll the one flow.

## Timeline grouping (THE key finding)

The headline Part B verdict: the **flat chronological grid makes curating a year
*harder than Apple Photos*** — the plan's grouping has to be felt.

**✅ Session 3: adaptive day-grouping is now implemented in the spike.**

- **How it's computed** — a **pure function of (capture dates, N)** in the throwaway
  tier (`SpikeGrouping.groups`), the deterministic precursor to Curation's grouping
  (project-phases "Timeline grouping (v1)"). It buckets the slice by calendar day
  (`PHAsset.creationDate`), then walks days in chronological order:
  - a day with **≥ N = 10** photos → **its own group** ("Sat 5 Jul · 53");
  - a maximal run of **consecutive days each < N** → **one merged group**
    ("16–18 Mar · 7");
  - a run **breaks** on a busy day or a **calendar gap** beyond a small tolerance
    (default 1 day), so quiet runs stay tight (no "Days 2–40" over an empty month);
  - label is a single day or a date range + count, **no quota**.
  It's written PhotoKit-free / main-actor-free (takes `(id, Date?)`, returns value
  `AssetDayGroup`s), so in Phase 1 it lifts into `Curation` almost verbatim (swap the
  `(id, Date)` tuples for `AssetRef`s) and gets the property tests the boundary buys.
- **How it's rendered** — the grid is a `LazyVGrid` with `Section { } header:` and
  **pinned section headers**, scrolling as one chronological flow; concatenating the
  groups reproduces the flat slice exactly. The render layer stays value-shaped (ids +
  `AssetDayGroup` metadata, no `PHAsset`). The scroll-driven prefetch window keeps
  working across sections (it indexes the flattened order).
- **TODO (Part B, re-evaluate the feel):** does the day-grouping make a whole year
  **manageable** (vs the flat grid, vs Apple Photos)? Do events pop out and quiet
  stretches stay compact? Is **N = 10/day** the right threshold, and is the **1-day gap
  tolerance** right (too tight → too many tiny runs; too loose → quiet runs span empty
  stretches)? Are the date-range labels readable at a glance?

## Full-screen gestures (the open question)

- _(seeded — author, PR #13)_ The full-screen interactions are **the open question**:
  "when opened in a larger image, we need to think how users would use the app — what
  double-tap does, what pulling down does, how to zoom in a bit, etc." The harness now
  implements all three so they can be **felt** in Part B (added in the review/test-fix
  pass):
  - **Double-tap** → toggles fit ↔ ~2.5×, centered toward the tap point.
  - **Pull-down** → drag the un-zoomed photo down past a threshold to dismiss back to
    the grid (the backdrop fades as you pull). Mostly-horizontal drags still page
    left/right; the select control hides while zoomed so it doesn't fight the pan.
  - **Pinch-zoom** → magnify into the current photo (up to 4×), with pan when zoomed;
    releasing below 1× snaps back and re-centers.
- _(Part B, on-device — author)_ **Pull-down-to-close animation looks a bit weird**, and
  **zoomed pan lags badly** (unusable). → reworked in session 3.
- **✅ Session 3 rework (zoom/pan + pull-down).**
  - **Zoom/pan rewritten to a `UIScrollView`-backed zoomable image**
    (`ZoomableImageView`, a `UIViewRepresentable`: `UIScrollView` + `UIImageView`).
    Native pinch + pan + double-tap-to-zoom (fit ↔ ~3×, centred on the tap), running at
    60/120fps — replacing the SwiftUI `MagnifyGesture` + `offset` that caused the pan
    lag. It coexists with the `TabView` left/right paging: at fit scale the scroll view
    doesn't intercept horizontal swipes, so paging still works; once zoomed the scroll
    view owns the pan.
  - **Pull-down-to-dismiss is now interactive.** A `UIPanGestureRecognizer` inside the
    scroll view (active only at fit scale, only for predominantly-vertical-downward
    drags) drives it: the photo tracks the finger and scales down, the backdrop fades
    with drag progress, and release past a threshold dismisses (else springs back).
    Horizontal swipes fall through to the pager; the select control hides while zoomed
    or mid-drag.
- TODO (Part B, re-feel on-device): is the **pan smooth now**? Is **3×** the right
  double-tap step? Does **pinch fight the page swipe** at the zoom boundary? Does the
  **interactive pull-down feel right** (tracking + scale + spring-back)? Should select
  stay visible while zoomed?

## Progressive / iCloud timing

`FullImageLoader` streams opportunistic **degraded → final** full-res with
`isNetworkAccessAllowed = true` (iCloud-optimized originals download). The
make-or-break "does progressive full-res feel instant" path. The simulator can't
exercise real iCloud/optimized-storage timing — this needs a device with optimized
storage on.

- **✅ Session 3 mitigation: neighbour-prefetch.** The pager now warms full-res for the
  **current ± 1 page** (draining each neighbour's degraded→final stream in a cancellable
  background task, so PhotoKit caches the downloaded original). A swipe should then land
  on a sharper image sooner instead of starting the long blur from scratch. **Some
  latency is inherent to the iCloud download** — Phase 2 adds the determinate long-scan
  surface (D12) for the cases where the download genuinely takes a while.
- TODO (Part B, re-feel on-device): does a degraded image appear instantly and sharpen
  in place? With the neighbour-prefetch, **does swiping ± 1 now show a sharper image
  sooner** on a real iCloud library? How long to final on cellular vs Wi-Fi for an
  iCloud-only original? Any blank flashes on fast swipe?

## Lazy-adapter-vs-flat-array numbers (D17)

Settle by benchmark on a real year (thousands of assets): is a flat materialized
`[AssetRef]` snapshot cheap enough that we skip a lazy adapter, or do we need to keep
the live `PHFetchResult` lazy inside the actor and snapshot windows by index range?
("Don't materialize" needs a number, not a reflex — architecture §2.) Note: the
harness's throwaway tier materializes a flat `[PHAsset]` for one date slice; the
**render layer is already typed on `id: String` value snapshots**, so either backing
fits behind the same seam.

- TODO (Part B): record memory + first-render time for a full prior year materialized
  as a flat array vs the windowed/lazy approach. Numbers, not vibes.

## Bytes-per-megapixel separation (D3)

Deferred quality/camera-originals heuristic — **validate, don't build** (D3/D11): a
~30-minute look at ~100 real assets (including iCloud-only) to see whether
bytes-per-megapixel discriminates camera-originals from recompressed at all, across
HEIC/JPEG and megapixel counts. Read the **recorded original** size (not the local
optimized cache). Ship the filter only if it separates cleanly (zero clean-HEIC false
positives — D24). _Note: the harness deliberately does **not** implement this; it's a
separate manual measurement._

- TODO (Part B): bytes/MP distribution for a labeled handful (camera-original vs
  shared/screenshot/recompressed). Does a threshold exist? Go / no-go for the filter.

## Overall feel

The verdict the doc can't pre-decide: does hand-curating a real year *feel* good with
the two-tier triage (grid for obvious calls, full-screen for borderline), and does the
tech hold up at scale?

- _(seeded — author, PR #13)_ "The basic functionality works" — the end-to-end loop
  (fetch → grid → open → select → export) runs on a real library; the UI is not
  ready, as expected for a spike.
- TODO (Part B): does triaging a full year feel fast and non-tedious, or does it drag?
  Where do you stall? This verdict (plus the tap-mapping resolution) is the primary
  Phase-0 gate.

---

## Run on device

The simulator can't exercise scale, iCloud/optimized-storage timing, or the *feel* of
the gestures — Part B runs on the author's device against a real year.

1. **Open** `App/PoimiApp.xcodeproj` in Xcode 26.x (iOS 26 SDK).
2. **Signing** — `PoimiApp` target → Signing & Capabilities → Team **`N4FKQHR5AC`**,
   `Automatic` signing (already set in the project for Debug + Release).
3. **Pick the device** as the run destination (a real iPhone — the spike's value is
   real-library scale + iCloud, which the simulator can't give).
4. **Bundle-id fallback** — the project ships `fi.paretosoftware.poimi`. If automatic
   provisioning rejects it for the device/team, switch the bundle id to
   **`com.valtteriluoma.poimi`** (the team's proven namespace — photo-export ships
   `com.valtteriluoma.photo-export`). _Signing change only; nothing else depends on the id._
5. **Run.** On first launch the app asks for Photos access — choose **Allow Full
   Access** (the spike only exercises the `.authorized` path; `.limited`/`.denied`
   recovery is Phase 2). Without full access it stops on a "not granted" screen.
6. **Exercise the loop:** the date range defaults to the **prior full calendar year**
   (Jan 1 – Dec 31 of last year) so the first run lands on a real, complete year — tap
   **Fetch slice** (or adjust the picker), triage in the **sectioned day-group grid**
   (pinch density, tap the badge to select / tap the cell to open), try the full-screen
   gestures (double-tap, pinch, pan-when-zoomed, interactive pull-down, swipe between),
   select, then **Dump to album** and confirm the album in Photos.
   **Re-evaluate the session-3 work in the same session:** (a) does the **day-grouping**
   make the year manageable (events pop, quiet runs merge — is N = 10 and the gap rule
   right)? (b) is the **zoom/pan smooth** and does the **interactive pull-down** feel
   right? (c) does **neighbour-prefetch** show a sharper image sooner on a swipe? Scroll
   fast to feel the prefetch window at scale across sections.
   _(The tap-mapping and cell-shape A/B toggles are resolved and removed — badge-select
   + square are now hard-coded.)_
7. **Record** the answers above as you go — this doc, not the code, is the Phase-0 output.
