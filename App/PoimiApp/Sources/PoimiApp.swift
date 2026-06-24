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
        // Hoist out of the log autoclosure: it escapes, and capturing `self` mid-init is illegal.
        let libraryType = String(describing: type(of: photoLibrary))
        Log.app.notice("Poimi launched (library: \(libraryType, privacy: .public))")
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
        if let screen = DebugLaunch.requestedScreen {
            DebugScreenHost(screen: screen)
        } else {
            SpikeRootView()
        }
        #else
        SpikeRootView()
        #endif
    }
}
