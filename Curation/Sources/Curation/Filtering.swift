//
//  Filtering.swift
//  Curation — the two exact v1 source filters (issue #20, D2).
//
//  Cheap, exact, no false positives: drop screenshots (by media subtype) and any asset
//  belonging to an excluded album (a precomputed set-difference on `localIdentifier`s —
//  album membership is resolved in the fetch tier, architecture §3). The deferred
//  bytes-per-megapixel quality heuristic (D3) is NOT here — it is the Phase-4 async pass.
//
//  The media filter is TWO bools, not one (#273): `includePhotos` + `includeVideos` express
//  the three reachable lenses (photos only / both / videos only). They are a serialization
//  detail — the app layer's `MediaSelection` is their single writer, so the degenerate
//  "neither" combination can't be constructed there.
//

public enum Filtering {
    /// The assets that survive the opt-in source filters.
    ///
    /// - Parameters:
    ///   - assets: the fetched slice.
    ///   - excludeScreenshots: drop assets flagged `isScreenshot`.
    ///   - includePhotos: keep still assets; when `false`, stills are dropped — the
    ///     videos-only lens (#273). Defaults to `true` so every existing caller is unchanged.
    ///   - includeVideos: keep video assets; when `false` (the default), videos are dropped —
    ///     the app is images-only unless the album opts in (#125).
    ///   - excludedAssetIDs: ids belonging to excluded albums (precomputed membership).
    ///
    /// The fetch universe is exactly `{image, video}`, so "not a video" is exactly "a photo" —
    /// the two clauses below partition it. A Live Photo is an `.image` (kept as a photo, dropped
    /// under videos-only); a screen recording is a `.video` (kept under videos-only). Note that
    /// with `includePhotos == false` a screenshot is already dropped as a still, whether or not
    /// `excludeScreenshots` is set.
    public static func included(
        _ assets: [AssetRef],
        excludeScreenshots: Bool,
        includePhotos: Bool = true,
        includeVideos: Bool = false,
        excludedAssetIDs: Set<String> = []
    ) -> [AssetRef] {
        assets.filter { asset in
            if excludeScreenshots, asset.isScreenshot { return false }
            if !includeVideos, asset.isVideo { return false }
            if !includePhotos, !asset.isVideo { return false }
            if excludedAssetIDs.contains(asset.id) { return false }
            return true
        }
    }
}
