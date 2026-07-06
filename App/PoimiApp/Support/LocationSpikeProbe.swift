//
//  LocationSpikeProbe.swift
//  PoimiApp — the interactive location-clustering spike probe (issue #133, serving spike #129).
//
//  A DEBUG-only `DebugScreen` that turns the spike's real question — *"do clear trips emerge, and is
//  there a stable parameter plateau that surfaces them without junk?"* (preprocessing-and-caching.md
//  §5.5) — into a live tuning instrument. It drives the ALREADY-MERGED pure core (#132) —
//  `PlaceClustering` + `TripOverlay` (`Curation`) — over whatever `\.photoLibrary` vends, recomputing
//  on every control change so you watch the Italy trip appear / merge / fragment as you drag `eps`.
//
//  Nothing here is new algorithm work: the controls map 1:1 onto the core's existing args (`eps`,
//  `minPts`, `gapToleranceDays`, home exclusion). The clustering stays pure in `Curation` (D14/D21);
//  the only impure things are app-tier and live only here: the `CLGeocoder` medoid reverse-geocode
//  (EXIF coordinates → `CLLocation`, no CoreLocation permission — D7) and the findings export.
//
//  Everything is `#if DEBUG` + release-isolated (D30): the whole file compiles out of Release, and it
//  reads the `-PoimiUseFakeLibrary` flag only to pick the geocoder (real vs deterministic placeholder).
//
//  Performance (the main build risk, §8): the core's neighbour search is O(n²), so the live recompute
//  runs OFF the main thread in a detached `Task`, coalesced by a debounce, with a spinner — never in a
//  `body`. That (not downsampling) is the primary mitigation; the full located set is clustered by
//  default. An OPT-IN downsample cap is the "if still laggy on a huge library" escape hatch, and because
//  clustering a subset changes which clusters *form*, it is surfaced (never a silent cap).
//
//  Overfitting guard (§5.5): the reported result is a *plateau* (a param range that surfaces the trips
//  with ~0 junk), never a lucky point — freeze expectations first in
//  `docs/plans/location-spike-preregistration.md`, then tune. The synthetic planted seed
//  (`FakePhotoLibrary.locationSpikeSeed`) is the reproducible CI/screenshot anchor.
//
#if DEBUG

import CoreLocation
import OSLog
import SwiftUI
import UIKit
import Curation

// MARK: - Parameters + result value types (all Sendable so they cross the detached-compute hop)

/// The four live-tunable knobs, captured per recompute. `minPts == nil` means "adaptive" (the
/// production path — `PlaceClustering.adaptiveMinPts`). `Equatable` so the view can debounce on change.
struct SpikeParams: Equatable, Sendable {
    var epsMeters: Double
    var minPts: Int?
    var gapToleranceDays: Int
    var excludeHome: Bool
}

/// One surfaced place cluster, enriched for a card: identity (medoid asset id), the medoid coordinate
/// (the geocode query point), member count, date span, a few representative thumbnails, and whether it
/// was detected as home.
struct SpikeClusterCard: Identifiable, Sendable {
    let id: String
    let medoid: Coordinate
    let count: Int
    let isHome: Bool
    let firstDay: DayKey?
    let lastDay: DayKey?
    let thumbIDs: [String]
}

/// One detected trip: a contiguous away-from-home run, labeled by its plurality cluster. Carries its
/// own GPS coverage (located / total assets on its days) so the per-trip coverage the review required
/// is visible at a glance.
struct SpikeTripCard: Identifiable, Sendable {
    let id: String
    let labelClusterID: String
    let labelMedoid: Coordinate?
    let firstDay: DayKey
    let lastDay: DayKey
    let dayCount: Int
    let photoCount: Int
    let gpsCoverage: Double
    let thumbIDs: [String]
}

/// The whole recompute output — counts + coverage for the results panel, plus the cluster/trip cards.
struct SpikeResult: Sendable {
    let params: SpikeParams
    let totalCount: Int
    let locatedCount: Int
    let noLocationCount: Int
    let clusterCount: Int
    let tripCount: Int
    let globalCoverage: Double
    let adaptiveMinPts: Int
    let resolvedMinPts: Int
    let homeClusterID: String?
    /// How many located points were actually clustered (< `locatedCount` when the live preview
    /// downsampled a large library — surfaced, never a silent cap).
    let previewedLocatedCount: Int
    let clusters: [SpikeClusterCard]
    let trips: [SpikeTripCard]

    var didDownsample: Bool { previewedLocatedCount < locatedCount }
}

