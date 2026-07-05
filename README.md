# Poimi

Hand-pick a year of photos into an album — *you choose every photo, not an algorithm.*
iOS 26 / iPadOS 26, SwiftUI. The output is a native Apple Photos album.

**Status: Phase 2 (the v1 critical path) is in progress** — the pure domain, the PhotoKit
seam, the test tier, dev tooling, the persisted state foundation, the navigation coordinator,
and the onboarding/authorization flow are in. The app now launches the real flow (onboarding →
permission → albums); the remaining screens (albums list, review grid, …) are landing on top.
See
[`docs/plans/project-phases.md`](docs/plans/project-phases.md) for the build sequence and
[`CLAUDE.md`](CLAUDE.md) for an agent/contributor orientation.

## Layout

```
.
├── Poimi.xcworkspace          # open this in Xcode (app + package together)
├── CLAUDE.md                  # start-here orientation for agents + contributors
├── App/
│   ├── PoimiApp.xcodeproj      # the iOS app target (hand-authored project spec)
│   ├── PoimiApp/
│   │   ├── Sources/            # @main PoimiApp (composition root)
│   │   ├── PhotoLibrary/       # System/FakePhotoLibrary + the DI seam
│   │   ├── Persistence/        # CurationProject @Model + SwiftData schema
│   │   ├── State/              # ProjectStore / SelectionStore (@Observable)
│   │   ├── Navigation/         # Route, AppCoordinator, AppRootView (the adaptive spine)
│   │   ├── Onboarding/         # OnboardingView, AccessRecoveryView (first-run + auth)
│   │   ├── Support/            # Log (OSLog) + DebugScreen (screenshot harness)
│   │   ├── Spike/              # THROWAWAY Phase-0 spike (no longer launched; deleted at #35)
│   │   └── Resources/          # Assets.xcassets (AppIcon, AccentColor, BrandGreen, OnAccent)
│   └── PoimiAppTests/          # integration tier (Swift Testing, runs on a sim)
├── Curation/                   # local Swift package — pure domain (no Photos/SwiftData)
│   ├── Package.swift
│   ├── Sources/Curation/       # AssetRef, DayKey/DayGrouping, target math, …
│   └── Tests/CurationTests/    # pure unit/property tests (Swift Testing)
├── Scripts/                    # CI guards + the screenshot harness
│   ├── check-curation-boundary.sh       # the domain-boundary invariant (D14/D21)
│   ├── check-liquid-glass.sh            # the pure-Liquid-Glass invariant
│   ├── check-fake-release-isolation.sh  # the release-isolation invariant (D30)
│   └── screenshots.sh                   # deterministic screen captures
└── docs/                       # plans + design (the durable record)
```

**Dependency direction (D14/D21):** the app target depends on `Curation`; `Curation`
depends on nothing platform-specific. Dependencies point *toward* the domain. The
`Curation` package must not import Photos, PhotoKit, SwiftData, UIKit, or SwiftUI, and
must not use main-actor isolation — that is what keeps it unit-testable without a
simulator or a real photo library.

## Tooling choice

XcodeGen and Tuist are **not installed** in this environment, so the project is a
**hand-authored `.xcodeproj` committed to the repo** (the most reproducible option
available without adding a tool). The local `Curation` package is referenced from the
project as an `XCLocalSwiftPackageReference` at `../Curation`. If XcodeGen/Tuist is
adopted later, the spec can be regenerated; until then the committed `.xcodeproj` *is*
the spec.

Because it's hand-maintained: new files/targets are added by hand-editing
`project.pbxproj` using the structured ID blocks documented in [CLAUDE.md](CLAUDE.md) →
Conventions, and **avoid committing Xcode's incidental reformatting churn** — keep the
diff to the intended change so the file stays reviewable. If targets grow past a handful,
adopt a generator.

## Requirements

- **Xcode 26.x** with the **iOS 26 SDK** and an **iOS 26 simulator runtime** installed.
- Swift 6 toolchain (ships with Xcode 26). Both the package and the app build in
  **Swift 6 language mode with strict (`complete`) concurrency**.

## Build & run the app

Open the workspace in Xcode and run:

```sh
open Poimi.xcworkspace
# select the PoimiApp scheme + an iOS 26 simulator (e.g. iPhone 17), then ⌘R
```

Or from the command line (no signing needed for the simulator):

```sh
xcodebuild \
  -project App/PoimiApp.xcodeproj \
  -scheme PoimiApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  build CODE_SIGNING_ALLOWED=NO
```

For a **physical device**, open the workspace, pick the `PoimiApp` target, and set a
development team under *Signing & Capabilities* (the bundle id is
`com.valtteriluoma.poimi`); automatic signing is enabled.

## Test

The pure `Curation` package runs headlessly — no simulator required:

```sh
swift test --package-path Curation
```

