//
//  Curation.swift
//  Curation
//
//  The pure-domain package for Poimi.
//
//  `Curation` holds the app's domain value types and pure functions: the asset
//  value model (`AssetRef`/`Coordinate`/`AssetMetadata`), the PhotoKit-facing
//  protocols (`PhotoLibraryProviding`, etc.), the filtering pipeline, the adaptive
//  day-grouping of the timeline, the running-total / target math, selection-set
//  logic, and location distance math.
//
//  Dependency direction (D14/D21): dependencies point *toward* this package, never
//  away from it. The PhotoKit implementation in the app target depends on `Curation`;
//  `Curation` depends on nothing platform-specific.
//
//  Boundary invariant: this package MUST NOT import Photos, PhotoKit, SwiftData,
//  UIKit, or SwiftUI, and MUST NOT use `@MainActor`. That is what keeps the domain
//  fully unit-testable with synthetic data — no simulator, no real photo library.
//  The invariant is checked by `Scripts/check-curation-boundary.sh`.
//
//  This file is a deliberate bootstrap stub (GitHub issue #3). The real domain
//  model is fleshed out in Phase 1 (issue per project-phases.md).

/// A placeholder value type marking the `Curation` domain boundary.
///
/// It exists only so the bootstrap package compiles, ships a public symbol, and has
/// something for the trivial test to exercise. It carries no behavior and will be
/// replaced by the real domain model (`AssetRef`, the filtering pipeline, the
/// day-grouping function, target math, …) in Phase 1.
public struct CurationPlaceholder: Sendable, Equatable {
    /// A human-readable note describing this package's role. Pure data, no behavior.
    public let purpose: String

    /// Creates the placeholder with a default description of the package's purpose.
    public init(purpose: String = "Pure domain for Poimi: no Photos, no SwiftData, no main-actor isolation.") {
        self.purpose = purpose
    }
}
