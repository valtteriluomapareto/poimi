//
//  ReviewChrome.swift
//  PoimiApp — the review chrome: the grid's top bar (#167, design 4AB) + the Overview's tally.
//
//  The review grid's fixed top bar (`ReviewTopBar`) carries the CURRENT cluster's identity on the
//  leading lane and the album's progress on the trailing lane — a compact `ProgressRing` +
//  "picked / target". The full linear `ReviewTally` ("147 / 200" + bar + "N left") lives on the
//  Overview (the album's landing screen + "I'm done → export" spot), not the grid.
//
//  These pieces read the `SelectionStore` THEMSELVES (rather than taking values from the review
//  screen) so the dependency on `selected` lives here — the grid's parent body stays independent of
//  selection and a toggle never re-walks the timeline.
//

import SwiftUI
import Curation

/// The review grid's fixed top bar (design 4AB). Two lanes on one glass surface: the CURRENT cluster's
/// identity on the leading lane (a pin for trips · the cluster name · its photo count · a green seal
/// once it's done) and the album's running progress on the trailing lane (a compact `ProgressRing` +
/// "picked / target"). This replaces the old album-title + metadata + full-width tally header — the
/// album's own identity now lives on the Overview you came from, so the grid top is PER-CLUSTER and
/// updates as you swipe pages. It reads the `SelectionStore` itself (like the old header) so a pick
/// toggle re-renders only this bar, never the grid body. Liquid Glass, bled to the top edge under the
/// (backdrop-hidden) nav bar; Reduce Transparency falls back to a solid surface.
struct ReviewTopBar: View {
    /// The current cluster's title — a trip's location sentence ("Week in Salo") or a date title.
    let clusterTitle: String
    /// The current cluster's photo count (shown as "47 photos").
    let count: Int
    /// A trip/visit cluster → show the leading gold pin.
    var isTrip = false
    /// The cluster is marked done → show the green seal by the name.
    var isDone = false
    @Environment(SelectionStore.self) private var selection

    var body: some View {
        let progress = selection.progress
        HStack(alignment: .center, spacing: 12) {
            identity
            Spacer(minLength: 8)
            progressView(progress)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        // iOS 26 Liquid Glass, bled up under the status bar + (backdrop-hidden) nav bar so the whole top
        // is one continuous surface — no bright photo band above it. RT → solid surface (styleguide §5).
        .glassBarBackground(extendTop: true)
    }

    /// Leading lane: pin (trips) · cluster name · photo count · a done seal. Combined into one VoiceOver
    /// element so it reads as a single "Nokia, 47 photos, done" phrase.
    private var identity: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                if isTrip {
                    Image(systemName: "mappin.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                }
                Text(clusterTitle)
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)   // a long trip sentence scales before truncating at AX sizes
                if isDone {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.subheadline)
                        .foregroundStyle(Color.brandGreen)
                        .accessibilityLabel(Text("Done"))
                }
            }
            // Automatic grammar agreement: "1 photo" / "47 photos" from a single catalog entry.
            Text("^[\(count) photo](inflect: true)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }

    /// Trailing lane: album progress toward the target — "picked / target" (+ "+N over" once past it) + a
    /// compact ring. The count turns amber and the ring's arc goes amber when over (unclamped honesty,
    /// #170). The ring is decorative (a11y-hidden); the count text carries the spoken value.
    private func progressView(_ progress: TargetProgress) -> some View {
        HStack(spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                (Text("\(progress.picked)").fontWeight(.semibold)
                    .foregroundStyle(progress.isOver ? Color.brandWarning : Color.primary)
                    + Text(" / \(progress.target)").foregroundStyle(.secondary))
                    .font(.subheadline)
                    .monospacedDigit()
                    .lineLimit(1)
                if progress.isOver {
                    Text("+\(progress.overage) over")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.brandWarning)
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }
            ProgressRing(fraction: progress.fraction, tint: pacingTint(progress))
                .frame(width: 30, height: 30)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(progressA11y(progress))
    }

    private func progressA11y(_ progress: TargetProgress) -> String {
        if progress.isOver {
            return String(localized: "\(progress.picked) of \(progress.target) picked, \(progress.overage) over target",
                          comment: "Grid top-bar progress a11y when over target")
        }
        if progress.isComplete {
            return String(localized: "\(progress.picked) of \(progress.target) picked, target reached",
                          comment: "Grid top-bar progress a11y when the target is reached")
        }
        return String(localized: "\(progress.picked) of \(progress.target) picked, \(progress.remaining) left",
                      comment: "Grid top-bar progress a11y: picked of target, remaining left")
    }
}

/// A compact circular progress indicator — an arc over a faint track — showing how far the album's pick
/// count has come toward the target. Replaces the review grid's full-width linear tally bar with a
/// glanceable ring in the top bar (design 4AB). The caller sets `tint` (gold climbing, green at target,
/// amber over — `pacingTint`); the arc runs full when over (fraction is already clamped to 1).
/// Decorative: the sibling "picked / target" text carries the accessible value, so it's hidden from VoiceOver.
struct ProgressRing: View {
    /// The fraction picked, 0…1 — clamped by the drawer so an over-target value still reads as full.
    let fraction: Double
    var tint: Color = .accentColor
    var lineWidth: CGFloat = 3.5

    var body: some View {
        // Floor a non-zero fraction to a visible arc so the FIRST pick already moves the ring (mirrors
        // the Overview tally bar's sliver floor); zero stays empty (track only).
        let arcEnd = fraction > 0 ? max(0.04, min(1, fraction)) : 0
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.15), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: arcEnd)
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))   // start the arc at 12 o'clock
        }
        .accessibilityHidden(true)
    }
}

