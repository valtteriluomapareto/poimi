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
import UIKit
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
    /// The new-album setup form, against an in-memory store + fake albums (#33).
    case setup
    /// The exclude-album picker, against the fake's albums (#33).
    case albumpicker
    /// The review-fetch scanning surface — drives the fetch+filter pipeline against the fake and
    /// shows the resulting candidate summary (#34).
    case scanning
    /// The thumbnail seam — a grid of deterministic fake tiles, proving `\.thumbnailProvider`
    /// renders without PhotoKit (#35).
    case thumbs
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
        case .setup: DebugSetupHostView()
        case .albumpicker: DebugAlbumPickerHostView()
        case .scanning: DebugScanningHostView()
        case .thumbs: DebugThumbnailHostView()
        }
    }
}

/// Hosts `AppRootView` with a coordinator seeded to a chosen authorization, so each root phase
/// (onboarding / recovery / albums) can be screenshotted deterministically (#30/#31).
struct DebugShellView: View {
    let screen: DebugScreen
    let authorization: LibraryAuthorization
    @State private var coordinator: AppCoordinator?
    @State private var projectStore: ProjectStore?

    var body: some View {
        Group {
            if let coordinator, let projectStore {
                AppRootView()
                    .environment(coordinator)
                    .environment(projectStore)
            } else {
                ProgressView()
            }
        }
        .task {
            // A dedicated fake at the chosen status — independent of the global `\.photoLibrary`,
            // so onboarding/recovery/albums each render their phase regardless of the launch flag.
            let resolved = AppCoordinator(library: FakePhotoLibrary(status: authorization))
            await resolved.refreshAuthorization()
            guard let store = (try? AppModelContainer.make(inMemory: true)).map({ ProjectStore(container: $0) }) else {
                // Don't signal ready — the capture script then times out loudly instead of
                // snapshotting the spinner as if it were the screen.
                Log.app.error("DebugShellView: failed to build the in-memory store")
                return
            }
            if screen == .shell { Self.seedSampleAlbums(into: store) }
            coordinator = resolved
            projectStore = store
            Log.app.notice("screenshot-ready: \(screen.rawValue, privacy: .public)")
        }
    }

    /// Seed three albums spanning the derived statuses so the `shell` screenshot is a meaningful,
    /// deterministic library (not an empty state).
    private static func seedSampleAlbums(into store: ProjectStore) {
        let start = Date(timeIntervalSince1970: 1_735_689_600)   // 2025-01-01Z
        let end = Date(timeIntervalSince1970: 1_767_225_600)     // 2026-01-01Z
        func snapshot(_ count: Int) -> Data {
            (try? SelectionSnapshot(assetIDs: Set((0..<count).map { "id\($0)" })).encoded()) ?? Data()
        }
        let done = store.create(title: "Best of 2024", rangeStart: start, rangeEnd: end, targetCount: 200)
        done.selectionSnapshot = snapshot(187)
        done.markedDoneAt = Date(timeIntervalSince1970: 1_750_000_000)
        let inProgress = store.create(title: "Summer trip", rangeStart: start, rangeEnd: end, targetCount: 80)
        inProgress.selectionSnapshot = snapshot(34)
        _ = store.create(title: "Best of 2025", rangeStart: start, rangeEnd: end, targetCount: 150)  // not started
        store.refresh()
    }
}

/// Hosts the new-album setup form (#33) against an in-memory store + an authorized fake. Uses a
/// FIXED clock + UTC calendar so the defaulted title/dates are deterministic in the screenshot.
struct DebugSetupHostView: View {
    @State private var coordinator: AppCoordinator?
    @State private var store: ProjectStore?

    var body: some View {
        Group {
            if let coordinator, let store {
                NewAlbumSetupView(draft: .priorCalendarYear(now: Self.fixedNow, calendar: Self.utc),
                                  calendar: Self.utc)
                    .environment(coordinator)
                    .environment(store)
            } else {
                ProgressView()
            }
        }
        .task {
            let coord = AppCoordinator(library: FakePhotoLibrary(status: .authorized))
            await coord.refreshAuthorization()
            guard let built = (try? AppModelContainer.make(inMemory: true)).map({ ProjectStore(container: $0) }) else {
                Log.app.error("DebugSetupHostView: failed to build the in-memory store")
                return
            }
            coordinator = coord
            store = built
            Log.app.notice("screenshot-ready: \(DebugScreen.setup.rawValue, privacy: .public)")
        }
    }

