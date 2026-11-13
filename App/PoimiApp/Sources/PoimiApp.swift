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
    // Composition root (#23/#29/#30): the app's dependencies, wired once at launch by `AppGraph` and
    // injected into the environment. `AppRootView` + `AppCoordinator` drive the UI (onboarding →
    // permission → albums), reading `\.photoLibrary` and the stores — never PhotoKit/SwiftData
    // directly. Held in `@State` so the graph survives every `App` re-evaluation.
    @State private var graph: AppGraph
    @Environment(\.scenePhase) private var scenePhase

    init() {
        #if DEBUG
        // Control plane (#296): `-PoimiControl` swaps in an isolated, fixture-seeded graph (fake
        // library, in-memory store, its own defaults). All of it lives in `Control/`, DEBUG-only (D30).
        if let control = ControlLaunch.bootGraph() {
            _graph = State(initialValue: control)
            Log.app.notice("Poimi launched")
            return
        }
        #endif
        _graph = State(initialValue: .production())
        Log.app.notice("Poimi launched")
    }

    var body: some Scene {
        WindowGroup {
            rootView
                .environment(graph: graph)
                // The cold-launch authorization read (D6): `.onChange(of: scenePhase)` doesn't fire for
                // the initial `.active`, so this is the launch read; the handler below covers the resume
                // re-read (the Settings round-trip). A control launch's runtime starts its graph itself.
                .task { if !isControlLaunch { await graph.start() } }
                .onChange(of: scenePhase) { _, phase in
                    if phase != .active {
                        // Durability point (D15/§12): persist the live selection as soon as we
                        // stop being active. `.inactive` fires on the app-switcher gesture —
                        // before `.background` — so picks survive a force-quit, which delivers no
                        // `.background`. (A jetsam kill mid-foreground still loses the last
                        // `debounce` window; acceptable at v1.)
                        graph.selectionStore.flushNow()
                        graph.doneStore.flushNow()
                    } else {
                        // Re-read authorization on resume (D6): the user may have changed it in
                        // Settings (the recovery deep-link path) while we were backgrounded.
                        Task { await graph.coordinator.refreshAuthorization() }
                    }
                }
        }
        .modelContainer(graph.modelContainer)
    }

    /// Whether the control plane runs this launch (it starts the graph from its own bootstrap).
    private var isControlLaunch: Bool {
        #if DEBUG
        ControlLaunch.isActive
        #else
        false
        #endif
    }

    @ViewBuilder
    private var rootView: some View {
        #if DEBUG
        // A refused control launch (malformed `-PoimiControl` flags) runs isolated and says why; a
        // headless one (`-PoimiHeadless`, #298) runs the graph + album session behind a static view.
        // Screenshot harness (#48): `-PoimiScreen <id>` boots straight to a catalog screen.
        // An unknown id fails loud (never a silent fallback that mis-captures the real root).
        if let refusal = ControlLaunch.refusal {
            ControlRefusedView(message: refusal)
        } else if let headless = ControlLaunch.headlessRun {
            ControlHeadlessView(run: headless)
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
