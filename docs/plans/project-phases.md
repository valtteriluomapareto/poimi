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

> **Closed.** Verdicts are recorded in [spike-findings.md](./spike-findings.md); this section is the spike's original charter, so references below to what "the spike settles" were resolved there.

**Goal:** answer the questions the fake structurally can't — does hand-curating a year *feel* good, and does the tech hold up on a real, large library — before committing to architecture. **The single most important thing this spike resolves is the image-picking interaction** (below); everything else is secondary.

### ★ The core thing to inspect and test: the picking interaction

This is the make-or-break loop and the one decision a doc cannot settle — it must be *felt* on a real library. The spike exists primarily to answer it.

**The model to validate (two-tier triage):** the grid handles the **obvious** keeps/skips; the full-screen view handles the **borderline** calls. For this to work:

- **Tap mapping.** The plan is *tap badge → select; tap cell → open full-screen* (D9/D10). The spike must pressure-test this against the alternative *whole-cell tap → select; long-press/pinch → inspect*. The real question: **which action deserves the cheap whole-cell tap — select (the constant action, done hundreds of times) or inspect (occasional)?** Try both on a real year; record which is faster and less error-prone.
- **Badge as a real target.** If the badge stays the select affordance, it must be a **≥44pt hit area** (small glyph, large touch target — effectively the whole corner). Validate it isn't fiddly at speed, and that it doesn't mis-fire while scrolling.
- **Thumbnail density & cell shape.** Default to **~3 columns on iPhone (~128pt)** — large enough to recognize the photo and make obvious calls — with **pinch-to-adjust** density (more columns on iPad). Confirm on a real library: can you make *most* calls from the grid at this size, opening full-screen only for fine ones (sharpness, burst disambiguation, eyes-open)? If you're constantly forced full-screen, the density (or the whole model) is wrong. Also try **square vs aspect-ratio justified cells** (square scans faster but crops framing).
- **Timeline grouping.** Validate the **adaptive day-grouping** (see the Timeline grouping spec) against plain months on a real year: do events pop out and quiet stretches stay compact? Is the **N≈10/day** threshold and the gap-break rule right? This is where the grouping model earns its place or doesn't.
- **Full-screen swipe + select is part of this loop — test it in the spike.** Opening a photo must not be a dead-end: you swipe left/right between photos *and* select in place, so "open to decide" is itself a fast multi-select path. (This is why within-overlay swipe is promoted to v1 — see the design inventory.)

**Record the answers** in `spike-findings.md`: the chosen tap mapping, the default column count, whether the badge target works, and whether grid-triage + full-screen-triage together feel fast over a real year. These seed the Phase 2 grid build and the UI spec.

**High-level tasks:**
1. Throwaway vertical slice on the author's real library: date-range fetch → `LazyVGrid` thumbnails via `PHCachingImageManager` → `.navigationTransition(.zoom)` expand/return → toggle selection into a `Set` → dump to a Photos album. No tests, no design gate, no persistence. **Build it to exercise the picking interaction above** — both tap mappings, full-screen swipe+select, and adjustable density.
2. Benchmark the **lazy `PHFetchResult` adapter vs a flat `[AssetRef]` array** over thousands of assets — record the *numbers* (D17).
3. Exercise the **iCloud-only / optimized-storage** path explicitly (progressive degraded→final under real network latency), not just local assets — this is the make-or-break load case (and what the fake will later model, D25).
4. 30-minute quality-heuristic eyeball: recorded-original sizes for ~100 real assets (incl. iCloud-only), checking whether bytes/megapixel separates re-saves from camera originals — record the observed distribution (informs D3).

**Three tiers of code (D1, refined):**
- **Persists** — the repo bootstrap (Xcode project, app target, folder structure, a stubbed `Curation` package) is created *before* the spike and carried into Phase 1; it is not throwaway.
- **Salvaged behind the protocol seam in Phase 1** — the spike's image-loading, prefetch-window, `.scrollPosition` restore, and `.zoom` transition code is the fiddliest in the app; write it cleanly enough to promote.
- **Thrown away** — the spike's data/fetch/selection/export shortcuts.

