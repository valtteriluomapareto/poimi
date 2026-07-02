//
//  AppRootView.swift
//  PoimiApp — the adaptive navigation container (issue #30, D20; architecture §6/§11).
//
//  Binds the `AppCoordinator`: the root phase (onboarding/recovery/albums) is auth-driven, and
//  the albums phase is one logical `Route` path expressed in two containers — compact
//  `NavigationStack` and regular `NavigationSplitView` whose detail column hosts its own stack. The
//  photo viewer is a `.sheet` (a Now-Playing-style modal card, pull-down to dismiss) over this, not a route.
//
//  The destination views here are **labeled stubs**: #30 builds the spine; the real screens
//  replace each stub (onboarding/recovery #31, albums #32, overview #37, review #35, photo #36,
//  export #39). The full iPad split-view polish is #42.
//

import SwiftUI
import Curation

struct AppRootView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(ProjectStore.self) private var projectStore
    @Environment(\.horizontalSizeClass) private var sizeClass
    var body: some View {
        Group {
            switch coordinator.rootPhase {
            case .onboarding:
                OnboardingView()
            case .recovery:
                AccessRecoveryView(authorization: coordinator.authorization)
            case .albums:
                // Test compact positively so an unknown/`nil` size class (iPad mid-scene-setup)
                // defaults to the regular split layout, not the iPhone stack. Mid-flip reflow
                // polish (push/scroll state across a size-class change) is #42.
                if sizeClass == .compact { stack } else { splitView }
            }
        }
        // The cold-launch authorization read (D6): `.onChange(of: scenePhase)` doesn't fire for
        // the initial `.active`, so this `.task` is the launch read; @main's scenePhase handler
        // covers the resume re-read (the Settings round-trip).
        .task { await coordinator.refreshAuthorization() }
        // The photo viewer (#36) is a MODAL SHEET (a Now-Playing-style card) — it rises from the bottom
        // and you pull it down to dismiss (grabber + interactive drag, owned by the sheet). Never the
        // sideways nav-pop a path push animates. The grid stays mounted beneath, exactly where you left
        // it. Presented content inherits the environment (like AlbumsView's sheet).
        .sheet(isPresented: Binding(
            get: { coordinator.presentedPhotoID != nil },
            set: { if !$0 { coordinator.dismissPhoto() } }   // one dismiss path → keeps the Perf span closed
        )) {
            if let id = coordinator.presentedPhotoID {
                PhotoViewerView(startID: id)
            }
        }
    }

    // Compact (iPhone): one NavigationStack rooted at the album library.
    private var stack: some View {
        @Bindable var coordinator = coordinator
        return NavigationStack(path: $coordinator.path) {
            AlbumsView()
                .navigationDestination(for: Route.self, destination: destination)
        }
    }

    // Regular (iPad): sidebar = the library; detail column hosts its own path stack (#42 polishes).
    private var splitView: some View {
        @Bindable var coordinator = coordinator
        return NavigationSplitView {
            AlbumsView()
        } detail: {
            NavigationStack(path: $coordinator.path) {
                RoutePlaceholder(symbol: "sidebar.right", title: "Select an album",
                                 detail: "Detail column — overview / review (#37/#35)")
                    .navigationDestination(for: Route.self, destination: destination)
            }
        }
    }

    /// Resolve a route's project id against the library. A `nil` (e.g. a stale path after the
    /// project was deleted) routes to a labeled placeholder rather than crashing.
    private func project(_ id: UUID) -> CurationProject? {
        projectStore.projects.first { $0.id == id }
    }

    @ViewBuilder
    private func destination(for route: Route) -> some View {
        switch route {
        case .albumOverview(let id):
            if let project = project(id) {
                AlbumOverviewView(project: project)
            } else {
                RoutePlaceholder(symbol: "questionmark.folder", title: "Album not found",
                                 detail: "This album is no longer in your library.")
            }
        case .review(let id, let day):
            if let project = project(id) {
                ScanningView(project: project, scrollToDay: day)   // scanning → grid (#34/#35), #37 drill

            } else {
                RoutePlaceholder(symbol: "questionmark.folder", title: "Album not found",
                                 detail: "This album is no longer in your library.")
            }
        case .export(let id):
            if let project = project(id) {
                ExportView(project: project)   // export + completion (#39)
            } else {
                RoutePlaceholder(symbol: "questionmark.folder", title: "Album not found",
                                 detail: "This album is no longer in your library.")
            }
        case .settings(let id):
            if let project = project(id) {
                AlbumSettingsView(project: project)   // edit / reset / delete (#41)
            } else {
                RoutePlaceholder(symbol: "questionmark.folder", title: "Album not found",
                                 detail: "This album is no longer in your library.")
            }
        }
    }
}

/// A clearly-labeled placeholder for a not-yet-built screen — names the screen and its issue so a
/// screenshot of the shell is self-documenting, never mistaken for a finished screen.
struct RoutePlaceholder: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(detail)
        }
    }
}
