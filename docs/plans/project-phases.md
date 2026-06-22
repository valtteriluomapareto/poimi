# Poimi — Project Phases

*The build sequence: high-level tasks in order, with exit criteria per phase. Companion to [product-plan.md](./product-plan.md), [architecture.md](./architecture.md), [development-guidelines.md](./development-guidelines.md), and [plan-review-decisions.md](./plan-review-decisions.md) (decisions referenced as D#). GitHub issues will link back to the tasks here.*

---

## Shape of the plan

Five phases. The ordering follows the committed **spike-first** sequencing (D1): prove the riskiest UX on a real library *before* building durable scaffolding, then build the v1 critical path, ship it, and only then add the deferred features and heavier machinery.

```
Phase 0  Spike            de-risk the make-or-break UX (throwaway)
Phase 1  Foundation       package, fake, CI — the testable spine
Phase 2  v1 critical path the shippable app
Phase 3  Ship v1          TestFlight → App Store
Phase 4  Post-v1          quality filter, location, grow machinery
```

A hard rule across all phases: **Phase 2+ work depends on Phase 1's `FakePhotoLibrary`** — it's the linchpin that makes everything testable headless. Phase 0 deliberately skips it (throwaway code).

---

## Phase 0 — Spike *(throwaway, de-risk)*

**Goal:** answer the questions the fake can't — does hand-curating a year *feel* good, and does the tech hold up on a real, large library — before committing to any architecture.

**High-level tasks:**
1. Throwaway vertical slice on the author's real library: date-range fetch → `LazyVGrid` thumbnails via `PHCachingImageManager` → `.navigationTransition(.zoom)` expand/return → toggle selection into a `Set` → dump to a Photos album. No tests, no design gate, no persistence.
2. Benchmark **lazy `PHFetchResult` adapter vs a flat `[AssetRef]` array** over thousands of assets (settles D17).
3. 30-minute quality-heuristic eyeball: read recorded-original sizes for ~100 real assets (including iCloud-only) and check whether bytes/megapixel separates re-saves from camera originals (informs D3).

**Exit criteria (go/no-go):**
- The review loop feels good at scale, scroll-position restore works, scrolling stays smooth, progressive full-res feels instant. *(If it's a slog, rethink the product before building.)*
- A decision recorded on adapter-vs-array.
- A decision recorded on whether the quality filter is worth building at all.

---

## Phase 1 — Foundation *(the testable spine)*

**Goal:** stand up the project skeleton and the protocol/fake seam that every later phase tests against. Little user-facing value; high leverage.

**High-level tasks:**
1. Repo scaffolding: `Curation` SPM package + the app target, Xcode `.gitignore`, SwiftLint config (D28), lean CI (build + lint + unit/integration + E2E smoke — D23).
2. Domain in `Curation` (pure, no PhotoKit): `AssetRef`/`Coordinate`/`AssetMetadata`, the `PhotoLibraryProviding` protocol, and the dependency direction (D14).
3. **`FakePhotoLibrary`** as a first-class artifact (D25): dual size fields, mutate-and-notify, deterministic progressive image delivery, permission states; a fixture-builder DSL and canonical seeds (`YearMixed2025`, `AllICloudOptimized`, `LimitedAccess`, `EmptyLibrary`).
4. `SystemPhotoLibrary` actor + the `PHPhotoLibraryChangeObserver` shim (D16).
5. The **conformance suite** that runs against both impls (D24).

**Exit criteria:**
- `swift test` runs green headless against `Curation` + the fake.
- CI gates enforced on PRs.
- The conformance suite passes against the fake (and is ready to run against the real impl on device).

---

## Phase 2 — v1 critical path *(the shippable app)*

**Goal:** the whole v1 product (D2). Build the permission flow **first** in this phase — it gates everything downstream.

**High-level tasks (roughly in dependency order):**
1. **Authorization & permissions flow (D6):** rationale screen → system prompt → `.authorized`/`.limited`/`.denied`/`.notDetermined` branches; limited/denied recovery with Settings deep-link. Observable app state driving navigation.
2. **Navigation coordinator (D20):** `NavigationStack` + typed path on a `@MainActor @Observable` coordinator (onboarding → permission → setup → review → export).
3. **Source range + fetch:** date-interval selection; fetch that slice via the actor.
4. **Exact filters:** exclude screenshots (media subtype) + exclude selected album(s) (set difference on identifiers).
5. **Review grid:** thumbnails with progressive loading; **in-grid selection** — quick-select badge + drag-to-multi-select (D9); selected-state encoding (checkmark + dim, ≥44pt); VoiceOver labels/actions + accessibility audit.
6. **Expand view:** zoom navigation destination (D10); Reduce Motion cross-fade; post-condition tests (destination correct, scroll restored, selection preserved — D22).
7. **Targets & tally:** authoritative running total + soft per-month guides in section headers (D5).
8. **Selection & persistence:** in-memory `Set` source of truth + debounced snapshot; SwiftData `CurationSession`; lifecycle/state restoration (D15, D20).
9. **Long-scan progress surface (D12):** determinate, cancelable, curate-while-scanning.
10. **Album export (D19):** create-or-find by stored id + dupe guard + date sort; typed error model + partial-failure handling.

**Exit criteria:**
- A user can pick a range, filter, hand-pick toward a target, and export a correct native album — end to end, on a real device.
- Limited/denied states behave gracefully (no blank grids).
- Integration scenario checklist covered against the fake; E2E smoke green.

---

## Phase 3 — Ship v1 *(TestFlight → App Store)*

**Goal:** get it into real hands and through review. Deploy is manual at first (D26) — no pipeline pre-investment.

**High-level tasks:**
1. Manual TestFlight build from Xcode; dogfood on a real year of photos; fix what hurts.
2. App Store readiness: specific `NSPhotoLibrary*UsageDescription` strings, accurate App Privacy label (on-device-only, iCloud-not-our-servers — D8), description, subtitle/keywords (settle "yearbook"/"photo book" placement).
3. Capture the settled review-screen design as a `docs/design/` UI spec (D27).
4. Accessibility pass (Dynamic Type, VoiceOver, contrast, Reduce Motion).
5. Submit for review; address feedback.

**Exit criteria:**
- v1 approved and live (or in a TestFlight beta deemed ship-ready).
- No dead-ends in any permission state; no rejection blockers.

---

## Phase 4 — Post-v1 *(deferred features + grow machinery)*

**Goal:** add what was deliberately deferred, and scale up the tooling now that there's a product worth protecting.

**High-level tasks:**
1. **Quality / camera-originals filter (D3, D11)** — *only if the Phase 0 spike validated it:* labeled-corpus tests with confusion-matrix metrics (D24), the scoring function in `Curation`, the persisted resource-size cache (D18), an off-by-default toggle, and an inspectable hidden set.
2. **Location bucketing v1.1 (D4):** `NamedLocation`, MapKit pin + radius UI, cluster *suggestions* (human-confirmed), the always-present "no location" bucket — all on EXIF coordinates, no CoreLocation permission (D7).
3. **Grow the machinery (D26, D29):** snapshot test tier (pin simulator OS/device, ban committed record-mode); a fuller E2E suite; the fastlane/`match` deploy pipeline with the App Store Connect API key in CI secrets; promote the performance/scale check to a gate.

**Exit criteria:** judged per feature; no single gate.

---

## Ordering at a glance

| Phase | Depends on | Produces |
|---|---|---|
| 0 Spike | nothing | go/no-go + two recorded decisions (adapter, quality filter) |
| 1 Foundation | Phase 0 decisions | package, protocols, `FakePhotoLibrary`, CI |
| 2 v1 path | Phase 1 fake + CI | the shippable app |
| 3 Ship v1 | Phase 2 | TestFlight / App Store v1 |
| 4 Post-v1 | Phase 3 (+ Phase 0 for the filter) | deferred features, heavier tooling |

GitHub issues link to the high-level tasks above; each issue is a discrete, testable slice within its phase.
