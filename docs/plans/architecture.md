# Poimi — App Architecture

*Companion to [product-plan.md](./product-plan.md). Modern Swift throughout.*

---

## Stack decisions

| Choice | Pick | Why |
|---|---|---|
| Min target | **iOS 18+** | Unlocks `@Observable`, SwiftData, and `.navigationTransition(.zoom)` — the API that *is* the tap-to-expand-land-back interaction. In 2026 this excludes almost no one. |
| UI | **SwiftUI only** | No UIKit unless forced (none expected). |
| State | **Observation (`@Observable`)** | No Combine, no `ObservableObject` boilerplate. |
| Concurrency | **Swift 6 language mode, strict concurrency** | PhotoKit isn't Sendable-friendly; isolate it behind an actor, keep UI on `@MainActor`. |
| Persistence | **SwiftData** | For *our* model only (sessions, named locations, selection). Photos stay in PhotoKit — we only ever store `localIdentifier`s. |
| Modularization | **Local SPM packages** | Keeps the pure curation/filtering logic testable without a photo library or simulator. |

---

## Module layout (local SPM packages)

```
PoimiApp            (app target: navigation, wiring, @main)
├── Curation        (pure domain: models, filtering, selection, targets)  ← no PhotoKit, fully unit-testable
├── PhotoLibrary    (PhotoKit actor, image loading, album export)         ← depends on Photos
├── LocationKit     (CoreLocation clustering, named-location matching)
└── PoimiUI         (review grid, full-screen overlay, design system)
```

The win: `Curation` — the filtering pipeline, bytes-per-megapixel heuristic, per-month target math, selection-set logic — is plain Swift value types and pure functions. It runs in fast unit tests with synthetic data: no simulator, no real library.

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

### 1. PhotoKit access — one actor

All `PHPhotoLibrary`, fetch, and export calls go through a single `actor PhotoLibrary`. It owns the `PHPhotoLibraryChangeObserver` and hands the UI lightweight `Sendable` value models — never live `PHAsset` objects across the actor boundary.

### 2. Lazy asset model over `PHFetchResult`

A year is thousands of assets. We do **not** materialize them into an array. `PHFetchResult` is already lazy; we wrap it in an adapter that maps `index → AssetRef` on demand and caches the cheap metadata. The grid indexes into this directly.

```swift
struct AssetRef: Sendable, Identifiable {
    let id: String            // PHAsset.localIdentifier — the only key that travels
    let captureDate: Date
    let location: CLLocation?
    let pixelSize: CGSize
    let isScreenshot: Bool
    let isFavorite: Bool
}
```

### 3. Filtering pipeline — two tiers

- **Cheap, as fetch predicates:** date range, screenshot subtype, album-membership set difference. NSPredicate / set ops on `localIdentifier` — fast, exact, no false positives.
- **Heavy, lazy background pass:** the "camera originals only" / bytes-per-megapixel quality heuristic, which needs per-asset resource size. Runs async with progress, reads the **recorded original** size (not the local cache) to dodge the Optimize-Storage trap, and is format-aware for HEIC vs JPEG. Pure scoring function lives in `Curation`; the I/O to read sizes lives in `PhotoLibrary`.

### 4. Selection & targets — `@Observable`, app-owned

Selection is a `Set<String>` of identifiers held in `SelectionStore`, persisted in SwiftData. **Decision: app-owned selection with an explicit export step** (rather than live-writing the album as you tap). Undo, soft per-month targets, the running tally, and the "update existing album / guard duplicate adds" re-run behavior all want an app-side source of truth. The album is a *render target*, produced on export.

### 5. Image loading

`PHCachingImageManager` with a prefetch window driven by the grid's visible range (thumbnails). The overlay requests progressive full-res — opportunistic delivery (instant low-res → sharpen), `isNetworkAccessAllowed = true` since not everything is local.

### 6. Review screen — the make-or-break

`LazyVGrid` in a `ScrollView`, `.scrollPosition` for restore. Tap uses iOS 18's **`.matchedTransitionSource` + `.navigationTransition(.zoom)`** so the thumbnail expands to full-screen and animates *back to its exact place* on dismiss — exactly the behavior the plan describes, for free. Selection toggle is just `Set` membership, so it's instant.

### 7. Location bucketing

`NamedLocation` (center coordinate, radius, name) in SwiftData. Bucketing is a pure distance check in `LocationKit`. Optional cluster *suggestion* via simple grid/greedy clustering on capture coordinates — suggest a name, human confirms. Always a "no location" bucket.

### 8. Album export

Resolve selection → `PHAsset`s, create-or-find `PHAssetCollection` by stored album identifier, add only missing assets (dupe guard), let date sort happen naturally (capture date, oldest first). Membership only — **no sequencing**, per the plan.

### 9. Persistence (SwiftData)

We persist `CurationSession` (date range, target count, chosen filters, exported album id), `NamedLocation`, and the selection set. Never photo bytes or metadata we can re-fetch.

---

## Concurrency model

- UI types and `@Observable` stores are `@MainActor`.
- `PhotoLibrary` is an `actor`; it returns only `Sendable` value models.
- Heavy passes (quality scoring, clustering) run off the main actor with structured concurrency and report progress back to the main actor.

---

## Explicitly out of scope (v1)

No Vision/face clustering, no print-service integration, no manual sequencing, no Combine, no UIKit.
