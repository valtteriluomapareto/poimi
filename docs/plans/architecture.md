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
| Persistence | **SwiftData** | For *our* model only (projects, named locations, selection). Photos stay in PhotoKit — we only ever store `localIdentifier`s. |
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
@Observable stores  (SelectionStore, ProjectStore)  ← app state, persisted via SwiftData
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

Selection is an in-memory `Set<String>` held in `SelectionStore` — **the source of truth, mutated instantly on every tap** (D15). It is *not* backed by a per-tap SwiftData write (rewriting a large set on the hottest UI path is the riskiest persistence trap in the plan). Durability comes from a **debounced/coalesced snapshot** — a `Codable` blob on the project (or throttled child rows), flushed on `scenePhase → background` and on project switch (§12). This decouples tap latency from durability.

**Decision: app-owned selection with an explicit export step** (rather than live-writing the album as you tap). Undo, soft per-month targets, the running tally, and the "update existing album / guard duplicate adds" re-run behavior all want an app-side source of truth. The album is a *render target*, produced on export.

`SelectionStore`/`ProjectStore` are `@MainActor @Observable` and SwiftData-bound, so they live in the app target — never in `Curation` (which stays free of SwiftData and `@MainActor`).

### 5. Image loading

`PHCachingImageManager` with a prefetch window driven by the grid's visible range (thumbnails). The overlay requests progressive full-res — opportunistic delivery (instant low-res → sharpen), `isNetworkAccessAllowed = true` since not everything is local.

### 6. Review screen — the make-or-break

`LazyVGrid` in a `ScrollView`, `.scrollPosition` for restore. **In-grid selection is first-class** (D9): a quick-select badge per cell plus drag-to-multi-select, so the expand view is for inspection, not the only way to pick. Selection toggle is just `Set` membership — instant. Selected state uses redundant encoding (checkmark + dim), ≥44pt hit targets, and accessibility labels/actions for VoiceOver on a dense grid.

Tap opens a **navigation destination** (not a `.fullScreenCover`/overlay — D10) using **`.matchedTransitionSource` + `.navigationTransition(.zoom)`**, keyed by `localIdentifier`, so the thumbnail expands and animates back toward its source cell on dismiss. The transition's *feel* is not machine-verifiable; we verify its **post-conditions** — correct destination, scroll position restored, selection preserved (D22). Reduce Motion must substitute a cross-fade (verify; don't layer extra motion). Handle the case where the source cell scrolled out of view or was recycled.

**Adaptive navigation (iOS + iPadOS).** Compact width uses the typed `NavigationStack` above with the zoom push. Regular width (iPad) uses `NavigationSplitView` — sidebar · grid · detail — where the **detail column hosts its own `NavigationStack`** that carries the zoom destination, so the transition still applies (the expand is a push within the detail column, not a split selection). The `@MainActor @Observable` coordinator's typed path (§11) maps onto split-view selection + that nested stack; it is therefore *one logical path expressed in two containers*, not literally one stack on iPad. v1 ships this layout; iPad input polish (keyboard/hover/drag-and-drop) is v1.1.

**Liquid Glass surfaces.** Chrome is glass over opaque photo content. Standard navigation/toolbars adopt it for free; the few custom surfaces — the **tally + export grouped into one `GlassEffectContainer`** (never glass-on-glass), legibility guaranteed by the scroll-edge effect — use `glassEffect`/`.buttonStyle(.glass)`. These are `@MainActor` view modifiers and fit the concurrency model. Two enforced invariants: **no SDK-version availability gates / `.regularMaterial` version fallbacks** (CI-checked, Phase 1), and **every custom glass surface defines a Reduce-Transparency opaque appearance** (an accessibility axis, distinct from version fallbacks). **v1 status:** the review-grid header ships with a **`.bar` material** (translucent, Reduce-Transparency-safe) as a deliberate interim; the full `glassEffect` scroll-edge is a deferred device-iteration task (no in-app precedent yet, blur unverifiable from a screenshot, glass-nav-glitch-adjacent).

### 7. Location bucketing *(v1.1 — deferred, D4)*

