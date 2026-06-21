# Poimi — Plan Review Decisions

*Outcome of the four-perspective review (Swift Architect, Senior Tester, Pragmatic Developer, Apple HIG expert) of the product, architecture, and development plans. This is the authoritative record of what we decided and why; the three plan docs were revised to match.*

**Committed sequencing:** *spike-first, grow machinery* — prove the risky UX on a real library before building test/CI scaffolding; apply depth where it pays (pure `Curation` logic + fake fidelity), defer ceremony (snapshot tier, full E2E, release pipeline) until there's something worth shipping.

---

## The reviews in one line each

- **Architect:** sound spine; fix `CLLocation` Sendability, a module dependency inversion, and SwiftData-as-live-selection-store; fill three gaps — authorization flow, error model, lifecycle/restoration.
- **Tester:** excellent instinct, but the hardest/fuzziest behaviors (quality heuristic, progressive load, zoom/restore, scale) are described as "for free" without a runnable verification mechanism.
- **Pragmatist:** over-built for a v1 that doesn't exist yet; spike the review loop on a real library first, cut packages/tiers/pipeline, defer the design-freeze gate.
- **HIG:** the permission/limited-access UX and in-grid selection mechanics are the make-or-break gaps; drop unnecessary CoreLocation permission; the quality filter must never silently lose photos.

---

## Decisions

### Sequencing & scope

