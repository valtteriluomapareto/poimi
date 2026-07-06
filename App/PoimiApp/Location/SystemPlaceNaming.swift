//
//  SystemPlaceNaming.swift
//  PoimiApp — the real reverse-geocoder (issue #130, preprocessing §7).
//
//  A single `CLGeocoder` owned by an actor and awaited SERIALLY: `CLGeocoder` has no batch API and
//  rejects concurrency (a second request while one is in flight fails) — so callers must issue one at a
//  time. `LocationPreprocessor` does exactly that (a serial loop), and this actor never issues a request
//  itself, so there is only ever one in flight. No location permission (D7): `reverseGeocodeLocation`
//  geocodes the supplied coordinate; it never reads the device location.
//

import Foundation
import CoreLocation
import Curation

actor SystemPlaceNaming: PlaceNaming {
    private let geocoder = CLGeocoder()

    func name(for coordinate: Coordinate) async throws -> String? {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        do {
            let placemarks = try await geocoder.reverseGeocodeLocation(location)
            return placemarks.first.flatMap(Self.label(from:))
        } catch let error as CLError {
            switch error.code {
            case .geocodeFoundNoResult, .geocodeFoundPartialResult:
                return nil                       // valid "no usable name" — not a retryable failure
            case .geocodeCanceled:
                throw PlaceNamingError.cancelled
            case .network:
                throw PlaceNamingError.rateLimited   // CLGeocoder surfaces throttling as .network
            default:
                throw PlaceNamingError.network
            }
        }
    }

    /// A concise place label, coarsening from city → sub-admin → admin → name → country. City
    /// (`locality`) is the human-recognisable "trip to X" grain; the fallbacks keep sparse regions
    /// (a remote coordinate with no locality) from resolving to nothing.
    private static func label(from placemark: CLPlacemark) -> String? {
        placemark.locality
            ?? placemark.subAdministrativeArea
            ?? placemark.administrativeArea
            ?? placemark.name
            ?? placemark.country
    }
}
