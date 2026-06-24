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
import SwiftData
import SwiftUI

@main
struct PoimiApp: App {
    // Composition root (#23/#29): resolve the app's dependencies once at launch and inject them
    // into the environment. The Spike still drives the UI in Phase 0/1; Phase 2's coordinator
    // reads `\.photoLibrary` and the stores instead of touching PhotoKit / SwiftData directly.
    private let photoLibrary = PhotoLibraryProvider.make()
    private let modelContainer: ModelContainer
    @State private var projectStore: ProjectStore
    @State private var selectionStore: SelectionStore
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let container: ModelContainer
        do {
            container = try AppModelContainer.make()
        } catch {
            // The data store is unrecoverable at launch — there is no sensible degraded mode.
            Log.app.fault("Failed to open the data store: \(String(describing: error), privacy: .public)")
            fatalError("Poimi could not open its data store: \(error)")
        }
        modelContainer = container
        _projectStore = State(initialValue: ProjectStore(container: container))
        _selectionStore = State(initialValue: SelectionStore(container: container))
        Log.app.notice("Poimi launched")
    }

    var body: some Scene {
        WindowGroup {
            rootView
                .environment(\.photoLibrary, photoLibrary)
                .environment(projectStore)
                .environment(selectionStore)
                .onChange(of: scenePhase) { _, phase in
                    // Durability point (D15/§12): persist the live selection when we background.
                    if phase == .background { selectionStore.flushNow() }
                }
        }
        .modelContainer(modelContainer)
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