// MARK: - The pure compute (off-main; over Sendable inputs only)

/// Runs the merged #132 core over a candidate set at the given params, off the main actor. Pure over
/// its Sendable inputs — it calls only `PlaceClustering` / `TripOverlay` (the tested `Curation` core),
/// so the live recompute can never diverge from what the property tests pin.
enum LocationSpikeCompute {
    /// Default value for the OPT-IN downsample cap (`LocationSpikeModel.downsampleCap`). Downsampling is
    /// OFF by default: the live recompute clusters the FULL located set (the issue's §8 primary
    /// mitigation is debounce + off-main + spinner; downsampling is only the "if still laggy" fallback).
    /// A real multi-thousand-photo year is O(n²) but runs in a detached task with a spinner — acceptable
    /// for a manual tuning tool — and clustering a strided subset changes which clusters *form*, which
    /// would mislead the plateau read the spike exists to make.
    static let defaultDownsampleCap = 2_500

    /// Mirror of `PlaceClustering.isLocated` (which is module-internal to `Curation`): a real coordinate
    /// that is not the `(0,0)` null-island EXIF sentinel. `locatedCount`/`globalCoverage` are the
    /// has-GPS count (a superset of clustered points — DBSCAN noise is GPS-bearing yet routes to the
    /// no-location bucket, §5.4), so they intentionally differ from `clustered.noLocationIDs`.
    static func isLocated(_ asset: AssetRef) -> Bool {
        guard let c = asset.coordinate else { return false }
        return !(c.latitude == 0 && c.longitude == 0)
    }

    /// Deterministic stride subsample of `cap` items from an id-sorted set (stable across recomputes).
    private static func downsample(_ located: [AssetRef], to cap: Int) -> [AssetRef] {
        let sorted = located.sorted { $0.id < $1.id }
        let stride = Double(sorted.count) / Double(cap)
        return (0..<cap).map { sorted[Int(Double($0) * stride)] }
    }

    /// - Parameter cap: optional live-preview downsample ceiling on the LOCATED set. `nil` (the default)
    ///   clusters everything. When set and exceeded, a strided subset is clustered — which changes which
    ///   clusters *form*, not merely the counts (surfaced via `SpikeResult.didDownsample`).
    static func run(assets: [AssetRef], params: SpikeParams, calendar: Calendar, cap: Int?) -> SpikeResult {
        let total = assets.count
        let locatedAssets = assets.filter(isLocated)
        let locatedCount = locatedAssets.count

        let previewLocated: [AssetRef]
        if let cap, locatedCount > cap {
            previewLocated = downsample(locatedAssets, to: cap)
        } else {
            previewLocated = locatedAssets
        }
        let noLocationAssets = assets.filter { !isLocated($0) }
        let input = previewLocated + noLocationAssets

        // Density floor from the FULL located set (O(n) day-binning, cheap) so the adaptive `minPts`
        // matches production even when the clustered point set is thinned — a downsampled `input` would
        // deflate the mean-per-day toward the floor and mislead the plateau read.
        let adaptive = PlaceClustering.adaptiveMinPts(for: assets, calendar: calendar)
        let resolved = params.minPts ?? adaptive
        let clustered = PlaceClustering.clusters(
            for: input, eps: params.epsMeters, minPts: resolved, calendar: calendar)
        let home = params.excludeHome
            ? PlaceClustering.homeCluster(clustered.clusters, assets: input, calendar: calendar)
            : nil
        let trips = TripOverlay.trips(
            assets: input, clusters: clustered, home: home,
            gapToleranceDays: params.gapToleranceDays, calendar: calendar)

        // Per-asset day + membership maps for card enrichment (built once, not per card).
        let dayByID = Dictionary(input.map { ($0.id, $0.dayKey(in: calendar)) },
                                 uniquingKeysWith: { first, _ in first })
        let medoidByCluster = Dictionary(clustered.clusters.map { ($0.id, $0.medoid) },
                                         uniquingKeysWith: { first, _ in first })

        let clusterCards: [SpikeClusterCard] = clustered.clusters.map { cluster in
            let days = cluster.assetIDs.compactMap { dayByID[$0] }.filter { $0 != .undated }.sorted()
            return SpikeClusterCard(
                id: cluster.id, medoid: cluster.medoid, count: cluster.count,
                isHome: cluster.id == home?.id,
                firstDay: days.first, lastDay: days.last,
                thumbIDs: Array(cluster.assetIDs.prefix(4)))
        }.sorted { lhs, rhs in                               // busiest first; lower id as tiebreak
            lhs.count != rhs.count ? lhs.count > rhs.count : lhs.id < rhs.id
        }

        // Assets grouped by day for per-trip coverage (located / total on the run's days).
        var assetsByDay: [DayKey: [AssetRef]] = [:]
        for asset in input {
            assetsByDay[asset.dayKey(in: calendar), default: []].append(asset)
        }
        let tripCards: [SpikeTripCard] = trips.compactMap { trip in
            guard let first = trip.days.first, let last = trip.days.last else { return nil }
            let onDays = trip.days.flatMap { assetsByDay[$0] ?? [] }
            let located = onDays.filter(isLocated).count
            let coverage = onDays.isEmpty ? 0 : Double(located) / Double(onDays.count)
            let thumbs = onDays.filter(isLocated).map(\.id).sorted().prefix(4)
            return SpikeTripCard(
                id: trip.id, labelClusterID: trip.clusterID, labelMedoid: medoidByCluster[trip.clusterID],
                firstDay: first, lastDay: last, dayCount: trip.days.count,
                photoCount: onDays.count, gpsCoverage: coverage, thumbIDs: Array(thumbs))
        }

        return SpikeResult(
            params: params, totalCount: total, locatedCount: locatedCount,
            noLocationCount: clustered.noLocationIDs.count,
            clusterCount: clustered.clusters.count, tripCount: trips.count,
            globalCoverage: total == 0 ? 0 : Double(locatedCount) / Double(total),
            adaptiveMinPts: adaptive, resolvedMinPts: resolved, homeClusterID: home?.id,
            previewedLocatedCount: previewLocated.count,
            clusters: clusterCards, trips: tripCards)
    }

