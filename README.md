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