**Exit criteria (go/no-go) — captured in a durable artifact:**
- **The picking interaction is resolved** (tap mapping, thumbnail density, cell shape, badge target, full-screen swipe+select) with evidence — this is the primary gate.
- **The timeline grouping is resolved** — adaptive day-groups vs months, the N threshold, and the gap rule — recorded with the real-year observations.
- A `docs/plans/spike-findings.md` (or appended decision entries) recording: the picking-interaction answers above; the loop *feels* good at scale (or not); scroll-restore + recycled-cell behavior; progressive/iCloud timing; the adapter-vs-array numbers; the bytes/MP separation data; and UX/gesture observations to seed the Phase 2 UI spec. **The findings doc is the real Phase 0 output** — the code is disposable, the evidence is not.
- The "Still open" items in the decisions log (picking interaction, adapter-vs-array, quality-filter go/no-go) resolved with reference to that evidence.

### Phase 0 issues (GitHub)

| Issue | Scope | Depends on |
|---|---|---|
| [#3](https://github.com/valtteriluomapareto/poimi/issues/3) | Repo bootstrap — runnable iOS 26 project + stubbed `Curation` package *(persists; pre-spike infra)* | — |
| [#4](https://github.com/valtteriluomapareto/poimi/issues/4) | Spike harness — throwaway review-loop slice on a real library | #3 |
| [#5](https://github.com/valtteriluomapareto/poimi/issues/5) | ★ Resolve the picking interaction *(primary gate)* | #4 |
| [#6](https://github.com/valtteriluomapareto/poimi/issues/6) | Resolve timeline grouping + thumbnail density & cell shape | #4 |
| [#7](https://github.com/valtteriluomapareto/poimi/issues/7) | Benchmark: lazy adapter vs flat `[AssetRef]` array (D17) | #4 |
| [#8](https://github.com/valtteriluomapareto/poimi/issues/8) | Validate the iCloud-only / optimized-storage path | #4 |
| [#9](https://github.com/valtteriluomapareto/poimi/issues/9) | Quality-heuristic eyeball — bytes-per-megapixel (D3) *(standalone)* | — |
| [#10](https://github.com/valtteriluomapareto/poimi/issues/10) | Close out → `spike-findings.md` + resolve open items | #5–#9 |

**Flow:** #3 → #4 → (#5★, #6, #7, #8) → #10; #9 runs in parallel.

---

## Phase 1 — Core spine *(irreducible foundation)*

**Goal:** stand up just enough to make Phase 2 features real and testable. Deliberately small — avoid the infrastructure trough.

**High-level tasks:**
1. Flesh out the scaffolding the bootstrap began (the Xcode project, app target, and stubbed `Curation` package already exist from Phase 0): wire `Curation` as a real dependency of the app target, add SwiftLint config (D28), and **lean CI: build + lint + unit + integration** (the E2E smoke arrives in Phase 2 when there's a flow to drive). **Pin the CI runner's Xcode + iOS 26 simulator runtime explicitly** — the simulator-bound tiers depend on it (the pure `Curation` unit tier does not).
2. Domain in `Curation` (pure): `AssetRef`/`Coordinate`/`AssetMetadata`, the `PhotoLibraryProviding` protocol, dependency direction (D14).
3. A **minimal `FakePhotoLibrary`** (one seed, `.authorized`) honoring the actor isolation — *enough for the permission flow + first grid*. Its harder capabilities (dual sizes, mutate-and-notify, deterministic progressive delivery, the other permission states, access-counting, 10k-scale seeds) grow in Phase 2 with the features that consume them — each landing with a test that exercises it (D25).
4. `SystemPhotoLibrary` actor skeleton + the `PHPhotoLibraryChangeObserver` shim (D16).
5. **Composition root / DI seam:** the `@main` wiring that swaps `FakePhotoLibrary` for `SystemPhotoLibrary`, compiled into the app only under a test/debug configuration and **inert in release** (D30).

**Exit criteria (verifiable):**
- `swift test` green headless against `Curation` + the minimal fake.
- CI enforced on PRs (build + lint + unit + integration).
- A build-time/CI check confirms **`Curation` imports neither Photos nor SwiftData** (the boundary invariant, D14/D21).
- A CI check confirms **no SDK-version availability gates / `.regularMaterial` version fallbacks** for Liquid Glass (the "pure glass" invariant — parallels the `Curation` import check; accessibility fallbacks are exempt).
- A check confirms `FakePhotoLibrary` is excluded from the release configuration and the swap flag is inert in release (D30).

### Phase 1 issues (GitHub)

| Issue | Scope | Depends on |
|---|---|---|
| [#17](https://github.com/valtteriluomapareto/poimi/issues/17) | Scaffolding & lean CI — wire `Curation` dep, SwiftLint, CI (build + lint + unit + integration), pinned Xcode/iOS-26 runtime, the boundary / pure-glass / release-exclusion guards | #3 |
| [#18](https://github.com/valtteriluomapareto/poimi/issues/18) | `Curation` value model (`AssetRef` / `Coordinate` / `AssetMetadata`) + `PhotoLibraryProviding` protocol (D13/D14) | #17 |
| [#19](https://github.com/valtteriluomapareto/poimi/issues/19) | `Curation`: `DayKey` + adaptive day-grouping *(pure, property-tested)* | #18 |
| [#20](https://github.com/valtteriluomapareto/poimi/issues/20) | `Curation`: target math + selection + section-done + stats *(pure, property-tested; D32(d))* | #18, #19 |
| [#21](https://github.com/valtteriluomapareto/poimi/issues/21) | Minimal `FakePhotoLibrary` (one seed, `.authorized`) | #18 |
| [#22](https://github.com/valtteriluomapareto/poimi/issues/22) | `SystemPhotoLibrary` actor skeleton + change-observer shim (D16) | #18 |
| [#23](https://github.com/valtteriluomapareto/poimi/issues/23) | Composition root / DI seam (D30) | #21, #22 |

**Flow:** #17 → #18 → (#19 → #20) ∥ (#21, #22) → #23. The two `Curation` "testable core" issues (#19, #20) realize the pure parts of D32(d)/D34 — no PhotoKit, no SwiftData.

---

## Phase 2 — v1 critical path *(the shippable app)*

**Goal:** the whole v1 product (D2). The fake, seeds, conformance suite, and E2E smoke grow here, alongside the features that need them.

**High-level tasks (in dependency order):**
1. **Onboarding + Authorization flow (D6):** first-run explanation of what the app does (it earns the full-access grant; the name is opaque, so orientation matters) → rationale screen → system prompt → `.authorized`/`.limited`/`.denied`/`.notDetermined` branches; limited/denied recovery with `UIApplication.openSettingsURLString` deep-link (copy sets the right expectation: Settings → Poimi → Photos → All Photos). **Author the specific `NSPhotoLibrary*UsageDescription` strings here** — they are build-time and the app crashes on the auth call without them.
2. **Navigation coordinator (D20), adaptive:** a `@MainActor @Observable` coordinator with a typed path rooted at the album library (onboarding → permission → albums → albumOverview → review → photo → export, per architecture §11); auth state drives it. Compact width = `NavigationStack` with the zoom push; regular width = `NavigationSplitView` (sidebar · grid · detail) whose **detail column hosts its own `NavigationStack`** so the zoom transition still applies. The typed path maps onto split-view selection + the nested stack (see the architecture's adaptive-navigation note).
3. **Selection store + target math (D15, D5):** the in-memory `Set<String>` source of truth and the running-total / per-month tally — built *before* the grid that consumes them. *(Persistence is task 9, deliberately later.)*
4. **Source range + fetch:** date-interval selection; fetch via the actor; land the **access-counting / scale named test** (D29) with the fetch tier so the "lazy" invariant can't regress silently.
5. **Exact filters + setup screens:** exclude screenshots (media subtype) + exclude selected album(s) (set difference — needs album *enumeration* on `PhotoLibraryProviding`); the **export-album naming/selection** step; empty-result handling (no photos after filters / empty month) as an explicit state, not a void grid.
6. **Review grid:** thumbnails with progressive loading (promoted from the spike); **in-grid selection** — quick-select badge + drag-to-multi-select (D9) + a **Select-mode contextual toolbar** (select-all-month / clear); selected-state encoding (checkmark + dim, ≥44pt); the **tally + export grouped as one glass region** with scroll-edge legibility; **Dynamic Type + VoiceOver labels/actions/section-summary + Reduce-Transparency built in**, `performAccessibilityAudit()` per screen. A first **`docs/design/` UI-spec draft** is written here, before/with the grid (spike-then-document, D27).
7. **Expand view + swipe-and-select:** zoom navigation destination (D10); Reduce Motion cross-fade; **swipe left/right between photos and select in place** (load-bearing for the picking model; the spike resolved that we return to the photo you swiped to); post-condition tests — destination correct, scroll restored, selection preserved (D22).
8. **Long-scan indicator (minimal):** a simple determinate/indeterminate fetch+thumbnail-load indicator. *(The full cancelable curate-while-scanning surface, D12, moves to Phase 4 with the quality filter it actually serves.)*
9. **Persistence + lifecycle:** debounced selection snapshot + SwiftData `CurationProject` (don't-lose-picks — essential; the plural album-library model, D31); **establish a SwiftData migration/versioning approach here** since the schema evolves into Phase 4. Cross-launch scroll restoration + background flush + **library-change reconciliation** (prune selection when assets vanish, refresh fetch on resume, consuming the Phase 1 observer) land late in this phase — robustness, after the loop works.
10. **Album export (D19):** create-or-find by stored id (recreate if deleted) + dupe guard + date sort; typed error model + partial-failure handling; a success/idempotence confirmation ("Updated Best of 2025: added 12, now 187").
11. **iPad split-view layout:** the `NavigationSplitView` regular-width layout (sidebar · grid · detail) and reflow for Split View / Stage Manager / resize. *Layout only — keyboard shortcuts, hover, and drag-and-drop are v1.1 (per the "split-view yes, input later" decision).*
12. **Grow test infrastructure here:** the fake's remaining capabilities + canonical seeds, the **conformance suite** (D24), and the **one E2E smoke** (D23) — each as its consuming feature lands. **E2E selects by accessibility identifier, never by coordinate/screenshot** (glass chrome floats over content). Include a **`localIdentifier`-churn** fixture scenario (the whole app rests on identifier stability).

**Exit criteria (verifiable):**
- Each permission-state branch has an integration test asserting the resulting destination/recovery, including the `.limited` reduced visible set and the Settings deep-link path.
- Export correctness (create-or-find, dupe guard, date sort, partial-failure) asserted in the integration tier — not by eyeball.
- Zoom post-conditions, project + scroll-position restoration, and selection flush-on-background each verified by tests.
- The enumerated integration **scenario checklist** (defined in development-guidelines) is complete; E2E smoke green. One compact + one regular (iPad split-view) layout each have an integration path; live resize / Stage Manager are human-verified.
- **Conformance suite green against `SystemPhotoLibrary` on a real device** (the gate that proves the fake isn't lying — D24).
- "No new compiler warnings" flips from advisory to a hard gate at this exit (D28).
- End to end on a real device: pick a range, filter, hand-pick toward a target, export a correct native album; no blank/dead-end in any permission or empty-result state.

### Phase 2 issues (GitHub)

Folds the original task list together with the design/architecture additions — the album library, Overview, mark-as-done, completion, and settings (D31–D34).

| Issue | Scope | Depends on |
|---|---|---|
| [#28](https://github.com/valtteriluomapareto/poimi/issues/28) | Test target + integration tier + fake growth + conformance suite (D23/D24/D25/D29) | Phase 1 |
| [#29](https://github.com/valtteriluomapareto/poimi/issues/29) | State foundation: `CurationProject` + `ProjectStore` + `SelectionStore` + target math (D15/D31/D34) | #28 |
| [#30](https://github.com/valtteriluomapareto/poimi/issues/30) | Navigation coordinator, adaptive (D20) | #29 |
| [#31](https://github.com/valtteriluomapareto/poimi/issues/31) | Onboarding + authorization flow (D6) — Welcome, Limited fallback | #30 |
| [#32](https://github.com/valtteriluomapareto/poimi/issues/32) | Albums home (D31) — Project list | #29, #30 |
| [#33](https://github.com/valtteriluomapareto/poimi/issues/33) | New-album setup + album picker — Project setup, Album picker | #32 |
| [#34](https://github.com/valtteriluomapareto/poimi/issues/34) | Fetch + exact filters + long-scan surface (D2/D12/D17) — Scanning | #29, #33 |
| [#35](https://github.com/valtteriluomapareto/poimi/issues/35) | ★ Review grid + in-grid selection (D9) — Review grid, Select mode | #34 |
| [#36](https://github.com/valtteriluomapareto/poimi/issues/36) | Expand viewer + swipe-and-select (D10/D22) — Photo viewer | #35 |
| [#37](https://github.com/valtteriluomapareto/poimi/issues/37) | Overview (zoom-out level) — Overview | #35 |
| [#38](https://github.com/valtteriluomapareto/poimi/issues/38) | Mark-as-done + resume (D32(d)) — Mark as done | #37, #29 |
| [#39](https://github.com/valtteriluomapareto/poimi/issues/39) | Album export + completion (D19) — Completion | #29, #35 |
| [#40](https://github.com/valtteriluomapareto/poimi/issues/40) | Empty + error states | #34, #39 |
| [#41](https://github.com/valtteriluomapareto/poimi/issues/41) | Album settings (D31) — Album settings | #32, #33 |
| [#42](https://github.com/valtteriluomapareto/poimi/issues/42) | iPad split-view layout (D20) | #30, #35 |
| [#43](https://github.com/valtteriluomapareto/poimi/issues/43) | E2E smoke + UI spec (D23/D27) | most of the above |

**Flow:** #28 → #29 → #30 → onboarding/home/setup (#31/#32/#33) → fetch (#34) → **★#35 review grid** → #36 viewer ∥ #37 overview → #38 mark-as-done ; export #39 ; states #40 ; settings #41 ; iPad #42 ; close-out #43.

**Build order:** stand up the spine (#28→#30), then drive a thin path to **#34 + #35** to re-validate the picking *feel* on a real library *before* spreading into breadth — the spike validated the concept; #35 is where the real implementation holds up or doesn't.

---

## Phase 3 — Ship v1 *(TestFlight → App Store)*

**Goal:** real hands, through review. Deploy is manual at first (D26).

**High-level tasks:**
1. Manual TestFlight build from Xcode; dogfood on a real year; fix what hurts.
2. **Prepare the App Review submission for full-access** (the most likely rejection): written justification (no PHPicker — no persistent identifiers, no date-range fetch, no album writes), reviewer walkthrough, demo notes. **Decide the hard-gate-vs-degraded-limited-mode posture and a fallback *before* submitting**, not in response to rejection.
3. App Store listing: accurate App Privacy label (on-device-only; iCloud is Apple's, not our servers — D8), description, subtitle, and the album/curation keyword placement (discoverability, given the opaque name). Screenshots must reflect the Liquid Glass UI (built against the current SDK — the App Store gives legacy appearance otherwise).
4. **App icon** — the layered iOS 26 deliverable (Icon Composer; light/dark/clear/tinted), distinctive given the opaque name.
5. **Finalize** the `docs/design/` review-screen UI spec (drafted in Phase 2).
6. Accessibility **final verification**: end-to-end VoiceOver flow walkthrough + a full audit (Dynamic Type / contrast / Reduce Motion / Reduce Transparency were built per-screen in Phase 2; this confirms the holistic flow, incl. tally legibility over bright photos).
7. Submit; address feedback.

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

## Design inventory — views & interactions to design

The screens and interactions that need a Paper design, tagged by the phase/version they ship in, and doubling as the **design→test coverage checklist** (most items map to a planned test tier). The `docs/design/` UI spec transcribes each one as it's settled.

> **This is a tracking checklist, not a batch to complete up front.** Each v1 item is designed **just-in-time, as its Phase 2 screen is built** (D27) — designing all of them before Phase 2 starts would reconstitute the design-freeze gate we deliberately removed.

### Onboarding & permissions *(v1)*
1. **First-run intro** — what the app does ("you pick every photo, not an algorithm"); orients before the access ask (the name is opaque, so this carries weight).
2. **Permission rationale** — shown *before* the system prompt; explains why full library access is needed.
3. **Access-recovery screen** — *one parameterized screen* covering both `.limited` ("the year can't be scanned in limited mode") and `.denied`, with the `UIApplication.openSettingsURLString` deep-link and expectation-setting copy. (Don't design two near-identical screens.)

### Source setup *(v1)*
4. **Range & target setup** — date-interval picker + target count + opt-in filter toggles (exclude screenshots, exclude album(s)).
5. **Album picker** — pick the album(s) to exclude (WhatsApp, Downloads, etc.); requires album *enumeration* as a `PhotoLibraryProviding` capability (the fake must model it).
6. **Export-album naming / selection** — name the new album ("Best of 2025") or pick an existing one to update. The album name is the only metadata that travels, so this is a real first-run step, not an afterthought.

### Review — the core loop *(v1)*

> **The picking interaction is the make-or-break of the whole app and is validated first in the Phase 0 spike (see ★ there).** Model: two-tier triage — grid for obvious calls, full-screen for borderline. Items 7–11 below carry the resolved design; the Phase-0 spike **resolved** the tap mapping, thumbnail density, badge target, and full-screen swipe+select ([spike-findings.md](./spike-findings.md)).

7. **Review grid** — chronological thumbnail grid grouped by **adaptive day-groups** (spec below), not by month; the make-or-break screen. **Default ~3 columns on iPhone (~128pt — large enough to judge obvious calls), pinch-adjustable density** (more on iPad). **Cell shape — resolved by the spike → square** (scannable; the aspect alternative was tried on-device and dropped — [spike-findings.md](./spike-findings.md)). Group headers show the label + count (no quota — D5); they're a label, not a separate screen.
8. **Selection affordances** — quick-select badge per cell, with a **≥44pt hit area** (small glyph, large touch target — effectively the whole corner) so selecting is fast and doesn't mis-fire while scrolling; selected-state encoding (checkmark + dim, never colour-alone). *(Tap mapping — badge-select + cell-opens vs whole-cell-select — is resolved by the spike.)*
9. **Select-mode contextual toolbar** — batch operators essential at year scale: Select-all-this-month, Deselect-month, Clear-selection, with a live count (Photos pattern).
10. **Running tally / target progress** — always-visible total ("147 / 200"); **grouped with the export action into a single glass region** (no glass-on-glass), legibility over photos guaranteed by the scroll-edge effect, with a designed Dynamic-Type reflow at AX sizes.
11. **Expand / full-screen inspection + swipe-and-select** — the zoom-destination detail view; progressive thumbnail→full-res; **swipe left/right between photos and select in place**, so "open to decide" is itself a fast multi-select path (load-bearing for the two-tier picking model, not a dead-end). *(Which photo we land back on is resolved in the spike.)*
12. **Fetch / load indicator (minimal)** — simple determinate/indeterminate state while fetching the range and loading thumbnails. *(The full curate-while-scanning surface is deferred, item 23.)*

### Export *(v1)*
13. **Export result / confirmation** — success + idempotence ("Updated Best of 2025: added 12, now 187"); re-run communicated. (In-progress is a transient state of item 12, not its own screen.)

### States *(v1 — easy to forget, design explicitly)*
14. **Empty states** — no photos in range, everything filtered out, empty month, empty library; each actionable (e.g. relax filters), never a void grid.
15. **Error states** — iCloud fetch failure, export failure (incl. partial), authorization revoked mid-session; each recoverable.
16. **Session resume** — "Resume your Best of 2025 (147 / 200)?" on relaunch.

### Cross-cutting interactions & behaviors *(v1)*
17. **Tap-to-expand → return-to-position** — zoom transition out and back to the source cell, scroll position + selection preserved (D10/D22); handle a recycled/off-screen source cell.
18. **Drag-to-multi-select** — pan across cells to batch-toggle (the speed-maker at scale, D9).
19. **Accessibility & motion** — Dynamic Type reflow of all chrome (incl. the tally at AX sizes), VoiceOver labels + a custom select action on cells + **section grouping/summary** ("March, 31 photos, 4 selected") so a thousands-cell grid is navigable, **focus-ring appearance** over photos, contrast/scroll-edge over bright thumbnails, and **Reduce-Motion** (cross-fade) + **Reduce-Transparency** (opaque glass) fallbacks; designed into each screen, not bolted on.

### iPad *(layout in v1; input polish in v1.1 — per the "split-view yes, input later" decision)*
20. **iPad split-view + sidebar** *(v1)* — `NavigationSplitView`: sidebar (the album library; location buckets join in v1.1) · grid · detail; the detail column hosts its own `NavigationStack` so the zoom transition applies. Reflows for Split View / Stage Manager / window resize.
21. **iPad input polish** *(v1.1)* — keyboard-shortcut map + ⌘-hold discoverability overlay, pointer/hover states, drag-and-drop.

### Identity & App Store *(v1, designed for Phase 3)*
22. **App icon** — distinctive (the name is opaque); on iOS 26 a layered Icon Composer deliverable with light/dark/clear/tinted variants. App Store screenshots must reflect the Liquid Glass UI.

### Deferred *(design when the feature lands)*
23. **Full long-scan progress** *(Phase 4, with the quality filter)* — determinate count, cancelable, curate-while-scanning (D12).
24. **Quality filter toggle + inspectable hidden set** *(Phase 4)* — off-by-default toggle in setup; a browsable "Hidden: 312 — review" view so nothing is silently lost (D11).
25. **Named-locations management** *(v1.1)* — list/create/edit named locations.
26. **Map pin + radius editor** *(v1.1)* — drop a pin, adjust radius (`MKCircle`), name it; EXIF-based, no location permission (D7).
27. **Cluster-suggestion confirmation** *(v1.1)* — "name this frequent cluster?", human-confirmed, dismissible.
28. **Location buckets + "no location" bucket** *(v1.1)* — bucketed review entry points, always including no-GPS.

## Timeline grouping *(v1)*

The grid is one chronological flow (capture date, oldest → newest) split into **adaptive day-groups** — a deterministic, location-free heuristic that makes events stand out while keeping quiet stretches compact. It replaces month grouping (which models a family's year badly: life clusters by event, not calendar, and a flat monthly quota over-serves quiet months and under-serves the vacation).

**The rule:**
- Threshold **N = 10 photos/day** (a tunable constant; **held in the spike**).
- A calendar day with **≥ N** photos → **its own group** ("Sat 5 Jul · 53").
- A maximal run of **consecutive days each with < N** photos → **merged into one group** ("16–18 Mar · 7").
- A run breaks on (a) a busy day, or (b) a calendar gap with no photos beyond a small tolerance — so quiet runs stay tight (no "Days 2–40" spanning an empty month). The gap tolerance (default 1 day) held in the spike; still tunable.
- **No per-group target/quota** — show the count only; the running **total** is the authoritative constraint (D5).
- Labels are date-based for v1 (single day vs date range); event/place names arrive with the location feature.

**Why this shape:**
- **Pure & deterministic** — a function of (capture dates, N) with no ML and no fuzzy continuous gap-clustering. Lives in `Curation`; unit- and property-testable (the off-by-one/empty-day/gap edges are exactly what property tests catch).
- **Events emerge for free** — a trip is a run of busy days, each its own section; a lazy week collapses into one. Better than months, with none of the cost.
- **A clean stepping stone** — when location/event grouping lands (v1.1), consecutive busy days at one place collapse into a named "Italy trip"; the day-group is the fallback when there's no location.

**Spike verdict:** the adaptive day-grouping made a real year manageable — events pop, quiet runs merge — and **N≈10 + the gap rule held** ([spike-findings.md](./spike-findings.md)).

## Ordering at a glance

| Phase | Depends on | Produces |
|---|---|---|
| 0 Spike | nothing | `spike-findings.md` (numbers + UX notes) → two resolved decisions; salvageable render-layer code |
| 1 Core spine | Phase 0 findings | `Curation` + protocol + minimal fake + DI seam + lean CI |
| 2 v1 path | Phase 1 spine | the shippable app; fake/conformance/E2E grown to full |
| 3 Ship v1 | Phase 2 (incl. on-device conformance) | TestFlight / App Store v1 |
| 4 Post-v1 | Phase 3 (+ Phase 0 for the filter) | deferred features, heavier tooling |

GitHub issues link to the high-level tasks above; each issue is a discrete, testable slice within its phase.