- **D1 — Spike first.** Phase 0 is a throwaway vertical slice run against the author's *real* photo library: date-range fetch → `LazyVGrid` thumbnails → `.zoom` expand/return → toggle selection into a `Set` → dump to an album. No tests, no design gate. It answers the only questions that matter early: does the review loop feel good at scale, does scroll-position restore work, does `PHCachingImageManager` stay smooth over thousands of assets, does progressive full-res feel instant. *(Pragmatist §6; the fake is blind to all of this.)*
- **D2 — v1 critical path** (after the spike validates the loop): date-range fetch → review grid with in-grid selection → running total toward target → export to album (create-or-find + dupe guard) → two exact filters (screenshots, exclude-album). Nothing else is on the path.
- **D3 — Defer the quality (bytes/MP) filter.** Not on the v1 path. Validate it with a 30-minute spike on ~100 real assets (incl. iCloud-only) to see if it discriminates at all. Ship only if it works, and only as described in D11. *(All three of Tester/Pragmatist/HIG.)*
- **D4 — Defer location bucketing + named pins to v1.1.** A whole subsystem; the month + total loop works without it. *(Pragmatist §3.)*
- **D5 — Per-month targets are light scaffolding, not a gate.** Keep the running total authoritative; show a per-month guide in section headers. *(Pragmatist §3; matches the product plan's own framing.)*

### Permissions & privacy (the biggest gap — was absent everywhere)

- **D6 — Full library access, hard-gated, with a real flow.** PHPicker cannot work (no persistent `localIdentifier`s, no date predicates, no album writes), so we require full access. Build: (a) an in-app rationale screen *before* the system prompt; (b) explicit `.limited` and `.denied` recovery screens with a Settings deep-link (we cannot re-prompt for Full once Limited is chosen); (c) specific `NSPhotoLibraryUsageDescription` / `...AddUsageDescription` strings. Authorization status is observable app state that drives navigation. *(HIG #1, Architect #6, Pragmatist §7.)*
- **D7 — No CoreLocation permission.** Coordinates come from `PHAsset.location` (EXIF), already covered by the photo grant. Only request `whenInUse` if we later add an explicit "use my current location" convenience. *(HIG #4.)*
- **D8 — On-device-only privacy stance, stated loudly.** We store only `localIdentifier`s, no photo bytes, nothing to third parties. Note precisely in the App Privacy label that `isNetworkAccessAllowed` fetches go to Apple's iCloud, not our servers. *(HIG #1/#8.)*

### UX

- **D9 — In-grid selection is a v1 requirement.** Photos-style quick-select badge per cell + drag-to-multi-select; the full-screen overlay is for *inspection*, not the only way to pick. Tap-to-expand-then-select for every photo is too slow at this scale. Selected state uses redundant encoding (checkmark + dim, never color alone) and ≥44pt hit targets. *(HIG #2/#5.)*
- **D10 — The expand view is a navigation destination, not a `.fullScreenCover`.** `.navigationTransition(.zoom)` + `.matchedTransitionSource` keyed by `localIdentifier`, on a `NavigationStack`. Reconciles the "overlay" (product) vs "navigation" (architecture) wording, which had real API consequences. Verify Reduce Motion substitutes a cross-fade and we don't layer extra motion. *(Architect notes; HIG #3.)*
- **D11 — Quality filter never loses photos silently.** Off by default; concrete copy ("Hide non-camera images: screenshots, saved memes, low-res copies"); the excluded set is **inspectable** ("Hidden: 312 — review"). *(HIG #7.)*
- **D12 — Long-scan progress is a designed surface.** Determinate count ("Scanning 1,240 of 8,300…"), cancelable, and the cheap-filtered set is curatable *while* the heavy pass runs. Never a bare spinner. *(HIG #6.)*

### Architecture

- **D13 — `AssetRef` stores `latitude`/`longitude` as `Double?`** (a small `Coordinate: Sendable`), not `CLLocation` (reference type, not `Sendable`). Reconstruct `CLLocation` only where a CoreLocation API needs it. *(Architect #1.)*
- **D14 — Fix the dependency direction.** `AssetRef`/`AssetMetadata` and the PhotoKit-facing protocols live in `Curation` (the domain); the PhotoKit implementation depends *on* `Curation`. Dependencies point toward the domain. *(Architect, module section.)*
- **D15 — Selection: in-memory `Set<String>` is the source of truth; persist a debounced/coalesced snapshot** (Codable blob on the session, or throttled child rows, flushed on `scenePhase` → background). Do not back per-tap mutations with a SwiftData write. *(Architect #2.)*
- **D16 — Change-observer shim.** A small `NSObject` conforms to `PHPhotoLibraryChangeObserver` and immediately hops into the `PhotoLibrary` actor with only `Sendable` change results. The observer callback is not guaranteed main-thread. *(Architect #4.)*
- **D17 — Grid data source = main-actor snapshot of `AssetRef` for the visible/prefetch window**, served from the actor; the live `PHFetchResult` adapter never leaves the actor. Benchmark a flat `[AssetRef]` array against the lazy adapter during the spike before committing — "don't materialize" needs a number, not a reflex. *(Architect #3.)*
- **D18 — Persist a resource-size cache** keyed by `localIdentifier` + modification date — a deliberate exception to "never store re-fetchable metadata," because the cost (iCloud-touching reads over a year) is the whole point of caching. *(Architect #5.)*
- **D19 — Add an error model** (`PhotoLibraryError` / `ExportError`) and a partial-failure channel for the quality pass and export (iCloud download failure, asset deleted under a selection, revoked authorization, album deleted between runs → recreate). *(Architect #7; HIG #6.)*
- **D20 — State the navigation + lifecycle model:** `NavigationStack` + typed path on a `@MainActor @Observable` coordinator; restore active session + scroll position across launches; flush selection on background; reconcile library mutations on resume. *(Architect #8/#9.)*
- **D21 — Packages: start lean, keep the seam.** v1 = one `Curation` package (pure: models, protocols, filtering, target math, location distance math) + the app target (real & fake PhotoKit impls, UI). Extract `PhotoLibrary`/`PoimiUI` later if they grow. One `PhotoLibraryProviding` protocol to start; split `ImageLoading`/`AlbumExporting` only when a consumer needs just one. *(Pragmatist §1, reconciled with Architect's boundary direction.)*

### Testing & verification

- **D22 — Soften the north star.** *"Pure logic must be tested; UX is validated by using the app on a real library + design sign-off."* The zoom-transition *feel* and real-iCloud behavior are not machine-verifiable; test the transition's **post-conditions** (correct destination, scroll position restored, selection preserved) instead of claiming it's correct "for free." *(Tester 1.2, Pragmatist §1, HIG #3.)*
- **D23 — Two tiers gate PRs in v1: unit (`Curation`) + integration (stores + `FakePhotoLibrary`).** Plus exactly one E2E happy-path smoke test as a tripwire. *(Pragmatist §1/§4.)*
- **D24 — Where rigor stays (apply the Tester's depth):**
  - **Labeled corpus** for the quality heuristic — checked-in synthetic fixtures tagged camera-original vs recompressed across HEIC/JPEG/megapixel counts; assert on confusion-matrix metrics (precision/recall, **zero clean-HEIC false positives**), not example cases. Gate this *if/when* the filter ships. *(Tester 1.1.)*
  - **Property-based tests** for the pure target/selection/set-difference math. *(Tester §7.)*
  - **Conformance suite** run against both `SystemPhotoLibrary` and `FakePhotoLibrary` to prevent fake drift. *(Tester §3.)*
- **D25 — `FakePhotoLibrary` API surface is a first-class design item, not just seed data:** dual size fields (local cache vs recorded original), mutate-and-notify (change tracking), deterministic progressive image delivery (degraded→final, injectable iCloud delay/failure), and permission states (`.authorized`/`.limited`/`.denied`/`.notDetermined`). Canonical named seeds: `YearMixed2025`, `AllICloudOptimized`, `LimitedAccess`, `EmptyLibrary`. *(Tester §2; Architect "fake honors the same isolation".)*
- **D26 — Defer snapshot testing, the full E2E suite, and the fastlane/match/deliver pipeline.** Ship the first TestFlight builds manually from Xcode. Add snapshot tests once the UI stabilizes post-launch; pin exact simulator OS/device and ban committed record-mode when we do. *(Pragmatist §1/§4; Tester §4 for the eventual config.)*
- **D27 — Replace the design-freeze gate with spike-then-document.** Validate the interaction by using a rough build, *then* commit a design and a `docs/design/` UI spec as documentation following validation — not a gate preceding code. *(Pragmatist §5.)*
- **D28 — CI tooling: SwiftLint only for v1** (with autocorrect); skip running swift-format alongside it (the reconciliation is friction). "No new warnings" is advisory early, a gate once the codebase settles. *(Pragmatist §4.)*
- **D29 — Add a performance/scale check** (against the fake): seed/fetch 10k assets, the heavy pass over 10k, and an access-counting guard that fails if the whole fetch result is materialized. Not a per-PR gate initially; a named test that backs the "lazy" claim. *(Tester 1.4.)*
- **D30 — Guard the fake out of release builds** — compile it only under a test/debug configuration; a launch flag that swaps it in must be inert in release. *(Tester §5.)*

### Deferred / explicitly not now

- Mutation testing (immature Swift tooling) — optional, nightly on `Curation` only if ever. *(Tester §7.)*
- Full snapshot device/Dynamic-Type/locale matrix — revisit with D26.
- Within-overlay swipe navigation, burst/hidden/shared-library asset handling — note as open, decide during the slice.

---

## Still open (decide during the spike / slice)

- Lazy adapter vs flat `[AssetRef]` array — settle with the D17 benchmark.
- Whether to support a degraded `.limited` mode at all, or hard-gate (D6 leans hard-gate).
- Whether "yearbook"/"photo book" belongs in the App Store subtitle/keywords (discoverability, given the opaque name). *(HIG #9.)*
- Within-overlay swipe-between-photos behavior and which photo we land back on.
