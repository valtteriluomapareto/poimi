//
//  ClusterCharacter.swift
//  Curation — the cheap, string-free "character" of a review cluster (day-cluster personality).
//
//  A plain date cluster reads as a bare date + count ("Sat, Jul 5 · 47 photos"), which the product
//  owner flagged as soulless. This distils a cluster's assets into a handful of cheap facts — the
//  time-of-day "shape" of a single day, how many videos / favourites it holds — that the app tier
//  turns into a descriptive subtitle ("Morning – Evening · 2 videos"). Pure + string-free (D14/D21):
//  the domain computes the facts (deterministic, unit-tested); the app tier phrases + localizes them.
//
//  Trips already carry a location sentence ("Week in Salo"), so this is only used to give the
//  everyday, non-trip date clusters some personality.
//

import Foundation

/// Cheap, display-oriented facts about a cluster's contents — the substrate the app tier phrases into
/// a characterful subtitle. Pure value type; `calendar` is injected so the time-of-day bucketing is
/// explicit + testable (mirrors the rest of the domain's calendar policy).
public struct ClusterCharacter: Sendable, Equatable {
    /// A coarse time-of-day bucket — enough to say "a morning" vs "morning to evening" without the
    /// false precision of a clock time. `Comparable` by natural day order (morning < … < night) so a
    /// cluster's earliest/latest parts form a span.
    public enum PartOfDay: Int, Sendable, Equatable, Comparable, CaseIterable {
        case morning, midday, afternoon, evening, night

        public static func < (lhs: PartOfDay, rhs: PartOfDay) -> Bool { lhs.rawValue < rhs.rawValue }

        /// Bucket an hour-of-day (`0...23`). Boundaries are product choices, not magic: 5–11 morning,
        /// 11–14 midday, 14–17 afternoon, 17–21 evening, else night (the late/early-hours wrap).
        public init(hour: Int) {
            switch hour {
            case 5..<11: self = .morning
            case 11..<14: self = .midday
            case 14..<17: self = .afternoon
            case 17..<21: self = .evening
            default: self = .night
            }
        }
    }

    /// Total assets in the cluster (stills + videos).
    public let assetCount: Int
    /// How many of the assets are videos.
    public let videoCount: Int
    /// How many of the assets are marked favourite.
    public let favoriteCount: Int
    /// The earliest / latest part-of-day among the cluster's DATED assets — the "shape" of the day.
    /// `nil` when no asset carries a capture date. The app tier surfaces this span only for a
    /// single-day cluster (a multi-day run spans several days, so its earliest/latest read is noise).
    public let earliest: PartOfDay?
    public let latest: PartOfDay?

    public init(assetCount: Int, videoCount: Int, favoriteCount: Int,
                earliest: PartOfDay?, latest: PartOfDay?) {
        self.assetCount = assetCount
        self.videoCount = videoCount
        self.favoriteCount = favoriteCount
        self.earliest = earliest
        self.latest = latest
    }

    /// Summarise a cluster's assets into character facts. Pure; a single O(n) pass over the assets.
    /// A `nil`-capture-date asset contributes to the counts but not to the time-of-day span.
    public static func of(assets: [AssetRef], calendar: Calendar = .current) -> ClusterCharacter {
        var videos = 0
        var favorites = 0
        var earliest: PartOfDay?
        var latest: PartOfDay?
        for asset in assets {
            if asset.isVideo { videos += 1 }
            if asset.isFavorite { favorites += 1 }
            if let date = asset.captureDate {
                let part = PartOfDay(hour: calendar.component(.hour, from: date))
                earliest = min(earliest ?? part, part)
                latest = max(latest ?? part, part)
            }
        }
        return ClusterCharacter(assetCount: assets.count, videoCount: videos,
                                favoriteCount: favorites, earliest: earliest, latest: latest)
    }
}
