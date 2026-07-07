//
//  PoimiApp.swift
//  PoimiApp
//
//  The SwiftUI app entry point + composition root. It launches the real coordinator-driven
//  `AppRootView` (onboarding → permission → albums → …, #30/#31). (The Phase-0 throwaway spike that
//  seeded the review grid, #35, has since been deleted.)
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
    /// The reverse-geocoding seam (#130): the real `CLGeocoder` on device, the deterministic fake only
    /// under `-PoimiUseFakeLibrary`. MUST be injected here — the environment's DEBUG default is the fake,
    /// so a missing injection silently shows synthetic "Place <lat>,<lon>" names instead of real places.
    private let placeNaming = PlaceNamingProvider.make()
    private let modelContainer: ModelContainer
    @State private var projectStore: ProjectStore
    @State private var selectionStore: SelectionStore
    @State private var doneStore: DoneStore
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
        _doneStore = State(initialValue: DoneStore(container: container))
        _coordinator = State(initialValue: AppCoordinator(library: photoLibrary))
        Log.app.notice("Poimi launched")
    }

    var body: some Scene {
        WindowGroup {
            rootView
                .environment(\.photoLibrary, photoLibrary)
                .environment(\.thumbnailProvider, thumbnailProvider)
                .environment(\.placeNaming, placeNaming)
                .environment(projectStore)
                .environment(selectionStore)
                .environment(doneStore)
                .environment(coordinator)
                .onChange(of: scenePhase) { _, phase in
                    if phase != .active {
                        // Durability point (D15/§12): persist the live selection as soon as we
                        // stop being active. `.inactive` fires on the app-switcher gesture —
                        // before `.background` — so picks survive a force-quit, which delivers no
                        // `.background`. (A jetsam kill mid-foreground still loses the last
                        // `debounce` window; acceptable at v1.)
                        selectionStore.flushNow()
                        doneStore.flushNow()
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
