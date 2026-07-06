//
//  PlaceNaming.swift
//  PoimiApp — the reverse-geocoding seam (issue #130, preprocessing §4/§7).
//
//  Coordinate → human label ("Åland", "Pori") means reverse geocoding, which is CoreLocation
//  (`CLGeocoder`) — so, like `ThumbnailProviding` and unlike `PhotoLibraryProviding`, this seam lives
//  in the app, not in pure `Curation` (D14/D21: `Curation` must not import CoreLocation). It mirrors the
//  same shape: an abstract `Sendable` contract with a real `SystemPlaceNaming` (CLGeocoder) and a
//  deterministic, DEBUG-only `FakePlaceNaming`, chosen at the composition root (D30) and injectable via
//  the environment.
//
//  No CoreLocation permission (D7): reverse-geocoding a SUPPLIED coordinate needs no authorization —
//  the coordinate comes from EXIF (`AssetRef.coordinate`), never from the device's location.
//

import SwiftUI
import Curation

/// Why a reverse-geocode failed (D19). Distinct from a *valid* "no usable name" result, which the seam
/// reports as `nil` (the place exists, the geocoder just had no label) so the caller can tell "unnamed"
/// from "retry later."
enum PlaceNamingError: Error, Sendable, Equatable {
    case rateLimited
    case network
    case cancelled
}

/// The abstract reverse-geocoding seam. `Sendable` because the implementations are actors and their
/// results cross the actor boundary; `async` for the same reason.
protocol PlaceNaming: Sendable {
    /// A concise place label for `coordinate`. Returns `nil` for a valid "no usable name" result (the
    /// place exists but the geocoder gave no label); throws `PlaceNamingError` for a transient failure
    /// (network / rate-limit / cancellation) the caller may retry later.
    func name(for coordinate: Coordinate) async throws -> String?
}

enum PlaceNamingProvider {
    /// Build the place-naming dependency for this launch — the fake only in DEBUG under
    /// `-PoimiUseFakeLibrary`, matching `PhotoLibraryProvider`/`ThumbnailProvider` so all the impure
    /// seams stay in lock-step (a fake library always pairs with a fake geocoder).
    static func make() -> any PlaceNaming {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-PoimiUseFakeLibrary") {
            Log.location.notice("Composition root: using FakePlaceNaming (-PoimiUseFakeLibrary)")
            return FakePlaceNaming()
        }
        #endif
        Log.location.notice("Composition root: using SystemPlaceNaming")
        return SystemPlaceNaming()
    }
}

extension EnvironmentValues {
    /// The injected reverse-geocoding seam. The DEBUG default is the deterministic fake (safe for
    /// previews / un-injected readers); release defaults to the real provider (never reached at runtime
    /// — `@main` always injects the composition-root instance). Mirrors `\.thumbnailProvider`.
    #if DEBUG
    @Entry var placeNaming: any PlaceNaming = FakePlaceNaming()
    #else
    @Entry var placeNaming: any PlaceNaming = SystemPlaceNaming()
    #endif
}
