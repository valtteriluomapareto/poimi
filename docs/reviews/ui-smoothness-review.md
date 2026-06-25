# UI Smoothness Architecture Review

**Reviewer perspective:** senior Swift / iOS architect
**Date:** 2026-06-25
**Scope:** the review-grid hot path and the conventions that feed it
**Question asked:** *Will the conventions in this app keep the UI smooth?* (the stated top priority)
**Commit reviewed:** `53daed3` (merge of #67, "review grid + in-grid selection")

---

## Executive verdict

**The foundation is genuinely well-built for smoothness — better than most apps at this
stage of development.** The decisions that usually wreck a photo grid (per-tap disk writes,
main-thread PhotoKit fetches, whole-grid re-renders on selection, eager image materialization)
were all made *correctly and deliberately*. The pure `Curation` boundary keeps the expensive
logic out of the view layer and unit-tested.

**But there is one real defect on the single most important screen** — `DayGrouping` is
recomputed inside a SwiftUI `body` on the scroll/tap hot path — and it directly contradicts the
code's own documented invariant. On a small, recent library you will not feel it; over "a year
of photos" (the actual product target) it is exactly the kind of unbounded main-thread work that
drops frames. Fix that one item and the grid will hold up at scale.

There are two further papercuts (a guaranteed thumbnail spinner-flash on cell recycle; repeated
JSON decoding in the album list) that are lower severity and, in one case, already acknowledged
in a code comment.

Severity legend used below:

| Marker | Meaning |
| --- | --- |
| 🔴 **Critical** | Will drop frames at the product's target scale; on the smoothness-critical path; contradicts a stated invariant. |
| 🟡 **Medium** | Perceived-smoothness / minor hitch; or a real cost that is currently bounded but will grow. |
| 🟢 **Sound** | Verified correct — a decision that actively protects smoothness; do not regress. |

---

## 🔴 Finding 1 — `DayGrouping` recomputes on the scroll/tap hot path

**Severity:** Critical
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

`scrollAnchorID` is `@State` **owned by `ScanningView`**:

```swift
// ScanningView.swift:29
@State private var scrollAnchorID: String?
```

It is wired **two-way** into the grid's scroll position:

```swift
// ReviewGridView.swift:32  (the binding)
@Binding var scrollAnchorID: String?

// ReviewGridView.swift:75  (two-way scroll tracking)
.scrollPosition(id: $scrollAnchorID, anchor: .center)
```

`.scrollPosition(id:anchor:)` is a **read/write** binding: SwiftUI writes the identity of the
item at the anchor *back into the binding as the user scrolls*. On top of that, the binding is
written:

- on **every cell tap** — `ReviewGridView.swift:108`: `onOpen: { scrollAnchorID = id; openAsset(id) }`
- by the **photo viewer on swipe-dismiss** (#36), to restore the source cell.

Every one of those writes mutates `ScanningView`'s `@State`, which invalidates `ScanningView`'s
`body`, which re-enters the `.ready` branch, which calls `DayGrouping.groups(for: assets)`
**again** — on the main thread, mid-interaction.

### What that recompute actually costs

`DayGrouping.groups(for:)` is not cheap-by-construction. It **defensively re-sorts the entire
input every call**:

```swift
// DayGrouping.swift:135-144 — full O(n log n) sort, every call
private static func chronological(_ assets: [AssetRef]) -> [AssetRef] {
    assets.enumerated().sorted { lhs, rhs in
        switch (lhs.element.captureDate, rhs.element.captureDate) {
        case let (left?, right?): return left != right ? left < right : lhs.offset < rhs.offset
        case (nil, _?): return false
        case (_?, nil): return true
        case (nil, nil): return lhs.offset < rhs.offset
        }
    }.map(\.element)
}
```

…then buckets every asset by calendar day, walks the day order doing gap math, and **allocates a
fresh `[DayGroup]` array** (`DayGrouping.swift:155-171`, `:99-120`). The product target is
"a year (or any date range) of your photo library" — that is realistically **thousands to tens of
thousands** of `AssetRef`s. Re-sorting and re-bucketing ~10k elements is single-digit milliseconds
*per call*; at 60 fps the entire frame budget is 16 ms. Worse, the freshly-allocated `[DayGroup]`
forces `ForEach(groups)` (`ReviewGridView.swift:63`) to re-diff the section structure each time.

This is precisely the unbounded main-thread work the grouping was *extracted into a pure value to
avoid* — note the sibling `PrefetchWindow` carries the same "does it stay smooth over thousands of
assets" promise in its own header (`PrefetchWindow.swift:5-8`).

### Why it will pass review and bite later

On a small or recent test library the candidate count is low and the recompute is imperceptible —
so it builds green, screenshots look right, and the latent cost ships. It only manifests at the
product's actual target scale, on a real device, during fast scrolling — the worst place to
discover it.

### Direction (not yet implemented)

Compute the grouping **once**, when `.ready` is reached, and pass the stable value down. Options,
cheapest first:

1. Group in `CandidateStore` when it transitions to `.ready` (store `[DayGroup]` instead of, or
   alongside, `[AssetRef]`). Keeps it off the view entirely. The store's current `.ready([AssetRef])`
   shape is justified for testability (`ScanningView.swift:72-74`), but a `.ready([DayGroup])` is
   equally testable.
2. Memoize in `ScanningView` via `@State` populated in a `.task(id:)` keyed on the asset-set
   identity, so the `body` only reads the cached value.

Either removes the recompute from the interaction path without touching the pure domain logic —
it is a hoist, not a refactor, because the boundary is already clean.

---

## 🟡 Finding 2 — guaranteed thumbnail spinner-flash on every cell recycle

**Severity:** Medium (perceived smoothness; flicker, not dropped frames)
**Files:** `App/PoimiApp/Review/ReviewGridCell.swift:30,65-68`,
`App/PoimiApp/PhotoLibrary/SystemThumbnailProvider.swift:33-67`

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
holds resolved `PHAsset`s (`assetsByID`) and drives `PHCachingImageManager`, but **every** image
fetch is an `async` actor hop wrapped in `withCheckedContinuation`:

```swift
// SystemThumbnailProvider.swift:33-60 (abridged)
func thumbnail(for assetID: String, targetSize: CGSize) async -> UIImage? {
    guard let asset = resolve(assetID) else { return nil }
    ...
    return await withCheckedContinuation { continuation in
        let id = manager.requestImage(for: asset, ...) { image, info in
            ...
            if resumed.setOnce() { continuation.resume(returning: image) }
        }
    }
}
```

So even when the prefetch window (`updateCachingWindow`) has fully primed an asset, a recycled
cell still: clears to `nil` → shows the spinner → hops to the actor → awaits the opportunistic
callback → only then sets `image`. The prefetch window removes the *decode* latency but **not the
guaranteed `nil` frame**. During a fast scroll-back over already-seen rows, the user sees a wave of
`ProgressView` spinners flashing over content that is effectively already in memory.

### Direction (not yet implemented)

Add a small bounded in-memory `NSCache<NSString, UIImage>` keyed by `assetID` (+ quantized size)
in `SystemThumbnailProvider`, returning a hit **synchronously**, so the cell can seed `image`
without nil-ing first (e.g. only clear when there is no cache hit). This removes the flash on
recycle while keeping the actor/PhotoKit path for cold loads. Bound it and clear it in
`resetCache()` alongside the existing `assetsByID` reset (`SystemThumbnailProvider.swift:104-111`).

---

## 🟡 Finding 3 — album list decodes the selection blob repeatedly per row

**Severity:** Medium (currently bounded; will grow; **already acknowledged in-code**)
**Files:** `App/PoimiApp/Persistence/CurationProject.swift:93-109`,
`App/PoimiApp/Albums/AlbumsView.swift:77-128`,
`App/PoimiApp/State/ProjectStore.swift`

### What the code does

`persistedPickedCount` runs a `JSONDecoder` pass on each access:

```swift
// CurationProject.swift:99-101
var persistedPickedCount: Int {
    SelectionSnapshot.decode(selectionSnapshot).assetIDs.count
}

// CurationProject.swift:105-109 — status decodes again
var status: ProjectStatus {
    if markedDoneAt != nil { return .done }
    if persistedPickedCount > 0 || !doneDays.isEmpty { return .inProgress }
    return .empty
}
```

`AlbumRow` reaches these through a **computed** `summary` property and several other computed
accessors, each re-evaluated per render:

```swift
// AlbumsView.swift:80 — computed, not stored: rebuilds AlbumSummary on every access
private var summary: AlbumSummary { AlbumSummary(project: project) }
```

`AlbumSummary(project:)` calls **both** `project.status` (one decode) **and**
`project.persistedPickedCount` (a second decode) — `AlbumsView.swift:145-147`. `summary` is then
referenced in the `Text` (`:98`) **and** the `accessibilityLabel` (`:108`), and `statusSymbol`
(`:113-119`) / `statusTint` (`:121-127`) each call `project.status` again. That is roughly **half a
dozen JSON decodes of the id-set blob per row, per render.**

Compounding it, `ProjectStore.refresh()` replaces the **entire** `projects` array on every
mutation (create / open / duplicate / reset / delete), so the whole `List` re-renders — e.g.
deleting one album re-fetches all projects and re-renders every remaining row.

### Why it is only Medium

This is the album library, not the scroll-critical grid: a handful of rows, rendered occasionally.
The code comment already calls the trap out explicitly and accepts it for v1:

```swift
// CurationProject.swift:96-98
// Decodes the blob on each access — fine at v1 scale (a handful of projects, read once per
// library render). If the album-list cell ever decodes large snapshots every frame, cache
// this (or store a cheap `pickedCount: Int` column alongside the blob).
```

That is a reasonable call. It is listed here so it is not forgotten once snapshots hold hundreds
of ids and the album list grows — at which point the suggested cheap-`Int`-column fix (a stored
`pickedCount` updated on flush) is the clean resolution and should land before this surface ships
for real.

---

## 🟢 What is already right (do not regress)

These are verified-correct decisions that actively protect smoothness. They are the reason the app
is in good shape and the reason Finding 1 is a one-line hoist rather than a rewrite.

### Selection is in-memory, mutated per-tap, debounced to disk (D15)
`App/PoimiApp/State/SelectionStore.swift`. The source of truth is an in-memory `Set<String>`
mutated synchronously on tap (`toggle`, `:77-89`); durability is a **debounced** snapshot
(`scheduleFlush`, `:107-116`) flushed on background / project-switch. No per-tap SwiftData write —
the single biggest persistence trap, deliberately avoided. The debounce is keyed by
`PersistentIdentifier` and re-validated in `write` (`:118-132`) so a stale timer cannot write one
project's picks onto another.

### A selection toggle re-renders only the *visible* cells, never the O(n) grid
`ReviewGridView.swift:13-16`, `ReviewGridCell.swift:29,33`. Cells and headers observe the
`SelectionStore` themselves via `@Environment(SelectionStore.self)`; the parent grid `body` does
**not** read `selected`. Because `LazyVGrid` only instantiates visible cells and `@Observable`
invalidation is property-scoped, a toggle re-renders the ~20-50 on-screen cells (cheap, one-shot),
not the whole grid. The documented invariant here **holds** (unlike Finding 1's).

### PhotoKit work is off the main actor
`SystemThumbnailProvider` is a plain `actor`, not `@MainActor` (`SystemThumbnailProvider.swift:19`)
— PhotoKit's image manager is thread-safe and decode happens on its own queues. The library fetch
is likewise on an `actor` (`SystemPhotoLibrary.swift:22`), so the heavy
`result.enumerateObjects { ... }` materialization (`:44-49`) runs off the main thread. Only the
finished `[AssetRef]` value array crosses back.

### Per-cell PhotoKit request cancellation tied to recycling
`ReviewGridCell.swift:65` (`.task(id:)`) + `SystemThumbnailProvider.swift:40-66`
(`withTaskCancellationHandler` → `manager.cancelImageRequest`). When a cell recycles, the in-flight
request for the old asset is cancelled. Correct and important under fast scroll.

### Resolved-`PHAsset` caching + batch resolution
`SystemThumbnailProvider.swift:78-83,113-118`. The prefetch window batch-resolves missing ids in a
single `fetchAssets(withLocalIdentifiers:)` and caches them, so subsequent single thumbnail
requests are fetch-free. `resetCache()` clears the map to bound session growth (`:104-111`).

### The generation-guarded prefetch updater
`ReviewGridView.swift:128-141`. A single in-flight updater loops until it has applied the latest
visible generation, so out-of-order actor completions cannot leave a stale caching window. This is
**not** a busy-spin — each iteration `await`s the actor call. Good backpressure design for a
scroll-driven producer.

### The prefetch windowing math is a pure, tested value
`PrefetchWindow.swift`. Built once per slice (the O(n) index map), queried O(visible) per scroll
tick. Extracted out of the view specifically so the "smooth over thousands" property is unit-tested
rather than buried in a `View`.

### The pure `Curation` domain boundary
The grouping/filtering logic lives in a dependency-free SPM package (no PhotoKit/UIKit/SwiftUI),
unit- and property-tested headlessly. This is *why* Finding 1 is fixable without risk — the
expensive logic is already isolated; it is merely being *called* from the wrong place.

---

## Two subagent-flagged items checked and dismissed

For the record, two items surfaced during review were investigated and found **not** to be
problems:

- **`.animation(.snappy, value: columnCount)` (`ReviewGridView.swift:76`)** — this is
  *value-scoped*: it animates only when `columnCount` changes (the pinch-to-adjust density gesture),
  **not** on every body re-render. Correct usage. Not a concern.
- **Coordinator `path` mutation (`AppCoordinator`)** — standard `@Observable` +
  `NavigationStack(path:)` usage; no observation race.

---

## The one convention-level risk

The conventions are strong, but Finding 1 exposes a blind spot: **the codebase reasons about
re-renders informally in comments, and that reasoning was wrong on the most important screen.**
"This runs once per ready render" was *asserted*, not *measured* — and the assertion missed a
second write path into the same `@State`.

For an app whose stated #1 priority is smoothness, one convention would have caught both Finding 1
and Finding 3 at review time:

> **No non-trivial computation (sorts, decodes, groupings, large allocations) in a SwiftUI `body`,
> or in a computed property read from `body`. Compute in `.task` / `@State` / the store, and pass
> finished values down.**

Pair it with a process gate:

> **Run an Instruments Time Profiler pass on the review grid against a seeded ~10k-asset fake
> library as part of the Definition of Done for the grid issues (#35 / #37).** The existing
> screenshot harness eyeballs *layout* but cannot surface a main-thread *hitch*; a seeded
> large-library profiling pass would have caught Finding 1 immediately.

---

## Summary table

| # | Finding | Severity | Path | Status |
| --- | --- | --- | --- | --- |
| 1 | `DayGrouping` recomputed in `ScanningView.body` via `scrollAnchorID` `@State` churn | 🔴 Critical | Scroll/tap hot path | Open — contradicts documented invariant |
| 2 | Guaranteed `nil`→spinner frame on every cell recycle; no synchronous image cache | 🟡 Medium | Scroll hot path | Open |
| 3 | Album list decodes selection blob ~6× per row per render; full-list re-fetch on mutation | 🟡 Medium | Album library | Open — acknowledged in-code, acceptable at v1 |
| — | Selection in-memory + debounced (D15) | 🟢 Sound | — | Keep |
| — | Toggle re-renders visible cells only | 🟢 Sound | — | Keep |
| — | PhotoKit off the main actor | 🟢 Sound | — | Keep |
| — | Per-cell request cancellation on recycle | 🟢 Sound | — | Keep |
| — | Resolved-asset cache + batch resolution | 🟢 Sound | — | Keep |
| — | Generation-guarded prefetch updater | 🟢 Sound | — | Keep |
| — | Pure, tested `Curation` boundary | 🟢 Sound | — | Keep |

**Bottom line:** the bones are right. The risky architectural decisions were all made correctly.
Fix Finding 1 (a hoist of `DayGrouping.groups` out of the `body`, ideally with a regression test
that asserts the grouping is computed once per `.ready`), and the review grid will stay smooth at
the product's target scale.
