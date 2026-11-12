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
import Curation

@main
struct PoimiApp: App {
    // Composition root (#23/#29/#30): resolve the app's dependencies once at launch and inject
    // them into the environment. `AppRootView` + `AppCoordinator` drive the UI (onboarding →
    // permission → albums), reading `\.photoLibrary` and the stores — never PhotoKit/SwiftData
    // directly.
    private let photoLibrary: any PhotoLibraryProviding
    private let thumbnailProvider: any ThumbnailProviding
    /// The reverse-geocoding seam (#130): the real `CLGeocoder` on device, the deterministic fake only
    /// under `-PoimiUseFakeLibrary`. MUST be injected here — the environment's DEBUG default is the fake,
    /// so a missing injection silently shows synthetic "Place <lat>,<lon>" names instead of real places.
    private let placeNaming: any PlaceNaming
    private let modelContainer: ModelContainer
    @State private var projectStore: ProjectStore
    @State private var selectionStore: SelectionStore
    @State private var doneStore: DoneStore
    @State private var coordinator: AppCoordinator
    @State private var whatsNewState: WhatsNewState
    @State private var appReviewPrompt: AppReviewPrompt
    @Environment(\.scenePhase) private var scenePhase

    init() {
        #if DEBUG
        // Control plane (#296): `-PoimiControl` swaps in an isolated, fixture-seeded graph (fake
        // library, in-memory store, its own defaults). All of it lives in `Control/`, DEBUG-only (D30).
        if let control = ControlLaunch.bootGraph() {
            self.init(graph: control)
            return
        }
        #endif
        self.init(graph: .production())
    }

    private init(graph: AppGraph) {
        photoLibrary = graph.photoLibrary
        thumbnailProvider = graph.thumbnailProvider
        placeNaming = graph.placeNaming
        modelContainer = graph.modelContainer
        _projectStore = State(initialValue: graph.projectStore)
        _selectionStore = State(initialValue: graph.selectionStore)
        _doneStore = State(initialValue: graph.doneStore)
        _coordinator = State(initialValue: graph.coordinator)
        _whatsNewState = State(initialValue: graph.whatsNewState)
        _appReviewPrompt = State(initialValue: graph.appReviewPrompt)
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
                .environment(whatsNewState)
                .environment(appReviewPrompt)
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
        // A refused control launch (malformed `-PoimiControl` flags) runs isolated and says why.
        // Screenshot harness (#48): `-PoimiScreen <id>` boots straight to a catalog screen.
        // An unknown id fails loud (never a silent fallback that mis-captures the real root).
        if let refusal = ControlLaunch.refusal {
            ControlRefusedView(message: refusal)
        } else if let id = DebugLaunch.screenArgument {
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

/// The app's object graph, built once at launch. `production()` is the real wiring; a DEBUG control
/// launch (#296) builds an isolated graph of the same shape (`ControlRuntime`).
@MainActor
struct AppGraph {
    let photoLibrary: any PhotoLibraryProviding
    let thumbnailProvider: any ThumbnailProviding
    let placeNaming: any PlaceNaming
    let modelContainer: ModelContainer
    let projectStore: ProjectStore
    let selectionStore: SelectionStore
    let doneStore: DoneStore
    let coordinator: AppCoordinator
    let whatsNewState: WhatsNewState
    let appReviewPrompt: AppReviewPrompt

    static func production() -> AppGraph {
        let container: ModelContainer
        do {
            container = try AppModelContainer.make()
        } catch {
            // The data store is unrecoverable at launch — there is no sensible degraded mode.
            Log.app.fault("Failed to open the data store: \(String(describing: error), privacy: .public)")
            fatalError("Poimi could not open its data store: \(error)")
        }
        let photoLibrary = PhotoLibraryProvider.make()
        // One shared timeline cache (#130): the review screens read/write it through the coordinator,
        // and `ProjectStore` uses the SAME instance to drop an album's cached file on delete.
        let timelineCache = TimelineCache()
        return AppGraph(
            photoLibrary: photoLibrary,
            thumbnailProvider: ThumbnailProvider.make(),
            placeNaming: PlaceNamingProvider.make(),
            modelContainer: container,
            projectStore: ProjectStore(container: container, timelineCache: timelineCache),
            selectionStore: SelectionStore(container: container),
            doneStore: DoneStore(container: container),
            coordinator: AppCoordinator(library: photoLibrary, timelineCache: timelineCache),
            // What's New (#248): reads the current CFBundleShortVersionString + the last-seen version from
            // UserDefaults and decides whether to present on this launch. Owned once at the root (above the
            // layout swap) so it survives the iPad size-class re-init and its silent-mark persist is
            // lifecycle-free.
            whatsNewState: WhatsNewState(),
            // App Store review prompt (#269): reads the current app version + the last-prompted version from
            // UserDefaults and gates the ask to once per version. Owned at the root (like whatsNewState) so
            // it survives the iPad size-class re-init; the actual requestReview() fires from ExportView on a
            // successful export.
            appReviewPrompt: AppReviewPrompt())
    }
}
