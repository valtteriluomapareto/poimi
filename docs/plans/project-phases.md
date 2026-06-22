# Poimi — Project Phases

*The build sequence: high-level tasks in order, with verifiable exit criteria per phase. Companion to [product-plan.md](./product-plan.md), [architecture.md](./architecture.md), [development-guidelines.md](./development-guidelines.md), and [plan-review-decisions.md](./plan-review-decisions.md) (decisions referenced as D#). GitHub issues link back to the tasks here.*

> Revised after a four-perspective review of the first draft (Architect / Tester / Pragmatist / HIG). Key changes: Phase 1 shrunk to a core spine with the fake grown feature-by-feature; spike findings captured durably; UI-spec drafted in Phase 2 not Phase 3; usage strings + onboarding pulled into Phase 2; App-Review justification scheduled; exit criteria made verifiable.

---

## Shape of the plan

Five phases, **spike-first** (D1): prove the riskiest UX on a real library *before* building durable scaffolding, then a lean spine, then the v1 critical path, ship, and only then the deferred features and heavier machinery.

```
Phase 0  Spike            de-risk the make-or-break UX (data layer throwaway, render layer salvageable)
Phase 1  Core spine       Curation domain + protocol + minimal fake + lean CI
Phase 2  v1 critical path the shippable app; the fake/CI grow feature-by-feature
Phase 3  Ship v1          TestFlight → App Store
Phase 4  Post-v1          quality filter, location, grow machinery
```

**Two rules across all phases:**
- Phase 2+ feature work tests against `FakePhotoLibrary` — but each fake *capability* is built (and gated by a test) only when the feature that needs it lands. Phase 1 ships a minimal fake, not the whole harness.
- Every bug fix ships with a failing-then-passing regression test (per development-guidelines). The integration tier carries the regression load through Phase 2; the single E2E smoke is a tripwire, not the safety net.

---

## Phase 0 — Spike *(de-risk)*

**Goal:** answer the questions the fake structurally can't — does hand-curating a year *feel* good, and does the tech hold up on a real, large library — before committing to architecture.

**High-level tasks:**
1. Throwaway vertical slice on the author's real library: date-range fetch → `LazyVGrid` thumbnails via `PHCachingImageManager` → `.navigationTransition(.zoom)` expand/return → toggle selection into a `Set` → dump to a Photos album. No tests, no design gate, no persistence.
2. Benchmark the **lazy `PHFetchResult` adapter vs a flat `[AssetRef]` array** over thousands of assets — record the *numbers* (D17).
3. Exercise the **iCloud-only / optimized-storage** path explicitly (progressive degraded→final under real network latency), not just local assets — this is the make-or-break load case (and what the fake will later model, D25).
4. 30-minute quality-heuristic eyeball: recorded-original sizes for ~100 real assets (incl. iCloud-only), checking whether bytes/megapixel separates re-saves from camera originals — record the observed distribution (informs D3).

**The salvageable render layer (D1, loosened):** the spike's image-loading, prefetch-window, `.scrollPosition` restore, and `.zoom` transition code is the fiddliest in the app — write it cleanly enough to **promote into Phase 2 behind the protocol seam**. Only the data/fetch/selection/export shortcuts are thrown away.

**Exit criteria (go/no-go) — captured in a durable artifact:**
- A `docs/plans/spike-findings.md` (or appended decision entries) recording: the loop *feels* good at scale (or not); scroll-restore + recycled-cell behavior; progressive/iCloud timing; the adapter-vs-array numbers; the bytes/MP separation data; and UX/gesture observations to seed the Phase 2 UI spec. **The findings doc is the real Phase 0 output** — the code is disposable, the evidence is not.
- The "Still open" items in the decisions log (adapter-vs-array, quality-filter go/no-go) resolved with reference to that evidence.

---

## Phase 1 — Core spine *(irreducible foundation)*

**Goal:** stand up just enough to make Phase 2 features real and testable. Deliberately small — avoid the infrastructure trough.

**High-level tasks:**
1. Repo scaffolding: `Curation` SPM package + the app target, Xcode `.gitignore`, SwiftLint config (D28), **lean CI: build + lint + unit + integration** (the E2E smoke arrives in Phase 2 when there's a flow to drive).
2. Domain in `Curation` (pure): `AssetRef`/`Coordinate`/`AssetMetadata`, the `PhotoLibraryProviding` protocol, dependency direction (D14).
3. A **minimal `FakePhotoLibrary`** (one seed, `.authorized`) honoring the actor isolation — *enough for the permission flow + first grid*. Its harder capabilities (dual sizes, mutate-and-notify, deterministic progressive delivery, the other permission states, access-counting, 10k-scale seeds) grow in Phase 2 with the features that consume them — each landing with a test that exercises it (D25).
4. `SystemPhotoLibrary` actor skeleton + the `PHPhotoLibraryChangeObserver` shim (D16).
5. **Composition root / DI seam:** the `@main` wiring that swaps `FakePhotoLibrary` for `SystemPhotoLibrary`, compiled into the app only under a test/debug configuration and **inert in release** (D30).

**Exit criteria (verifiable):**
- `swift test` green headless against `Curation` + the minimal fake.
- CI enforced on PRs (build + lint + unit + integration).
- A build-time/CI check confirms **`Curation` imports neither Photos nor SwiftData** (the boundary invariant, D14/D21).
- A check confirms `FakePhotoLibrary` is excluded from the release configuration and the swap flag is inert in release (D30).

---

## Phase 2 — v1 critical path *(the shippable app)*

**Goal:** the whole v1 product (D2). The fake, seeds, conformance suite, and E2E smoke grow here, alongside the features that need them.

**High-level tasks (in dependency order):**
1. **Onboarding + Authorization flow (D6):** first-run explanation of what the app does (it earns the full-access grant; the name is opaque, so orientation matters) → rationale screen → system prompt → `.authorized`/`.limited`/`.denied`/`.notDetermined` branches; limited/denied recovery with `UIApplication.openSettingsURLString` deep-link (copy sets the right expectation: Settings → Poimi → Photos → All Photos). **Author the specific `NSPhotoLibrary*UsageDescription` strings here** — they are build-time and the app crashes on the auth call without them.
2. **Navigation coordinator (D20):** `NavigationStack` + typed path on a `@MainActor @Observable` coordinator (onboarding → permission → setup → review → export); auth state drives the path.
3. **Selection store + target math (D15, D5):** the in-memory `Set<String>` source of truth and the running-total / per-month tally — built *before* the grid that consumes them. *(Persistence is task 9, deliberately later.)*
4. **Source range + fetch:** date-interval selection; fetch via the actor; land the **access-counting / scale named test** (D29) with the fetch tier so the "lazy" invariant can't regress silently.
5. **Exact filters:** exclude screenshots (media subtype) + exclude selected album(s) (set difference); empty-result handling (no photos after filters / empty month) as an explicit state, not a void grid.
6. **Review grid:** thumbnails with progressive loading (promoted from the spike); **in-grid selection** — quick-select badge + drag-to-multi-select (D9); selected-state encoding (checkmark + dim, ≥44pt); **Dynamic Type + contrast + VoiceOver labels/actions built in**, `performAccessibilityAudit()` per screen. A first **`docs/design/` UI-spec draft** is written here, before/with the grid (spike-then-document, D27).
7. **Expand view:** zoom navigation destination (D10); Reduce Motion cross-fade; within-overlay swipe + which-photo-we-return-to resolved (was open); post-condition tests — destination correct, scroll restored, selection preserved (D22).
8. **Long-scan indicator (minimal):** a simple determinate/indeterminate fetch+thumbnail-load indicator. *(The full cancelable curate-while-scanning surface, D12, moves to Phase 4 with the quality filter it actually serves.)*
9. **Persistence + lifecycle:** debounced selection snapshot + SwiftData `CurationSession` (don't-lose-picks — essential); **establish a SwiftData migration/versioning approach here** since the schema evolves into Phase 4. Cross-launch scroll restoration + background flush + **library-change reconciliation** (prune selection when assets vanish, refresh fetch on resume, consuming the Phase 1 observer) land late in this phase — robustness, after the loop works.
10. **Album export (D19):** create-or-find by stored id (recreate if deleted) + dupe guard + date sort; typed error model + partial-failure handling; a success/idempotence confirmation ("Updated 2025 Yearbook: added 12, now 187").
11. **Grow test infrastructure here:** the fake's remaining capabilities + canonical seeds, the **conformance suite** (D24), and the **one E2E smoke** (D23) — each as its consuming feature lands. Include a **`localIdentifier`-churn** fixture scenario (the whole app rests on identifier stability).

**Exit criteria (verifiable):**
- Each permission-state branch has an integration test asserting the resulting destination/recovery, including the `.limited` reduced visible set and the Settings deep-link path.
- Export correctness (create-or-find, dupe guard, date sort, partial-failure) asserted in the integration tier — not by eyeball.
- Zoom post-conditions, session + scroll-position restoration, and selection flush-on-background each verified by tests.
- The enumerated integration **scenario checklist** (defined in development-guidelines) is complete; E2E smoke green.
- **Conformance suite green against `SystemPhotoLibrary` on a real device** (the gate that proves the fake isn't lying — D24).
- "No new compiler warnings" flips from advisory to a hard gate at this exit (D28).
- End to end on a real device: pick a range, filter, hand-pick toward a target, export a correct native album; no blank/dead-end in any permission or empty-result state.

---

## Phase 3 — Ship v1 *(TestFlight → App Store)*

**Goal:** real hands, through review. Deploy is manual at first (D26).

**High-level tasks:**
1. Manual TestFlight build from Xcode; dogfood on a real year; fix what hurts.
2. **Prepare the App Review submission for full-access** (the most likely rejection): written justification (no PHPicker — no persistent identifiers, no date-range fetch, no album writes), reviewer walkthrough, demo notes. **Decide the hard-gate-vs-degraded-limited-mode posture and a fallback *before* submitting**, not in response to rejection.
3. App Store listing: accurate App Privacy label (on-device-only; iCloud is Apple's, not our servers — D8), description, subtitle, and the "yearbook"/"photo book" keyword placement (discoverability, given the opaque name).
4. **Finalize** the `docs/design/` review-screen UI spec (drafted in Phase 2).
5. Accessibility **final verification**: end-to-end VoiceOver flow walkthrough + a full audit (Dynamic Type / contrast / Reduce Motion were built per-screen in Phase 2; this confirms the holistic flow).
6. Submit; address feedback.

**Exit criteria:**
- Machine-checkable readiness met *before* submission: usage strings present, privacy-label fields populated, `performAccessibilityAudit()` green on review grid + expand + permission screens.
- No dead-ends in any permission/empty state; the full-access justification is prepared.
- v1 approved and live (or a TestFlight beta deemed ship-ready).

---

## Phase 4 — Post-v1 *(deferred features + grow machinery)*

**Goal:** add what was deferred, and scale the tooling now there's a product worth protecting.

**High-level tasks:**
1. **Quality / camera-originals filter (D3, D11)** — *only if Phase 0 validated it:* labeled-corpus tests with confusion-matrix metrics, **zero clean-HEIC false positives** (D24), thresholds grounded in the Phase 0 real-asset data (and the synthetic corpus validated to reflect that distribution); the scoring function in `Curation`; the persisted resource-size cache (D18); off-by-default toggle; inspectable hidden set; **plus the full long-scan progress surface** (determinate, cancelable, curate-while-scanning — D12, which this filter is what actually justifies).
2. **Location bucketing v1.1 (D4):** `NamedLocation`, MapKit pin + radius UI, human-confirmed cluster *suggestions*, the always-present "no location" bucket — all on EXIF coordinates, no CoreLocation permission (D7). Requires the SwiftData migration approach established in Phase 2.
3. **Grow the machinery (D26, D29, D28):** snapshot test tier — triggered by the Phase 3 UI-spec commit (the concrete "UI has stabilized" signal), pin simulator OS/device, ban committed record-mode; a fuller E2E suite; the fastlane/`match` deploy pipeline with the App Store Connect API key in CI secrets; promote the access-counting/scale check from a named test to a hard gate.

**Exit criteria:** judged per feature — each workstream carries the mini exit criterion from its referenced decision (D24 metrics, D29 budgets, D26 snapshot pinning).

---

## Ordering at a glance

| Phase | Depends on | Produces |
|---|---|---|
| 0 Spike | nothing | `spike-findings.md` (numbers + UX notes) → two resolved decisions; salvageable render-layer code |
| 1 Core spine | Phase 0 findings | `Curation` + protocol + minimal fake + DI seam + lean CI |
| 2 v1 path | Phase 1 spine | the shippable app; fake/conformance/E2E grown to full |
| 3 Ship v1 | Phase 2 (incl. on-device conformance) | TestFlight / App Store v1 |
| 4 Post-v1 | Phase 3 (+ Phase 0 for the filter) | deferred features, heavier tooling |

GitHub issues link to the high-level tasks above; each issue is a discrete, testable slice within its phase.
