//
//  ClusterCharacter.swift
//  Curation — the cheap, string-free "character" of a review cluster (day-cluster personality).
//
//  A plain date cluster reads as a bare date + count ("Sat, Jul 5 · 47 photos"). This distils a
//  cluster's assets into a couple of cheap facts — how many videos / favourites it holds — that the app
//  tier turns into a media-highlight subtitle ("2 videos · 3 favorites"). Pure + string-free (D14/D21):
//  the domain computes the facts (deterministic, unit-tested); the app tier phrases + localizes them.
//
//  A richer, more meaningful descriptor — a locality "shape" ("Mostly at home" / a place) — is tracked
//  separately in #201. An earlier time-of-day span ("Morning – Evening") was dropped as low-signal.
//
//  Trips already carry a location sentence ("Week in Salo"), so this is only used to give the
//  everyday, non-trip date clusters some personality.
//

import Foundation

/// Cheap, display-oriented facts about a cluster's contents — the substrate the app tier phrases into
/// a characterful subtitle. Pure value type.
public struct ClusterCharacter: Sendable, Equatable {
    /// Total assets in the cluster (stills + videos).
    public let assetCount: Int
    /// How many of the assets are videos.
    public let videoCount: Int
    /// How many of the assets are marked favourite.
    public let favoriteCount: Int

    public init(assetCount: Int, videoCount: Int, favoriteCount: Int) {
        self.assetCount = assetCount
        self.videoCount = videoCount
        self.favoriteCount = favoriteCount
    }

    /// Summarise a cluster's assets into character facts. Pure; a single O(n) pass over the assets.
    public static func of(assets: [AssetRef]) -> ClusterCharacter {
        var videos = 0
        var favorites = 0
        for asset in assets {
            if asset.isVideo { videos += 1 }
            if asset.isFavorite { favorites += 1 }
        }
        return ClusterCharacter(assetCount: assets.count, videoCount: videos, favoriteCount: favorites)
    }
}