    /// The sorted k-distance list for the elbow plot (an objective `eps` starting point, §5.2): for each
    /// located point, the distance at which it would become a DBSCAN core point, sorted ascending. The
    /// "knee" is where density drops off — a data-driven `eps` candidate. O(n² log n), computed ONCE per
    /// data set (on load), not per drag.
    ///
    /// Rank note: this core's neighbour list is **self-inclusive** and core requires `count >= minPts`
    /// (PlaceCluster.swift), so a point turns core once its **(minPts − 1)-th** nearest *other* neighbour
    /// is within `eps`. We therefore plot that distance (`dists[k − 2]` for `k = minPts`), not the k-th,
    /// to match this DBSCAN's definition. Sorted by id before any subsample so it sees the SAME points
    /// the preview clusters (mirrors `run`) and is order-independent of the fetch.
    static func kDistanceCurve(for assets: [AssetRef], k: Int, cap: Int?) -> [Double] {
        var located = assets.filter(isLocated)
        if let cap, located.count > cap { located = downsample(located, to: cap) }
        let coords = located.map { $0.coordinate! }
        let othersNeeded = max(1, k - 1)          // (minPts − 1) other neighbours ⇒ core
        let n = coords.count
        guard n > othersNeeded else { return [] }
        var kth: [Double] = []
        kth.reserveCapacity(n)
        for i in 0..<n {
            var dists: [Double] = []
            dists.reserveCapacity(n - 1)
            for j in 0..<n where j != i { dists.append(coords[i].distance(to: coords[j])) }
            dists.sort()
            kth.append(dists[othersNeeded - 1])   // distance to the (minPts−1)-th nearest other point
        }
        return kth.sorted()
    }
}

// MARK: - Geocoding seam (app-tier; real on device, deterministic placeholder in CI)

/// Reverse-geocode a medoid coordinate to a suggested name. A seam so the fake/CI path stays
/// deterministic (the real `CLGeocoder` is non-deterministic and can't run headlessly — §7/§8).
protocol SpikePlaceNaming: Sendable {
    func name(for coordinate: Coordinate) async -> String?
}

