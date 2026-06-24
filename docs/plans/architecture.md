# Poimi — App Architecture

*Companion to [product-plan.md](./product-plan.md). Modern Swift throughout.*

> Revised after the four-perspective plan review — see [plan-review-decisions.md](./plan-review-decisions.md) for the decisions referenced below as (D#).

---

## Stack decisions

| Choice | Pick | Why |
|---|---|---|
| Min target | **iOS 26 / iPadOS 26** | A new app with no install base to protect: target the latest for **pure Liquid Glass with no fallback code** and the newest SwiftUI/PhotoKit APIs. Reach isn't the lever for a niche audience; polish is. (The `.navigationTransition(.zoom)` interaction predates 26 — it's not the reason; pure Liquid Glass is.) |
| UI | **SwiftUI only** | No UIKit unless forced (none expected). |
| State | **Observation (`@Observable`)** | No Combine, no `ObservableObject` boilerplate. |
| Concurrency | **Swift 6 language mode, strict concurrency** | PhotoKit isn't Sendable-friendly; isolate it behind an actor, keep UI on `@MainActor`. |
| Persistence | **SwiftData** | For *our* model only (sessions, named locations, selection). Photos stay in PhotoKit — we only ever store `localIdentifier`s. |
| Modularization | **Local SPM packages** | Keeps the pure curation/filtering logic testable without a photo library or simulator. |

---

## Module layout (start lean — D21)

v1 is **one package + the app target**; extract more only when something actually grows.

```
PoimiApp            (app target: real + fake PhotoKit impls, UI, navigation, @main)
└── Curation        (pure domain: AssetRef + protocols, filtering, target math, location distance math)
                     ← no PhotoKit, no SwiftData, no @MainActor; fully unit-testable
```

The win: `Curation` is plain Swift value types and pure functions — the filtering pipeline, the **adaptive day-grouping** of the timeline (a deterministic function of capture dates + a threshold; see the grouping spec), the running-total/target math, selection-set logic, the (deferred) bytes-per-megapixel scoring, and location distance math (no need for a separate `LocationKit` package). It runs in fast unit/property tests with synthetic data: no simulator, no real library.

**Dependency direction (D14):** the domain value model `AssetRef`/`AssetMetadata` *and* the PhotoKit-facing protocols (`PhotoLibraryProviding`, etc.) live in `Curation`. The PhotoKit implementation in the app target depends *on* `Curation`. Dependencies point toward the domain, never away from it — `Curation` must not import Photos. Later extractions (`PhotoLibrary`, `PoimiUI`) keep this direction.

---

## Layered data flow

```
SwiftUI Views (@MainActor)
   │  bind to
@Observable stores  (SelectionStore, SessionStore)  ← app state, persisted via SwiftData
   │  call
PhotoLibrary actor  (fetch / filter predicates / image requests / export)
   │  wraps
PhotoKit (PHAsset, PHFetchResult, PHCachingImageManager, PHAssetCollection)
```

---

## Key subsystem designs

### 1. PhotoKit access — one actor + a change-observer shim

All `PHPhotoLibrary`, fetch, and export calls go through a single `actor PhotoLibrary` (conforming to `PhotoLibraryProviding`). It hands the UI lightweight `Sendable` value models — never live `PHAsset` objects across the actor boundary.

The change observer is a separate concern (D16): a small `NSObject` conforms to `PHPhotoLibraryChangeObserver` and, since `photoLibraryDidChange(_:)` is **not guaranteed on the main thread**, immediately hops into the actor (`Task { await library.apply(change) }`) carrying only the `Sendable` results of `changeDetails(for:)`. The actor owns the fetch result and processes the change against it. The actor *itself* can't conform to the `@objc` observer protocol — hence the shim. `FakePhotoLibrary` honors the same isolation and exposes the same mutate-and-notify path (D25).

### 2. Lazy asset model over `PHFetchResult`

A year is thousands of assets, so we keep the live `PHFetchResult` (already lazy) **inside the actor** and never let it cross to the main actor. The grid's data source is a **main-actor immutable snapshot of `AssetRef` for the visible/prefetch window** (D17), requested from the actor by index range — not a per-cell async call into the actor, and not the live adapter held by the UI.

