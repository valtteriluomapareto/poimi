# Poimi — Development Guidelines

*Companion to [product-plan.md](./product-plan.md) and [architecture.md](./architecture.md). The code author is an AI agent, so every guideline here optimizes for verifiable correctness: deterministic, headless, fast feedback — while being honest about what a machine cannot verify.*

> Revised after the four-perspective plan review — see [plan-review-decisions.md](./plan-review-decisions.md) for the decisions referenced below as (D#). Committed sequencing: **spike-first, grow machinery** (D1).

---

## Guiding principle (D22)

**Pure logic must be tested; UX is validated by using the app on a real library, plus design sign-off.** Most correctness is machine-provable — and we make it so. But the make-or-break moments (does the zoom transition *feel* right, is curating a year pleasant, how does it behave against real iCloud) are *not* unit-testable. For those we test **post-conditions** (e.g. after dismiss: correct scroll position, selection preserved) and rely on a human using a real build for the *feel*. We do not pretend a green snapshot proves good UX.

## Sequencing (D1)

Build the risky UX before the scaffolding. **Phase 0** is a throwaway spike on a real photo library — no tests, no design gate — to prove the review loop and eyeball the quality heuristic. **Phase 1** is the v1 critical path with the lean test/CI setup below. Heavier machinery (snapshot tier, full E2E, release pipeline) grows in *after* there's something worth shipping.

---

## Testability first — the PhotoKit problem

PhotoKit can't be mocked directly (it talks to a real, device-bound photo library) and can't be controlled in CI. So:

- **All PhotoKit access sits behind protocols**, defined in `Curation` (the domain — D14). Start with a single `PhotoLibraryProviding`; split `ImageLoading` / `AlbumExporting` out only when a consumer needs just one (D21). Application and UI code depend only on the protocols, never on `PHAsset`/`PHPhotoLibrary` directly.
- **Two implementations:**
  - `SystemPhotoLibrary` — the real PhotoKit-backed impl. Thin — but *not* assumed correct (see the conformance suite below; the "thin so untested" assumption is exactly how fakes drift undetected).
  - `FakePhotoLibrary` — an in-memory, seedable library, an `actor` honoring the same isolation as the real one.
- **The fake's API surface is a first-class design item, not just seed data (D25).** It must model:
  - **Dual size fields** — local-cache size *vs* recorded-original size — or the quality-heuristic's core bug class (Optimize-Storage trap) is untestable.
  - **Mutate-and-notify** — insert/delete/modify an asset mid-test and fire the change observer, so change-tracking is actually exercised.
  - **Deterministic progressive image delivery** — emit degraded-then-final on demand, with injectable iCloud delay/failure, so the lazy/progressive load path (otherwise the flakiest thing in the app) is testable.
  - **Permission states** — `.authorized` / `.limited` / `.denied` / `.notDetermined`. Limited access is a first-class state that changes the visible asset set; almost always forgotten.
  - **Canonical named seeds:** `YearMixed2025`, `AllICloudOptimized`, `LimitedAccess`, `EmptyLibrary`, via a fixture-builder DSL.
- **Conformance suite (D24):** one shared test suite run against *both* impls (`FakePhotoLibrary` in CI, `SystemPhotoLibrary` in a manual/nightly real-device job) so the fake can't quietly lie.
- The fake is swapped in via a launch argument / environment flag for E2E — **compiled only under a test/debug configuration**, and the flag is inert in release builds (D30). It must never ship.

Because the heavy logic lives in the pure `Curation` package (no PhotoKit at all), most correctness is provable with plain unit tests — the fake only matters at the integration boundary and above.

---

## Test tiers

**v1 PR gate = Unit + Integration + one E2E smoke test** (D23). Snapshot and a full E2E suite are deferred (D26).

| Tier | Status | Framework | Runs against | What it proves |
|---|---|---|---|---|
| **Unit** | v1 gate | Swift Testing (`@Test`/`#expect`), incl. **parameterized/property-based** for the math (D24) | `Curation` pure functions, value types | Filtering predicates, per-month target math (off-by-one / divide-by-zero edges), selection-set logic, location distance math. No simulator — `swift test`. |
| **Integration** | v1 gate | Swift Testing | Stores + `FakePhotoLibrary` | Fetch → filter → select → export round-trips; re-run idempotence/dedupe; change-tracking mid-session; permission-state branches; progressive-load sequencing. Deterministic, headless. |
| **E2E smoke** | v1 gate (one test) | XCUITest | Real app + `FakePhotoLibrary` (launch flag) | One happy path as a tripwire: launch → scroll → tap-expand-**and-return-to-same-position-still-selected** → select → hit target → export. Asserts the transition's *post-conditions*, not its animation. |
| **Quality-heuristic metrics** | when filter ships (D3/D24) | Swift Testing over a **labeled corpus** | Tagged camera-original vs recompressed fixtures (HEIC/JPEG × megapixels) | Confusion-matrix assertions: precision/recall thresholds, **zero clean-HEIC false positives**. Not example-by-example. |
| **Performance / scale** | named test, not initial gate (D29) | XCTest `measure` / metrics | 10k-asset fake | Seed/fetch + heavy-pass budgets; an **access-counting guard** that fails if the whole fetch result is materialized (enforces "lazy"). |
| **Snapshot** | deferred (D26) | swift-snapshot-testing | SwiftUI views — **opaque content & layout/reflow only** | Added once UI stabilizes; pin exact simulator OS/device, decide Dynamic-Type/Dark-Mode/locale axes, **ban committed record-mode**. **Liquid Glass surfaces are excluded from pixel assertions** — translucent/refractive rendering isn't byte-stable across Xcode point releases; glass *appearance* is a design-signoff concern, not a snapshot. |
| **Accessibility** | cheap add | XCUITest `performAccessibilityAudit()` | Key screens | Labels/contrast/hit-targets headlessly; also enforces stable a11y identifiers for E2E selectors. *Known blind spot:* glass-chrome contrast over arbitrary photo content is content-dependent — the tally's legibility over the brightest seeded thumbnail needs an explicit assertion, not just the static audit. |

**Coverage:** `Curation` held to high coverage — where bugs hide, free to test. For integration, "scenario completeness" is made concrete as an enumerated, DoD-checked fixture/scenario checklist (not a vibe). Every fixed bug ships with a failing-then-passing regression test.

### iOS 26 / iPadOS testing implications

- **CI runtime is a pinned dependency.** The simulator-bound tiers (E2E, accessibility) need a GitHub-hosted runner image with an Xcode that ships the **iOS 26 simulator runtime** — pin it explicitly (Phase 1). The pure `Curation` unit tier runs via `swift test` and is *insulated* from this.
- **Select by accessibility identifier, never coordinate/screenshot** in E2E — Liquid Glass chrome floats over content and changes hit-testing/layering.
- **`performAccessibilityAudit()` on a new OS is itself unproven** and runs on static screens; pair it with the explicit glass-over-photo contrast assertion above.
- **Bound the iPad matrix:** one compact + one regular (split-view) layout each get an integration path; the v1.1 keyboard shortcuts are unit-tested where they map to pure actions; Stage Manager / live window resize / drag-and-drop are **human-verified only**, not gated.

---

## Tooling

| Concern | Tool | Notes |
|---|---|---|
| Lint + format | **SwiftLint only** (with autocorrect) for v1 (D28) | Checked-in config; CI fails on violations; no inline disables without a justifying comment. Skip running swift-format alongside it — the reconciliation is friction we don't need yet; revisit later. |
| Test runner | `swift test` (packages) + `xcodebuild test` (app) | Pure packages run fast without a simulator; app/E2E in simulator. |
| Snapshot | swift-snapshot-testing | **Deferred (D26);** when added, pin OS/device and ban committed record-mode. |

**Dependency-minimalism policy:** SPM only. Every new third-party dependency requires explicit justification in the PR and a note in this doc's appendix. An unattended agent does not add libraries freely.

---

## Design workflow (Paper + MCP) — spike then document (D27)

- The design is authored in **Paper**; the agent reads and reasons about designs through the **Paper MCP connection**.
- **No design-freeze gate.** You can't freeze a UX you haven't validated, and a freeze gate serializes the whole project behind a human approval bottleneck. Instead: validate the interaction with the rough Phase-0 build, *then* commit a design.
- The agent transcribes each settled screen into a **UI spec** under `docs/design/` (states, gestures, transitions, copy) — documentation *following* validation, not a gate *preceding* code.
- Snapshot tests (deferred, D26) become the regression guard once the UI stabilizes.

Pre-UI (data, PhotoKit, filtering, export) work proceeds independently.

---

## CI / CD (GitHub Actions)

**On every PR (v1 gates — all must be green to merge):**
1. Build (package + app).
2. SwiftLint — zero violations.
3. Unit + integration tests.
4. One E2E smoke test (simulator).
5. No new compiler warnings — **advisory early, a hard gate once the codebase settles** (D28).

**Deploy to App Store Connect — deferred (D26).** Until there's something worth a TestFlight build, **ship manually from Xcode**; building out fastlane is pre-investment with no user value yet. When automated:
- GitHub Actions → **fastlane** (`pilot` for TestFlight, `deliver`/`upload_to_app_store` for release).
- Signing via **fastlane `match`** (or App Store Connect API key + automatic signing).
- **App Store Connect API key** in GitHub Actions secrets — never in the repo.
- Build/version numbers auto-incremented in CI.
- TestFlight trigger (merge vs tag) decided then.

---

## Workflow & coordination

- **GitHub Issues are the unit of work.** Each issue is a discrete, testable slice. PRs link to their issue and close it.
- **Detailed planning and documentation live in the repo** under `docs/` (`docs/plans/`, `docs/design/`). Issues coordinate; docs are the durable record.
- **Branching:** short-lived branches per issue, PR into the main line. (Session branches follow the harness's required naming.)
- **Commits:** clear, descriptive, scoped to one logical change.

### Definition of Done (every agent PR)

- [ ] Linked to an issue.
- [ ] If UI: references the settled design / `docs/design/` UI spec.
- [ ] New behavior covered by tests at the appropriate tier(s); the integration scenario checklist updated if a new scenario applies.
- [ ] Every bug fix ships with a failing-then-passing regression test.
- [ ] All CI gates green (build, SwiftLint, unit + integration, E2E smoke; warnings per D28).
- [ ] No new third-party dependency without justification (logged below).
- [ ] Public types/functions documented where intent isn't obvious.

---

## Open decisions (revisit when the relevant machinery lands)

- **Signing strategy:** fastlane `match` vs App Store Connect API key with automatic signing — decide when deploy is automated (D26).
- **TestFlight trigger:** merge to main line vs tagged releases — decide then.
- **Snapshot device matrix / axes:** canonical simulators, OS pin, Dynamic-Type/Dark-Mode/locale coverage — decide when snapshot testing lands (D26).
- **Mutation testing:** optional, nightly on `Curation` only if ever (immature Swift tooling) — not a gate.