/// The real device path: a single serial `CLGeocoder` (it has no batch API and rejects concurrency —
/// §7). Reconstructs `CLLocation` from the EXIF coordinate (no CoreLocation permission, D7), paces
/// requests, and degrades to `nil` ("unnamed") on any failure.
///
/// `CLGeocoder` is soft-deprecated on iOS 26 in favour of `MKReverseGeocodingRequest`; the two
/// deprecation warnings are knowingly accepted here — this is a throwaway `#if DEBUG` spike probe (D30)
/// the issue scopes to `CLGeocoder`, and a MapKit migration is out of scope for a tool that never ships.
/// The v1.1 production `PlaceNaming` seam (§7) is where the modern API lands.
actor SystemSpikeGeocoder: SpikePlaceNaming {
    private let geocoder = CLGeocoder()

    func name(for coordinate: Coordinate) async -> String? {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        // Reduce the (non-Sendable) placemark to a Sendable `String?` INSIDE the handler, so nothing
        // that isn't `Sendable` crosses the continuation (Swift 6 strict concurrency).
        let resolved: String? = await withCheckedContinuation { continuation in
            geocoder.reverseGeocodeLocation(location) { placemarks, _ in
                let placemark = placemarks?.first
                let parts = [placemark?.locality ?? placemark?.name, placemark?.country].compactMap { $0 }
                continuation.resume(returning: parts.isEmpty ? nil : parts.joined(separator: ", "))
            }
        }
        // Gentle pacing so a burst of clusters doesn't trip Apple's rate limiter.
        try? await Task.sleep(for: .milliseconds(600))
        return resolved
    }
}

/// The fake/CI path: a deterministic coordinate label (never a real geocode). Honest — it visibly is
/// *not* a resolved place name, so a screenshot never masquerades as real geocoding.
struct PlaceholderSpikeGeocoder: SpikePlaceNaming {
    func name(for coordinate: Coordinate) async -> String? {
        String(format: "≈ %.2f, %.2f", coordinate.latitude, coordinate.longitude)
    }
}

// MARK: - The model (@MainActor; recompute off-main, debounced)

@MainActor
@Observable
final class LocationSpikeModel {
    // Inputs / lifecycle.
    private(set) var isLoading = true
    private(set) var isComputing = false
    private(set) var loadError: String?
    private(set) var allAssets: [AssetRef] = []
    private(set) var kDistances: [Double] = []
    private(set) var kUsed = 0

    // Live-tunable controls (bound by the view; a change schedules a debounced recompute).
    var epsMeters: Double = PlaceClustering.defaultEps
    var useAdaptiveMinPts = true
    var manualMinPts = 5
    var gapToleranceDays = TripOverlay.defaultGapToleranceDays
    var excludeHome = true
    /// Downsampling is OFF by default (cluster the full set — see `LocationSpikeCompute`). The opt-in
    /// cap is the "if still laggy" escape hatch for a very large real library (§8).
    var downsampleEnabled = false
    var downsampleCap = LocationSpikeCompute.defaultDownsampleCap

    // Outputs.
    private(set) var result: SpikeResult?
    /// clusterID (medoid asset id) → suggested name. Accumulated across recomputes and reused: a
    /// medoid's coordinate is fixed, so its name is stable once resolved.
    private(set) var names: [String: String] = [:]
    /// The findings Markdown, rebuilt once per recompute / geocode pass (NOT in a `body` — the export
    /// button reads this cached value so a slider drag never rebuilds it on the render hot path).
    private(set) var findings = ""

    let library: any PhotoLibraryProviding
    private let geocoder: any SpikePlaceNaming
    let calendar: Calendar

    /// The fetch scope. All-time by default (the library-wide launch/CI path); an album's date range
    /// when hosted per-album (`DebugAlbumLocationSpikeHostView`), which is what makes the located set
    /// small enough to cluster without downsampling.
    private let interval: DateInterval
    /// Source exclusions applied after the fetch so the clustered set matches the album's real
    /// candidate set (`Filtering.included`, mirroring `CandidateStore`). Empty for the library-wide path.
    private let excludedAlbumIDs: [String]
    private let excludeScreenshots: Bool

    private var debounceTask: Task<Void, Never>?
    private var generation = 0

    init(library: any PhotoLibraryProviding,
         geocoder: any SpikePlaceNaming,
         calendar: Calendar = .current,
         interval: DateInterval = DateInterval(start: .distantPast, end: .distantFuture),
         excludedAlbumIDs: [String] = [],
         excludeScreenshots: Bool = false,
         downsampleEnabled: Bool = false,
         downsampleCap: Int = LocationSpikeCompute.defaultDownsampleCap) {
        self.library = library
        self.geocoder = geocoder
        self.calendar = calendar
        self.interval = interval
        self.excludedAlbumIDs = excludedAlbumIDs
        self.excludeScreenshots = excludeScreenshots
        self.downsampleEnabled = downsampleEnabled
        self.downsampleCap = downsampleCap
    }

    /// The effective params — `minPts == nil` when adaptive. The view observes this to debounce.
    var params: SpikeParams {
        SpikeParams(epsMeters: epsMeters,
                    minPts: useAdaptiveMinPts ? nil : manualMinPts,
                    gapToleranceDays: gapToleranceDays,
                    excludeHome: excludeHome)
    }

