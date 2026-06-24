//
//  PoimiApp.swift
//  PoimiApp
//
//  The SwiftUI app entry point. During Phase 0 it hosts the THROWAWAY spike
//  harness (`SpikeRootView`, under `Spike/`) that de-risks the make-or-break
//  review loop on a real library (GitHub issue #4 Part A / D1). The real
//  navigation coordinator, onboarding, and permission flow replace this in
//  Phase 2 (see docs/plans/project-phases.md); the spike is then deleted while
//  the `Spike/Render/*` views are promoted behind the protocol seam.
//
//  This target owns the impure layers — PhotoKit, SwiftData, UI, navigation — and
//  depends on the pure `Curation` package. Dependencies point toward `Curation`,
//  never away from it (D14/D21).

import OSLog
import SwiftUI

@main
struct PoimiApp: App {
    // Composition root (#23): resolve the photo-library dependency once at launch and inject
    // it into the environment. The Spike still drives the UI in Phase 0/1; Phase 2's
    // coordinator reads `\.photoLibrary` instead of touching PhotoKit directly.
    private let photoLibrary = PhotoLibraryProvider.make()

    init() {
        // The composition root logs which concrete library it resolved; this is just the
        // launch marker. (The `notice` literal escapes into an autoclosure, so keep it
        // capture-free — no `self`.)
        Log.app.notice("Poimi launched")
    }

    var body: some Scene {
        WindowGroup {
            rootView
                .environment(\.photoLibrary, photoLibrary)
        }
    }

    @ViewBuilder
    private var rootView: some View {
        #if DEBUG
        // Screenshot harness (#48): `-PoimiScreen <id>` boots straight to a catalog screen.
        // An unknown id fails loud (never a silent fallback that mis-captures the spike root).
        if let id = DebugLaunch.screenArgument {
            if let screen = DebugLaunch.requestedScreen {
                DebugScreenHost(screen: screen)
            } else {
                DebugUnknownScreenView(id: id)
            }
        } else {
            SpikeRootView()
        }
        #else
        SpikeRootView()
        #endif
    }
}
