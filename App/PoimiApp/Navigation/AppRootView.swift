//
//  AppRootView.swift
//  PoimiApp — the adaptive navigation container (issue #30, D20; architecture §6/§11).
//
//  Binds the `AppCoordinator`: the root phase (onboarding/recovery/albums) is auth-driven, and
//  the albums phase is one logical `Route` path expressed in two containers — compact
//  `NavigationStack` (with the `.zoom` push for review→photo) and regular `NavigationSplitView`
//  whose detail column hosts its own stack so the zoom transition still applies.
//
//  The destination views here are **labeled stubs**: #30 builds the spine; the real screens
//  replace each stub (onboarding/recovery #31, albums #32, overview #37, review #35, photo #36,
//  export #39). The full iPad split-view polish is #42.
//

import SwiftUI
import Curation

struct AppRootView: View {
    @Environment(AppCoordinator.self) private var coordinator
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
    }

    // Compact (iPhone): one NavigationStack rooted at the album library.
    private var stack: some View {
        @Bindable var coordinator = coordinator
        return NavigationStack(path: $coordinator.path) {
            AlbumsRootStub()
                .navigationDestination(for: Route.self, destination: destination)
        }
    }

    // Regular (iPad): sidebar = the library; detail column hosts its own path stack (#42 polishes).
    private var splitView: some View {
        @Bindable var coordinator = coordinator
        return NavigationSplitView {
            AlbumsRootStub()
        } detail: {
            NavigationStack(path: $coordinator.path) {
                RoutePlaceholder(symbol: "sidebar.right", title: "Select an album",
                                 detail: "Detail column — overview / review (#37/#35)")
                    .navigationDestination(for: Route.self, destination: destination)
            }
        }
    }

    @ViewBuilder
    private func destination(for route: Route) -> some View {
        switch route {
        case .albumOverview(let id):
            RoutePlaceholder(symbol: "square.grid.2x2", title: "Overview",
                             detail: "album \(id.uuidString.prefix(8)) (#37)")
        case .review(let id, let day):
            RoutePlaceholder(symbol: "photo.on.rectangle.angled", title: "Review grid",
                             detail: "album \(id.uuidString.prefix(8))\(day.map { " · \($0)" } ?? "") (#35)")
        case .photo(let assetID):
            RoutePlaceholder(symbol: "photo", title: "Photo", detail: "\(assetID) (#36)")
        case .export(let id):
            RoutePlaceholder(symbol: "rectangle.stack.badge.plus", title: "Export",
                             detail: "album \(id.uuidString.prefix(8)) (#39)")
        }
    }
}

/// The albums-library root stub (#32 replaces it). Routes are pushed by the coordinator.
private struct AlbumsRootStub: View {
    var body: some View {
        RoutePlaceholder(symbol: "photo.stack", title: "Albums", detail: "The album library (#32)")
            .navigationTitle("Albums")
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