    /// The live-preview downsample ceiling on the located set: `nil` (full run) unless the opt-in
    /// control is on. Threaded into every `LocationSpikeCompute.run` / `kDistanceCurve` call.
    var effectiveCap: Int? { downsampleEnabled ? downsampleCap : nil }

    /// Fetch the whole library (no new fetch on recompute — clustering is live over this in-memory set,
    /// §7 step 1), compute the k-distance curve once, then the first clustering.
    func load() async {
        isLoading = true
        loadError = nil
        // The real path needs Photos authorization (the irreducible human part); ask if undetermined.
        if await library.authorizationStatus() == .notDetermined {
            _ = await library.requestAuthorization()
        }
        do {
            // Fetch the scope (all-time or one album's range), then apply the same source exclusions the
            // real curation flow uses (`CandidateStore`), so a per-album run clusters exactly that album's
            // candidate set — no new fetch on recompute; clustering is live over this in-memory set (§7).
            let fetched = try await library.fetchAssets(in: interval)
            let excludedAssetIDs = excludedAlbumIDs.isEmpty
                ? Set<String>() : try await library.assetIDs(inAlbums: excludedAlbumIDs)
            let assets = Filtering.included(
                fetched, excludeScreenshots: excludeScreenshots, excludedAssetIDs: excludedAssetIDs)
            allAssets = assets
            // k for the elbow is the full-set adaptive minPts — the same density reference the recompute
            // uses. Computed once here (§ "once per data set"); the plot caption notes it's the load-time
            // adaptive value, so it stays a fixed reference even if the user later sets a manual minPts.
            let k = PlaceClustering.adaptiveMinPts(for: assets, calendar: calendar)
            kUsed = k
            let cap = effectiveCap
            kDistances = await Task.detached(priority: .userInitiated) {
                LocationSpikeCompute.kDistanceCurve(for: assets, k: k, cap: cap)
            }.value
            Log.app.notice("LocationSpikeProbe loaded \(assets.count) assets, k=\(k, privacy: .public)")
        } catch {
            loadError = String(describing: error)
            Log.photoLibrary.error("LocationSpikeProbe load failed: \(String(describing: error), privacy: .public)")
        }
        isLoading = false
        await recomputeNow()
    }

