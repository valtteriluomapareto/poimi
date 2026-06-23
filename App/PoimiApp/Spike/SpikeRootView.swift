// SPIKE — throwaway, delete in Phase 2
//
//  SpikeRootView.swift
//  PoimiApp — Spike orchestration (THROWAWAY)
//
//  Wires the throwaway review loop end-to-end so the author can *feel* it on a
//  real library (Phase 0 ★ / D1):
//    auth gate → date-range picker → fetch → LazyVGrid (pinch density) →
//    tap cell → .navigationTransition(.zoom) full-screen pager (swipe + select
//    in place) → toggle selection into a Set → dump to an album.
//
//  This is the disposable orchestration tier. The real app replaces it with the
//  navigation coordinator + onboarding/permission flow (D6/D20). Only the
//  `Spike/Render/*` views it hosts are meant to survive.

import Photos
import SwiftUI

struct SpikeRootView: View {
    @State private var model = SpikeModel()

    var body: some View {
        Group {
            switch model.phase {
            case .needsAuth:
                AuthGate(model: model)
            case .denied:
                DeniedView(model: model)
            case .authorized:
                ReviewFlow(model: model)
            }
        }
        .task {
            model.refreshCurrentStatus()
            #if DEBUG
            // Smoke-test affordance: when launched with `-PoimiSpikeAutoAuth`
            // (used by the simulator smoke check), drive the real
            // requestAuthorization path automatically so the grid can render
            // without a synthetic tap. Inert without the flag and in release.
            if model.phase == .needsAuth,
               ProcessInfo.processInfo.arguments.contains("-PoimiSpikeAutoAuth") {
                await model.requestAuthorization()
            }
            #endif
        }
    }
}

// MARK: - Auth gate (throwaway)

private struct AuthGate: View {
    let model: SpikeModel

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.stack")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
            Text("Poimi spike")
                .font(.title.weight(.semibold))
            Text("This throwaway harness needs full Photos access to fetch a date range, review thumbnails, and dump a selection to an album.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Button("Grant Photos access") {
                Task { await model.requestAuthorization() }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }
}

private struct DeniedView: View {
    let model: SpikeModel

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.slash")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Full access not granted")
                .font(.headline)
            Text("The spike only exercises the .authorized path (status: \(statusText)). Grant Full Access in Settings → Poimi → Photos, then relaunch.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Button("Re-check") { model.refreshCurrentStatus() }
        }
        .padding()
    }

    private var statusText: String {
        switch model.rawStatus {
        case .notDetermined: "notDetermined"
        case .restricted: "restricted"
        case .denied: "denied"
        case .authorized: "authorized"
        case .limited: "limited"
        @unknown default: "unknown"
        }
    }
}

// MARK: - Review flow (throwaway orchestration; hosts the salvageable render views)

private struct ReviewFlow: View {
    @Bindable var model: SpikeModel

    // Default range: this calendar year so the sim's sample photos fall in it.
    @State private var startDate = Calendar.current.date(
        from: DateComponents(year: Calendar.current.component(.year, from: .now), month: 1, day: 1)) ?? .now
    @State private var endDate = Date.now

    @State private var path: [String] = []          // pushed asset localIdentifiers
    @State private var scrollAnchorID: String?       // scroll-restore anchor
    @Namespace private var zoomNamespace

    @State private var imageManager = ThumbnailImageManager()
    @State private var exportTitle = "Poimi Spike"

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                datePicker
                Divider()
                content
            }
            .navigationTitle("Review")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { reviewToolbar }
            .navigationDestination(for: String.self) { assetID in
                pager(startingAt: assetID)
            }
            .safeAreaInset(edge: .bottom) { exportBar }
        }
        .task {
            #if DEBUG
            // Smoke-test affordance: auto-fetch the default range so the grid
            // populates without a tap. Inert without the launch flag / in release.
            if ProcessInfo.processInfo.arguments.contains("-PoimiSpikeAutoAuth"),
               model.assets.isEmpty {
                let end = Calendar.current.date(byAdding: .day, value: 1,
                    to: Calendar.current.startOfDay(for: endDate)) ?? endDate
                model.fetch(from: Calendar.current.startOfDay(for: startDate), to: end)
            }
            #endif
        }
    }

    // MARK: Date range

    private var datePicker: some View {
        VStack(spacing: 8) {
            DatePicker("From", selection: $startDate, displayedComponents: .date)
            DatePicker("To", selection: $endDate, displayedComponents: .date)
            Button {
                // End-exclusive: include the whole "to" day.
                let end = Calendar.current.date(byAdding: .day, value: 1,
                    to: Calendar.current.startOfDay(for: endDate)) ?? endDate
                model.fetch(from: Calendar.current.startOfDay(for: startDate), to: end)
            } label: {
                Label("Fetch slice", systemImage: "arrow.down.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        .font(.subheadline)
        .padding()
    }

    @ViewBuilder
    private var content: some View {
        if model.isFetching {
            ProgressView("Fetching…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.assets.isEmpty {
            ContentUnavailableView(
                "No photos in range",
                systemImage: "photo.on.rectangle",
                description: Text("Pick a date range that contains photos, then tap Fetch slice.")
            )
            .frame(maxHeight: .infinity)
        } else {
            AssetGridView(
                assets: model.assets,
                imageManager: imageManager,
                isSelected: { model.isSelected($0) },
                toggleSelection: { model.toggle($0) },
                openAsset: { asset in path.append(asset.localIdentifier) },
                zoomNamespace: zoomNamespace,
                scrollAnchorID: $scrollAnchorID
            )
            // Prefetch window: cache the whole fetched slice for the spike (a
            // single date range is bounded; the real grid windows by visible
            // range — that windowing lives in ThumbnailImageManager already).
            .task(id: model.assets.map(\.localIdentifier)) {
                imageManager.updateCachingWindow(to: model.assets)
            }
        }
    }

    // MARK: Pager destination (zoom)

    @ViewBuilder
    private func pager(startingAt assetID: String) -> some View {
        // The pager binds its current page back to scrollAnchorID so dismissing
        // restores the grid to whichever photo the user swiped to (D22 / ★).
        let binding = Binding<String?>(
            get: { scrollAnchorID ?? assetID },
            set: { scrollAnchorID = $0 }
        )
        AssetPagerView(
            assets: model.assets,
            isSelected: { model.isSelected($0) },
            toggleSelection: { model.toggle($0) },
            currentID: binding
        )
        .navigationTransition(.zoom(sourceID: scrollAnchorID ?? assetID, in: zoomNamespace))
        .toolbarVisibility(.visible, for: .navigationBar)
        .onAppear { scrollAnchorID = assetID }
    }

    // MARK: Toolbars

    @ToolbarContentBuilder
    private var reviewToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Text("\(model.selection.count) selected")
                .font(.subheadline.weight(.medium))
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button("Clear") { model.clearSelection() }
                .disabled(model.selection.isEmpty)
        }
    }

    private var exportBar: some View {
        HStack(spacing: 12) {
            if let message = model.exportMessage {
                Text(message).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await model.dumpSelectionToAlbum(named: exportTitle) }
            } label: {
                if model.isExporting {
                    ProgressView()
                } else {
                    Label("Dump \(model.selection.count) to album", systemImage: "square.and.arrow.down")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.selection.isEmpty || model.isExporting)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }
}
