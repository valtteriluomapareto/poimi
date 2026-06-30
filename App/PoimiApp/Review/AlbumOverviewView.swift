//
//  AlbumOverviewView.swift
//  PoimiApp — the album's zoom-out overview (issue #37; design 19P).
//
//  Opening an album lands here. It scans the candidate set (so it can show coverage), then presents:
//  a big title, the running "N / target picked" tally, a "where your photos pile up" month histogram,
//  and one row per calendar month — month name · "N picked · total" · a strip of that month's photos.
//  Tapping a month drills into the review grid scrolled to that month's first day-group.
//
//  The month rows are the v1 treatment (design 19P, "thumbnail rows"); when the v1.1 location
//  subsystem lands, the strip becomes a location-segmented thumbnail bar (design 1PV).
//
//  Month aggregation is done once in `CandidateStore` (`MonthGrouping`, pure) — never in this body
//  (the no-grouping-in-views guard), which re-evaluates on every selection change.
//

import SwiftUI
import Curation

struct AlbumOverviewView: View {
    let project: CurationProject
    @Environment(\.photoLibrary) private var library
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(SelectionStore.self) private var selection
    @State private var store: CandidateStore?
    /// Gate the scanning indicator behind a short grace delay so an instant scan never flashes it.
    @State private var indicatorVisible = false

    var body: some View {
        content
            // No visible nav title — the big title lives in the scroll header (like the design); the
            // nav bar keeps just the back button.
            .navigationBarTitleDisplayMode(.inline)
            .task(id: project.id) {
                selection.activate(project)   // hydrate persisted picks so the counts are live
                let resolved = store ?? CandidateStore(library: library)
                store = resolved
                if resolved.phase == .idle { await resolved.load(project) }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch store?.phase ?? .idle {
        case .idle, .scanning:
            scanningIndicator
        case .ready:
            overview(summaries: store?.monthSummaries ?? [], dayByID: store?.dayByID ?? [:])
        case .empty:
            ContentUnavailableView {
                Label("No photos in range", systemImage: "photo.on.rectangle")
            } description: {
                Text("Nothing matched this album's date range and filters.")
            }
        case .failed:
            ContentUnavailableView {
                Label("Couldn't load your photos", systemImage: "exclamationmark.triangle")
            } description: {
                Text("Something went wrong while scanning your library. Try again.")
            } actions: {
                Button("Try again") { Task { await store?.load(project) } }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var scanningIndicator: some View {
        ZStack {
            if indicatorVisible {
                VStack(spacing: 16) {
                    ProgressView().controlSize(.large)
                    Text("Looking over your year…").font(.headline).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            indicatorVisible = false
            try? await Task.sleep(for: .milliseconds(300))   // UI grace — replaced before it shows on a fast scan
            indicatorVisible = true
        }
    }

    // MARK: Overview

    private func overview(summaries: [MonthSummary], dayByID: [String: DayKey]) -> some View {
        let total = summaries.reduce(0) { $0 + $1.count }
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                header(total: total, summaries: summaries)
                ForEach(summaries) { month in
                    monthRow(month, dayByID: dayByID)
                    Divider()
                }
            }
        }
    }

    private func header(total: Int, summaries: [MonthSummary]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(project.title)
                    .font(.largeTitle.bold())
                Text("\(total.formatted()) photos · pick your best \(selection.progress.target)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ReviewTally()   // "147 / 200" + bar + "N left" — reads the SelectionStore
            CoverageHistogram(summaries: summaries)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 20)
    }

    private func monthRow(_ month: MonthSummary, dayByID: [String: DayKey]) -> some View {
        let name = MonthLabel.name(year: month.year, month: month.month)
        let picked = month.assetIDs.reduce(into: 0) { if selection.selected.contains($1) { $0 += 1 } }
        return Button {
            // Drill into the review grid scrolled to this month's first day-group.
            coordinator.openReview(project.id, day: month.assetIDs.first.flatMap { dayByID[$0] })
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(name)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)   // a long month name at AX type sizes shrinks, not clips
                    Spacer(minLength: 12)
                    Text("\(picked) picked")
                        .font(.subheadline.weight(.semibold))
                        // `.primary` when there are picks (semibold carries the emphasis), NOT gold:
                        // small gold text on the light row fails the styleguide §1 contrast caveat —
                        // gold is reserved for graphical marks (the histogram fill, the check badges).
                        .foregroundStyle(picked > 0 ? .primary : .secondary)
                        .monospacedDigit()
                    Text("· \(month.count)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                OverviewThumbnailStrip(ids: month.assetIDs)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name), \(picked) of \(month.count) picked")
        .accessibilityHint("Opens this month in review")
        .accessibilityAddTraits(.isButton)
    }
}

/// Month-name formatting for the overview, pulled out so it's not rebuilt per row read.
enum MonthLabel {
    static func name(year: Int, month: Int, calendar: Calendar = .current, locale: Locale = .current) -> String {
        var components = DateComponents()
        components.year = year
        components.month = month
        guard let date = calendar.date(from: components) else { return "" }
        var style = Date.FormatStyle.dateTime.month(.wide).locale(locale)
        style.timeZone = calendar.timeZone
        return date.formatted(style)
    }
}
