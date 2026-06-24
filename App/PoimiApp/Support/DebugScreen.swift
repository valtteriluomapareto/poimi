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
//  Real Phase-2 screens register a `case` here as they land. Each screen logs
//  `Log.app.notice("screenshot-ready: <id>")` once its content is on screen; the
//  capture script waits for that signal instead of a blind sleep, so the PNG never races the
//  screen's async load. A screen catalogued here MUST render against `\.photoLibrary` (the
//  fake) — never real PhotoKit — or its screenshot is no longer deterministic.
//
#if DEBUG

import OSLog
import SwiftUI
import Curation

/// The screenshot-harness catalog. Each raw value is a `-PoimiScreen <id>` argument and the
/// name of the PNG `Scripts/screenshots.sh` writes. Keep cases simple — one per line, the
/// raw value identical to the case name — so the script can discover ids by parsing this enum.
enum DebugScreen: String, CaseIterable {
    /// Inspector over whatever `\.photoLibrary` vends — proves the fake → UI → screenshot path.
    case library
    /// The adaptive navigation shell (`AppRootView`) against an authorized fake — shows the
    /// album-library root + stub destinations (#30).
    case shell
    /// The first-run onboarding flow (`AppRootView` with a `.notDetermined` fake, #31).
    case onboarding
    /// The access-recovery screen (`AppRootView` with a `.denied` fake, #31).
    case recovery
}

/// Resolves the `-PoimiScreen` launch override.
enum DebugLaunch {
    /// The raw value passed to `-PoimiScreen`, if the flag is present (even if it doesn't
    /// resolve to a catalog case). `nil` → the flag was not passed → run the normal app.
    static var screenArgument: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let flag = args.firstIndex(of: "-PoimiScreen") else { return nil }
        let valueIndex = args.index(after: flag)
        return valueIndex < args.endIndex ? args[valueIndex] : nil
    }

    /// The resolved catalog screen, or `nil` if the flag is absent or names an unknown screen.
    static var requestedScreen: DebugScreen? {
        screenArgument.flatMap(DebugScreen.init(rawValue:))
    }
}

/// Renders a single catalog screen full-bleed for capture.
struct DebugScreenHost: View {
    let screen: DebugScreen

    var body: some View {
        switch screen {
        case .library: DebugLibraryView()
        case .shell: DebugShellView(screen: .shell, authorization: .authorized)
        case .onboarding: DebugShellView(screen: .onboarding, authorization: .notDetermined)
        case .recovery: DebugShellView(screen: .recovery, authorization: .denied)
        }
    }
}

/// Hosts `AppRootView` with a coordinator seeded to a chosen authorization, so each root phase
/// (onboarding / recovery / albums) can be screenshotted deterministically (#30/#31).
struct DebugShellView: View {
    let screen: DebugScreen
    let authorization: LibraryAuthorization
    @State private var coordinator: AppCoordinator?

    var body: some View {
        Group {
            if let coordinator {
                AppRootView().environment(coordinator)
            } else {
                ProgressView()
            }
        }
        .task {
            // A dedicated fake at the chosen status — independent of the global `\.photoLibrary`,
            // so onboarding/recovery/albums each render their phase regardless of the launch flag.
            let resolved = AppCoordinator(library: FakePhotoLibrary(status: authorization))
            await resolved.refreshAuthorization()
            coordinator = resolved
            Log.app.notice("screenshot-ready: \(screen.rawValue, privacy: .public)")
        }
    }
}

/// Shown when `-PoimiScreen` names a screen the catalog doesn't have. A loud, unmistakable
/// failure so a typo (`-PoimiScreen libary`) can never masquerade as a real capture — the
/// harness's whole value is honest, comparable screenshots.
struct DebugUnknownScreenView: View {
    let id: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 48))
            Text("Unknown screen").font(.title.bold())
            Text("“\(id)” is not in the DebugScreen catalog.").multilineTextAlignment(.center)
            Text("Valid: \(DebugScreen.allCases.map(\.rawValue).joined(separator: ", "))")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.red)
        .foregroundStyle(.white)
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
            // Sort by id so the captured order is self-evidently stable, not reliant on the
            // seed's array order.
            albums = try await library.albums().sorted { $0.id < $1.id }
            // Integer counts are not redacted by the unified log, so no `privacy:` needed.
            Log.app.debug("DebugLibraryView loaded \(assets.count) assets, \(albums.count) albums")
        } catch {
            loadError = String(describing: error)
            Log.photoLibrary.error("DebugLibraryView load failed: \(String(describing: error), privacy: .public)")
        }
        // The content is now on screen — tell the capture script it's safe to snapshot.
        Log.app.notice("screenshot-ready: \(DebugScreen.library.rawValue, privacy: .public)")
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()
}

#endif
