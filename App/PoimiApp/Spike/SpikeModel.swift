// SPIKE — throwaway, delete in Phase 2
//
//  SpikeModel.swift
//  PoimiApp — Spike state (THROWAWAY)
//
//  The disposable view-model for the spike loop. In the real app this splits into
//  the `PhotoLibrary` actor (fetch), a `@MainActor @Observable SelectionStore`
//  (the in-memory `Set<String>` source of truth, D15), and the auth coordinator
//  (D20). Here it's one `@Observable` blob — the simplest thing that runs the
//  loop. Selection is an in-memory `Set<String>` of `localIdentifier`s, exactly
//  as the real app will keep it (that part of the shape is right; the housing is
//  throwaway).

import Observation
import Photos
import UIKit

@MainActor
@Observable
final class SpikeModel {

    enum Phase {
        case needsAuth          // not yet asked / not authorized
        case authorized         // full access granted, ready to fetch
        case denied             // anything other than .authorized (spike stops here)
    }

    private(set) var phase: Phase = .needsAuth
    private(set) var rawStatus: PHAuthorizationStatus = .notDetermined

    /// The fetched slice (throwaway flat array — see SpikeLibrary).
    private(set) var assets: [PHAsset] = []
    private(set) var isFetching = false

    /// `localIdentifier` → `PHAsset` index for the current slice. The render layer
    /// is typed on `id: String` (never `PHAsset`, per D17/§2), so this throwaway
    /// tier resolves ids back to live assets for the PhotoKit image loads. In the
    /// real app the actor owns this resolution; here it's a plain dictionary.
    private var assetsByID: [String: PHAsset] = [:]

    /// Ordered ids of the slice — the value snapshot the grid/pager render over.
    var assetIDs: [String] { assets.map(\.localIdentifier) }

    /// In-memory selection — the source of truth, mutated instantly on tap (D15).
    /// This `Set<String>` shape is the one piece of "data" the real app keeps.
    private(set) var selection: Set<String> = []

    /// Export status surfaced to the UI.
    private(set) var exportMessage: String?
    private(set) var isExporting = false

    // MARK: - Auth

    func requestAuthorization() async {
        let status = await SpikeLibrary.requestAuthorization()
        rawStatus = status
        phase = (status == .authorized) ? .authorized : .denied
    }

    func refreshCurrentStatus() {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        rawStatus = status
        switch status {
        case .authorized: phase = .authorized
        case .notDetermined: phase = .needsAuth
        default: phase = .denied
        }
    }

    #if DEBUG
    /// Smoke-test only: jump to the authorized phase without the live full-access
    /// prompt, so the grid render path can be verified headlessly (the iOS 26
    /// system dialog can't be tapped via `simctl`). Gated behind the
    /// `-PoimiSpikeForceAuthorized` launch arg by the caller; never reached in
    /// release. PhotoKit fetches still require the OS to have actually granted
    /// access (the seeded simulator library), so this only bypasses the UI prompt.
    func forceAuthorizedForSmokeTest() {
        rawStatus = .authorized
        phase = .authorized
    }
    #endif

    // MARK: - Fetch

    func fetch(from start: Date, to end: Date) {
        isFetching = true
        // Synchronous PhotoKit fetch is fast for one date slice; the spike keeps
        // it simple. (The real app does this off the main actor.)
        let fetched = SpikeLibrary.fetchImageAssets(from: start, to: end)
        assets = fetched
        assetsByID = Dictionary(
            fetched.map { ($0.localIdentifier, $0) },
            uniquingKeysWith: { first, _ in first })
        // Drop any stale selection that isn't in the new slice.
        let validIDs = Set(fetched.map(\.localIdentifier))
        selection.formIntersection(validIDs)
        isFetching = false
    }

    // MARK: - Selection (id-keyed, matching the render-layer closures)

    func isSelected(_ id: String) -> Bool {
        selection.contains(id)
    }

    func toggle(_ id: String) {
        if selection.contains(id) {
            selection.remove(id)
        } else {
            selection.insert(id)
        }
    }

    func clearSelection() {
        selection.removeAll()
    }

    var selectedAssets: [PHAsset] {
        assets.filter { selection.contains($0.localIdentifier) }
    }

    // MARK: - Asset metadata (id → value, for the value-shaped render layer)

    /// Natural aspect ratio (width / height) for `id`, read off the live `PHAsset`
    /// here so the render layer (which only carries `id: String`) can lay out the
    /// aspect cell shape without touching PhotoKit. `nil` if unknown / unresolvable.
    func aspectRatio(id: String) -> CGFloat? {
        guard let asset = assetsByID[id], asset.pixelHeight > 0 else { return nil }
        return CGFloat(asset.pixelWidth) / CGFloat(asset.pixelHeight)
    }

    /// Resolve a window of ids (from the grid's visible range) back to live
    /// `PHAsset`s and update the caching manager's prefetch window (Fix 2). The
    /// render layer hands us only ids; the id → live-asset resolution stays here in
    /// the throwaway tier (the real app's actor owns it).
    func updateCachingWindow(ids: [String], using imageManager: ThumbnailImageManager) {
        let window = ids.compactMap { assetsByID[$0] }
        imageManager.updateCachingWindow(to: window)
    }

    // MARK: - Image loads (resolve id → live PHAsset for the render layer)

    /// Thumbnail for `id` via the caching manager. Resolves the id to the live
    /// `PHAsset` here in the throwaway tier so the render views never touch one.
    func thumbnail(id: String, using imageManager: ThumbnailImageManager) async -> UIImage? {
        guard let asset = assetsByID[id] else { return nil }
        return await imageManager.thumbnail(for: asset)
    }

    /// Progressive full-res stream for `id`, resolved to the live `PHAsset` here.
    func fullImageStream(id: String) -> AsyncStream<UIImage> {
        guard let asset = assetsByID[id] else {
            return AsyncStream { $0.finish() }
        }
        return FullImageLoader.images(for: asset)
    }

    // MARK: - Export

    func dumpSelectionToAlbum(named title: String) async {
        let toExport = selectedAssets
        guard !toExport.isEmpty else {
            exportMessage = "Nothing selected."
            return
        }
        isExporting = true
        exportMessage = nil
        do {
            try await SpikeLibrary.dumpToAlbum(named: title, assets: toExport)
            exportMessage = "Added \(toExport.count) to “\(title)”."
        } catch {
            exportMessage = "Export failed: \(error.localizedDescription)"
        }
        isExporting = false
    }
}