`NamedLocation` (center coordinate, radius, name) in SwiftData. Bucketing is a pure distance check in `Curation` (folded in; no separate `LocationKit` package for now). Optional cluster *suggestion* via simple grid/greedy clustering on capture coordinates — suggest a name, human confirms. Always a "no location" bucket. Coordinates come from `PHAsset.location` (EXIF), so **no CoreLocation permission is requested** (D7); MapKit is used only for pin/radius UI. **v1 scope (D33):** v1 sections stay **date-only** adaptive day-groups (§13); the design's by-location overview and trip names ("Italy", "Summer cabin") are an *additive view* over those same day-groups once location lands — not a rework. The concrete subsystem plan — the geocode-once preprocessing pass, the boundary placement (CL/MapKit in the app tier, distance math in `Curation`), and the persisted, invalidatable place-assignment cache (the D18 pattern) — is in [preprocessing-and-caching.md](preprocessing-and-caching.md).

### 8. Album export (#39, built)

Resolve selection → `PHAsset`s, create-or-find `PHAssetCollection` by stored album identifier, add only missing assets (dupe guard), let date sort happen naturally (capture date, oldest first). Membership only — **no sequencing**, per the plan.

`PhotoLibraryProviding` also **enumerates albums** (`PHAssetCollection`s) — needed both for the exclude-album filter's picker and the export-album selection step — so the fake must model album listing and membership (D25).

