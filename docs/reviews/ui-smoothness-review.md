# UI Smoothness Architecture Review

**Reviewer perspective:** senior Swift / iOS architect
**Date:** 2026-06-25
**Scope:** the review-grid hot path and the conventions that feed it
**Question asked:** *Will the conventions in this app keep the UI smooth?* (the stated top priority)
**Commit reviewed:** `53daed3` (merge of #67, "review grid + in-grid selection")

> **Revision note (peer-reviewed, 2026-06-25).** This document was reviewed by three personas
> (Swift Architect, Test Engineer, Pragmatic Developer) and revised. Material corrections from
> that pass: **Finding 1 downgraded 🔴→🟡** (its `.scrollPosition` mechanism was overstated — it
> does *not* write per-frame); **Finding 1's fix changed to favour hoisting into `CandidateStore`**
> (testability + a calendar-staleness pitfall a naive memo would introduce); **Finding 2's fix
> corrected** (a cache *behind the actor* still incurs the async hop — it must be a synchronous
> front); **the process gate corrected** (the 10k seed already exists; an Instruments pass is not
> CI-automatable — replaced with a grep guard + headless timing smoke). New lower-confidence
> findings (pinch re-layout storm, `groupIdentity` coupling) added from the architect pass. The
> per-persona provenance is in the appendix.

---

## Executive verdict

**The foundation is genuinely well-built for smoothness — better than most apps at this
stage of development.** The decisions that usually wreck a photo grid (per-tap disk writes,
main-thread PhotoKit fetches, whole-grid re-renders on selection, eager image materialization)
were all made *correctly and deliberately*. The pure `Curation` boundary keeps the expensive
logic out of the view layer and unit-tested.

**There are no ship-blockers.** The headline issue (Finding 1) is a real, avoidable main-thread
hitch on the review grid that contradicts the code's own documented invariant — but it is a
one-line-class hoist, not a fire drill, and its cost was originally dramatized (see the revision
note). The two further items (a thumbnail spinner-flash on cell recycle; repeated JSON decoding
in the album list) are lower severity, and one is already acknowledged in a code comment.

Net: the bones are right and the risky architectural decisions were all made correctly. The work
remaining is a small set of cheap, targeted fixes — not a rethink.

Severity legend used below:

| Marker | Meaning |
| --- | --- |
| 🔴 **Critical** | Ship-blocker; will reliably drop frames at target scale. *(none found)* |
| 🟡 **Medium** | A real hitch / perceived-smoothness cost, or a bounded cost that will grow. Fix, but not a blocker. |
| 🟢 **Sound** | Verified correct — a decision that actively protects smoothness; do not regress. |
| 🔵 **Investigate** | Plausible smoothness cost raised in peer review, not yet measured. Profile before acting. |

---

## 🟡 Finding 1 — `DayGrouping` recomputes in a SwiftUI `body` on the scroll/tap path

**Severity:** Medium (an avoidable main-thread hitch on settle/tap/restore; not a per-frame storm)
**Files:** `App/PoimiApp/Review/ScanningView.swift:71-79`,
`App/PoimiApp/Review/ReviewGridView.swift:32,75,108`,
`Curation/Sources/Curation/DayGrouping.swift:68-144`

### What the code does

The day-grouping is computed *inside the view body*, as an argument to `ReviewGridView`:

```swift
// ScanningView.swift:71-79
case .ready(let assets):
    // The grid sections by the same adaptive day-groups the overview/completion use. Grouped
    // here (not in the store) so the store's `.ready` stays a plain `[AssetRef]` for tests;
    // this runs once per ready render — selection toggles re-render the grid, not this view.
    ReviewGridView(
        groups: DayGrouping.groups(for: assets),     // ← O(n log n) sort + bucket, every body eval
        openAsset: { coordinator.openPhoto($0) },
        zoomNamespace: zoomNamespace,
        scrollAnchorID: $scrollAnchorID)
```

The comment (line 73-74) asserts the invariant the design relies on:

> *"this runs once per ready render — selection toggles re-render the grid, not this view."*

### Why the invariant is false

The author correctly reasoned that **selection** toggles will not re-render `ScanningView`
(selection is observed by the cells/headers, not the parent). But they missed a second source of
re-evaluation that they introduced themselves: **the scroll anchor.**

`scrollAnchorID` is `@State` **owned by `ScanningView`** (`ScanningView.swift:29`), and it is wired
**two-way** into the grid's scroll position:

```swift
// ReviewGridView.swift:75
.scrollPosition(id: $scrollAnchorID, anchor: .center)
```

`.scrollPosition(id:anchor:)` is a read/write binding — SwiftUI writes the anchored item's id back
into it — and it is also written on **every cell tap** (`ReviewGridView.swift:108`:
`onOpen: { scrollAnchorID = id; openAsset(id) }`) and by the **photo viewer on swipe-dismiss**
(#36). Every such write mutates `ScanningView`'s `@State`, invalidates its `body`, re-enters the
`.ready` branch, and calls `DayGrouping.groups(for: assets)` **again** on the main thread.

**Corrected frequency (peer review).** The original draft claimed this fires "during fast
scrolling … the worst place." That is overstated. `.scrollPosition(id:)` does **not** write
per-frame; it writes when the *anchored item's identity changes* (row-granularity) and on
settle — plus on tap and viewer-dismiss. So the recompute recurs **tens of times per fling and
once per tap/restore**, not 60×/sec. It is an avoidable hitch at the moment the user expects a
tap/zoom/scroll-stop to feel instant — real, but not a continuous storm.

### What that recompute costs

`DayGrouping.groups(for:)` defensively **re-sorts the entire input every call**
(`DayGrouping.swift:135-144`, full O(n log n)), buckets every asset by calendar day, walks the day
order, and **allocates a fresh `[DayGroup]`**. The product target is "a year (or any date range)"
— realistically low thousands of assets in the common case, up to tens of thousands at the ceiling.
At ~2k assets a single pass is sub-millisecond; at the 10k ceiling it is single-digit milliseconds.
The freshly-allocated array also forces `ForEach(groups)` (`ReviewGridView.swift:63`) to re-diff the
section structure (cheap — `DayGroup` is `Equatable` — but non-zero).

So the honest framing: *not* a guaranteed dropped frame, but unbounded, wholly avoidable
main-thread work executed on the interaction path of the make-or-break screen, plus a documented
invariant that is simply wrong and will mislead the next person who reads it.

### Why it would pass review and bite later

On a small or recent test library the candidate count is low and the recompute is imperceptible —
so it builds green and the latent cost ships, surfacing only at the product's target scale on a
real device.

### Direction (not yet implemented) — prefer hoisting into the store

Compute the grouping **once**, when `.ready` is reached, and pass the stable value down. Two
options were considered; **option 1 is now recommended** on both testability and correctness
grounds (this changed in peer review):

1. **Group in `CandidateStore`** when it transitions to `.ready` — change
   `Phase.ready([AssetRef])` to `.ready([DayGroup])` (`CandidateStore.swift:33`). `DayGroup` is
   already `Equatable`, so `Phase` stays `Equatable` and existing `store.phase == .empty`
   assertions keep compiling. **Why preferred:**
   - *Testable.* The regression guard becomes a plain store-state assertion ("`.ready` carries the
     expected `[DayGroup]`"), in the exact shape `CandidateStoreTests` already uses
     (`CandidateStoreTests.swift:47-53`). A "computed once per body render" assertion is **not**
     realistically implementable (SwiftUI gives no supported render-count hook), so leaving the
     call in the view leaves the fix unverifiable.
   - *Forces the calendar decision into the open.* See the pitfall below.
2. **Memoize in `ScanningView`** via `@State` populated in the existing `.task(id: project.id)`
   (`ScanningView.swift:37`). Smaller diff, doesn't touch the store's payload — but has **no clean
   unit test**, and a naive memo is exposed to the calendar pitfall.

**Calendar / timezone pitfall (peer review — must address in either option).**
`ScanningView.swift:76` calls `DayGrouping.groups(for:)` with **no `calendar:` argument**, so it
uses the default `.current` (`DayGrouping.swift:72`) — while every existing grouping test pins a
fixed UTC calendar. The current in-`body` recompute is *accidentally self-healing*: if the user
crosses a timezone or the locale changes, the next re-eval regroups with the new calendar. **A
naive memo keyed only on "asset-set identity" would silently go stale.** The hoist must either key
the memo on calendar identity, invalidate on `NSCurrentLocaleDidChange` / timezone change, or make
the store own an explicit injected calendar that is covered by a test. This calendar choice is
currently *untested* and should gain a test as part of the fix.

A static **grep guard** (in the spirit of `Scripts/check-curation-boundary.sh`) makes the fix
durable: assert `DayGrouping.groups` never appears in `App/PoimiApp/Review/*View.swift`.

---

## 🟡 Finding 2 — guaranteed thumbnail spinner-flash on every cell recycle

**Severity:** Medium (perceived smoothness; a flicker, not dropped frames). Highest value-per-effort
item in this review.
**Files:** `App/PoimiApp/Review/ReviewGridCell.swift:30,65-68`,
`App/PoimiApp/PhotoLibrary/SystemThumbnailProvider.swift:19,33-67`

### What the code does

```swift
// ReviewGridCell.swift:30
@State private var image: UIImage?

// ReviewGridCell.swift:65-68
.task(id: id) {
    image = nil                 // ← unconditionally clears to placeholder on every recycle
    image = await load(id)
}
```

When a `LazyVGrid` cell recycles onto a new asset, `.task(id:)` re-runs, sets `image = nil`
(rendering the `ProgressView` branch at `ReviewGridCell.swift:41-43`), then awaits the load.

### Why it flickers even when the image is "cached"

There is **no synchronous decoded-image cache** anywhere in the pipeline. `SystemThumbnailProvider`
holds resolved `PHAsset`s and drives `PHCachingImageManager`, but **every** image fetch is an
`async` actor hop wrapped in `withCheckedContinuation` (`SystemThumbnailProvider.swift:33-67`).
`PHCachingImageManager` pre-*decodes* and holds images in *its* cache but exposes **no synchronous
accessor** — delivery is always through the async `requestImage` callback. So even on a fully
primed asset, a recycled cell still: clears to `nil` → shows the spinner → hops to the actor →
awaits the callback. On a fast scroll-back over already-seen rows the user sees a wave of
`ProgressView` spinners over content that is effectively in memory. This is the single most common
"this feels cheap" tell in a photo grid, and the app's #1 stated priority is smoothness.

### Direction (not yet implemented) — corrected from the original draft

The original draft said "add a cache *in `SystemThumbnailProvider`*." That is **wrong as stated**:
the provider is an `actor` (`SystemThumbnailProvider.swift:19`), so any cache read there is `async`
and **still incurs the actor hop** — it would not remove the `nil` frame. The fix must give the
cell a **synchronous** path:

- A small, bounded `NSCache<NSString, UIImage>` exposed as a **`nonisolated`** front (NSCache is
  its own thread-safe class, and `UIImage` is safe for concurrent reads, so this is Sendable-clean),
  or threaded through the environment, so the cell can check it **synchronously inside `body`** and
  seed `image` without ever rendering the placeholder on a hit.
- This is *complementary* to `PHCachingImageManager`, not a duplicate: the manager solves decode
  latency; the synchronous cache solves the mandatory-async-hop `nil` frame. NSCache auto-evicts
  under memory pressure, so bound it with `countLimit` and clear it in `resetCache()` alongside the
  existing `assetsByID` reset (`SystemThumbnailProvider.swift:104-111`).

**Testability note (peer review).** This fix is only verifiable if the "should the cell clear to
`nil`?" decision is hoisted into a **pure helper** — e.g. a `ThumbnailCacheKey(assetID:size:)` plus
an `enum CellImageState { case cached(UIImage), needsLoad }` resolver — and unit-tested at the value
level. `FakeThumbnailProvider` is stateless (`FakeThumbnailProvider.swift:15-21`) and
`SystemThumbnailProvider` is not reachable in the headless/simulator tiers, so the flicker logic
cannot be asserted through the seam as it stands.

**Status: fixed (this PR).** Implemented exactly as above: `ThumbnailMemoryCache` (synchronous,
`@unchecked Sendable` over a thread-safe `NSCache`), a `nonisolated cachedThumbnail(...)` on the
seam, the provider fills it with the final (non-degraded) image, and the cell paints a hit via the
pure `thumbnailDisplay(...)` resolver — never clearing to a placeholder on a hit. **Coverage
boundary (peer review):** the *decision logic* is unit-tested (the resolver's placeholder rule + the
cache's store/lookup/keying), but the cell's `.task(id:)` recycle path that drives `loadedID`/`image`
is **not** rendered in a test — the project has no SwiftUI view-rendering test tier, so the
spinner-flash regression is guarded at the pure-function seam, not at the live recycle. A device/UI
test is the residual, tracked for the on-device pass (#46).

---

## 🟡 Finding 3 — album list decodes the selection blob repeatedly per row

**Severity:** Medium (currently bounded; will grow; **already acknowledged in-code** — defer)
**Files:** `App/PoimiApp/Persistence/CurationProject.swift:93-109`,
`App/PoimiApp/Albums/AlbumsView.swift:77-128`,
`App/PoimiApp/State/ProjectStore.swift`

### What the code does

`persistedPickedCount` runs a `JSONDecoder` pass on each access (`CurationProject.swift:99-101`),
and `status` decodes again (`:105-109`). `AlbumRow` reaches these through a **computed** `summary`
property (`AlbumsView.swift:80`) referenced in both the `Text` (`:98`) and the `accessibilityLabel`
(`:108`), while `statusSymbol` (`:113-119`) / `statusTint` (`:121-127`) each call `project.status`
again. `AlbumSummary(project:)` itself calls both `status` and `persistedPickedCount`
(`AlbumsView.swift:145-147`). That is roughly **half a dozen JSON decodes of the id-set blob per
row, per render.** Compounding it, `ProjectStore.refresh()` replaces the **entire** `projects` array
on every mutation, re-rendering the whole `List`.

### Why it is Medium and deferred

This is the album library, not the scroll-critical grid: a handful of rows, rendered occasionally.
The code already calls the trap out and accepts it for v1:

```swift
// CurationProject.swift:96-98
// Decodes the blob on each access — fine at v1 scale (a handful of projects, read once per
// library render). If the album-list cell ever decodes large snapshots every frame, cache
// this (or store a cheap `pickedCount: Int` column alongside the blob).
```

That is a reasonable call, and all three review personas agreed: **do nothing now.** Building a
stored `pickedCount` column means a property kept in sync on every flush plus a migration concern —
premature for a surface (#32) that just landed. The in-code comment serves as the ticket; revisit
when snapshots exceed a few hundred ids **or** the album count grows. When that fix lands, the
stored-`pickedCount` column is also what makes the decode-count assertable (today there is no
injection point and no existing test would catch a regression here).

---

## 🔵 Additional findings raised in peer review (investigate before acting)

These were surfaced by the architect pass, are plausible on inspection, but have **not been
measured**. Two of them are arguably more likely real-device frame-drop sources than Finding 1's
settle-time recompute. Profile before committing fixes.

### 🔵 4 — Pinch → `columnCount` re-layout / animation / prefetch storm
**`ReviewGridView.swift:56-58,76,79-90`.** `MagnifyGesture.onChanged` mutates `columnCount` on
*every gesture sample*. `columnCount` drives `columns` (a full `LazyVGrid` re-layout), is animated
by `.animation(.snappy, value: columnCount)`, **and** fires `.onChange(of: columnCount)`
→ `scheduleRecomputeWindow()` — so each pinch tick triggers re-layout **+** animation **+** a
prefetch-window recompute. (Note: this revises the original draft's dismissal of the `.animation`
line — the line is correctly value-scoped, but the `onChange` storm next to it is the real concern.)
Likely wants a throttle / quantization so `columnCount` changes only when it crosses an integer
boundary, not on every sample.

**Status: addressed (defensive).** `ReviewGridView`'s `MagnifyGesture.onChanged` now writes
`columnCount` only when the rounded value actually changes, so the re-layout, the `.snappy`
animation, and the `.onChange`-driven prefetch recompute fire once per step instead of per gesture
sample. Unmeasured (no device profiling available) — the change is purely a redundant-write guard.

### 🔵 5 — `groupIdentity` onChange rebuilds the whole prefetch window
**`ReviewGridView.swift:92-96,120-122`.** `.onChange(of: groupIdentity)` resets `visibleIDs = []`
and rebuilds the entire `PrefetchWindow`. `groupIdentity` is a string of `first-id # total-count`,
so a *deterministic* regroup should keep it stable and not fire — but that means Finding 1's "fresh
array forces a re-diff" coexists with a window that *doesn't* rebuild, a tension worth reconciling.
This `groupIdentity` ↔ `visibleIDs` ↔ window coupling is the most fragile wiring on the screen and
deserves a focused look when Finding 1 is addressed.

**Status: resolved by Finding 1.** Grouping is now computed once in `CandidateStore`, so the
`groups` the grid receives are stable across scrolls and taps — `groupIdentity` no longer changes
mid-session, so the `visibleIDs`-reset + window-rebuild only fires on a genuine new grouping (a new
project / reload), which is the intended trigger. No further change needed.

### 🔵 6 — Per-cell `.task` actor-hop steady-state cost
**`ReviewGridCell.swift:65`.** Every cell recycle spins up a `Task` that hops to the actor and sets
up a continuation. At 5-8 columns scrolling fast this is a high rate of task creation + actor hops.
The cancellation design is correct (and credited below); the steady-state hop cost is simply
unmeasured. The synchronous cache from Finding 2 would also relieve this (a hit avoids the hop).

**Status: relieved by Finding 2.** With the synchronous `cachedThumbnail` front, a recycle onto a
primed asset is satisfied in `body` with no `Task` spawn and no actor hop at all; only a genuine
cold cell takes the async path. The remaining cold-load hop is inherent and unmeasured.

### 🔵 7 — `.scrollPosition` restore + pinned headers
**`ReviewGridView.swift:62,75`.** `pinnedViews: [.sectionHeaders]` combined with
`.scrollPosition(id:anchor: .center)` over variable-height sections is a known source of
restore-jump jank — directly relevant to the #36 zoom-dismiss restore path. Verify the restore
lands cleanly on a busy-day boundary.

**Status: open — deferred to #36.** The full-screen viewer that exercises the restore path is #36
and not built yet (`openAsset` currently just records the anchor). There is nothing safe to change
blind; verify on a device once #36 lands.

---

## 🟢 What is already right (do not regress)

Verified-correct decisions that actively protect smoothness — the reason the app is in good shape
and the reason Finding 1 is a hoist rather than a rewrite.

### Selection is in-memory, mutated per-tap, debounced to disk (D15)
`App/PoimiApp/State/SelectionStore.swift`. In-memory `Set<String>` mutated synchronously on tap
(`toggle`, `:77-89`); durability is a **debounced** snapshot (`scheduleFlush`, `:107-116`) flushed
on background / project-switch. No per-tap SwiftData write — the single biggest persistence trap,
deliberately avoided. The debounce is keyed by `PersistentIdentifier` and re-validated in `write`
(`:118-132`) so a stale timer can't cross projects.

### A selection toggle re-renders only the *visible* cells, never the O(n) grid
`ReviewGridView.swift:13-16`, `ReviewGridCell.swift:29,33`. Cells/headers observe `SelectionStore`
via `@Environment`; the parent grid `body` does **not** read `selected`. With `LazyVGrid` laziness
+ property-scoped `@Observable` invalidation, a toggle re-renders only the ~20-50 on-screen cells.
*Subtlety (peer review):* `@Observable` tracks the whole `selected` property, not per-element, so a
toggle invalidates *all* visible cells (not just the tapped one) and each visible
`ReviewSectionHeader` recomputes `selected.intersection(group.assetIDs)` (`ReviewGridView.swift:176`,
`O(min(|selected|, group))` per visible header). Bounded and fine — but it is "all visible cells,"
not "only the tapped cell."

### PhotoKit work is off the main actor
`SystemThumbnailProvider` is a plain `actor` (`SystemThumbnailProvider.swift:19`); `SystemPhotoLibrary`
likewise (`SystemPhotoLibrary.swift:22`), so the heavy `enumerateObjects` materialization (`:44-49`)
runs off-main. Only finished value arrays cross back.

### Per-cell PhotoKit request cancellation tied to recycling
`ReviewGridCell.swift:65` + `SystemThumbnailProvider.swift:40-66` — recycling cancels the old
asset's in-flight request. Important under fast scroll.

### Resolved-`PHAsset` caching + batch resolution
`SystemThumbnailProvider.swift:78-83,113-118` — the prefetch window batch-resolves missing ids in a
single fetch and caches them; `resetCache()` bounds session growth (`:104-111`).

### The generation-guarded prefetch updater
`ReviewGridView.swift:128-141` — single in-flight updater that loops to the latest visible
generation, so out-of-order completions can't cache a stale window. Not a busy-spin: each iteration
`await`s the actor.

### The prefetch windowing math is a pure, tested value
`PrefetchWindow.swift` — built once per slice (O(n) index map), queried O(visible) per scroll tick;
extracted from the view so the "smooth over thousands" property is unit-tested.

### The pure `Curation` domain boundary
Grouping/filtering live in a dependency-free SPM package, unit- and property-tested headlessly
(`GroupingTests`, `PropertyTests` — 250 randomized seeds, DST stability, partition/no-loss). This is
the empirical safety net that makes the Finding 1 hoist low-risk: `groups(for:)` is pure and
order-independent of its call site, so moving *where* it is called cannot change *what* it returns.

---

## One item checked and dismissed

For the record: the **coordinator `path` mutation** (`AppCoordinator`) is standard `@Observable` +
`NavigationStack(path:)` usage — no observation race. (The original draft also dismissed
`.animation(.snappy, value: columnCount)`; that dismissal is **partly revised** — the `.animation`
line itself is correctly value-scoped, but the adjacent `.onChange(of: columnCount)` storm is now
tracked as 🔵 Finding 4.)

---

## The one convention-level risk

The conventions are strong, but Finding 1 exposes a blind spot: **the codebase reasons about
re-renders informally in comments, and that reasoning was wrong on the most important screen.**
"This runs once per ready render" was *asserted*, not *measured* — and missed a second write path
into the same `@State`.

One convention would have caught Findings 1 and 3 at review time:

> **No non-trivial computation (sorts, decodes, groupings, large allocations) in a SwiftUI `body`,
> or in a computed property read from `body`. Compute in `.task` / `@State` / the store, and pass
> finished values down.**

This is free — a one-line code-review heuristic worth adding to `CLAUDE.md`'s conventions.

**Process gate — corrected (peer review).** The original draft proposed an Instruments Time
Profiler pass as a Definition-of-Done gate "against a seeded ~10k-asset library." Two corrections:
the seed **already exists** (`FakePhotoLibrary.scale(10_000)`, already exercised by a perf-smoke test
at `FakePhotoLibrarySeedTests.swift:74-81`), and an Instruments trace is **not CI-automatable** —
it is a manual, human-judged artifact with no pass/fail threshold, so it cannot gate a PR. The
proportionate, in-convention substitutes:

1. **A static grep guard** — `DayGrouping.groups` must not appear in `App/PoimiApp/Review/*View.swift`
   (mirrors `Scripts/check-curation-boundary.sh`). CI-runnable; directly prevents Finding 1's
   regression.
2. **A headless timing smoke** in the integration tier over the existing `scale(10_000)` seed —
   load the store, assert grouping happens once and completes under a generous wall-clock bound.
   Won't catch frame drops, but is CI-runnable and would have caught Finding 1's repeated recompute.
3. **A one-time, manual large-library eyeball-scroll** on a device before the grid ships (#35/#37) —
   ad hoc, *not* a per-PR ritual (which would be written down and never honored on a small project).

---

## What to do

| When | Item | Effort |
| --- | --- | --- |
| **Now** | Finding 1 — hoist grouping into `CandidateStore` (`.ready([DayGroup])`), fix the wrong comment, make the calendar explicit + tested, add the grep guard. | ~30-45 min |
| **Now** | Finding 2 — synchronous (`nonisolated`) thumbnail cache so a hit skips the placeholder; hoist the clear-to-nil decision into a pure, tested helper. | ~1 hr |
| **Profile, then decide** | Findings 4-7 (pinch storm, `groupIdentity` coupling, per-cell hop, pinned-header restore) — measure on a device / Instruments before fixing. | varies |
| **Defer / ticket** | Finding 3 — leave the code; the in-code comment is the ticket; revisit when snapshots/album-count grow. | — |
| **Adopt (free)** | The "no heavy work in `body`" convention in `CLAUDE.md`. | trivial |

---

## Summary table

| # | Finding | Severity | Path | Status |
| --- | --- | --- | --- | --- |
| 1 | `DayGrouping` recomputed in `ScanningView.body` via `scrollAnchorID` `@State` writes | 🟡 Medium | Scroll/tap/restore | **Fixed** (this PR) — grouped once in `CandidateStore` + CI guard |
| 2 | Guaranteed `nil`→spinner frame on every cell recycle; no synchronous image cache | 🟡 Medium | Scroll hot path | **Fixed** (this PR) — synchronous `ThumbnailMemoryCache` front |
| 3 | Album list decodes selection blob ~6× per row per render; full-list re-fetch on mutation | 🟡 Medium | Album library | Defer — acknowledged in-code, fine at v1 |
| 4 | Pinch → `columnCount` re-layout + animation + prefetch recompute per gesture sample | 🔵 Investigate | Pinch gesture | **Addressed** (this PR) — redundant-write guard; unmeasured |
| 5 | `groupIdentity` onChange resets `visibleIDs` + rebuilds `PrefetchWindow` | 🔵 Investigate | Grouping change | **Resolved by #1** — groups now stable across scrolls |
| 6 | Per-cell `.task` actor-hop steady-state cost under fast scroll | 🔵 Investigate | Scroll hot path | **Relieved by #2** — a cache hit avoids the Task/hop |
| 7 | `.scrollPosition` restore + pinned headers restore-jump | 🔵 Investigate | #36 dismiss path | Open — deferred to #36 (viewer not built) |
| — | Selection in-memory + debounced (D15) | 🟢 Sound | — | Keep |
| — | Toggle re-renders visible cells only | 🟢 Sound | — | Keep |
| — | PhotoKit off the main actor | 🟢 Sound | — | Keep |
| — | Per-cell request cancellation on recycle | 🟢 Sound | — | Keep |
| — | Resolved-asset cache + batch resolution | 🟢 Sound | — | Keep |
| — | Generation-guarded prefetch updater | 🟢 Sound | — | Keep |
| — | Pure, tested `Curation` boundary | 🟢 Sound | — | Keep |

**Bottom line:** the bones are right and the risky architectural decisions were all made correctly.
There are no ship-blockers. Two cheap fixes (Findings 1 and 2) clear the real hot-path issues;
Findings 4-7 want a profiling pass before action; Finding 3 is a fair-to-note deferral.

---

## Appendix — peer-review provenance

This document's second revision incorporated a three-persona review. What each persona changed:

- **Swift Architect** — corrected the `.scrollPosition(id:)` mechanism (writes on anchored-item
  change/settle, not per-frame) → Finding 1 downgraded 🔴→🟡; flagged the calendar/timezone
  staleness pitfall in any memoization; corrected Finding 2's actor-isolation gap (a cache behind
  the actor still hops); raised Findings 4-7.
- **Test Engineer** — showed "computed once per body render" is not assertable, making the
  `CandidateStore` hoist (option 1) the testability-decisive choice; noted the spinner-flash fix is
  only testable if the clear-to-nil decision is a pure helper; confirmed `FakePhotoLibrary.scale(10_000)`
  already exists and an Instruments gate is not CI-automatable → proposed the grep guard + headless
  smoke; confirmed existing `GroupingTests`/`PropertyTests` coverage makes the hoist safe.
- **Pragmatic Developer** — pushed back on the original 🔴 severity and the "drops frames during
  fast scroll" framing; endorsed the now/defer/drop prioritization; argued Finding 2 is the highest
  value-per-effort item; rejected the per-PR Instruments ceremony in favour of a one-time eyeball.
