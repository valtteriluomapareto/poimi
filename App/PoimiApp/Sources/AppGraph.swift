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
import Curation

@MainActor
struct AppGraph {
    let photoLibrary: any PhotoLibraryProviding
    let thumbnailProvider: any ThumbnailProviding
    let placeNaming: any PlaceNaming
    let modelContainer: ModelContainer
    /// The shared per-album review-timeline cache (#130): the coordinator hands it to the review
    /// screens' `CandidateStore`s, and `ProjectStore` drops an album's file on delete.
    let timelineCache: TimelineCache
    /// The persistent geocoded-name cache (D18) over `modelContainer`.
    let nameCache: NameCacheStore
    /// The calendar the timeline buckets by. Not yet consumed by the review views (they read
    /// `Calendar.current`); slice B's album session takes it from here.
    let calendar: Calendar
    let projectStore: ProjectStore
    let selectionStore: SelectionStore
    let doneStore: DoneStore
    let coordinator: AppCoordinator
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
        AppGraph(
            photoLibrary: library,
            thumbnailProvider: thumbnails,
            placeNaming: naming,
            modelContainer: container,
            timelineCache: timelineCache,
            nameCache: NameCacheStore(modelContainer: container),
            calendar: calendar,
            projectStore: ProjectStore(container: container, timelineCache: timelineCache, now: now),
            selectionStore: SelectionStore(container: container, debounce: debounce),
            doneStore: DoneStore(container: container, debounce: debounce),
            coordinator: AppCoordinator(library: library, timelineCache: timelineCache),
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
