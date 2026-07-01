# Spike findings (Phase 0) — CLOSED

> **Status: closed.** Phase 0 was a throwaway spike on the author's **real** photo library to
> answer the questions a doc (and the fake) structurally can't — does hand-curating a year *feel*
> good, and does the tech hold up at scale. This doc is the **durable Phase-0 output**: the spike
> code is disposable, this evidence is not. Its verdicts seeded Phase 1 (the `Curation` domain) and
> Phase 2 (the review grid, navigation, persistence). The harness still drives the app today and is
> deleted when the real review grid replaces it (#35).

The spike was the make-or-break gate for the picking interaction (#5★), grouping/density (#6), the
lazy-vs-flat data shape (#7), and the iCloud path (#8). What it settled, and what it deliberately
left for later, is below.

---

## Resolved — the verdicts that drove Phase 1/2

| Question | Verdict | Evidence |
|---|---|---|
| **Tap mapping** (#5★ — the primary gate) | **Badge-select + cell-opens.** Tap the badge → select; tap the rest → open full-screen. | On-device A/B against the same real year; whole-cell-select + long-press-to-open lost ("the select with badge feels better"). Canonical in styleguide §6. |
| **Cell shape** | **Square.** | On-device ("square is good"); the aspect path was dropped. *(Later refined: a ~3pt gutter + ~6pt corner rounding, Apple-Photos-style — still square. See styleguide §3/§4.)* |
| **Column density** | **3 columns on iPhone**, pinch-adjustable. | Confirmed on-device. iPad wants more (adaptive). |
| **Badge hit target** | **A ≥44pt corner zone works** — no mis-fire during fast triage. | On-device. |
| **Scroll-restore** | **Good** — returning from full-screen lands on the photo you swiped to, cleanly, with the zoom transition. | On-device, with `.scrollPosition(id:)` + the pager writing the page back. |
| **Timeline grouping** (#6, the headline finding) | **Required.** The flat chronological grid made a year *harder than Apple Photos*; **adaptive day-grouping** (busy days stand alone, quiet days merge) makes it manageable. Implemented in the spike as the pure `SpikeGrouping` precursor to `Curation`'s grouping. | On-device, repeatedly. N = 10/day + the gap rule held. |
| **A coarser overview level is needed** | **Confirmed.** One grid level isn't enough to scan a whole *year*; an overview *above* the selection grid (à la Photos' Years/Months) is wanted — drill from overview into the day-group grid where selection happens. | On-device. Informs the navigation model (D20) and the Overview screen (#37). |
| **Zoom / pan in the viewer** | **Solved** by a `UIScrollView`-backed zoomable image (native pinch + pan + double-tap at 60/120fps), replacing the laggy SwiftUI `MagnifyGesture` + `offset`. | On-device ("works and makes sense"). |
| **Pull-down-to-dismiss** | **Interactive** — photo tracks the finger and scales, backdrop fades, release past a threshold dismisses; coexists with paging + zoom. | On-device. |
| **iCloud progressive load** | **Mitigated, not eliminated.** Neighbour-prefetch (current ±1 page) lands a sharper image sooner; some latency is inherent to the iCloud download — Phase 2 adds the determinate long-scan surface (D12). | On-device (iCloud-only originals stay blurry without the prefetch). |
| **Scale / smoothness** | **Good** once the pager decode was bounded (~2048pt, not `MaximumSize`), fetch/grouping moved off-main, and the prefetch window driven from the visible range. | On-device over a real year. **Caveat:** an intermittent stall over a long session was observed and not fully root-caused — re-watch in the real grid (#35). |
| **Two-tier picking loop** (grid for obvious, full-screen for borderline) | **Validated.** The end-to-end loop (fetch → grid → open → select → export) feels right on a real library. | On-device. |

The picking interaction (#5★), grouping/density/cell-shape (#6), and the iCloud path (#8) gates are
**passed**. The runtime A/B toggles (tap mapping, cell shape) did their job and were removed; the
spike hard-codes the winners.

## Not separately quantified — tracked elsewhere

The spike resolved these *by decision/observation*, not by recorded numbers. They are not blockers;
each has a home where it's actually settled:

- **Lazy adapter vs flat `[AssetRef]` array (#7 / D17).** The harness materialized a flat array for
  one slice and stayed smooth, but no memory/first-render numbers were recorded against a windowed
  adapter. The architecture commits to a **main-actor windowed snapshot served from the actor**
  (architecture §2); the "don't materialize the whole result" claim is enforced not by a spike
  number but by the **access-counting / scale guard (D29)** landing with the real fetch tier (#34).
- **Bytes-per-megapixel separation (#9 / D3).** The quality / camera-originals filter stays
  **deferred** (D3). The spike did *not* measure the bytes/MP distribution; that measurement is a
  precondition of ever building the filter (Phase 4), with the labeled-corpus metrics of D24.

## How it fed the build (salvaged code)

Per D1's three-tier rule, the fiddliest spike code was written to be promoted, and was:

- **`SpikeGrouping`** → the deterministic, PhotoKit-free grouping function (takes `(id, Date?)`,
  returns value groups) that lifted into `Curation`'s `DayGrouping` almost verbatim, where it earns
  the property tests the boundary buys.
- **The render layer** — windowed `PHCachingImageManager` prefetch, `.scrollPosition` restore, the
  `UIScrollView` zoomable viewer, the interactive pull-down, the `.zoom` transition — is the
  reference for the Phase-2 review grid (#35) and viewer (#36), promoted behind the protocol seam.
- **Thrown away** — the spike's data/fetch/selection/export shortcuts (replaced by the real
  `PhotoLibraryProviding` actor + the stores).

---

## Running the spike on device (until #35 replaces it)

The simulator can't exercise scale, iCloud/optimized-storage timing, or the *feel* of the gestures —
the spike is meant for a real device against a real year.

1. **Open** `App/PoimiApp.xcodeproj` in Xcode 26.x (iOS 26 SDK).
2. **Signing** — `PoimiApp` target → Signing & Capabilities → Team **`N4FKQHR5AC`**, `Automatic`
   (set for Debug + Release). Bundle id `com.valtteriluoma.poimi` (the team's namespace) should
   provision without a change.
3. **Pick a real iPhone** as the destination (the spike's value is real-library scale + iCloud).
4. **Run.** Grant **Allow Full Access** (the spike only exercises `.authorized`; the
   `.limited`/`.denied` recovery is Phase 2, #31). The range defaults to the prior full calendar
   year. Triage in the sectioned day-group grid (tap badge → select, tap cell → open), try the
   full-screen gestures, then **Dump to album** and confirm it in Photos.
