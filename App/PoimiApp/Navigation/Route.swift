//
//  Route.swift
//  PoimiApp — the typed navigation path (issue #30, D20; architecture §11).
//
//  The navigation stack roots at the album library and pushes through:
//      albums → albumOverview(projectID) → review(dayKey?) → export
//  The photo viewer is NOT a path route — it's a `.sheet` (a Now-Playing-style modal card, pull-down
//  to dismiss), driven by `AppCoordinator.presentedPhotoID`.
//  Review routes by `DayKey`, never a section id (sections are a computed view, §13). Routes
//  key by the project's stable `id: UUID` (itself `Hashable`/`Codable`) — not its SwiftData
//  `PersistentIdentifier` — so a path stays valid across re-fetches and could be persisted.
//

import Foundation
import Curation

enum Route: Hashable {
    /// The zoomed-out overview of one album (§6 — the level above the selection grid).
    case albumOverview(UUID)
    /// The review/selection grid for an album, optionally scrolled to a day-group.
    case review(UUID, DayKey?)
    /// The export / completion step for an album.
    case export(UUID)
    /// The album's settings — edit name / period / target / exclusions / destination, or reset / delete (#41).
    case settings(UUID)
    /// App-level settings — Photos access + About (version / license / source). Not album-scoped.
    case appSettings
}

/// The app's root phase, derived from authorization (D6). Onboarding/permission sit *above* the
/// albums library (§11); the typed `Route` path only exists once we're in `.albums`.
enum RootPhase: Equatable {
    /// Not yet asked — show the first-run intro + rationale, then the system prompt.
    case onboarding
    /// Full access granted — the album library and everything below it.
    case albums
    /// Limited / denied / restricted — the recovery screen with the Settings deep-link.
    case recovery
}
