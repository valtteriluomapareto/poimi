//
//  LocationSpikeProbeTests.swift
//  PoimiAppTests — integration coverage for the interactive location-clustering spike probe (#133).
//
//  The probe is a throwaway DEBUG instrument, but three things about it are worth pinning so it stays a
//  HONEST instrument and doesn't rot:
//    1. Its wiring — load the library → run the merged #132 core → publish counts/cards — actually
//       recovers the planted trips against the deterministic fake seed (the same field the `Curation`
//       precision/recall test proves at the pure layer).
//    2. The live recompute over the SAME core yields the SAME clustering as calling `PlaceClustering`
//       directly (the probe must not silently diverge from what the property tests pin), and a control
//       change (minPts, home exclusion, downsample) actually re-runs the core with the new inputs.
//    3. The findings export carries the params + counts + cluster/trip tables + resolved names — the
//       plateau-capture artifact (§8).
//

import Testing
import Foundation
import Curation
@testable import PoimiApp

@MainActor
@Suite("Location spike probe (#133)")
struct LocationSpikeProbeTests {
    private let cal = utcCalendar()

    private func makeModel(downsampleEnabled: Bool = false,
                           downsampleCap: Int = LocationSpikeCompute.defaultDownsampleCap) -> LocationSpikeModel {
        LocationSpikeModel(
            library: FakePhotoLibrary(assets: FakePhotoLibrary.locationSpikeSeed()),
            geocoder: PlaceholderSpikeGeocoder(), calendar: cal,
            downsampleEnabled: downsampleEnabled, downsampleCap: downsampleCap)
    }

    private func loadedModel() async -> LocationSpikeModel {
        let model = makeModel()
        await model.load()
        return model
    }

    @Test("default params recover the six planted trips + detect Helsinki as home")
    func recoversPlantedTrips() async throws {
        let model = await loadedModel()
        let result = try #require(model.result)

        // Six planted trips: Stockholm, Italy (Rome/Florence/Venice → one trip), Paris, London, Fiji,
        // Barcelona. Precision-first at the pure layer proves exactly these recover at default params.
        #expect(result.tripCount == 6)
        // Home detected (excluded from trips) and near Helsinki (60.17, 24.94).
        let home = try #require(result.clusters.first { $0.isHome })
        #expect(result.homeClusterID == home.id)
        #expect(home.medoid.distance(to: Coordinate(latitude: 60.17, longitude: 24.94)) < 60_000)
        // The multi-city Italian trip stays ≥3 distinct clusters yet one trip.
        #expect(result.clusterCount >= 8)
        #expect(result.trips.allSatisfy { $0.labelClusterID != home.id })
    }

    @Test("clusters + no-location bucket partition every asset; the 13 non-GPS assets route out")
    func noLocationRouting() async throws {
        let model = await loadedModel()
        let result = try #require(model.result)

        // The real invariant (not a tautology): every input asset is either clustered or in the
        // no-location bucket — no loss, no dup — even through the app-tier card mapping.
        let clusteredCount = result.clusters.reduce(0) { $0 + $1.count }
        #expect(clusteredCount + result.noLocationCount == result.totalCount)
        // The 8 null-island (0,0) + 5 dated-no-GPS assets must all route to no-location (≥13 because
        // any DBSCAN noise would land here too).
        #expect(result.noLocationCount >= 13)
        #expect(result.globalCoverage > 0.85)
    }

    @Test("the probe's live compute matches the pure core called directly (no divergence)")
    func matchesPureCore() async throws {
        let model = await loadedModel()
        let assets = model.allAssets

        // Same calls the compute makes internally, at the model's default params (full set, adaptive).
        let clusters = PlaceClustering.clusters(for: assets, calendar: cal)
        let home = PlaceClustering.homeCluster(clusters.clusters, assets: assets, calendar: cal)
        let trips = TripOverlay.trips(assets: assets, clusters: clusters, home: home, calendar: cal)

        let result = try #require(model.result)
        #expect(result.clusterCount == clusters.clusters.count)
        #expect(result.tripCount == trips.count)
        #expect(result.noLocationCount == clusters.noLocationIDs.count)
        #expect(result.homeClusterID == home?.id)
    }

    @Test("tightening minPts actually re-runs the core: dense trip cities collapse to noise")
    func recomputesOnParamChange() async throws {
        let model = await loadedModel()
        let base = try #require(model.result)
        let baseClusterCount = base.clusterCount
        #expect(base.adaptiveMinPts >= PlaceClustering.minAdaptiveMinPts)

        // A manual minPts far above the trip cities' per-place counts (≤24) drops them below core → they
        // become noise; only the dense home (~435 pts) survives → strictly fewer clusters.
        model.useAdaptiveMinPts = false
        model.manualMinPts = 30
        await model.recomputeNow()
        let tightened = try #require(model.result)
        #expect(tightened.resolvedMinPts == 30)
        #expect(tightened.clusterCount < baseClusterCount)
    }

    @Test("disabling home-exclusion surfaces the home cluster as a trip label")
    func homeExclusionToggle() async throws {
        let model = await loadedModel()
        // With home excluded (default) no trip is labeled by home.
        let withHome = try #require(model.result)
        let homeID = try #require(withHome.clusters.first { $0.isHome }).id
        #expect(withHome.trips.allSatisfy { $0.labelClusterID != homeID })

        model.excludeHome = false
        await model.recomputeNow()
        let noHome = try #require(model.result)
        // The largest cluster is home; without exclusion its away-runs get labeled by it.
        let biggest = try #require(noHome.clusters.first)  // sorted busiest-first
        #expect(noHome.trips.contains { $0.labelClusterID == biggest.id })
    }

    @Test("the opt-in downsample cap thins the clustered set and is surfaced")
    func downsamplePreview() async throws {
        let model = makeModel(downsampleEnabled: true, downsampleCap: 50)
        await model.load()
        let result = try #require(model.result)

        #expect(result.locatedCount > 50)                 // the seed has far more than the cap
        #expect(result.didDownsample)
        #expect(result.previewedLocatedCount == 50)
        #expect(model.findings.contains("downsampled"))   // surfaced in the export, never silent
    }

    @Test("the k-distance elbow curve is computed and sorted ascending")
    func kDistanceCurve() async throws {
        let model = await loadedModel()
        #expect(!model.kDistances.isEmpty)
        #expect(model.kDistances == model.kDistances.sorted())
        #expect(model.kUsed >= PlaceClustering.minAdaptiveMinPts)
    }

    @Test("findings export carries params + counts + cluster/trip tables + resolved names")
    func findingsExport() async throws {
        let model = await loadedModel()
        let markdown = model.findingsMarkdown(now: Date(timeIntervalSince1970: 0))

        #expect(markdown.contains("# Poimi location-spike findings"))
        #expect(markdown.contains("## Parameters"))
        #expect(markdown.contains("eps:"))
        #expect(markdown.contains("gapToleranceDays:"))
        #expect(markdown.contains("## Counts"))
        #expect(markdown.contains("no-location bucket:"))
        #expect(markdown.contains("## Clusters"))
        #expect(markdown.contains("## Trips"))
        // The placeholder geocoder resolves each medoid to a "≈ lat, lon" label; assert one folds into
        // the exported table (the "honest instrument" claim — names reach the artifact).
        #expect(markdown.contains("≈ "))
    }
}
