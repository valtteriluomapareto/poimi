//
//  AppGraph.swift
//  PoimiApp — the app's object graph, wired in ONE place (#296; docs/plans/control-plane.md).
//
//  `make(…)` is the single wiring of stores, coordinator and caches. The composition root uses it via
//  `production()`; the DEBUG control launch and the integration tests use it with their own
//  dependencies (fake library, in-memory container, isolated defaults). Hosts therefore can't wire the
//  graph differently from each other. Slice B of the control plane adds the album session here.
//

import Foundation
import SwiftData
import SwiftUI
import Curation

@MainActor
struct AppGraph {
    let photoLibrary: any PhotoLibraryProviding
    let thumbnailProvider: any ThumbnailProviding
    let placeNaming: any PlaceNaming
    let modelContainer: ModelContainer
    /// The shared per-album review-timeline cache (#130): the album session builds every
    /// `CandidateStore` with it, and `ProjectStore` drops an album's file on delete.
    let timelineCache: TimelineCache
    /// The persistent geocoded-name cache (D18) over `modelContainer`.
    let nameCache: NameCacheStore
    /// The calendar the timeline buckets by — the album session builds every `CandidateStore` with it.
    let calendar: Calendar
    let projectStore: ProjectStore
    let selectionStore: SelectionStore
    let doneStore: DoneStore
    let coordinator: AppCoordinator
    /// The open album's scan, review context and export (#297) — no view has to be mounted for it.
    let session: AlbumSession
    /// Open / create / delete / reset / edit, sequenced once (#297).
    let actions: AlbumActions
    let whatsNewState: WhatsNewState
    let appReviewPrompt: AppReviewPrompt

    /// Wire the graph from its dependencies. `debounce` is the selection/done durability window (D15),
    /// `defaults` backs What's New + the review-prompt gate, `now` is the album-library clock.
    static func make(
        container: ModelContainer,
        library: any PhotoLibraryProviding,
        thumbnails: any ThumbnailProviding,
        naming: any PlaceNaming,
        timelineCache: TimelineCache,
        debounce: Duration = .seconds(2),
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init,
        calendar: Calendar = .current
    ) -> AppGraph {
        let nameCache = NameCacheStore(modelContainer: container)
        let projects = ProjectStore(container: container, timelineCache: timelineCache, now: now)
        let selection = SelectionStore(container: container, debounce: debounce)
        let done = DoneStore(container: container, debounce: debounce)
        let coordinator = AppCoordinator(library: library)
        let session = AlbumSession(library: library, naming: naming, nameCache: nameCache,
                                   timelineCache: timelineCache, calendar: calendar,
                                   selection: selection, done: done)
        // Navigation decides when the album changes; the session drops what it held for it.
        coordinator.onCloseAlbum = { [weak session] in session?.close() }
        coordinator.onLeaveExport = { [weak session] in session?.exportScreenClosed() }
        return AppGraph(
            photoLibrary: library,
            thumbnailProvider: thumbnails,
            placeNaming: naming,
            modelContainer: container,
            timelineCache: timelineCache,
            nameCache: nameCache,
            calendar: calendar,
            projectStore: projects,
            selectionStore: selection,
            doneStore: done,
            coordinator: coordinator,
            session: session,
            actions: AlbumActions(projects: projects, selection: selection, done: done,
                                  session: session, coordinator: coordinator),
            // What's New (#248) and the App Store review prompt (#269) read their last-seen /
            // last-prompted version from `defaults`. Owned at the root so they survive the iPad
            // size-class re-init.
            whatsNewState: WhatsNewState(userDefaults: defaults),
            appReviewPrompt: AppReviewPrompt(userDefaults: defaults))
    }

    /// The real app: the on-disk store, and the library / thumbnails / naming the launch selects.
    static func production() -> AppGraph {
        let container: ModelContainer
        do {
            container = try AppModelContainer.make()
        } catch {
            // The data store is unrecoverable at launch — there is no sensible degraded mode.
            Log.app.fault("Failed to open the data store: \(String(describing: error), privacy: .public)")
            fatalError("Poimi could not open its data store: \(error)")
        }
        return make(
            container: container,
            library: PhotoLibraryProvider.make(),
            thumbnails: ThumbnailProvider.make(),
            // MUST be the provider's choice: the environment's DEBUG default is the fake, so a missing
            // injection would silently show synthetic names instead of real places (#130).
            naming: PlaceNamingProvider.make(),
            timelineCache: TimelineCache())
    }
}

extension View {
    /// Inject the whole graph into the environment — the ONE place the app (and the DEBUG screenshot
    /// hosts) put the stores, coordinator, session and façade where the views read them.
    func environment(graph: AppGraph) -> some View {
        environment(\.photoLibrary, graph.photoLibrary)
            .environment(\.thumbnailProvider, graph.thumbnailProvider)
            .environment(\.placeNaming, graph.placeNaming)
            .environment(graph.projectStore)
            .environment(graph.selectionStore)
            .environment(graph.doneStore)
            .environment(graph.coordinator)
            .environment(graph.session)
            .environment(graph.actions)
            .environment(graph.whatsNewState)
            .environment(graph.appReviewPrompt)
    }
}
