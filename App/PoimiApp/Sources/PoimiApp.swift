//
//  PoimiApp.swift
//  PoimiApp
//
//  The SwiftUI app entry point. Bootstrap skeleton only (GitHub issue #3): a single
//  `@main` App showing a placeholder. Navigation, the permission flow, and the
//  review loop arrive in later phases (see docs/plans/project-phases.md).
//
//  This target owns the impure layers — PhotoKit, SwiftData, UI, navigation — and
//  depends on the pure `Curation` package. Dependencies point toward `Curation`,
//  never away from it (D14/D21).

import SwiftUI

@main
struct PoimiApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
