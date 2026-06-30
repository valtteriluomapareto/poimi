//
//  ReviewChrome.swift
//  PoimiApp — the review-grid top chrome: tally + export + clear (issue #35, part 3).
//
//  Per the Paper design, the review chrome lives at the TOP, not a floating bottom bar that fights
//  the scroll/select gestures: the album title, a metadata subtitle, and a full-width running-tally
//  strip stack under it, with Export as the nav's top-right action. The tally is the orientation
//  device (count toward target).
//
//  These pieces read the `SelectionStore` THEMSELVES (rather than taking values from the review
//  screen) so the dependency on `selected` lives here — the grid's parent body stays independent of
//  selection and a toggle never re-walks the timeline.
//

import SwiftUI
import Curation

/// The header pinned beneath the large nav title: a metadata subtitle + the full-width tally. Pinned
/// (not scrolled) so the tally stays glanceable while you scroll the grid — it's the orientation
/// device. A `.bar` backing gives the scroll-edge legibility over bright thumbnails for free and
/// adapts under Reduce Transparency.
struct ReviewHeader: View {
    /// The album name — the screen's identity (the nav title is blanked so this is the one title).
    let title: String
    /// e.g. "1,847 photos · Jan 2025 – Dec 2025" — static metadata from the project, passed in.
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // The album identity. `.title` (not `.largeTitle`): this header is PINNED, so a full
            // large title would permanently eat the photo wall; `.title.bold()` still reads as a
            // real, on-brand title (vs the tiny centred inline nav title it replaces).
            Text(title)
                .font(.title.bold())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            ReviewTally()
                .padding(.top, 8)
        }
        // 20pt leading aligns the text under the design's title inset (cells are full-bleed at 0).
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        // `.bar`: the system bar material — translucent, scroll-edge-legible over bright thumbnails,
        // adapts under Reduce Transparency. No hard `Divider()` (a legacy table-header look); the
        // material edge carries the separation. (A full iOS 26 glassEffect scroll-edge is a device-
        // iteration item — no precedent in-app + can't be verified statically + glitch-adjacent.)
        .background(.bar)
    }
}

/// The running tally — "147 / 200" + a full-width progress bar + "N left" (Paper design). At
/// accessibility text sizes it drops the bar to numerals only (the dense bar-on-chrome is the most
/// likely Dynamic-Type contrast failure, styleguide §2/§8). `monospacedDigit` so it doesn't jitter.
struct ReviewTally: View {
    @Environment(SelectionStore.self) private var selection
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let progress = selection.progress
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                counts(progress).font(.title3)
                Spacer(minLength: 12)
                Text("\(progress.remaining) left")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if !typeSize.isAccessibilitySize {
                progressBar(progress)
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
        GeometryReader { geo in
            Capsule()
                .fill(.quaternary)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(progress.isComplete ? Color.brandGreen : Color.accentColor)   // brand green, not system
                        // Floor the fill to a visible sliver once there's any pick, so the first pick
                        // moves the bar; zero at zero.
                        .frame(width: progress.picked > 0 ? max(4, geo.size.width * progress.fraction) : 0)
                }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }

    private func accessibilityLabel(_ progress: TargetProgress) -> String {
        let base = "\(progress.picked) of \(progress.target) photos picked, \(progress.remaining) left"
        return progress.isComplete ? base + ", target reached" : base
    }
}

/// The trailing nav actions: Clear (only when there's a selection) + Export (disabled until at
/// least one photo is picked — there's nothing to export from an empty album).
struct ReviewToolbarActions: View {
    let onExport: () -> Void
    @Environment(SelectionStore.self) private var selection
    @State private var confirmingClear = false

    var body: some View {
        let picked = selection.progress.picked
        HStack(spacing: 12) {
            if picked > 0 {
                // Confirm before wiping: a tap here used to clear every pick instantly (an hour of
                // irreplaceable work) — `.destructive` only colours it red, it doesn't gate the action.
                Button("Clear", role: .destructive) { confirmingClear = true }
                    .accessibilityHint("Deselects all photos in this album.")
            }
            Button(action: onExport) {
                Label("Export", systemImage: "rectangle.stack.badge.plus")
            }
            .disabled(picked == 0)
        }
        .confirmationDialog("Clear all picks?", isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("Clear \(picked) picked", role: .destructive) { selection.clear() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deselects all \(picked) photos. Your photos aren't deleted — but you'd pick this album again from scratch.")
        }
    }
}
