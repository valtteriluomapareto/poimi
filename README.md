# Poimi

Album Curator — hand-pick photos into an album. iOS 26 / iPadOS 26, SwiftUI.

This is the **repo bootstrap** (Phase 0, issue #3): a runnable, empty app skeleton
with the domain module seam in place. No features yet — see
[`docs/plans/project-phases.md`](docs/plans/project-phases.md) for what lands when.

## Layout

```
.
├── Poimi.xcworkspace          # open this in Xcode (app + package together)
├── App/
│   ├── PoimiApp.xcodeproj      # the iOS app target (hand-authored project spec)
│   └── PoimiApp/
│       ├── Sources/            # @main App + placeholder ContentView
│       └── Resources/          # Assets.xcassets (AppIcon, AccentColor)
├── Curation/                   # local Swift package — pure domain (no Photos/SwiftData)
│   ├── Package.swift
│   ├── Sources/Curation/       # CurationPlaceholder stub
│   └── Tests/CurationTests/    # Swift Testing
├── Scripts/
│   └── check-curation-boundary.sh   # enforces the domain-boundary invariant
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
`project.pbxproj` (stable sequential IDs, e.g. the `…A301` PhotoKit block, the `…0041`
test target), and **avoid committing Xcode's incidental reformatting churn** — keep the
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
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.2' \
  build CODE_SIGNING_ALLOWED=NO
```

For a **physical device**, open the workspace, pick the `PoimiApp` target, and set a
development team under *Signing & Capabilities* (the bundle id is
`fi.paretosoftware.poimi`); automatic signing is enabled.

## Test the domain package

The pure `Curation` package runs headlessly — no simulator required:

```sh
cd Curation && swift test
```

## Check the domain boundary

Verifies the invariant that `Curation` imports neither Photos nor SwiftData (nor other
platform/UI frameworks) and uses no main-actor isolation:

```sh
./Scripts/check-curation-boundary.sh
```

(This is the precursor to the build-time/CI check formalized in Phase 1, per the
project-phases exit criteria.)

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

The app logs at its impure seams via `os.Logger` under the `fi.paretosoftware.poimi`
subsystem (see `App/PoimiApp/Support/Log.swift`). Pull a run's `.notice`+ logs (composition
root, launch, fetch counts) off a booted simulator after the fact:

```sh
xcrun simctl spawn booted log show \
  --predicate 'subsystem == "fi.paretosoftware.poimi"' \
  --last 2m --style compact
```

`.info` and `.debug` messages are **not** persisted to the log store by default, so `log show`
won't surface them retroactively — stream live to see everything (start this, *then* launch):

```sh
xcrun simctl spawn booted log stream \
  --predicate 'subsystem == "fi.paretosoftware.poimi"' \
  --level debug --style compact
```

Narrow to one area with `category == "PhotoLibrary"` (or `App`). Logging lives in the app
target only — the pure `Curation` package stays side-effect-free.
