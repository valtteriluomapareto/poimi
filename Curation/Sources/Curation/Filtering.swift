//
//  Filtering.swift
//  Curation — the two exact v1 source filters (issue #20, D2).
//
//  Cheap, exact, no false positives: drop screenshots (by media subtype) and any asset
//  belonging to an excluded album (a precomputed set-difference on `localIdentifier`s —
//  album membership is resolved in the fetch tier, architecture §3). The deferred
//  bytes-per-megapixel quality heuristic (D3) is NOT here — it is the Phase-4 async pass.
//

public enum Filtering {
    /// The assets that survive the opt-in source filters.
    ///
    /// - Parameters:
    ///   - assets: the fetched slice.
    ///   - excludeScreenshots: drop assets flagged `isScreenshot`.
    ///   - includeVideos: keep video assets; when `false` (the default), videos are dropped —
    ///     the app is images-only unless the album opts in (#125).
    ///   - excludedAssetIDs: ids belonging to excluded albums (precomputed membership).
    public static func included(
        _ assets: [AssetRef],
        excludeScreenshots: Bool,
        includeVideos: Bool = false,
        excludedAssetIDs: Set<String> = []
    ) -> [AssetRef] {
        assets.filter { asset in
            if excludeScreenshots, asset.isScreenshot { return false }
            if !includeVideos, asset.isVideo { return false }
            if excludedAssetIDs.contains(asset.id) { return false }
            return true
        }
    }
}
