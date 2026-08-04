//
//  FakeThumbnailProvider.swift
//  PoimiApp — the deterministic, DEBUG-only thumbnail provider (issue #35, D25/D30).
//
//  Default: renders a stable flat-color tile per asset id instead of touching PhotoKit, so the review
//  grid draws a colorful, reproducible mosaic for tests / previews — no real photos, no authorization.
//
//  Screenshot mode (issue #230): with `-PoimiScreenshotPhotos`, serves REAL images for App Store
//  marketing captures. The images are read from the app's `Documents/ScreenshotPhotos/` — the harness
//  pushes them onto the simulator at runtime, so they live ONLY on the sim during a capture run and
//  never enter any built artifact (Debug or Release). That keeps D30 trivially satisfied (nothing to
//  isolate — no photos ship) and needs no build-phase/pbxproj changes. Off by default, so CI / tests /
//  previews keep instant, deterministic color tiles.
//
//  An `actor` like `SystemThumbnailProvider`, so it honors the same isolation and is trivially
//  `Sendable`. `#if DEBUG`, release-inert (D30).
//

#if DEBUG
import UIKit

actor FakeThumbnailProvider: ThumbnailProviding {
    func thumbnail(for assetID: String, targetSize: CGSize) async -> UIImage? {
        Self.image(for: assetID, size: targetSize)
    }

    // Same mapping at the viewer's (larger) size, so the full-screen image matches the cell the user
    // tapped: the flat tile shares the id's stable hue; a screenshot photo shares the id's ordinal.
    func fullImage(for assetID: String, targetSize: CGSize) async -> UIImage? {
        Self.image(for: assetID, size: targetSize)
    }

    // No synchronous cache for the fake: its images are recomputed/redrawn deterministically, so it
    // always takes the (instant) async path. Returning nil keeps it stateless.
    nonisolated func cachedThumbnail(for assetID: String, targetSize: CGSize) -> UIImage? { nil }

    // No real video to vend: a video page shows its poster image and the play button is inert.
    func playerItem(for assetID: String) async -> PlayerItemBox? { nil }

    // The prefetch window / cache lifecycle is a no-op for the fake — there's nothing to pre-decode.
    func updateCachingWindow(to assetIDs: [String]) {}
    func resetCache() {}

    // MARK: - Screenshot (real-photo) mode — #230

    /// Real-photo mode is opt-in via `-PoimiScreenshotPhotos` (matches the D30 `-Poimi…` guard, and is
    /// inside this `#if DEBUG` file). Default OFF → tests/CI/previews keep instant color tiles.
    private static let usePhotos = ProcessInfo.processInfo.arguments.contains("-PoimiScreenshotPhotos")

    /// Loaded once: the screenshot photos pushed to `Documents/ScreenshotPhotos/`, sorted by filename
    /// (so the owner controls placement by naming files `01.jpg`, `02.jpg`, …). Empty when the flag is
    /// off or nothing was pushed.
    private static let photos: [UIImage] = usePhotos ? loadScreenshotPhotos() : []

    /// The image for an id: a real photo in screenshot mode, else the deterministic flat tile. In
    /// screenshot mode with NO photos found, renders a LOUD magenta error tile and logs — it never
    /// silently pretty-falls-back to tiles, so a broken capture run is unmistakable.
    static func image(for id: String, size: CGSize) -> UIImage {
        guard usePhotos else { return tile(for: id, size: size) }
        guard !photos.isEmpty else {
            Log.photoLibrary.error(
                "-PoimiScreenshotPhotos set but no images in Documents/ScreenshotPhotos — rendering error tiles."
            )
            return errorTile(size: size)
        }
        return aspectFill(photos[ordinal(id) % photos.count], to: size)
    }

    /// A deterministic index into the photo set: the LAST integer run in the id (fake ids end with an
    /// index, e.g. `fake/busy/5` → 5, `fake/ov/2-14-3` → 3), else a stable hash. Deterministic and
    /// controllable — the mapping only changes when you reorder the files.
    static func ordinal(_ id: String) -> Int {
        var run = "", last = ""
        for ch in id {
            if ch.isNumber { run.append(ch) } else if !run.isEmpty { last = run; run = "" }
        }
        if !run.isEmpty { last = run }
        if let n = Int(last) { return n }
        return Int(stableHash(id) % 100_000)
    }

    /// Read + decode the pushed photos from `Documents/ScreenshotPhotos/`, sorted naturally by name.
    static func loadScreenshotPhotos() -> [UIImage] {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        else { return [] }
        let dir = docs.appendingPathComponent("ScreenshotPhotos", isDirectory: true)
        let exts: Set<String> = ["jpg", "jpeg", "png", "heic", "heif"]
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
            .filter { exts.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            ?? []
        let images = urls.compactMap { UIImage(contentsOfFile: $0.path) }
        Log.photoLibrary.notice("Screenshot mode: loaded \(images.count) real photo(s) from Documents/ScreenshotPhotos")
        return images
    }

    /// Scale-and-center-crop `image` to exactly `size` (aspect-fill), so grid cells fill without
    /// letterboxing regardless of the photo's aspect ratio.
    static func aspectFill(_ image: UIImage, to size: CGSize) -> UIImage {
        let target = CGSize(width: max(1, size.width), height: max(1, size.height))
        return UIGraphicsImageRenderer(size: target).image { _ in
            let scale = max(target.width / image.size.width, target.height / image.size.height)
            let drawn = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            image.draw(in: CGRect(
                x: (target.width - drawn.width) / 2,
                y: (target.height - drawn.height) / 2,
                width: drawn.width,
                height: drawn.height
            ))
        }
    }

    /// A loud, unmistakable tile for the "screenshot mode but no photos" failure — never a pretty color.
    static func errorTile(size: CGSize) -> UIImage {
        let pixelSize = CGSize(width: max(1, size.width), height: max(1, size.height))
        return UIGraphicsImageRenderer(size: pixelSize).image { context in
            UIColor.magenta.setFill()
            context.fill(CGRect(origin: .zero, size: pixelSize))
        }
    }

    // MARK: - Default (flat-tile) mode

    /// A deterministic flat-color tile keyed by a STABLE hash of the id. `String.hashValue` is seeded
    /// per process, so it can't be used here (it would make screenshots differ run-to-run); FNV-1a is
    /// stable, so the same id always maps to the same hue → reproducible captures.
    static func tile(for id: String, size: CGSize) -> UIImage {
        let hue = stableHue(id)
        let color = UIColor(hue: hue, saturation: 0.55, brightness: 0.80, alpha: 1)
        let pixelSize = CGSize(width: max(1, size.width), height: max(1, size.height))
        return UIGraphicsImageRenderer(size: pixelSize).image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: pixelSize))
        }
    }

    /// A stable hue in [0, 1) from the id (FNV-1a fold). Internal (not private) so a golden test can pin
    /// a known id to a known hue and catch a regression back to a per-process hash.
    static func stableHue(_ id: String) -> CGFloat {
        CGFloat(stableHash(id) % 360) / 360
    }

    /// The stable FNV-1a fold of the id's UTF-8 bytes — deterministic *across processes* (unlike
    /// `String.hashValue`, which is seeded per launch). Shared by the hue tile and the photo ordinal.
    static func stableHash(_ id: String) -> UInt64 {
        var hash: UInt64 = 1_469_598_103_934_665_603        // fixed basis
        for byte in id.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }  // FNV prime
        return hash
    }
}
#endif
