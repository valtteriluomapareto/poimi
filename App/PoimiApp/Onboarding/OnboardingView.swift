//
//  OnboardingView.swift
//  PoimiApp — first-run intro + permission rationale (issue #31, D6; architecture §10).
//
//  Shown while authorization is `.notDetermined` (root phase `.onboarding`). A two-step local
//  flow: an intro that orients (the name is opaque, so this carries weight) → a rationale that
//  earns the full-access grant *before* the system prompt. "Allow access" calls the coordinator,
//  which drives the real `PHPhotoLibrary` prompt; the resolved status flips `rootPhase`
//  reactively (→ albums, or → recovery if limited/denied).
//

import SwiftUI

struct OnboardingView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @State private var step: Step = .intro

    private enum Step { case intro, rationale }

    var body: some View {
        switch step {
        case .intro:
            OnboardingScaffold(
                symbol: "hand.tap",
                symbolTint: .brandGreen,   // first-run identity uses the green brand accent (§1)
                title: "Poimi",            // the app NAME — verbatim, never localized
                headline: String(localized: "Hand-pick your year.", comment: "Onboarding intro headline"),
                message: String(localized: """
                    Go through a whole year of photos and choose the best into one album — toward a \
                    count you set. You pick every photo, not an algorithm.
                    """, comment: "Onboarding intro body"),
                primaryTitle: String(localized: "Get started", comment: "Onboarding intro primary button"),
                primaryAction: { step = .rationale })
        case .rationale:
            OnboardingScaffold(
                symbol: "photo.stack",
                symbolTint: .brandGreen,
                title: String(localized: "Full library access", comment: "Onboarding permission title"),
                headline: String(localized: "Poimi works across your whole library.",
                                 comment: "Onboarding permission headline"),
                message: String(localized: """
                    It needs full access to browse a date range, show your photos, and save the album \
                    you build. Your photos never leave your device — Poimi stores only references, \
                    nothing in the cloud, nothing shared.
                    """, comment: "Onboarding permission body"),
                primaryTitle: String(localized: "Allow access", comment: "Onboarding permission primary button"),
                primaryAction: { Task { await coordinator.requestAuthorization() } },
                footnote: String(localized: "We’ll ask iOS for permission next.",
                                 comment: "Onboarding permission footnote"))
        }
    }
}

/// A calm, centered onboarding/recovery layout: symbol · title · headline · supporting copy, with
/// a thumb-reachable prominent action at the bottom (design-language: Notes-calm, one clear
/// primary action, ≥44pt targets). Scrolls and the symbol scales with Dynamic Type so AX sizes
/// reflow instead of clipping.
struct OnboardingScaffold: View {
    let symbol: String
    var symbolTint: Color = .accentColor
    let title: String
    let headline: String
    let message: String
    let primaryTitle: String
    let primaryAction: () -> Void
    var footnote: String?

    @ScaledMetric(relativeTo: .largeTitle) private var symbolSize: CGFloat = 56

    var body: some View {
        VStack(spacing: 16) {
            ScrollView {
                VStack(spacing: 16) {
                    Image(systemName: symbol)
                        .font(.system(size: symbolSize))
                        .foregroundStyle(symbolTint)
                        .accessibilityHidden(true)
                    Text(title)
                        .font(.largeTitle.bold())
                        .accessibilityAddTraits(.isHeader)
                    Text(headline)
                        .font(.title3)
                        .multilineTextAlignment(.center)
                    Text(message)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: readableWidth)   // cap the measure on iPad/regular width
                .frame(maxWidth: .infinity)        // …centered in the wider container
                .padding(.top, 48)
            }
            VStack(spacing: 16) {
                if let footnote {
                    Text(footnote)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                Button(primaryTitle, action: primaryAction)
                    .buttonStyle(PrimaryActionButtonStyle())
                    // VoiceOver hears the consequence (the visual footnote) when on the button.
                    .accessibilityHint(footnote ?? "")
            }
            .frame(maxWidth: readableWidth)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// A comfortable reading measure — full-bleed on iPhone, capped so copy + button don't
    /// stretch across an iPad.
    private let readableWidth: CGFloat = 480
}

/// The primary action: the cloudberry-gold accent fill with a **dark** on-accent label (§1 — the
/// gold is light in both modes, so white-on-gold fails contrast; the label is `#1C1C1E`).
/// `.borderedProminent` forces a white label, so we style it explicitly. ≥44pt tall, full-width.
struct PrimaryActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(Color.onAccent)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(Color.accentColor, in: .capsule)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .contentShape(.capsule)
    }
}

// `Color.brandGreen` (Leaf green, brand/identity — styleguide §1) and `Color.onAccent` (the dark
// foreground for the light gold accent — §1) are the asset-catalog symbols Xcode generates from
// BrandGreen.colorset / OnAccent.colorset; no hand-written extension needed.
