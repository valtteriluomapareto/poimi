//
//  FakeThumbnailProvider.swift
//  PoimiApp — the deterministic, DEBUG-only thumbnail provider (issue #35, D25/D30).
//
//  Renders a stable flat-color tile per asset id instead of touching PhotoKit, so the review grid
//  draws a colorful, reproducible mosaic for screenshots / tests / previews — no real photos, no
//  authorization. An `actor` like `SystemThumbnailProvider`, so it honors the same isolation and is
//  trivially `Sendable`. `#if DEBUG`, release-inert (D30).
//

#if DEBUG
import UIKit

actor FakeThumbnailProvider: ThumbnailProviding {
    func thumbnail(for assetID: String, targetSize: CGSize) async -> UIImage? {
        Self.tile(for: assetID, size: targetSize)
    }

    // The prefetch window / cache lifecycle is a no-op for the fake — there's nothing to pre-decode.
    func updateCachingWindow(to assetIDs: [String]) {}
    func resetCache() {}

    /// A deterministic flat-color tile keyed by a STABLE hash of the id. `String.hashValue` is
    /// seeded per process, so it can't be used here (it would make screenshots differ run-to-run);
    /// FNV-1a is stable, so the same id always maps to the same hue → reproducible captures.
    static func tile(for id: String, size: CGSize) -> UIImage {
        let hue = stableHue(id)
        let color = UIColor(hue: hue, saturation: 0.55, brightness: 0.80, alpha: 1)
        let pixelSize = CGSize(width: max(1, size.width), height: max(1, size.height))
        return UIGraphicsImageRenderer(size: pixelSize).image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: pixelSize))
        }
    }

    /// A stable hue in [0, 1) from the id's UTF-8 bytes — an FNV-1a-style xor/multiply fold with a
    /// fixed 64-bit basis. Deterministic *across processes* (unlike `String.hashValue`, which is
    /// seeded per launch), which is what makes the rendered grid reproducible run-to-run. Internal
    /// (not private) so a golden test can pin a known id to a known hue and catch a regression back
    /// to a per-process hash.
    static func stableHue(_ id: String) -> CGFloat {
        var hash: UInt64 = 1_469_598_103_934_665_603        // fixed basis
        for byte in id.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }  // FNV prime
        return CGFloat(hash % 360) / 360
    }
}
#endif
