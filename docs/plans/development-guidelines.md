# Poimi — Development Guidelines

*Companion to [product-plan.md](./product-plan.md) and [architecture.md](./architecture.md). The code author is an AI agent, so every guideline here optimizes for **machine-verifiable correctness**: deterministic, headless, fast feedback.*

---

## Guiding principle

**If it can't be verified automatically, it isn't done.** The developer is an AI agent. Every change must be provable by something a machine can run — a test, a linter, a format check, a CI gate — without a human eyeballing a simulator. Designs are the one human-approved input, and even those get pinned to snapshot tests.

---

## Testability first — the PhotoKit problem

PhotoKit can't be mocked directly (it talks to a real, device-bound photo library) and can't be controlled in CI. So:

- **All PhotoKit access sits behind protocols**, defined in the `PhotoLibrary` package — e.g. `PhotoLibraryProviding`, `ImageLoading`, `AlbumExporting`. Application and UI code depend only on the protocols, never on `PHAsset`/`PHPhotoLibrary` directly.
- **Two implementations of each protocol:**
  - `SystemPhotoLibrary` — the real PhotoKit-backed impl. Thin; holds no logic worth testing beyond the wrapping.
  - `FakePhotoLibrary` — an in-memory, seedable library. Holds synthetic assets with controllable capture dates, locations, pixel sizes, subtypes, file sizes, and album membership.
- **The fake is the linchpin of the whole test strategy.** It makes integration *and* E2E runnable headless, deterministic, with no device and no real photos. Seed it from fixtures to reproduce any scenario (a year of mixed HEIC/JPEG/screenshots/WhatsApp saves, iCloud-only originals, no-GPS images, etc.).
- The provider is swapped at launch via a launch argument / environment flag so E2E can run the *real app* against the fake library.

Because the heavy logic lives in the pure `Curation` package (no PhotoKit at all), most correctness is provable with plain unit tests — the fake only matters at the integration boundary and above.

---

## Test tiers

| Tier | Framework | Runs against | What it proves |
|---|---|---|---|
| **Unit** | Swift Testing (`@Test`/`#expect`) | `Curation` pure functions, value types | Filtering predicates, bytes-per-megapixel heuristic, per-month target math, selection-set logic. No simulator — `swift test`. |
| **Integration** | Swift Testing | Stores + `FakePhotoLibrary` | Fetch → filter → select → export round-trips; re-run dedupe; change-tracking updates. Deterministic, headless. |
| **E2E** | XCUITest | Real app + `FakePhotoLibrary` (launch flag) | Full review flow: scroll, tap-to-expand-and-return, select, hit target, export. Runs in simulator in CI. |
| **Snapshot** | swift-snapshot-testing | SwiftUI views | UI matches the approved Paper design. The verifiable target for "does this look right." |

**Coverage expectation:** `Curation` (pure logic) held to high coverage — it's where bugs hide and it's free to test. UI/integration coverage is judged by scenario completeness, not a percentage.

---

## Tooling

| Concern | Tool | Notes |
|---|---|---|
| Lint | **SwiftLint** | Checked-in config. CI fails on violations; no inline disables without a comment justifying them. |
| Format | **swift-format** (Apple) | Format-check in CI (`--mode lint`); the agent runs the formatter before committing. Configure so it doesn't fight SwiftLint. |
| Test runner | `swift test` (packages) + `xcodebuild test` (app) | Pure packages run fast without a simulator; app/E2E in simulator. |
| Snapshot | swift-snapshot-testing | Recorded against approved designs; re-record only with design sign-off. |

**Dependency-minimalism policy:** SPM only. Every new third-party dependency requires explicit justification in the PR and a note in this doc's appendix. An unattended agent does not add libraries freely.

---

## Design workflow (Paper + MCP)

- The design is authored in **Paper**. The agent reads and reasons about designs through the **Paper MCP connection**.
- **Design-freeze gate:** the full design must be approved *before* UI development starts. No UI PR merges until the relevant design is approved.
- The agent transcribes each approved screen into a **UI spec** committed under `docs/design/` (states, gestures, transitions, copy) so the design intent lives in the repo and survives even if the Paper doc moves.
- Snapshot tests are written against the approved design; they are the regression guard.

Pre-UI (data, PhotoKit, filtering, export) work is **not** gated on design and can proceed in parallel.

---

## CI / CD (GitHub Actions)

**On every PR (gates — all must be green to merge):**
1. Build (all packages + app).
2. SwiftLint — zero violations.
3. swift-format check — no diff.
4. Unit + integration tests.
5. E2E + snapshot tests (simulator).
6. No new compiler warnings.

**Deploy to App Store Connect:**
- GitHub Actions → **fastlane** (`pilot` for TestFlight, `deliver`/`upload_to_app_store` for release).
- Signing via **fastlane `match`** (or App Store Connect API key + automatic signing).
- **App Store Connect API key** stored in GitHub Actions secrets — never in the repo.
- Build/version numbers auto-incremented in CI.
- Triggered on tagged releases (TestFlight builds may trigger on merge to the main line — decide in open items).

---

## Workflow & coordination

- **GitHub Issues are the unit of work.** Each issue is a discrete, testable slice. PRs link to their issue and close it.
- **Detailed planning and documentation live in the repo** under `docs/` (`docs/plans/`, `docs/design/`). Issues coordinate; docs are the durable record.
- **Branching:** short-lived branches per issue, PR into the main line. (Session branches follow the harness's required naming.)
- **Commits:** clear, descriptive, scoped to one logical change.

### Definition of Done (every agent PR)

- [ ] Linked to an issue.
- [ ] If UI: references the approved design and adds/updates snapshot tests.
- [ ] New behavior covered by tests at the appropriate tier(s).
- [ ] All CI gates green (build, lint, format, all test tiers, no new warnings).
- [ ] No new third-party dependency without justification.
- [ ] Public types/functions documented where intent isn't obvious.

---

## Open decisions

- **Format tool:** swift-format (recommended) vs SwiftFormat (nicklockwood) — pick one, avoid running both.
- **Signing strategy:** fastlane `match` vs App Store Connect API key with automatic signing.
- **TestFlight trigger:** auto-build on merge to main line, or only on tagged releases.
- **Snapshot device matrix:** which simulators/sizes are the canonical snapshot targets.
