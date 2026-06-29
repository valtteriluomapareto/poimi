//
//  ReviewChrome.swift
//  PoimiApp — the review-grid top chrome: tally + export + clear (issue #35, part 3).
//
//  Per the styleguide, the review chrome lives in the TOP region (a standard nav bar — Liquid Glass
//  + the scroll-edge effect come for free, no hand-rolled floating glass), never a floating bottom
//  bar that fights the scroll/select gestures. The running tally is the orientation device (count
//  toward target); Export is the top-right action; Clear sits beside it.
//
//  Both pieces read the `SelectionStore` THEMSELVES (rather than taking values from the review
//  screen) so the dependency on `selected` lives here — the grid's parent body stays independent of
//  selection and a toggle never re-walks the timeline.
//

import SwiftUI
import Curation

/// The running tally — "147 / 200" with a slim progress bar. At accessibility text sizes it reflows
/// to numerals only (the dense bar-on-chrome is the most likely Dynamic-Type contrast failure,
/// styleguide §2/§8). `monospacedDigit` so the count doesn't jitter as it climbs.
struct ReviewTally: View {
    @Environment(SelectionStore.self) private var selection
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let progress = selection.progress
        Group {
            if typeSize.isAccessibilitySize {
                counts(progress).font(.headline)
            } else {
                HStack(spacing: 8) {
                    counts(progress).font(.subheadline)
                    progressBar(progress)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(progress))
    }

    private func counts(_ progress: TargetProgress) -> some View {
        (Text("\(progress.picked)").fontWeight(.semibold)
            + Text(" / \(progress.target)").foregroundStyle(.secondary))
            .monospacedDigit()
            .lineLimit(1)
    }

    private func progressBar(_ progress: TargetProgress) -> some View {
        Capsule()
            .fill(.quaternary)
            .frame(width: 56, height: 5)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(progress.isComplete ? Color.green : Color.accentColor)
                    .frame(width: 56 * progress.fraction)
            }
            .accessibilityHidden(true)
    }

    private func accessibilityLabel(_ progress: TargetProgress) -> String {
        let base = "\(progress.picked) of \(progress.target) photos picked"
        return progress.isComplete ? base + ", target reached" : base
    }
}

/// The trailing nav actions: Clear (only when there's a selection) + Export (disabled until at
/// least one photo is picked — there's nothing to export from an empty album).
struct ReviewToolbarActions: View {
    let onExport: () -> Void
    @Environment(SelectionStore.self) private var selection

    var body: some View {
        let picked = selection.progress.picked
        HStack(spacing: 12) {
            if picked > 0 {
                Button("Clear", role: .destructive) { selection.clear() }
                    .accessibilityHint("Deselects all photos in this album.")
            }
            Button(action: onExport) {
                Label("Export", systemImage: "rectangle.stack.badge.plus")
            }
            .disabled(picked == 0)
        }
    }
}
