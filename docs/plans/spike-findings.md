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

## Tap mapping

The make-or-break decision (D9/D10, ★ primary gate). The harness ships the plan's
mapping — **tap the badge → select; tap the rest of the cell → open full-screen** —
and is built to also let the alternative (**whole-cell tap → select; open via a
different affordance**) be felt. The real question: which action deserves the cheap
whole-cell tap — *select* (the constant action, done hundreds of times) or *inspect*
(occasional)?

- _(seeded — author, PR #13)_ The grid selection works as wired: tapping the badge
  marked the photo selected; tapping the rest of the image opened it larger. **The
  mapping "reads well so far"** — badge = select, rest = open.
- TODO (Part B): run the alternative mapping over a real year; record which is faster
  and less error-prone, and whether the badge ever mis-fires while scrolling.

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
Apple's Library tab uses justified aspect so you see the real shot. The harness ships
**square** cells (`ThumbnailCell` `.aspectRatio(1, contentMode: .fit)` + `scaledToFill`).

- TODO (Part B): does square cost you real calls (framing/horizon/crop decisions) you
  can't make without opening? Worth prototyping justified aspect if so.

## Scroll-restore feel

`AssetGridView` uses `.scrollPosition(id:)`; the pager writes the current page back to
`scrollAnchorID` so dismissing returns the grid to whichever photo you swiped to
(D22 — "which photo we land back on"). Paired with `.matchedTransitionSource` +
`.navigationTransition(.zoom)`.

- TODO (Part B): on return, do you land on the photo you ended on, centered and with
  the zoom transition reading cleanly? Any jump/flicker with recycled cells?

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
- TODO (Part B): do these *feel* right? Is 2.5× the right double-tap step? Is the
  pull-down threshold/curve good, and should it be fully interactive (track the finger
  to the grid) rather than a threshold dismiss? Does pinch fight the page swipe at the
  zoom boundary? Should select stay visible while zoomed?

## Progressive / iCloud timing

`FullImageLoader` streams opportunistic **degraded → final** full-res with
`isNetworkAccessAllowed = true` (iCloud-optimized originals download). The
make-or-break "does progressive full-res feel instant" path. The simulator can't
exercise real iCloud/optimized-storage timing — this needs a device with optimized
storage on.

- TODO (Part B): does a degraded image appear instantly and sharpen in place? How long
  to final on cellular vs Wi-Fi for an iCloud-only original? Any blank flashes on fast
  swipe between photos?

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
   **Fetch slice** (or adjust the picker), triage in the grid (pinch density, tap to
   select/open), try the full-screen gestures (double-tap, pinch, pull-down, swipe
   between), select, then **Dump to album** and confirm the album in Photos.
7. **Record** the answers above as you go — this doc, not the code, is the Phase-0 output.
