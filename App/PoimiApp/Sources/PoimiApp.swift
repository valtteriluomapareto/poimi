//
//  PoimiApp.swift
//  PoimiApp
//
//  The SwiftUI app entry point + composition root. It launches the real coordinator-driven
//  `AppRootView` (onboarding → permission → albums → …, #30/#31). The Phase-0 throwaway spike
//  (`SpikeRootView`, under `Spike/`) is no longer the launch path; its `Render/*` views are the
//  reference for the real review grid (#35) and the spike is deleted when that lands.
//
//  This target owns the impure layers — PhotoKit, SwiftData, UI, navigation — and depends on the
//  pure `Curation` package. Dependencies point toward `Curation`, never away from it (D14/D21).

import OSLog
import SwiftData
import SwiftUI

@main
struct PoimiApp: App {
    // Composition root (#23/#29/#30): resolve the app's dependencies once at launch and inject
    // them into the environment. `AppRootView` + `AppCoordinator` drive the UI (onboarding →
    // permission → albums), reading `\.photoLibrary` and the stores — never PhotoKit/SwiftData
    // directly.
    private let photoLibrary = PhotoLibraryProvider.make()
    private let thumbnailProvider = ThumbnailProvider.make()
    private let modelContainer: ModelContainer
    @State private var projectStore: ProjectStore
    @State private var selectionStore: SelectionStore
    @State private var coordinator: AppCoordinator
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
        _coordinator = State(initialValue: AppCoordinator(library: photoLibrary))
        Log.app.notice("Poimi launched")
    }

    var body: some Scene {
        WindowGroup {
            rootView
                .environment(\.photoLibrary, photoLibrary)
                .environment(\.thumbnailProvider, thumbnailProvider)
                .environment(projectStore)
                .environment(selectionStore)
                .environment(coordinator)
                .onChange(of: scenePhase) { _, phase in
                    if phase != .active {
                        // Durability point (D15/§12): persist the live selection as soon as we
                        // stop being active. `.inactive` fires on the app-switcher gesture —
                        // before `.background` — so picks survive a force-quit, which delivers no
                        // `.background`. (A jetsam kill mid-foreground still loses the last
                        // `debounce` window; acceptable at v1.)
                        selectionStore.flushNow()
                    } else {
                        // Re-read authorization on resume (D6): the user may have changed it in
                        // Settings (the recovery deep-link path) while we were backgrounded.
                        Task { await coordinator.refreshAuthorization() }
                    }
                }
        }
        .modelContainer(modelContainer)
    }

    @ViewBuilder
    private var rootView: some View {
        #if DEBUG
        // Screenshot harness (#48): `-PoimiScreen <id>` boots straight to a catalog screen.
        // An unknown id fails loud (never a silent fallback that mis-captures the real root).
        if let id = DebugLaunch.screenArgument {
            if let screen = DebugLaunch.requestedScreen {
                DebugScreenHost(screen: screen)
            } else {
                DebugUnknownScreenView(id: id)
            }
        } else {
            AppRootView()
        }
        #else
        AppRootView()
        #endif
    }
}
