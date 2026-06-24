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
            let args = ProcessInfo.processInfo.arguments
            // Smoke-test affordance: when launched with `-PoimiSpikeForceAuthorized`
            // (the simulator smoke check), skip straight to the authorized phase so
            // the grid + its ★ toggles + the scroll-driven prefetch window can be
            // verified headlessly. The iOS 26 full-access prompt can't be tapped via
            // `simctl`, so the live `requestAuthorization` path stalls on the system
            // dialog; this forces past it for the render check only. Inert without
            // the flag and in release.
            if model.phase == .needsAuth,
               args.contains("-PoimiSpikeForceAuthorized") {
                model.forceAuthorizedForSmokeTest()
            } else if model.phase == .needsAuth,
                      args.contains("-PoimiSpikeAutoAuth") {
                // Drive the *real* requestAuthorization path (proves usage strings +
                // the auth call); the system dialog still needs a human tap.
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

    // Default range: the prior full calendar year (Jan 1 – Dec 31 of last year),
    // so Part B's first run lands on a real, complete year of photos rather than
    // a few months of the current year-to-date. The author can still adjust the
    // picker.
    @State private var startDate = Self.priorYearStart
    @State private var endDate = Self.priorYearEnd

    private static var priorYearStart: Date {
        let priorYear = Calendar.current.component(.year, from: .now) - 1
        return Calendar.current.date(
            from: DateComponents(year: priorYear, month: 1, day: 1)) ?? .now
    }

    private static var priorYearEnd: Date {
        let priorYear = Calendar.current.component(.year, from: .now) - 1
        return Calendar.current.date(
            from: DateComponents(year: priorYear, month: 12, day: 31)) ?? .now
    }

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
            let smokeArgs = ProcessInfo.processInfo.arguments
            if (smokeArgs.contains("-PoimiSpikeAutoAuth")
                || smokeArgs.contains("-PoimiSpikeForceAuthorized")),
               model.assets.isEmpty {
                let end = Calendar.current.date(byAdding: .day, value: 1,
                    to: Calendar.current.startOfDay(for: endDate)) ?? endDate
                await model.fetch(from: Calendar.current.startOfDay(for: startDate), to: end)
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
                Task { await model.fetch(from: Calendar.current.startOfDay(for: startDate), to: end) }
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
                dayGroups: model.dayGroups,
                load: { id in await model.thumbnail(id: id, using: imageManager) },
                isSelected: { model.isSelected($0) },
                toggleSelection: { model.toggle($0) },
                openAsset: { id in path.append(id) },
                // Prefetch window driven by the grid's visible range (Fix 2): the
                // grid reports a windowed slice (visible ± a row margin) as the
                // user scrolls; we resolve those ids to live assets and feed the
                // caching manager, so its windowing is exercised under scroll
                // rather than primed once with the whole slice.
                updateWindow: { ids in model.updateCachingWindow(ids: ids, using: imageManager) },
                zoomNamespace: zoomNamespace,
                scrollAnchorID: $scrollAnchorID
            )
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
            assetIDs: model.assetIDs,
            load: { id in model.fullImageStream(id: id) },
            isSelected: { model.isSelected($0) },
            toggleSelection: { model.toggle($0) },
            dismiss: { if !path.isEmpty { path.removeLast() } },
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
