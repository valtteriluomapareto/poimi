//
//  Curation.swift
//  Curation
//
//  The pure-domain package for Poimi — the app's domain value types and pure functions,
//  with no platform frameworks and no main-actor isolation, so it stays fully
//  unit-testable with synthetic data (no simulator, no real photo library).
//
//  Contents (one concern per file):
//    • AssetRef.swift       — AssetRef / Coordinate / PixelSize / AssetMetadata (#18)
//    • AlbumRef.swift       — AlbumRef value descriptor (#18)
//    • PhotoLibrary.swift   — PhotoLibraryProviding seam + LibraryAuthorization / errors (#18)
//    • DayKey.swift         — calendar-day key + adaptive day-grouping (#19)
//    • …target math / selection / section-done / stats (#20)
//
//  Dependency direction (D14/D21): dependencies point *toward* this package, never away
//  from it. The PhotoKit implementation in the app target depends on `Curation`; this
//  package depends on nothing platform-specific.
//
//  Boundary invariant (Scripts/check-curation-boundary.sh): MUST NOT import Photos,
//  PhotoKit, SwiftData, UIKit, SwiftUI, AppKit, Combine, or CoreLocation, and MUST NOT
//  use `@MainActor`.
//