    /// Debounced entry point for a control change — coalesces a slider drag into one recompute.
    func scheduleRecompute() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            if Task.isCancelled { return }
            await self?.recomputeNow()
        }
    }

    /// Run the pure core off-main and publish the result (+ kick geocoding). Last-writer-wins via a
    /// generation counter, so a stale in-flight compute can't clobber a newer one.
    func recomputeNow() async {
        guard !allAssets.isEmpty else { return }
        generation += 1
        let mine = generation
        let (assets, params, cal, cap) = (allAssets, self.params, calendar, effectiveCap)
        isComputing = true
        let computed = await Task.detached(priority: .userInitiated) {
            LocationSpikeCompute.run(assets: assets, params: params, calendar: cal, cap: cap)
        }.value
        guard mine == generation else { return }   // a newer recompute superseded this one
        result = computed
        findings = findingsMarkdown()
        isComputing = false
        await geocode(computed, generation: mine)
    }

    /// Serially reverse-geocode each surfaced cluster's medoid whose name isn't cached yet. Serial by
    /// construction (the actor / placeholder awaits each), so `CLGeocoder`'s no-concurrency rule holds.
    private func geocode(_ result: SpikeResult, generation mine: Int) async {
        for cluster in result.clusters where names[cluster.id] == nil {
            let resolved = await geocoder.name(for: cluster.medoid)
            guard mine == generation else { return }   // params changed under us — stop geocoding stale
            names[cluster.id] = resolved ?? "unnamed"
        }
        findings = findingsMarkdown()   // fold the resolved names into the export payload
    }

    /// The settled findings as Markdown (params + counts + cluster/trip tables) — the export payload so
    /// a tuned plateau is captured, not just remembered (§8). Pure over the current state.
    func findingsMarkdown(now: Date = Date()) -> String {
        guard let result else { return "# Poimi location-spike findings\n\n(no result yet)\n" }
        let stamp = ISO8601DateFormatter().string(from: now)
        let minPtsText = result.params.minPts.map(String.init) ?? "adaptive (\(result.adaptiveMinPts))"
        var lines: [String] = []
        lines.append("# Poimi location-spike findings")
        lines.append("")
        lines.append("_Captured \(stamp)._")
        lines.append("")
        lines.append("## Parameters")
        lines.append("- eps: \(Int(result.params.epsMeters)) m (\(String(format: "%.1f", result.params.epsMeters / 1000)) km)")
        lines.append("- minPts: \(minPtsText) — resolved \(result.resolvedMinPts)")
        lines.append("- gapToleranceDays: \(result.params.gapToleranceDays)")
        lines.append("- home exclusion: \(result.params.excludeHome ? "on" : "off")")
        lines.append("")
        lines.append("## Counts")
        lines.append("- assets (dated, in range): \(result.totalCount)")
        lines.append("- located (has GPS): \(result.locatedCount) — coverage \(percent(result.globalCoverage))")
        lines.append("- no-location bucket: \(result.noLocationCount)")
        lines.append("- clusters: \(result.clusterCount)")
        lines.append("- trips: \(result.tripCount)")
        if result.didDownsample {
            lines.append("- ⚠︎ live preview downsampled: clustered \(result.previewedLocatedCount) of \(result.locatedCount) located points")
        }
        lines.append("")
        lines.append("## Clusters")
        lines.append("| name | count | home | span | medoid |")
        lines.append("| --- | ---: | :---: | --- | --- |")
        for c in result.clusters {
            let name = names[c.id] ?? "…"
            let span = "\(c.firstDay?.description ?? "?") → \(c.lastDay?.description ?? "?")"
            let medoid = String(format: "%.3f, %.3f", c.medoid.latitude, c.medoid.longitude)
            lines.append("| \(name) | \(c.count) | \(c.isHome ? "🏠" : "") | \(span) | \(medoid) |")
        }
        lines.append("")
        lines.append("## Trips")
        lines.append("| label | days | photos | GPS coverage | span |")
        lines.append("| --- | ---: | ---: | ---: | --- |")
        for t in result.trips {
            let name = names[t.labelClusterID] ?? t.labelClusterID
            let span = "\(t.firstDay.description) → \(t.lastDay.description)"
            lines.append("| \(name) | \(t.dayCount) | \(t.photoCount) | \(percent(t.gpsCoverage)) | \(span) |")
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private func percent(_ fraction: Double) -> String { String(format: "%.0f%%", fraction * 100) }
}

/// Picks the geocoder for the run: the deterministic placeholder under `-PoimiUseFakeLibrary` (CI /
/// screenshots), the real serial `CLGeocoder` on device. Reading the flag here keeps the whole file
/// `#if DEBUG`-gated (release-isolation guard, D30).
enum SpikeGeocoderFactory {
    static func make() -> any SpikePlaceNaming {
        ProcessInfo.processInfo.arguments.contains("-PoimiUseFakeLibrary")
            ? PlaceholderSpikeGeocoder()
            : SystemSpikeGeocoder()
    }
}

// MARK: - The probe screen

/// The interactive probe. Controls at the top, a live results panel + k-distance elbow, then the
/// cluster/trip cards. All heavy work is in the model's off-main recompute — the `body` only reads
/// finished values.
struct LocationSpikeProbeView: View {
    @State private var model: LocationSpikeModel

    init(model: LocationSpikeModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        NavigationStack {
            Group {
                if model.isLoading {
                    ProgressView { Text(verbatim: "Loading library…") }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = model.loadError {
                    ContentUnavailableView {
                        Label { Text(verbatim: "Couldn’t load") } icon: {
                            Image(systemName: "exclamationmark.triangle")
                        }
                    } description: {
                        Text(verbatim: error)
                    }
                } else {
                    content
                }
            }
            .navigationTitle(Text(verbatim: "Location spike"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: model.findings) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityIdentifier("spike-export")
                    .disabled(model.findings.isEmpty)
                }
            }
        }
        // Loading + the screenshot-ready signal are owned by the host (`DebugLocationSpikeHostView`),
        // so the capture never races the async first cluster; the view only recomputes on a control change.
        .onChange(of: model.params) { _, _ in model.scheduleRecompute() }
        .onChange(of: model.downsampleEnabled) { _, _ in model.scheduleRecompute() }
        .onChange(of: model.downsampleCap) { _, _ in model.scheduleRecompute() }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SpikeControlsView(model: model)
                SpikeResultsPanel(model: model)
                if !model.kDistances.isEmpty {
                    KDistancePlot(distances: model.kDistances, k: model.kUsed, epsMeters: model.epsMeters)
                }
                if let result = model.result {
                    if !result.trips.isEmpty {
                        SpikeSectionHeader(title: "Trips", count: result.trips.count)
                        ForEach(result.trips) { trip in
                            SpikeTripCardView(trip: trip, name: model.names[trip.labelClusterID])
                        }
                    }
                    SpikeSectionHeader(title: "Clusters", count: result.clusters.count)
                    ForEach(result.clusters) { cluster in
                        SpikeClusterCardView(cluster: cluster, name: model.names[cluster.id])
                    }
                }
            }
            .padding()
        }
    }
}