**The write seam.** Export is the one WRITE on `PhotoLibraryProviding`: `export(assetIDs:toAlbumNamed:existingAlbumID:) -> ExportResult` (added to the same seam, not split per D21 — the app injects one `\.photoLibrary` and uses the whole surface). `SystemPhotoLibrary` runs it through `PHPhotoLibrary.performChanges` — first export creates the album and adds every resolved pick in one change (capturing the placeholder's `localIdentifier`); a re-export finds the album by `existingAlbumID`, throws `.albumMissing` if it was deleted, else adds only the picks it doesn't already hold. Only id strings + `Sendable` values cross the `performChanges` block (PHAssets are re-fetched inside it — Swift-6-safe). `FakePhotoLibrary` models it in-memory (create-or-find + dupe guard) so the flow is deterministic for tests + screenshots.

**Flow + state (`ExportStore` + `ExportView`, #39).** The review grid's Export → `coordinator.openExport` → `ExportView`, a small state machine: `exporting` → `done(result, wasReExport)` (completion / re-export copy) or `failed(ExportError, canCreateNew)` (D19 recoverable channel — `.notAuthorized` / `.albumMissing` / `.noAssetsResolved` / `.writeFailed`; "create a new album instead" appears when a re-export's album is gone). On success the store stamps **our state only** — `targetAlbumID` (the created/found album) + `markedDoneAt` (→ status `.done`) — a **one-way copy** that never reads the album back (D31). Completion **stats reuse the review scan's `reviewDayByID`** (on the coordinator) via `CompletionStats(dayByID:doneDays:selection:)`, so the celebration needs no second scan. There is no "open the album in Photos" action — iOS exposes no public deep-link to a specific `PHAssetCollection`.

### 9. Persistence (SwiftData)

We persist **many `CurationProject`s** (the album library, §12 — date range, target count, chosen filters, exported album id, done-days, resume pointer), `NamedLocation` (v1.1), and each project's debounced selection snapshot (D15). Never photo bytes — with **one deliberate exception** (D18): a **resource-size cache** keyed by `localIdentifier` + modification date, because re-reading recorded original sizes for a year of photos is iCloud-touching and expensive — caching it *is* the point.

`@Model` instances are not `Sendable`; never pass them across the actor boundary — pass `PersistentIdentifier` and re-fetch. Autosave policy is set explicitly (not relying on per-mutation autosave). If we ever persist off-main, use a `ModelActor` — but the debounced main-actor snapshot (D15) should avoid needing a background context at all.

### 10. Authorization & permissions (D6)

`PHAuthorizationStatus` is observable app state that drives navigation. The flow: rationale screen → system prompt → branch on `.authorized` / `.limited` / `.denied` / `.notDetermined`. `.limited` and `.denied` get explicit recovery screens with a Settings deep-link (we cannot re-prompt for Full once Limited is chosen). This gates the whole app, so it's modeled up front, not bolted on. No CoreLocation permission (D7).

### 11. Errors, navigation, lifecycle

- **Error model (D19):** typed `PhotoLibraryError` / `ExportError`. The quality pass and export are inherently partially-failing (iCloud download failure, asset deleted under a selection, revoked authorization, album deleted between runs → recreate); progress reporting carries an error channel, not just a percentage.
- **Navigation (D20, updated for the album library):** `NavigationStack` + a typed path on a `@MainActor @Observable` app coordinator. The path now **roots at the albums library** and inserts the zoom-out **album overview** above the grid: `onboarding → permission → albums → albumOverview(projectID) → review(dayKey?) → photo(zoom) → export`. Review **routes by `DayKey`, never a section id** — sections are a computed view, so derive the containing section at render. The `.zoom` destination lives on the review→photo step; overview→review is a plain push. On regular width the albums list is the split-view sidebar (§6).
- **Lifecycle / restoration (D20):** restore the **last-opened project**, its resume pointer (§13), and scroll position across launches; flush the selection snapshot on background; reconcile library mutations on resume — prune vanished assets from the selection, and re-derive day-groups + section-done from the stable per-day flags (§13).

---

## Key subsystem designs (cont. — added after the design pass)

### 12. Projects — the album library (D31)

The original model assumed a single active `CurationSession`. The design makes the **album library the home**: many named projects, each its own curation toward one Photos album. So the persisted aggregate is plural.

- A **`CurationProject`** (the user-facing "album") owns: title, date range, target count, exclusion settings (excluded album ids + screenshots flag), the **target Photos-album id** (`nil` until first export creates it, D19), the debounced selection snapshot, the done-day set + resume pointer (§13), and `createdAt` / `lastOpenedAt`.
- The **Albums list** (the new nav root) shows projects ordered by `lastOpenedAt`, each with **derived status**: *not started* (empty selection **and** no done days **and** `markedDoneAt == nil`), *done* (`markedDoneAt` set), else *in progress*. Progress (`picked / target`) and the cover are cheap derivations, not stored.
- Operations: **new** (setup flow); **open** (→ overview); **duplicate** (copy config with `targetAlbumID = nil` so it can never share another project's album); **reset picks** (clear selection **and** `doneDays` **and** `resumeDayKey` **and** `markedDoneAt` → back to *not started*; keep range/album/exclusions); **delete** (remove the project + its progress — the Photos album and originals are never touched; the copy is one-way).
- **Active-project lifecycle — v1 invariant: exactly one project hydrated.** Opening a project loads its `selectionSnapshot` into the single `SelectionStore`; switching or backgrounding **flushes the current project's set back to its own snapshot first**. The debounce is keyed by the project's `PersistentIdentifier` and **cancelled/validated on switch**, so a stale timer can never write one project's picks onto another (the multi-project trap). Ties into the D20 "restore last-opened project" line (§11).
- Two albums = two projects; nothing global is shared except app-level Photos access and the resource-size cache (keyed by asset, so it's reused across projects).

> Naming: internally `CurationProject` to avoid colliding with PhotoKit's album; the UI word stays "album."

### 13. Section completion & resume — "mark as done" (D32 → **(d), decided**)

The design lets the user mark **days / trips / months done** and **resume where they left off**. Completion needs persisted state with a **stable identity**, but adaptive day-groups are a *computed view* (pure function of capture dates + threshold) that shifts when the library changes. All four reviewers (Architect, Tester, Pragmatist, Codex) converged on **option (d)**: (a) span-key and (b) anchor-key orphan progress on a merge/split; (c) content-hash breaks on any membership change.

**(d) — persist per calendar day; derive section-done.** The stable atom is a **calendar day** (`DayKey`); store a sorted, de-duplicated set of done `DayKey`s. "Mark section done" writes the flag for every day the section spans (one day for a busy day; the whole run for a merged quiet stretch). A section renders *done* iff every `DayKey` it currently spans is in the set. Re-grouping is a pure **view over a stable per-day truth** — boundary shifts never lose progress.

*Worked example (the property that makes (d) win):* mark the merged run "16–18 Mar" done → flags `{03-16, 03-17, 03-18}`. A photo later added on 17 Mar splits it into "16 Mar" and "17–18 Mar"; **both render done** because all their days are flagged. Had only 16–17 been done, the split yields a done "16 Mar" and an undone "17–18 Mar" — no progress lost or fabricated.

Three rules the reviewers required to make (d) safe:
- **`DayKey` must be timezone-stable.** A `Date` is an instant, not a day. Define `DayKey` as a Gregorian `yyyy-MM-dd` derived through **one pinned `Calendar`/timezone policy**, and the **grouping function and the done-flag must use the identical projection** (compute spans with `Calendar.dateInterval(of: .day, …)`, not 24h arithmetic, for DST safety). The capture-local-vs-device-fixed choice is owned by the grouping spec and shared verbatim here.
- **No-`captureDate` assets need a home.** `AssetRef.captureDate` is `Date?` (§2). Fall back to the asset's modification-date day; if absent, place it in a fixed **"Undated"** pseudo-section with its own stable key, so it can be reviewed, marked done, and counted like any other.
- **"Done but changed" reconciliation.** A new asset landing on an already-done day must not be silently swallowed. On library-change reconcile (§11), if a done day's membership **increases**, **re-open that day** (clear its flag); deletions never re-open. This keeps "done" honest without content-hash identity.

**Resume** is **derived**, not a stored cursor: `resumeDayKey` = the earliest in-range day with photos that isn't done; all-done → the completion screen; empty range → the empty state. `lastViewedAssetID` is kept *only* as a scroll anchor (restore exact position if it still resolves, else fall back to `resumeDayKey`) — never the done-state authority.

**Auto-complete is v1.1.** "Auto-complete when every photo viewed" needs per-asset *viewed* tracking the v1 model deliberately doesn't store; v1 ships **explicit tap only**. Per-asset viewed + auto-complete arrive with the `DayProgress` child table in v1.1.

**Derived stats (well-defined, to avoid >100%):** let `reviewedAssets` = filtered in-range assets on done days; `keptReviewed` = selected assets within `reviewedAssets`. Show *kept* = `keptReviewed`, the denominator = `|reviewedAssets|`, *% kept* = `keptReviewed / denominator` (0 when the denominator is 0); show total picked (project-wide selection) separately. Because "done" is an explicit declaration, label the denominator **"marked done,"** not "reviewed."

**Implemented (Phase 2, #38 / #89).** Done-state lives in **`DoneStore`** (`@MainActor @Observable`, mirroring `SelectionStore`): an in-memory `Set<DayKey>`, debounced write to `CurationProject.doneDays`, one project hydrated at a time (multi-project guard). The **UI is an accordion** (D35), not the originally-designed done-driven collapse — one day-group cluster open at a time, "done" **decoupled** from collapse and set by an end-of-cluster **"Mark as done"** button that collapses the cluster and **advances to the next unreviewed** one; initial open = the derived first-unreviewed day (the resume, realized inline in the grid). The **"done-but-changed" reconcile** (above) is implemented via a persisted per-day candidate snapshot (**`reviewedIDsByDay`**, D38): each load diffs the current candidates against the last-load baseline and `Completion.reopening` re-opens any done day that *gained* an id (a first load / empty / corrupt baseline re-opens nothing). The snapshot field rides **additive-optional lightweight migration** (D37). Grid scroll positioning uses iOS-18 **`ScrollPosition`** (one-shot `scrollTo`, no re-apply on re-layout — D36).

### 14. Album settings (#41, built)

**Per-album** settings, pushed from the Overview's gear (`Route.settings(UUID)`). `AlbumSettingsView`
is a grouped `Form` that edits one `CurationProject` in place — name, period (the same
end-exclusive ↔ inclusive-day bridge as new-album setup, `NewAlbumDraft`), export destination and
excluded albums (reusing `AlbumPickerView`), and target — plus a destructive **Reset picks** /
**Delete album** card. Edits apply immediately (iOS-Settings style, no Save button): controls bind to
the `@Observable` model, and `onDisappear` forces a durable `ProjectStore.saveEdits(to:)` (rather than
leaning on the mainContext's deferred autosave) and re-syncs the live tally via
`SelectionStore.retarget(_:)` (the target is cached at `activate`, so a bare mutation wouldn't reach the
running count). Changing the period only re-scans the candidate pool on the next review load; picks
outside the new range are **kept** — the user chose them.

**Reset / Delete ordering.** Both reconcile the live stores so the Overview behind reflects the change
on pop. Reset runs `selection.deactivate()` → `doneStore.deactivate()` → `store.reset(project)` →
re-`activate` — deactivating *first* (flushing then clearing in-memory state) before zeroing the model,
so a later debounced flush can't resurrect the just-cleared picks. Delete deactivates the stores, calls
`store.delete(project)` (record only — **never** the exported Photos album or originals, D31), and
`coordinator.popToRoot()`s back to the library; a teardown guard skips the `onDisappear` save of the
now-deleted project.

**App-level settings are NOT here.** Photos access and About are app-wide, not per-album; the 2F1
design's "App" section belongs on a separate app-settings screen (reached from the album library),
deliberately omitted from this per-album screen.

## Data model — v1 SwiftData entities

Persist *our* state only; never photo bytes (one exception — the resource-size cache, D18). Commit to a lightweight **`VersionedSchema` from v1** (the project entity will gain fields), and wrap `selectionSnapshot` in a **versioned envelope** so the blob's own `Codable` shape can evolve without a silent decode wipe.

```
CurationProject            @Model
  id: UUID
  title: String                    // "Best of 2025" (the user-facing "album")
  rangeStart / rangeEnd: Date
  targetCount: Int
  excludeScreenshots: Bool
  excludedAlbumIDs: [String]       // PHAssetCollection localIdentifiers
  targetAlbumID: String?           // created on first export (create-or-find, D19)
  selectionSnapshot: Data          // versioned Codable Set<String>, debounced (D15) — never per-tap
  doneDays: [String]               // sorted, unique DayKey (yyyy-MM-dd) — set semantics; D32(d)
  reviewedIDsByDay: Data?          // @Attribute(.externalStorage); [DayKey → ids] baseline for the done-but-changed reconcile (D38)
  resumeDayKey: String?            // cache of the derived resume day
  lastViewedAssetID: String?       // scroll anchor only — not the done-state authority
  markedDoneAt: Date?              // user finalized → status .done
  createdAt / lastOpenedAt: Date

NamedLocation              @Model  // v1.1 (D4) — unchanged
ResourceSizeCacheEntry     @Model  // D18 — keyed by localIdentifier + modificationDate
```

- Selection lives in memory as a `Set<String>` (`SelectionStore`; see the active-project lifecycle in §12); `selectionSnapshot` is the debounced durable copy (D15).
- `@Model` instances aren't `Sendable`: pass `PersistentIdentifier` across the actor boundary and re-fetch.
- `doneDays` is a stored `[String]` treated as a **set** (insert-if-absent), fine at v1 scale (≤366/project); promote to a `DayProgress` child table only when per-asset viewed tracking lands (auto-complete, v1.1).

---

## Concurrency model

- UI types and `@Observable` stores are `@MainActor`.
- `PhotoLibrary` is an `actor`; it returns only `Sendable` value models and never lets the live `PHFetchResult` cross the boundary.
- The change-observer `NSObject` shim hops results into the actor (§1).
- Heavy passes (quality scoring, clustering) run off the main actor with structured concurrency and report progress (and errors) back via an `AsyncStream` / `@MainActor` callback — the actor does not hold and mutate the `@Observable` store directly.

---

## Explicitly out of scope (v1)

No Vision/face clustering, no manual sequencing, no Combine, no UIKit. **Deferred to later:** the quality/camera-originals filter (D3) and location bucketing (D4).
