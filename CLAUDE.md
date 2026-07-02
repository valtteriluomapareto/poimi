# CLAUDE.md

Orientation for AI agents (and humans) working in this repo. Read this first, then the
[doc map](#documentation-map) for depth. Keep it accurate — update it when the facts change.

## What Poimi is

An iOS 26 / iPadOS 26 app for **hand-curating a year (or any date range) of your photo
library into a single Apple Photos album** — efficiently, toward a target count.

**The one-line product truth:** *you choose every photo, not an algorithm.* No auto-selection.
The app makes manual curation at scale fast and keeps you oriented (count, coverage, day-groups);
the human picks each photo. Full rationale: [docs/plans/product-plan.md](docs/plans/product-plan.md).

The output is a **native Photos album** ("album", never "yearbook"). There is **no printing
feature** — do not add print/PDF/export-to-print language anywhere.

**License:** dual-licensed — AGPL-3.0 ([`LICENSE`](LICENSE)) for open-source use, with a
commercial license by request ([`COMMERCIAL-LICENSE.md`](COMMERCIAL-LICENSE.md)). Don't add
third-party dependencies under incompatible licenses.

## Status

**Phase 2 (the v1 critical path) is in progress.** Built: the pure `Curation` domain, the PhotoKit
seam (`PhotoLibraryProviding` + `System`/`Fake` impls), the integration test tier, dev tooling
(OSLog + screenshot harness), the state stores (`CurationProject`, `ProjectStore`, `SelectionStore`,
`DoneStore`), the **navigation coordinator** (#30), **onboarding + authorization** (#31), the
**albums library** (#32), **new-album setup + exclude-picker** (#33), the **scan surface** (#34),
the **review grid** (#35), the **photo viewer** (#36), the **cluster-index Overview** (#37),
**mark-as-done** (#38), and **album export + completion** (#39). `@main` launches the real
coordinator-driven `AppRootView` (onboarding → permission → albums → the built screens).

The **review grid is an accordion**: exactly one day-group cluster is open (its full grid) at a time
and every other is a collapsed peek; "done" is its own state (a green seal badge), decoupled from
collapse, set by a **"Mark as done" button at the end of an open cluster** that collapses it and
advances to the next unreviewed cluster (`DoneStore` + `Completion.reopening` reconcile). The
**Overview** is a **cluster index** (design 3BL): a per-day-cluster list + a coverage chart of
adaptive time buckets shaded gold by density. **Export** writes the picks into a native Photos album
(create-or-find + dupe-guard, one-way — D31) then shows the completion screen (`ExportStore` +
`ExportView`). Still open on the v1 path: **select-mode / drag-multi-select** (deferred from #35),
empty/error hardening (#40), **settings** (#41), **iPad** split-view (#42), **E2E** (#43).
The throwaway Phase-0 **Spike** was deleted (it seeded #35).
Phase/issue plan: [docs/plans/project-phases.md](docs/plans/project-phases.md).

## Repo map

```
Poimi.xcworkspace              open this in Xcode (app + package together)
App/
  PoimiApp.xcodeproj           hand-authored project (see "pbxproj" below)
  PoimiApp/
    Sources/                   @main PoimiApp (composition root)
    PhotoLibrary/              System/FakePhotoLibrary, PhotoLibraryProvider (DI seam)
    Persistence/               CurationProject @Model, AppSchema (SwiftData)
    State/                     ProjectStore, SelectionStore (@MainActor @Observable)
    Navigation/                Route, AppCoordinator, AppRootView (the adaptive spine, #30)
    Onboarding/                OnboardingView, AccessRecoveryView (first-run + auth, #31)
    Support/                   Log (OSLog), DebugScreen (screenshot harness)
    Resources/                 Assets.xcassets (AccentColor, BrandGreen, OnAccent, AppIcon)
  PoimiAppTests/               integration tier (Swift Testing, runs on a sim)
Curation/                      pure-domain SPM package — NO Photos/SwiftData/UIKit/SwiftUI
  Sources/Curation/            AssetRef, DayKey, DayGrouping, Completion, TargetProgress,
                               SelectionSnapshot, PhotoLibraryProviding, …
  Tests/CurationTests/         pure unit/property tests (headless: `swift test`)
Scripts/                       CI guards + the screenshot harness (see below)
docs/                          the durable record — plans + design
```

## Hard invariants (do not break)

These are enforced by CI guards and/or are load-bearing decisions. Breaking one should fail a
guard or a reviewer.

- **Domain boundary (D14/D21):** `Curation` is pure — it must **not** import Photos, PhotoKit, PhotosUI,
  SwiftData, UIKit, SwiftUI, AppKit, Combine, or CoreLocation, and must not use `@MainActor`.
  Dependencies point *toward* `Curation`. Guard: `Scripts/check-curation-boundary.sh`.
- **Pure Liquid Glass:** no SDK-version availability gates / `.regularMaterial` version
  fallbacks in app UI (iOS 26 is the floor, so glass is native). Accessibility fallbacks
  (Reduce Transparency) are exempt. Guard: `Scripts/check-liquid-glass.sh`.
- **Release isolation (D30):** `Fake*` doubles and the debug launch flags (`-PoimiUseFakeLibrary`,
  `-PoimiScreen`) are `#if DEBUG`-gated and absent from Release. Guard:
  `Scripts/check-fake-release-isolation.sh`.
- **Selection (D15):** the in-memory `Set<String>` in `SelectionStore` is the source of truth,
  mutated per tap; durability is a **debounced** snapshot — never a per-tap SwiftData write.
- **Identifiers:** bundle id + OSLog subsystem are `com.valtteriluoma.poimi` (tests:
  `com.valtteriluoma.poimiTests`). Never `fi.paretosoftware.*`. Match `~/personal/photo-export`.
- **Photos are sacrosanct:** we store only `localIdentifier`s, never photo bytes; deleting a
  project never touches the user's Photos album or originals (D31).

## Build / test / lint

```sh
# Pure domain — fast, headless, no simulator:
swift test --package-path Curation

# App + integration tier — needs an iOS 26 simulator (e.g. "iPhone 17 Pro"):
xcodebuild test -project App/PoimiApp.xcodeproj -scheme PoimiApp -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'   # any iOS 26 runtime

# Release build (proves DEBUG-only harness compiles out):
xcodebuild build -project App/PoimiApp.xcodeproj -scheme PoimiApp -configuration Release \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO

# Lint — warnings advisory, errors gate (not --strict yet, per D28); no unjustified disables:
swiftlint lint --quiet

# CI guards (all four must pass):
Scripts/check-curation-boundary.sh
Scripts/check-liquid-glass.sh
Scripts/check-fake-release-isolation.sh
Scripts/check-no-grouping-in-views.sh   # day-grouping stays in the store, never a View body
```

**Testing framework:** Swift Testing (`@Test`/`@Suite`/`#expect`/`#require`), not XCTest. The
`Curation` tier is unit/property tests; `PoimiAppTests` is the integration tier (stores +
`FakePhotoLibrary`). SwiftData test suites create an in-memory container per test; a store must
**retain its `ModelContainer`** (a `ModelContext` does not — a context-only store SIGTRAPs when
the container deallocates).

## Dev-loop tooling

- **Screenshots** (eyeball a screen against its Paper design): `./Scripts/screenshots.sh --list`,
  then `./Scripts/screenshots.sh <id>`. Boots a sim, builds, launches straight to a `DebugScreen`
  against the deterministic fake, captures `screenshots/<id>.png`. Deterministic, DEBUG-only.
- **Logs:** `os.Logger` under subsystem `com.valtteriluoma.poimi` at the impure seams. Retrieve
  with `xcrun simctl spawn booted log show --predicate 'subsystem == "com.valtteriluoma.poimi"'
  --last 2m --style compact` (`.notice`+; use `log stream --level debug` for `.info`/`.debug`).

Both are documented in the [README](README.md). Pixel-snapshot *testing* stays deferred (D26) —
the harness is for human/agent eyeballing, not assertions.

## CI gates (every PR, all green to merge)

Checkout → select Xcode 26 → SwiftLint → `Curation` tests → the 4 guards → Release build → app
build + integration tests on an iOS 26 sim. Defined in `.github/workflows/ci.yml`.

## Conventions

- **Branches:** always a named branch tracking the remote; never detached HEAD. One short-lived
  branch per issue → PR into `main`.
- **Issues are the unit of work.** Each PR links its issue. Docs (not issues) are the durable record.
- **Review rhythm:** substantive PRs get a **3-persona review** (Swift Architect, Senior Tester,
  Pragmatic Developer) via subagents before merge; add a Codex pass for algorithm-heavy PRs; skip
  the panel for trivial changes. Apply the findings, then merge.
- **SwiftUI-first** (design-language): use standard components everywhere they fit; build custom
  only where the product needs it (grid cell, zoom detail, tally chrome). No UIKit unless forced;
  Observation, not Combine.
- **Designs live in Paper; build screens from them.** The screen designs are in the Paper file
  (`paper-desktop` MCP) — see [docs/design/paper-index.md](docs/design/paper-index.md) for the map
  (node IDs + content + issue/build status). Read a screen's design before implementing it. **Keep
  the index current whenever you work with Paper:** add/rename/remove artboards, refresh content +
  build-status, and re-stamp the "Index created/updated" date on a meaningful change. Build the
  design's layout/interaction but keep **"album"** copy (the designs' "yearbook" wording is stale).
- **No heavy work in a `body`** (smoothness, ui-smoothness-review Finding 1): never run a sort,
  decode, grouping, or large allocation inside a SwiftUI `body` or a computed property read from
  `body` — a `body` re-evaluates on incidental state writes (e.g. a `.scrollPosition` anchor).
  Compute once in a store / `.task` / `@State` and pass finished values down.
- **Dependency-minimalism:** SPM only; a new third-party dependency needs explicit PR justification
  + a note in development-guidelines. An agent does not add libraries freely.
- **The `.xcodeproj` is hand-authored** (no XcodeGen/Tuist). Add files by editing `project.pbxproj`
  with the structured ID blocks (app=1, PhotoLibrary=3, tests=4, Support=5, Persistence=6,
  State=7, Navigation=8, Onboarding=9; Albums/Setup/Review use A0/B0/C0 ids; 2 retired with the
  Spike; next new group = 10); `plutil -lint` after, and
  `xcodebuild -list` to confirm it still reads. Keep diffs to
  the intended change — no Xcode reformatting churn.
- **Tests with fixes:** every bug fix ships with a failing-then-passing regression test.

## Documentation map

The durable record lives in `docs/`. Authoritative sources, in reading order:

- **[docs/plans/product-plan.md](docs/plans/product-plan.md)** — what we're building and why.
- **[docs/plans/architecture.md](docs/plans/architecture.md)** — the technical design (modules,
  data flow, PhotoKit actor, persistence, navigation, the album-library + mark-as-done subsystems).
- **[docs/plans/plan-review-decisions.md](docs/plans/plan-review-decisions.md)** — the **decisions
  log (D1–D38)**: the authoritative record of what was decided and why. Referenced everywhere as `D#`.
- **[docs/plans/project-phases.md](docs/plans/project-phases.md)** — the build sequence + GitHub
  issue tables + the design inventory + the timeline-grouping spec.
- **[docs/plans/development-guidelines.md](docs/plans/development-guidelines.md)** — testability,
  test tiers, tooling, CI, Definition of Done.
- **[docs/plans/preprocessing-and-caching.md](docs/plans/preprocessing-and-caching.md)** — what we
  cache (state, never bytes) and the v1.1 **location-preprocessing** subsystem (live clustering +
  the geocoded-name cache as the only network-bound thing worth persisting, the D18 pattern).
- **[docs/plans/localization.md](docs/plans/localization.md)** — the multi-locale plan (#95): a String
  Catalog foundation + Claude translating only deltas (manual at release first, CI later) + `fastlane`
  release notes/metadata, minimizing manual maintenance. **Deferred spec** — Phase 0 (catalog +
  localizable-by-default) now; the rest behind "v1 English stable." Open decisions at the end.
- **[docs/design/design-language.md](docs/design/design-language.md)** — the visual/interaction
  north star (Liquid Glass, SwiftUI-first, adaptive iPad).
- **[docs/design/styleguide.md](docs/design/styleguide.md)** — concrete tokens (color, type,
  spacing, materials, motion).
- **[docs/design/ui-spec.md](docs/design/ui-spec.md)** — per-screen UI spec (the review screen so
  far): anatomy, grid/header/selection/chrome, a11y, deferrals (spike-then-document, D27).
- **[docs/design/paper-index.md](docs/design/paper-index.md)** — index of the Paper design file: all
  33 artboards — 27 product screens + a 6-artboard v1.1 exploration cluster (node IDs, content,
  issue + build status). Keep current when working with Paper.
- **[docs/plans/spike-findings.md](docs/plans/spike-findings.md)** — the closed Phase-0 evidence
  (picking interaction, grouping, scale) that seeded Phase 1/2.
