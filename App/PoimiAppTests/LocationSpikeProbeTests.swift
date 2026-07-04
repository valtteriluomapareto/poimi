//
//  LocationSpikeProbeTests.swift
//  PoimiAppTests — integration coverage for the interactive location-clustering spike probe (#133).
//
//  The probe is a throwaway DEBUG instrument, but two things about it are worth pinning so it stays a
//  HONEST instrument and doesn't rot:
//    1. Its wiring — load the library → run the merged #132 core off-main → publish counts/cards —
//       actually recovers the planted trips against the deterministic fake seed (the same field the
//       `Curation` precision/recall test proves at the pure layer). If the app-tier port of the seed or
//       the compute drifted from the core, this catches it.
//    2. The live recompute over the SAME core yields the SAME clustering as calling `PlaceClustering`
//       directly (the probe must not silently diverge from what the property tests pin — the Algorithms
//       persona's concern).
//    3. The findings export contains the params + counts + cluster/trip tables (the plateau-capture
//       artifact, §8), so a settled result is recorded, not just remembered.
//

import Testing
import Foundation
import Curation
@testable import PoimiApp

@MainActor
@Suite("Location spike probe (#133)")
struct LocationSpikeProbeTests {
    private let cal = utcCalendar()

    private func loadedModel() async -> LocationSpikeModel {
        let library = FakePhotoLibrary(assets: FakePhotoLibrary.locationSpikeSeed())
        let model = LocationSpikeModel(
            library: library, geocoder: PlaceholderSpikeGeocoder(), calendar: cal)
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

    @Test("no-location bucket holds the null-island + dated-no-GPS assets; coverage is high")
    func noLocationRouting() async throws {
        let model = await loadedModel()
        let result = try #require(model.result)

        // 8 null-island (0,0) + 5 dated-no-GPS = 13 no-location; the rest are located.
        #expect(result.noLocationCount >= 13)
        #expect(result.locatedCount == result.totalCount - result.noLocationCount
                || result.locatedCount == result.totalCount - 13)   // located excludes (0,0)/no-GPS
        #expect(result.globalCoverage > 0.85)
    }

    @Test("the probe's live compute matches the pure core called directly (no divergence)")
    func matchesPureCore() async throws {
        let model = await loadedModel()
        let assets = model.allAssets

        // Same call the compute makes internally, at the model's default params.
        let clusters = PlaceClustering.clusters(for: assets, calendar: cal)
        let home = PlaceClustering.homeCluster(clusters.clusters, assets: assets, calendar: cal)
        let trips = TripOverlay.trips(assets: assets, clusters: clusters, home: home, calendar: cal)

        let result = try #require(model.result)
        #expect(result.clusterCount == clusters.clusters.count)
        #expect(result.tripCount == trips.count)
        #expect(result.noLocationCount == clusters.noLocationIDs.count)
        #expect(result.homeClusterID == home?.id)
    }

    @Test("changing a control (manual minPts) recomputes; adaptive value is surfaced")
    func recomputesOnParamChange() async throws {
        let model = await loadedModel()
        let adaptive = try #require(model.result).adaptiveMinPts
        #expect(adaptive >= PlaceClustering.minAdaptiveMinPts)

        // Flip to a manual minPts and recompute directly (bypassing the UI debounce).
        model.useAdaptiveMinPts = false
        model.manualMinPts = 30           // an extreme density floor → fewer/no clusters survive
        await model.recomputeNow()
        let tightened = try #require(model.result)
        #expect(tightened.resolvedMinPts == 30)
    }

    @Test("findings export carries params + counts + cluster/trip tables")
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
    }
}