/// The four live controls (§ scope 1). Each mutation flows through `model.params` → debounced recompute.
private struct SpikeControlsView: View {
    @Bindable var model: LocationSpikeModel

    /// Log-scale `eps` bounds: 500 m … 200 km (covers "one metro" to "cities merge", §5.2 sensitivity).
    private static let minEps = 500.0
    private static let maxEps = 200_000.0

    /// Slider position 0…1 ↔ log-scaled `eps`, so the low end (where a metro fragments) has resolution.
    private var epsSlider: Binding<Double> {
        Binding(
            get: { log(model.epsMeters / Self.minEps) / log(Self.maxEps / Self.minEps) },
            set: { model.epsMeters = Self.minEps * pow(Self.maxEps / Self.minEps, $0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(verbatim: "eps (radius)")
                    Spacer()
                    Text(verbatim: String(format: "%.1f km", model.epsMeters / 1000))
                        .foregroundStyle(.secondary).monospacedDigit()
                }
                Slider(value: epsSlider, in: 0...1)
                    .accessibilityIdentifier("spike-eps")
            }

            VStack(alignment: .leading, spacing: 4) {
                Toggle(isOn: $model.useAdaptiveMinPts) {
                    HStack {
                        Text(verbatim: "minPts adaptive")
                        Spacer()
                        Text(verbatim: model.useAdaptiveMinPts
                             ? "= \(model.result?.adaptiveMinPts ?? PlaceClustering.minAdaptiveMinPts)"
                             : "manual")
                        .foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                .accessibilityIdentifier("spike-adaptive")
                if !model.useAdaptiveMinPts {
                    HStack {
                        Text(verbatim: "minPts")
                        Slider(value: Binding(get: { Double(model.manualMinPts) },
                                              set: { model.manualMinPts = Int($0) }),
                               in: 1...30, step: 1)
                        Text(verbatim: "\(model.manualMinPts)").monospacedDigit().frame(width: 28)
                    }
                }
            }

            Stepper(value: $model.gapToleranceDays, in: 0...7) {
                HStack {
                    Text(verbatim: "gapToleranceDays")
                    Spacer()
                    Text(verbatim: "\(model.gapToleranceDays)").foregroundStyle(.secondary).monospacedDigit()
                }
            }

            Toggle(isOn: $model.excludeHome) {
                Text(verbatim: "Exclude home from trips")
            }
            .accessibilityIdentifier("spike-home")

            // Downsampling is OFF by default (full-set clustering); this is the "if still laggy on a huge
            // library" escape hatch (§8). Capping changes which clusters FORM, so it's opt-in + surfaced.
            VStack(alignment: .leading, spacing: 4) {
                Toggle(isOn: $model.downsampleEnabled) {
                    HStack {
                        Text(verbatim: "Downsample preview")
                        Spacer()
                        Text(verbatim: model.downsampleEnabled ? "\(model.downsampleCap) pts" : "full")
                            .foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                .accessibilityIdentifier("spike-downsample")
                if model.downsampleEnabled {
                    Stepper(value: $model.downsampleCap, in: 250...5000, step: 250) {
                        Text(verbatim: "cap \(model.downsampleCap) located pts")
                    }
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }
}

/// Cluster / trip / no-location counts + GPS coverage, updating on every recompute. Shows the spinner
/// while a recompute is in flight and the downsample note when the live preview capped the input.
private struct SpikeResultsPanel: View {
    let model: LocationSpikeModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(verbatim: "Results").font(.headline)
                if model.isComputing {
                    ProgressView().controlSize(.small).padding(.leading, 4)
                }
                Spacer()
            }
            if let r = model.result {
                let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
                LazyVGrid(columns: columns, spacing: 12) {
                    stat("\(r.clusterCount)", "clusters")
                    stat("\(r.tripCount)", "trips")
                    stat("\(r.noLocationCount)", "no-location")
                    stat("\(r.locatedCount)", "located")
                    stat(percent(r.globalCoverage), "GPS coverage")
                    stat("\(r.resolvedMinPts)", "minPts")
                }
                if r.didDownsample {
                    Label {
                        Text(verbatim: "Downsampled: clustered \(r.previewedLocatedCount) of \(r.locatedCount) located points — cluster/trip SHAPE is approximate, not just the counts")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                    }
                    .font(.caption).foregroundStyle(.orange)
                }
            } else {
                Text(verbatim: "Computing…").foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(verbatim: value).font(.title3.bold()).monospacedDigit()
            Text(verbatim: label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func percent(_ f: Double) -> String { String(format: "%.0f%%", f * 100) }
}

/// The sorted k-distance curve — a data-driven `eps` starting point (§5.2). The knee is where density
/// drops off; a dashed line marks the current `eps` so you can read it against the curve.
private struct KDistancePlot: View {
    let distances: [Double]
    let k: Int
    let epsMeters: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: "k-distance (k = \(k), load-time adaptive) — knee ≈ eps candidate").font(.headline)
            // y-axis top: the curve is sorted ascending, so its max sits at the top-right.
            HStack {
                Spacer()
                Text(verbatim: String(format: "max %.0f km", (distances.last ?? 0) / 1000))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Canvas { context, size in
                guard let maxD = distances.last, maxD > 0 else { return }
                var path = Path()
                for (index, value) in distances.enumerated() {
                    let x = size.width * CGFloat(index) / CGFloat(max(1, distances.count - 1))
                    let y = size.height * (1 - CGFloat(value / maxD))
                    if index == 0 { path.move(to: CGPoint(x: x, y: y)) }
                    else { path.addLine(to: CGPoint(x: x, y: y)) }
                }
                context.stroke(path, with: .color(.accentColor), lineWidth: 2)
                // Current eps as a horizontal reference (clamped into view).
                let epsY = size.height * (1 - CGFloat(min(epsMeters, maxD) / maxD))
                var line = Path()
                line.move(to: CGPoint(x: 0, y: epsY))
                line.addLine(to: CGPoint(x: size.width, y: epsY))
                context.stroke(line, with: .color(.secondary),
                               style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }
            .frame(height: 120)
            HStack {
                Text(verbatim: "points sorted by k-distance →").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text(verbatim: String(format: "eps %.1f km (dashed)", epsMeters / 1000))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct SpikeSectionHeader: View {
    let title: String
    let count: Int
    var body: some View {
        Text(verbatim: "\(title) (\(count))").font(.title3.bold()).padding(.top, 4)
    }
}

/// A trip card: name (geocoded label), span, day/photo counts, per-trip GPS coverage, thumbnails.
private struct SpikeTripCardView: View {
    let trip: SpikeTripCard
    let name: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "airplane").foregroundStyle(.tint)
                Text(verbatim: name ?? trip.labelClusterID).font(.headline)
                Spacer()
                Text(verbatim: "\(trip.dayCount)d · \(trip.photoCount)").foregroundStyle(.secondary).monospacedDigit()
            }
            Text(verbatim: "\(trip.firstDay.description) → \(trip.lastDay.description) · GPS \(percent(trip.gpsCoverage))")
                .font(.caption).foregroundStyle(.secondary)
            SpikeThumbRow(ids: trip.thumbIDs)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private func percent(_ f: Double) -> String { String(format: "%.0f%%", f * 100) }
}

/// A cluster card: name, home badge, count, span, thumbnails.
private struct SpikeClusterCardView: View {
    let cluster: SpikeClusterCard
    let name: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: cluster.isHome ? "house.fill" : "mappin.circle")
                    .foregroundStyle(cluster.isHome ? Color.green : Color.accentColor)
                Text(verbatim: name ?? cluster.id).font(.headline).lineLimit(1)
                if cluster.isHome {
                    Text(verbatim: "HOME").font(.caption2.bold()).foregroundStyle(.green)
                }
                Spacer()
                Text(verbatim: "\(cluster.count)").foregroundStyle(.secondary).monospacedDigit()
            }
            if let first = cluster.firstDay, let last = cluster.lastDay {
                Text(verbatim: first == last ? first.description : "\(first.description) → \(last.description)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            SpikeThumbRow(ids: cluster.thumbIDs)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }
}

/// A row of representative thumbnails, loaded through the shared `\.thumbnailProvider` seam (reused
/// from the review grid, so no bespoke image path).
private struct SpikeThumbRow: View {
    let ids: [String]
    var body: some View {
        HStack(spacing: 6) {
            ForEach(ids, id: \.self) { id in
                OverviewThumb(id: id, size: 56, cornerRadius: 10)
            }
        }
    }
}

#endif