Whether to keep a lazy adapter at all or just materialize a flat `[AssetRef]` array is settled by a **benchmark during the spike** — value structs (not `PHAsset`s) for thousands of rows may be cheap enough that the array is simpler. "Don't materialize" needs a number, not a reflex.

`AssetRef` carries only `Sendable` value data — note `latitude`/`longitude` as `Double?`, **not** `CLLocation` (a non-`Sendable` reference type, D13). Album membership is handled as a precomputed `Set<String>` difference in the fetch tier, so it isn't a per-`AssetRef` field. The original resource size (the quality-heuristic input) is deliberately *not* here — it's the async pass (§3).

```swift
struct Coordinate: Sendable { let latitude: Double; let longitude: Double }

struct AssetRef: Sendable, Identifiable, Codable {
    let id: String            // PHAsset.localIdentifier — the only key that travels
    let captureDate: Date?    // some assets have only a modification date
    let coordinate: Coordinate?
    let pixelSize: CGSize
    let isScreenshot: Bool
    let isFavorite: Bool
}
```

### 3. Filtering pipeline — two tiers

- **Cheap, as fetch predicates:** date range, screenshot subtype, album-membership set difference. NSPredicate / set ops on `localIdentifier` — fast, exact, no false positives.
- **Heavy, lazy background pass:** the "camera originals only" / bytes-per-megapixel quality heuristic, which needs per-asset resource size. Runs async with progress, reads the **recorded original** size (not the local cache) to dodge the Optimize-Storage trap, and is format-aware for HEIC vs JPEG. Pure scoring function lives in `Curation`; the I/O to read sizes lives in `PhotoLibrary`.

### 4. Selection & targets — `@Observable`, app-owned

Selection is an in-memory `Set<String>` held in `SelectionStore` — **the source of truth, mutated instantly on every tap** (D15). It is *not* backed by a per-tap SwiftData write (rewriting a large set on the hottest UI path is the riskiest persistence trap in the plan). Durability comes from a **debounced/coalesced snapshot** — a `Codable` blob on the session (or throttled child rows), flushed on `scenePhase → background`. This decouples tap latency from durability.

**Decision: app-owned selection with an explicit export step** (rather than live-writing the album as you tap). Undo, soft per-month targets, the running tally, and the "update existing album / guard duplicate adds" re-run behavior all want an app-side source of truth. The album is a *render target*, produced on export.

`SelectionStore`/`SessionStore` are `@MainActor @Observable` and SwiftData-bound, so they live in the app target — never in `Curation` (which stays free of SwiftData and `@MainActor`).

### 5. Image loading

`PHCachingImageManager` with a prefetch window driven by the grid's visible range (thumbnails). The overlay requests progressive full-res — opportunistic delivery (instant low-res → sharpen), `isNetworkAccessAllowed = true` since not everything is local.

### 6. Review screen — the make-or-break

`LazyVGrid` in a `ScrollView`, `.scrollPosition` for restore. **In-grid selection is first-class** (D9): a quick-select badge per cell plus drag-to-multi-select, so the expand view is for inspection, not the only way to pick. Selection toggle is just `Set` membership — instant. Selected state uses redundant encoding (checkmark + dim), ≥44pt hit targets, and accessibility labels/actions for VoiceOver on a dense grid.

Tap opens a **navigation destination** (not a `.fullScreenCover`/overlay — D10) using **`.matchedTransitionSource` + `.navigationTransition(.zoom)`**, keyed by `localIdentifier`, so the thumbnail expands and animates back toward its source cell on dismiss. The transition's *feel* is not machine-verifiable; we verify its **post-conditions** — correct destination, scroll position restored, selection preserved (D22). Reduce Motion must substitute a cross-fade (verify; don't layer extra motion). Handle the case where the source cell scrolled out of view or was recycled.

**Adaptive navigation (iOS + iPadOS).** Compact width uses the typed `NavigationStack` above with the zoom push. Regular width (iPad) uses `NavigationSplitView` — sidebar · grid · detail — where the **detail column hosts its own `NavigationStack`** that carries the zoom destination, so the transition still applies (the expand is a push within the detail column, not a split selection). The `@MainActor @Observable` coordinator's typed path (§11) maps onto split-view selection + that nested stack; it is therefore *one logical path expressed in two containers*, not literally one stack on iPad. v1 ships this layout; iPad input polish (keyboard/hover/drag-and-drop) is v1.1.

