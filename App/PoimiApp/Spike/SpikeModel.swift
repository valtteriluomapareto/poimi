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

    // MARK: - Fetch

    func fetch(from start: Date, to end: Date) {
        isFetching = true
        // Synchronous PhotoKit fetch is fast for one date slice; the spike keeps
        // it simple. (The real app does this off the main actor.)
        let fetched = SpikeLibrary.fetchImageAssets(from: start, to: end)
        assets = fetched
        // Drop any stale selection that isn't in the new slice.
        let validIDs = Set(fetched.map(\.localIdentifier))
        selection.formIntersection(validIDs)
        isFetching = false
    }

    // MARK: - Selection

    func isSelected(_ asset: PHAsset) -> Bool {
        selection.contains(asset.localIdentifier)
    }

    func toggle(_ asset: PHAsset) {
        let id = asset.localIdentifier
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
