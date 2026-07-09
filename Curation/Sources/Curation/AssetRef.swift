//
//  AssetRef.swift
//  Curation — the pure asset value model (issue #18).
//
//  The lightweight, `Sendable` value the domain and UI reason about. It deliberately
//  carries no live PhotoKit object (never a `PHAsset`) and no heavy / iCloud-touching
//  data — only what is cheap to read in bulk over a year of photos. The recorded
//  original byte size (the deferred quality heuristic's input, D3/D18) lives in the
//  separate `AssetMetadata`, fetched lazily — not here (architecture §2/§3).
//

import Foundation

/// A photo's GPS coordinate as plain `Sendable` value data — never `CLLocation`
/// (a non-`Sendable` reference type, D13). Reconstruct `CLLocation` in the app layer
/// only where a CoreLocation API actually needs it.
public struct Coordinate: Sendable, Equatable, Hashable, Codable {
    public let latitude: Double
    public let longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

/// Pixel dimensions as a portable value (the domain avoids CoreGraphics' `CGSize` so it
/// stays platform-free). Pixel counts are integers; megapixels come from `pixelCount`.
public struct PixelSize: Sendable, Equatable, Hashable, Codable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    public static let zero = PixelSize(width: 0, height: 0)

    /// Total pixels — the megapixel input for the deferred bytes-per-megapixel heuristic.
    public var pixelCount: Int { width * height }
}

/// The domain's value model for one photo. `id` (the PhotoKit `localIdentifier`) is the
/// only key that travels and persists (D8); everything else is a cheap snapshot used for
/// grouping, filtering, and display.
///
/// `Sendable` so it crosses the `PhotoLibrary` actor boundary; `Codable` for fixtures and
/// caching; `Identifiable` for SwiftUI lists.
public struct AssetRef: Sendable, Identifiable, Equatable, Hashable, Codable {
    /// `PHAsset.localIdentifier` — the stable key (the only thing we ever store, D8).
    public let id: String

    /// Capture (creation) date. Optional: some assets carry only a modification date
    /// (architecture §2). The day-grouping function (#19) defines the fallback day for a
    /// `nil` capture date.
    public let captureDate: Date?

    /// EXIF coordinate, if present (no separate location permission is requested — D7).
    public let coordinate: Coordinate?

    /// Pixel dimensions (free off the asset; an input to the deferred quality heuristic).
    public let pixelSize: PixelSize

    /// System screenshot media subtype — an exact, cheap exclusion predicate.
    public let isScreenshot: Bool

    /// User favorite flag.
    public let isFavorite: Bool

    /// Whether this asset is a video rather than a still — the media-type flag the grid badges
    /// and the viewer plays (#125). Default `false` keeps every existing still-only call site.
    public let isVideo: Bool

    /// Video duration in seconds; `nil` for a still. Surfaced as the grid badge + the viewer's
    /// info-panel duration. Always non-nil for a video, always nil for a still — the media-type
    /// contract the provider conformance suite pins.
    public let duration: Double?

    public init(
        id: String,
        captureDate: Date?,
        coordinate: Coordinate? = nil,
        pixelSize: PixelSize = .zero,
        isScreenshot: Bool = false,
        isFavorite: Bool = false,
        isVideo: Bool = false,
        duration: Double? = nil
    ) {
        self.id = id
        self.captureDate = captureDate
        self.coordinate = coordinate
        self.pixelSize = pixelSize
        self.isScreenshot = isScreenshot
        self.isFavorite = isFavorite
        self.isVideo = isVideo
        self.duration = duration
    }
}

/// Heavy / lazily-fetched per-asset metadata, kept *out* of `AssetRef` because reading it
/// touches iCloud and is the whole reason for the resource-size cache (D18). It is the
/// input to the deferred "camera originals only" quality heuristic (D3, Phase 4). Defined
/// now so the seam exists; populated later.
public struct AssetMetadata: Sendable, Equatable, Codable {
    /// The asset's `localIdentifier` (matches `AssetRef.id`).
    public let id: String

    /// Recorded *original* resource byte size (not the local optimized cache) — the
    /// bytes-per-megapixel input. `nil` until fetched.
    public let recordedByteSize: Int?

    public init(id: String, recordedByteSize: Int? = nil) {
        self.id = id
        self.recordedByteSize = recordedByteSize
    }
}

public extension AssetRef {
    /// The asset's calendar day under `calendar` — the single day-projection used by both
    /// grouping (#19) and completion (#20), so their keys always line up (architecture §13
    /// requires the identical projection). Defining it once keeps that contract in one place.
    func dayKey(in calendar: Calendar) -> DayKey {
        DayKey(date: captureDate, calendar: calendar)
    }
}
