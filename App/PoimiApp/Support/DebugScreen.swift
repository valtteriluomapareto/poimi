//
//  DebugScreen.swift
//  PoimiApp — the DEBUG-only screenshot harness (issue #48).
//
//  `-PoimiScreen <id>` boots the app straight to one named screen instead of the normal root,
//  rendered against the injected `\.photoLibrary`. Paired with `-PoimiUseFakeLibrary` the
//  content is deterministic, so `Scripts/screenshots.sh` can loop the catalog and capture a
//  stable PNG of each screen to eyeball against its Paper design — in one command, no taps.
//
//  Everything here is `#if DEBUG`: the catalog, the launch override, and the `-PoimiScreen`
//  flag are absent from release (D30, enforced by Scripts/check-fake-release-isolation.sh).
//  This is the screenshot *harness*, distinct from pixel-snapshot *testing* (deferred, D26).
//
//  Real Phase-2 screens register a `case` here as they land; today the catalog hosts the
//  fake-library inspector (which proves the fake → UI → screenshot path) and the spike root.
//
#if DEBUG

import OSLog
import SwiftUI
import Curation

/// The screenshot-harness catalog. Each raw value is a `-PoimiScreen <id>` argument and the
/// name of the PNG `Scripts/screenshots.sh` writes. `CaseIterable` so the script can discover
/// every screen without a hand-maintained list.
enum DebugScreen: String, CaseIterable {
    /// Inspector over whatever `\.photoLibrary` vends — proves the fake → UI → screenshot path.
    case library
    /// The Phase-0/1 throwaway spike root (removed with the spike in Phase 2).
    case spike
}

/// Resolves the `-PoimiScreen <id>` launch override. `nil` (the default) → the normal app.
enum DebugLaunch {
    static var requestedScreen: DebugScreen? {
        let args = ProcessInfo.processInfo.arguments
        guard let flag = args.firstIndex(of: "-PoimiScreen") else { return nil }
        let valueIndex = args.index(after: flag)
        guard valueIndex < args.endIndex else { return nil }
        return DebugScreen(rawValue: args[valueIndex])
    }
}

/// Renders a single catalog screen full-bleed for capture.
struct DebugScreenHost: View {
    let screen: DebugScreen

    var body: some View {
        switch screen {
        case .library: DebugLibraryView()
        case .spike: SpikeRootView()
        }
    }
}

/// A plain inspector over the injected photo library — its authorization, assets, and albums.
/// Deterministic under `-PoimiUseFakeLibrary`, so its screenshot is stable in CI / agent runs.
struct DebugLibraryView: View {
    @Environment(\.photoLibrary) private var library

    @State private var assets: [AssetRef] = []
    @State private var albums: [AlbumRef] = []
    @State private var status: LibraryAuthorization?
    @State private var loadError: String?

    var body: some View {
        NavigationStack {
            List {
                Section("Library") {
                    LabeledContent("Authorization", value: status.map(String.init(describing:)) ?? "—")
                    if let loadError {
                        LabeledContent("Error", value: loadError)
                    }
                }
                Section("Assets (\(assets.count))") {
                    ForEach(assets.prefix(50)) { asset in
                        LabeledContent(asset.id) {
                            Text(asset.captureDate.map { Self.dayFormatter.string(from: $0) } ?? "undated")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Section("Albums (\(albums.count))") {
                    ForEach(albums) { album in
                        LabeledContent(album.title, value: album.count.map(String.init) ?? "—")
                    }
                }
            }
            .navigationTitle("Debug · Library")
        }
        .task { await load() }
    }

    private func load() async {
        status = await library.authorizationStatus()
        do {
            assets = try await library.fetchAssets(in: DateInterval(start: .distantPast, end: .distantFuture))
            albums = try await library.albums()
            // Integer counts are not redacted by the unified log, so no `privacy:` needed.
            Log.app.debug("DebugLibraryView loaded \(assets.count) assets, \(albums.count) albums")
        } catch {
            loadError = String(describing: error)
            Log.photoLibrary.error("DebugLibraryView load failed: \(String(describing: error), privacy: .public)")
        }
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()
}

#endif