**Liquid Glass surfaces.** Chrome is glass over opaque photo content. Standard navigation/toolbars adopt it for free; the few custom surfaces — the **tally + export grouped into one `GlassEffectContainer`** (never glass-on-glass), legibility guaranteed by the scroll-edge effect — use `glassEffect`/`.buttonStyle(.glass)`. These are `@MainActor` view modifiers and fit the concurrency model. Two enforced invariants: **no SDK-version availability gates / `.regularMaterial` version fallbacks** (CI-checked, Phase 1), and **every custom glass surface defines a Reduce-Transparency opaque appearance** (an accessibility axis, distinct from version fallbacks).

### 7. Location bucketing *(v1.1 — deferred, D4)*

`NamedLocation` (center coordinate, radius, name) in SwiftData. Bucketing is a pure distance check in `Curation` (folded in; no separate `LocationKit` package for now). Optional cluster *suggestion* via simple grid/greedy clustering on capture coordinates — suggest a name, human confirms. Always a "no location" bucket. Coordinates come from `PHAsset.location` (EXIF), so **no CoreLocation permission is requested** (D7); MapKit is used only for pin/radius UI.

### 8. Album export

Resolve selection → `PHAsset`s, create-or-find `PHAssetCollection` by stored album identifier, add only missing assets (dupe guard), let date sort happen naturally (capture date, oldest first). Membership only — **no sequencing**, per the plan.

`PhotoLibraryProviding` also **enumerates albums** (`PHAssetCollection`s) — needed both for the exclude-album filter's picker and the export-album selection step — so the fake must model album listing and membership (D25).

### 9. Persistence (SwiftData)

We persist `CurationSession` (date range, target count, chosen filters, exported album id), `NamedLocation`, and the selection snapshot (D15). Never photo bytes — with **one deliberate exception** (D18): a **resource-size cache** keyed by `localIdentifier` + modification date, because re-reading recorded original sizes for a year of photos is iCloud-touching and expensive — caching it *is* the point.

`@Model` instances are not `Sendable`; never pass them across the actor boundary — pass `PersistentIdentifier` and re-fetch. Autosave policy is set explicitly (not relying on per-mutation autosave). If we ever persist off-main, use a `ModelActor` — but the debounced main-actor snapshot (D15) should avoid needing a background context at all.

### 10. Authorization & permissions (D6)

`PHAuthorizationStatus` is observable app state that drives navigation. The flow: rationale screen → system prompt → branch on `.authorized` / `.limited` / `.denied` / `.notDetermined`. `.limited` and `.denied` get explicit recovery screens with a Settings deep-link (we cannot re-prompt for Full once Limited is chosen). This gates the whole app, so it's modeled up front, not bolted on. No CoreLocation permission (D7).

### 11. Errors, navigation, lifecycle

- **Error model (D19):** typed `PhotoLibraryError` / `ExportError`. The quality pass and export are inherently partially-failing (iCloud download failure, asset deleted under a selection, revoked authorization, album deleted between runs → recreate); progress reporting carries an error channel, not just a percentage.
- **Navigation (D20):** `NavigationStack` + a typed path on a `@MainActor @Observable` app coordinator (onboarding → permission → session setup → review → export). The `.zoom` destination lives on this stack.
- **Lifecycle / restoration (D20):** restore the active `CurationSession` and scroll position across launches, flush the selection snapshot on background, and reconcile library mutations that happened while backgrounded.

---

## Concurrency model

- UI types and `@Observable` stores are `@MainActor`.
- `PhotoLibrary` is an `actor`; it returns only `Sendable` value models and never lets the live `PHFetchResult` cross the boundary.
- The change-observer `NSObject` shim hops results into the actor (§1).
- Heavy passes (quality scoring, clustering) run off the main actor with structured concurrency and report progress (and errors) back via an `AsyncStream` / `@MainActor` callback — the actor does not hold and mutate the `@Observable` store directly.

---

## Explicitly out of scope (v1)

No Vision/face clustering, no manual sequencing, no Combine, no UIKit. **Deferred to later:** the quality/camera-originals filter (D3) and location bucketing (D4).