The app's integration tier (stores + the deterministic `FakePhotoLibrary`) runs on an iOS 26
simulator via Swift Testing:

```sh
xcodebuild test -project App/PoimiApp.xcodeproj -scheme PoimiApp -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'   # any iOS 26 simulator
```

## CI guards

Three language-level invariants are enforced on every PR (and runnable locally). They fail
the build if violated:

```sh
./Scripts/check-curation-boundary.sh        # Curation imports no Photos/SwiftData/UI (D14/D21)
./Scripts/check-liquid-glass.sh             # no SDK-version gates / material fallbacks (pure glass)
./Scripts/check-fake-release-isolation.sh   # fakes + debug flags are absent from Release (D30)
```

The full pipeline (lint → `Curation` tests → guards → Release build → app tests on an iOS 26
sim) is in [`.github/workflows/ci.yml`](.github/workflows/ci.yml).

## TestFlight deploy (fastlane)

A separate, **manually-triggered** workflow builds a signed Release and uploads it to
TestFlight — no local Mac needed. It is `workflow_dispatch`-only (never on a PR or push) and
runs behind a protected `testflight` GitHub Environment. The lanes live in
[`fastlane/Fastfile`](fastlane/Fastfile) (`beta` = build + upload + poll for App Store Connect
`VALID`; `build_only` = archive + sign an `.ipa`, no upload); the workflow is
[`.github/workflows/testflight.yml`](.github/workflows/testflight.yml), whose header comments are
the runbook (one-time Apple/ASC setup + the required `testflight` Environment secrets). Ruby
tooling is pinned via [`Gemfile`](Gemfile) + `Gemfile.lock` (`bundle install` in frozen mode).
Signing uses `match (appstore)` in read-only mode; the App Store Connect API key is auth only.

## Screenshots (eyeball a screen against its design)

`Scripts/screenshots.sh` boots an iOS 26 simulator, builds + installs the app, and launches
it straight to a named screen against the deterministic `FakePhotoLibrary` — then captures a
PNG. No tapping, reproducible run-to-run:

```sh
./Scripts/screenshots.sh                # every screen in the catalog
./Scripts/screenshots.sh library        # only the named screens (validated against the catalog)
./Scripts/screenshots.sh --list         # print the catalog screen ids and exit (no sim)
SIM_NAME="iPhone 17 Pro" ./Scripts/screenshots.sh
FRESH=1 ./Scripts/screenshots.sh        # clean boot first (clears a stuck system alert)
READY_TIMEOUT=30 ./Scripts/screenshots.sh   # wait longer for the ready signal on slow machines
```

Output lands in `screenshots/<id>.png` (git-ignored). The catalog of screens is the
`DebugScreen` enum in `App/PoimiApp/Support/DebugScreen.swift` — each `case` is a
`-PoimiScreen <id>` launch target; new screens register a case as they land (and must render
against the injected `\.photoLibrary` fake, never real PhotoKit, to stay deterministic). A
mistyped id fails loud — the script validates against the catalog, and the app shows a red
"unknown screen" page rather than silently capturing the wrong screen. Each screen logs
`screenshot-ready: <id>` once its content is on screen, and the script waits for that signal
before snapshotting (no blind sleep). This is the screenshot *harness* (eyeball against the
Paper designs), distinct from pixel-snapshot *testing*, which stays deferred (D26). Everything
it drives is `#if DEBUG` and absent from Release (D30).

## Debugging (logs)

The app logs at its impure seams via `os.Logger` under the `com.valtteriluoma.poimi`
subsystem (see `App/PoimiApp/Support/Log.swift`). Pull a run's `.notice`+ logs (composition
root, launch, fetch counts) off a booted simulator after the fact:

```sh
xcrun simctl spawn booted log show \
  --predicate 'subsystem == "com.valtteriluoma.poimi"' \
  --last 2m --style compact
```

`.info` and `.debug` messages are **not** persisted to the log store by default, so `log show`
won't surface them retroactively — stream live to see everything (start this, *then* launch):

```sh
xcrun simctl spawn booted log stream \
  --predicate 'subsystem == "com.valtteriluoma.poimi"' \
  --level debug --style compact
```

Narrow to one area with `category == "PhotoLibrary"` (or `App`). Logging lives in the app
target only — the pure `Curation` package stays side-effect-free.

## License

Poimi is **dual-licensed** (© 2026 Valtteri Luoma):

- **Open source — [AGPL-3.0](LICENSE).** Free to use, study, modify, and share. Copyleft:
  if you distribute Poimi or a derivative, or run a modified version as a network service,
  you must release the complete corresponding source under AGPL-3.0 too.
- **Commercial — by request.** To use Poimi without the AGPL obligations (e.g. in a
  closed-source product), get a commercial license — see
  [`COMMERCIAL-LICENSE.md`](COMMERCIAL-LICENSE.md).