/// The pacing tint shared by the ring, the top-bar count, and the Overview tally (#170): accent gold
/// while climbing, brand-green when the target is reached exactly, and amber (`brandWarning`) once over —
/// the "heads-up, never a scold" over-target signal. Order matters: `isOver` is checked before
/// `isComplete` (which is also true past the target).
func pacingTint(_ progress: TargetProgress) -> Color {
    if progress.isOver { return .brandWarning }
    if progress.isComplete { return .brandGreen }
    return .accentColor
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
                // Once over, "+N over" (amber) replaces the clamped "N left" — the always-present text
                // that carries the over-target signal at AX sizes (where the bar is dropped, below).
                if progress.isOver {
                    Text("+\(progress.overage) over")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.brandWarning)
                        .monospacedDigit()
                } else {
                    Text("\(progress.remaining) left")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
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
            .foregroundStyle(progress.isOver ? Color.brandWarning : Color.primary)
            + Text(" / \(progress.target)").foregroundStyle(.secondary))
            .monospacedDigit()
            .lineLimit(1)
    }

    private func progressBar(_ progress: TargetProgress) -> some View {
        GeometryReader { geo in
            let width = geo.size.width
            if progress.isOver {
                // Rescale to 0…picked: gold up to the target tick, an amber cap for the overage past it —
                // the clamped bar used to just sit full-green, hiding the overshoot.
                let targetFrac = Double(progress.target) / Double(progress.picked)   // 0…1, target < picked
                ZStack(alignment: .leading) {
                    Rectangle().fill(Color.brandWarning)                             // full (the overage cap)
                    Rectangle().fill(Color.accentColor).frame(width: width * targetFrac)  // gold to target
                    Rectangle().fill(Color(.systemBackground))                       // the target tick
                        .frame(width: 2).offset(x: width * targetFrac - 1)
                }
                .clipShape(Capsule())
            } else {
                Capsule()
                    .fill(.quaternary)
                    .overlay(alignment: .leading) {
                        Capsule()
                            // brand green at target, else accent gold (not system green)
                            .fill(progress.isComplete ? Color.brandGreen : Color.accentColor)
                            // Floor the fill to a visible sliver once there's any pick, so the first pick
                            // moves the bar; zero at zero.
                            .frame(width: progress.picked > 0 ? max(4, width * progress.fraction) : 0)
                    }
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }

    private func accessibilityLabel(_ progress: TargetProgress) -> String {
        // Two full independent keys (not a localized fragment embedded in another) so a translator can
        // reorder the whole sentence per language.
        if progress.isOver {
            return String(localized: """
                \(progress.picked) of \(progress.target) photos picked, \(progress.overage) over target
                """, comment: "Tally a11y label when over target")
        }
        if progress.isComplete {
            return String(localized: """
                \(progress.picked) of \(progress.target) photos picked, \(progress.remaining) left, target reached
                """, comment: "Tally a11y label when the target is reached")
        }
        return String(localized: """
            \(progress.picked) of \(progress.target) photos picked, \(progress.remaining) left
            """, comment: "Tally a11y label: picked / target / remaining")
    }
}

/// iOS 26 Liquid Glass backing for the pinned TOP header (title + tally) — glass refracts the thumbnails
/// passing under it and carries its own adaptive contrast for the text on top. `extendTop` bleeds the
/// glass up under the status bar + (backdrop-hidden) nav bar, so the whole top is one continuous surface
/// to the edge — no bright photo band above the header. Under Reduce Transparency it swaps to a solid
/// surface + a `Color(.separator)` hairline (styleguide §5 — an accessibility axis, exempt from the
/// pure-glass rule; a solid color, NOT a `.regularMaterial` version fallback, so the guard stays satisfied).
/// (Day-group headers use `glassChip()` below, not this — they're capsules, not a full-width bar.)
private struct GlassBarBackground: ViewModifier {
    var extendTop = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        switch (extendTop, reduceTransparency) {
        case (false, false):
            content.glassEffect(.regular, in: Rectangle())
        case (true, false):
            // `Color.clear` is a shaped empty view to hang glass on; it draws nothing, the glass does.
            content.background { Color.clear.glassEffect(.regular, in: Rectangle()).ignoresSafeArea(edges: .top) }
        case (false, true):
            content.background(Color(.secondarySystemBackground)).overlay(alignment: .bottom) { hairline }
        case (true, true):
            content.background { Color(.secondarySystemBackground).ignoresSafeArea(edges: .top) }
                .overlay(alignment: .bottom) { hairline }
        }
    }

    /// The §5 Reduce-Transparency separator: once the glass edge is gone, this carries the header/photo
    /// boundary.
    private var hairline: some View { Rectangle().fill(Color(.separator)).frame(height: 0.5) }
}

/// Liquid Glass backing for a floating chip (the day-group header's day + Select-all capsules). Capsule
/// glass; under Reduce Transparency it swaps to a solid capsule + `Color(.separator)` hairline — every
/// custom glass surface owns its RT appearance (styleguide §5). Wrap co-located chips in a
/// `GlassEffectContainer` so their glass samples as one lens, never glass-on-glass (§5).
private struct GlassChipBackground: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(Color(.secondarySystemBackground), in: .capsule)
                .overlay { Capsule().strokeBorder(Color(.separator), lineWidth: 0.5) }
        } else {
            content.glassEffect(.regular, in: .capsule)
        }
    }
}

extension View {
    /// Liquid Glass backing for the pinned TOP header; `extendTop` bleeds it to the very top edge.
    func glassBarBackground(extendTop: Bool = false) -> some View { modifier(GlassBarBackground(extendTop: extendTop)) }
    /// Liquid Glass backing for a floating day-group chip (capsule) — RT-safe. Group co-located chips
    /// in a `GlassEffectContainer`.
    func glassChip() -> some View { modifier(GlassChipBackground()) }
}