    private static let fixedNow = Date(timeIntervalSince1970: 1_750_000_000)   // ~2025-06-15
    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
}

/// Hosts the exclude-album picker (#33) against the injected fake's albums, with one album
/// pre-selected so the checkmark is visible in the screenshot.
struct DebugAlbumPickerHostView: View {
    @Environment(\.photoLibrary) private var library
    @State private var selection: Set<String> = []

    var body: some View {
        NavigationStack {
            AlbumPickerView(selection: $selection, allowsMultiple: true)
        }
        .task {
            _ = try? await library.albums()          // ensure the fake's albums are ready first
            selection = ["album/whatsapp"]           // pre-select one so the checkmark shows
            Log.app.notice("screenshot-ready: \(DebugScreen.albumpicker.rawValue, privacy: .public)")
        }
    }
}

/// Hosts the review screen (#34 scan → #35 grid): an in-memory project over the injected fake
/// (authorized, `yearMixed` seed + WhatsApp membership), with screenshots + the WhatsApp album
/// excluded. `.ready` renders the grid, so this captures the grid against the deterministic fake
/// thumbnails with a few cells pre-selected (so selection encoding shows).
struct DebugScanningHostView: View {
    @Environment(\.photoLibrary) private var library
    // Retained so the in-memory container (owned by the stores) outlives `.task` — otherwise it
    // deallocates, resets its context, and destroys `project` out from under ScanningView.
    @State private var projectStore: ProjectStore?
    @State private var selectionStore: SelectionStore?
    @State private var coordinator: AppCoordinator?
    @State private var project: CurationProject?

    /// A few candidate ids to pre-select so the captured grid shows the badge + dim encoding.
    private static let preselected = ["fake/busy/2", "fake/busy/5", "fake/quiet/16"]

    var body: some View {
        Group {
            if let selectionStore, let coordinator, let project {
                NavigationStack { ScanningView(project: project) }
                    .environment(selectionStore)
                    .environment(coordinator)
            } else {
                ProgressView()
            }
        }
        .task {
            guard let container = try? AppModelContainer.make(inMemory: true) else {
                Log.app.error("DebugScanningHostView: failed to build the in-memory container")
                return
            }
            let projects = ProjectStore(container: container)
            let selection = SelectionStore(container: container)
            let created = projects.create(
                title: "Best of 2025",
                rangeStart: Self.yearStart, rangeEnd: Self.yearEnd,
                targetCount: 100,
                excludeScreenshots: true,
                excludedAlbumIDs: ["album/whatsapp"])
            selection.activate(created)
            Self.preselected.forEach { selection.toggle($0) }

            let coord = AppCoordinator(library: library)
            projectStore = projects
            selectionStore = selection
            coordinator = coord
            project = created

            // Probe the same fake the view loads against (instant) so we signal ready only once
            // the candidates have settled — the capture script never snapshots mid-scan.
            let probe = CandidateStore(library: library)
            await probe.load(created)
            Log.app.notice("screenshot-ready: \(DebugScreen.scanning.rawValue, privacy: .public)")
        }
    }

    private static let yearStart = Date(timeIntervalSince1970: 1_735_689_600)   // 2025-01-01Z
    private static let yearEnd = Date(timeIntervalSince1970: 1_767_225_600)     // 2026-01-01Z
}

/// Hosts the thumbnail seam (#35): a grid of deterministic fake tiles loaded through the injected
/// `\.thumbnailProvider`. Proves the seam renders end-to-end (id → provider → `UIImage` → cell) and
/// that the colors are stable run-to-run (FNV-1a hue, not the per-process `hashValue`).
struct DebugThumbnailHostView: View {
    @Environment(\.thumbnailProvider) private var provider
    @State private var tiles: [Tile] = []

    private struct Tile: Identifiable { let id: String; let image: UIImage }
    private static let ids = (0..<12).map { "fake/busy/\($0)" }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 3), spacing: 2) {
                ForEach(tiles) { tile in
                    Image(uiImage: tile.image)
                        .resizable()
                        .scaledToFit()
                }
            }
            .padding(2)
        }
        .task {
            var loaded: [Tile] = []
            for id in Self.ids {
                if let image = await provider.thumbnail(for: id, targetSize: CGSize(width: 200, height: 200)) {
                    loaded.append(Tile(id: id, image: image))
                }
            }
            tiles = loaded
            Log.app.notice("screenshot-ready: \(DebugScreen.thumbs.rawValue, privacy: .public)")
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
